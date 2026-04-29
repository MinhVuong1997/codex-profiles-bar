import Foundation
import Darwin

actor CodexModelProxyServer {
    typealias CredentialProvider = @Sendable () async throws -> ModelProxyCredential
    typealias RuntimeModelProvider = @Sendable () async throws -> ModelProxyRuntimeModel

    private var listenSocket: Int32 = -1
    private var acceptTask: Task<Void, Never>?

    func start(
        port: Int,
        upstreamBaseURL: URL,
        runtimeModelProvider: @escaping RuntimeModelProvider,
        credentialProvider: @escaping CredentialProvider
    ) throws -> URL {
        stop()

        let socket = try Self.makeLoopbackSocket(port: port)
        listenSocket = socket
        acceptTask = Task.detached(priority: .userInitiated) {
            await Self.acceptLoop(
                socket: socket,
                upstreamBaseURL: upstreamBaseURL,
                runtimeModelProvider: runtimeModelProvider,
                credentialProvider: credentialProvider
            )
        }

        guard let endpoint = URL(string: "http://127.0.0.1:\(port)/v1") else {
            throw CodexProfilesError.commandFailed("Could not build proxy endpoint URL.")
        }
        return endpoint
    }

    func stop() {
        acceptTask?.cancel()
        acceptTask = nil

        if listenSocket >= 0 {
            Darwin.shutdown(listenSocket, SHUT_RDWR)
            Darwin.close(listenSocket)
            listenSocket = -1
        }
    }

    deinit {
        if listenSocket >= 0 {
            Darwin.shutdown(listenSocket, SHUT_RDWR)
            Darwin.close(listenSocket)
        }
    }
}

private extension CodexModelProxyServer {
    static let requestCredentialBypassHeader = "X-Codex-Profiles-Bar-Use-Request-Credential"

    struct ProxyRequest {
        let method: String
        let target: String
        let headers: [(name: String, value: String)]
        let body: Data
    }

    enum ProxyError: LocalizedError {
        case clientDisconnected
        case message(String)

        var errorDescription: String? {
            switch self {
            case .clientDisconnected:
                "The client closed the proxy connection."
            case .message(let message):
                message
            }
        }
    }

    static let headerLimit = 64 * 1024
    static let bodyLimit = 100 * 1024 * 1024
    static let delimiter = Data([13, 10, 13, 10])

    static func makeLoopbackSocket(port: Int) throws -> Int32 {
        guard (1...65_535).contains(port) else {
            throw CodexProfilesError.commandFailed("Proxy port must be between 1 and 65535.")
        }

        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw CodexProfilesError.commandFailed("Could not create proxy socket: \(posixError()).")
        }

        guard configureNoSigPipe(on: socket) else {
            let message = posixError()
            Darwin.close(socket)
            throw CodexProfilesError.commandFailed("Could not configure proxy socket: \(message).")
        }

        var reuse: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let message = posixError()
            Darwin.close(socket)
            throw CodexProfilesError.commandFailed("Could not configure proxy socket: \(message).")
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(socket, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let message = posixError()
            Darwin.close(socket)
            throw CodexProfilesError.commandFailed("Could not bind proxy to 127.0.0.1:\(port): \(message).")
        }

        guard Darwin.listen(socket, SOMAXCONN) == 0 else {
            let message = posixError()
            Darwin.close(socket)
            throw CodexProfilesError.commandFailed("Could not start proxy listener: \(message).")
        }

        return socket
    }

    static func acceptLoop(
        socket: Int32,
        upstreamBaseURL: URL,
        runtimeModelProvider: @escaping RuntimeModelProvider,
        credentialProvider: @escaping CredentialProvider
    ) async {
        while !Task.isCancelled {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.accept(socket, sockaddrPointer, &length)
                }
            }

            guard client >= 0 else {
                if Task.isCancelled {
                    break
                }
                continue
            }

            guard configureNoSigPipe(on: client) else {
                Darwin.shutdown(client, SHUT_RDWR)
                Darwin.close(client)
                continue
            }

            Task.detached(priority: .userInitiated) {
                await handleClient(
                    socket: client,
                    upstreamBaseURL: upstreamBaseURL,
                    runtimeModelProvider: runtimeModelProvider,
                    credentialProvider: credentialProvider
                )
            }
        }
    }

    static func handleClient(
        socket: Int32,
        upstreamBaseURL: URL,
        runtimeModelProvider: @escaping RuntimeModelProvider,
        credentialProvider: @escaping CredentialProvider
    ) async {
        var request: ProxyRequest?
        var didHitUsageLimit = false

        defer {
            Darwin.shutdown(socket, SHUT_RDWR)
            Darwin.close(socket)
        }

        do {
            request = try readRequest(from: socket)
            guard let request else {
                throw ProxyError.message("Request payload was unavailable.")
            }

            if request.method.uppercased() == "OPTIONS" {
                try sendResponse(statusCode: 204, headers: corsHeaders(), body: Data(), to: socket)
                return
            }

            if isStatusTarget(request.target) {
                let credential = try await credentialProvider()
                try sendJSON(
                    statusCode: 200,
                    object: [
                        "ok": true,
                        "active_profile": credential.profileName,
                        "credential_kind": credential.kind.rawValue,
                        "endpoint": endpointString(from: request),
                        "upstream": upstreamBaseURL.absoluteString,
                    ],
                    to: socket
                )
                return
            }

            if isModelsListTarget(request.target) {
                let runtimeModel = try await runtimeModelProvider()
                try sendJSON(statusCode: 200, object: modelsListResponse(for: runtimeModel), to: socket)
                return
            }

            if let modelID = modelID(fromModelsTarget: request.target) {
                let runtimeModel = try await runtimeModelProvider()
                try sendJSON(statusCode: 200, object: modelResponse(for: runtimeModel, requestedID: modelID), to: socket)
                return
            }

            guard let upstreamURL = upstreamURL(for: request.target, baseURL: upstreamBaseURL) else {
                try sendJSON(statusCode: 400, object: ["error": "Invalid request target."], to: socket)
                return
            }

            let credential = try await credentialProvider()
            let (data, response) = try await URLSession.shared.data(for: upstreamRequest(
                from: request,
                upstreamURL: upstreamURL,
                credential: credential
            ))

            guard let httpResponse = response as? HTTPURLResponse else {
                try sendJSON(statusCode: 502, object: ["error": "Upstream returned a non-HTTP response."], to: socket)
                return
            }

            let body = normalizedResponseBody(
                data: data,
                request: request,
                response: httpResponse
            )
            didHitUsageLimit = responseIndicatesUsageLimit(statusCode: httpResponse.statusCode, body: body)

            try sendResponse(
                statusCode: httpResponse.statusCode,
                headers: responseHeaders(from: httpResponse, bodyLength: body.count),
                body: body,
                to: socket
            )
            if didHitUsageLimit {
                await MainActor.run {
                    NotificationCenter.default.post(name: .modelProxyDidHitUsageLimit, object: nil)
                }
            }
            await MainActor.run {
                NotificationCenter.default.post(name: .modelProxyDidCompleteRequest, object: nil)
            }
        } catch {
            if didHitUsageLimit {
                await MainActor.run {
                    NotificationCenter.default.post(name: .modelProxyDidHitUsageLimit, object: nil)
                }
            }
            if case ProxyError.clientDisconnected = error {
                return
            }
            try? sendJSON(statusCode: 502, object: ["error": error.localizedDescription], to: socket)
        }
    }

    static func readRequest(from socket: Int32) throws -> ProxyRequest {
        var buffer = Data()
        var headerRange: Range<Data.Index>?

        while headerRange == nil {
            let chunk = try receiveChunk(from: socket)
            if chunk.isEmpty {
                throw ProxyError.message("Client closed the connection before sending a request.")
            }
            buffer.append(chunk)
            if buffer.count > headerLimit {
                throw ProxyError.message("Request headers are too large.")
            }
            headerRange = buffer.range(of: delimiter)
        }

        guard let headerRange else {
            throw ProxyError.message("Request headers are incomplete.")
        }

        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw ProxyError.message("Request headers are not UTF-8.")
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw ProxyError.message("Request line is missing.")
        }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count == 3 else {
            throw ProxyError.message("Request line is invalid.")
        }

        let headers = parseHeaders(lines.dropFirst())
        if headerValue("Transfer-Encoding", in: headers)?.localizedCaseInsensitiveContains("chunked") == true {
            throw ProxyError.message("Chunked request bodies are not supported yet.")
        }

        let contentLength = try parsedContentLength(headers)
        if contentLength > bodyLimit {
            throw ProxyError.message("Request body is too large.")
        }

        let bodyStart = headerRange.upperBound
        var body = Data(buffer[bodyStart...])
        while body.count < contentLength {
            let chunk = try receiveChunk(from: socket)
            if chunk.isEmpty {
                throw ProxyError.message("Client closed the connection before sending the full body.")
            }
            body.append(chunk)
        }

        if body.count > contentLength {
            body = body.prefix(contentLength)
        }

        return ProxyRequest(
            method: requestParts[0],
            target: requestParts[1],
            headers: headers,
            body: body
        )
    }

    static func receiveChunk(from socket: Int32) throws -> Data {
        var storage = [UInt8](repeating: 0, count: 16 * 1024)
        let count = storage.withUnsafeMutableBytes { rawBuffer in
            Darwin.recv(socket, rawBuffer.baseAddress, rawBuffer.count, 0)
        }

        guard count >= 0 else {
            if isDisconnectedSocketError(errno) {
                throw ProxyError.clientDisconnected
            }
            throw ProxyError.message("Could not read request: \(posixError()).")
        }
        guard count > 0 else {
            return Data()
        }
        return Data(storage.prefix(count))
    }

    static func parseHeaders(_ lines: ArraySlice<String>) -> [(name: String, value: String)] {
        lines.compactMap { line in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return (name, value)
        }
    }

    static func parsedContentLength(_ headers: [(name: String, value: String)]) throws -> Int {
        guard let raw = headerValue("Content-Length", in: headers) else {
            return 0
        }
        guard let length = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), length >= 0 else {
            throw ProxyError.message("Content-Length is invalid.")
        }
        return length
    }

    static func responseIndicatesUsageLimit(statusCode: Int, body: Data) -> Bool {
        guard statusCode == 429 || statusCode == 403 else { return false }
        guard let message = String(data: body, encoding: .utf8)?
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) else {
            return statusCode == 429
        }

        let markers = [
            "you've hit your usage limit",
            "usage limit",
            "insufficient_quota",
            "quota",
            "rate_limit_exceeded"
        ]
        return markers.contains(where: { message.contains($0) })
    }

    static func upstreamRequest(
        from request: ProxyRequest,
        upstreamURL: URL,
        credential: ModelProxyCredential
    ) -> URLRequest {
        var output = URLRequest(url: upstreamURL)
        output.httpMethod = request.method
        if !request.body.isEmpty {
            output.httpBody = request.body
        }

        for header in request.headers where shouldForwardRequestHeader(header.name) {
            output.setValue(header.value, forHTTPHeaderField: header.name)
        }

        if wantsRequestCredentialBypass(request.headers) {
            if let authorization = headerValue("Authorization", in: request.headers) {
                output.setValue(authorization, forHTTPHeaderField: "Authorization")
            }
            if let accountID = headerValue("ChatGPT-Account-Id", in: request.headers) {
                output.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        } else {
            output.setValue(credential.authorizationValue, forHTTPHeaderField: "Authorization")
            if let accountID = credential.accountID {
                output.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        }
        if headerValue("User-Agent", in: request.headers) == nil {
            output.setValue("codex-profiles-bar-proxy", forHTTPHeaderField: "User-Agent")
        }
        return output
    }

    static func upstreamURL(for target: String, baseURL: URL) -> URL? {
        guard let components = requestComponents(for: target) else {
            return nil
        }

        var path = components.path
        let basePath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if basePath == "v1" {
            if path == "/v1" {
                path = ""
            } else if path.hasPrefix("/v1/") {
                path = String(path.dropFirst(3))
            }
        }

        if basePath == "backend-api" {
            if path == "/v1/responses" || path.hasPrefix("/v1/responses/") {
                path = "/codex" + String(path.dropFirst(3))
            } else if path == "/backend-api" {
                path = ""
            } else if path.hasPrefix("/backend-api/") {
                path = String(path.dropFirst("/backend-api".count))
            }
        }

        var urlString = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
        if let query = components.percentEncodedQuery, !query.isEmpty {
            urlString += "?\(query)"
        }
        return URL(string: urlString)
    }

    static func requestComponents(for target: String) -> URLComponents? {
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            return URLComponents(string: target)
        }

        let normalized = target.hasPrefix("/") ? target : "/\(target)"
        return URLComponents(string: "http://127.0.0.1\(normalized)")
    }

    static func isStatusTarget(_ target: String) -> Bool {
        requestComponents(for: target)?.path == "/__codex-profiles-bar/proxy/status"
    }

    static func endpointString(from request: ProxyRequest) -> String {
        guard let host = headerValue("Host", in: request.headers), !host.isEmpty else {
            return "http://127.0.0.1/v1"
        }
        return "http://\(host)/v1"
    }

    static func isModelsListTarget(_ target: String) -> Bool {
        requestComponents(for: target)?.path == "/v1/models"
    }

    static func modelID(fromModelsTarget target: String) -> String? {
        guard let path = requestComponents(for: target)?.path else {
            return nil
        }
        guard path.hasPrefix("/v1/models/") else {
            return nil
        }
        let suffix = String(path.dropFirst("/v1/models/".count))
        guard !suffix.isEmpty else {
            return nil
        }
        return suffix.removingPercentEncoding ?? suffix
    }

    static func modelsListResponse(for runtimeModel: ModelProxyRuntimeModel) -> [String: Any] {
        [
            "object": "list",
            "data": [modelResponse(for: runtimeModel)],
        ]
    }

    static func modelResponse(for runtimeModel: ModelProxyRuntimeModel, requestedID: String? = nil) -> [String: Any] {
        var response: [String: Any] = [
            "id": requestedID ?? runtimeModel.name,
            "object": "model",
            "owned_by": "codex-profiles-bar",
            "name": requestedID ?? runtimeModel.name,
            "slug": requestedID ?? runtimeModel.name,
            "display_name": requestedID ?? runtimeModel.name,
            "supported_in_api": true,
        ]

        let shouldAdvertiseConfiguredMetadata = requestedID == nil || requestedID == runtimeModel.name
        if shouldAdvertiseConfiguredMetadata {
            if let contextWindow = runtimeModel.contextWindow {
                response["context_window"] = contextWindow
            }
            if let autoCompactTokenLimit = runtimeModel.autoCompactTokenLimit {
                response["auto_compact_token_limit"] = autoCompactTokenLimit
            }
            if let contextWindow = runtimeModel.contextWindow {
                var preset: [String: Any] = [
                    "label": "Configured",
                    "context_window": contextWindow,
                    "description": "Configured in ~/.codex/config.toml",
                ]
                if let autoCompactTokenLimit = runtimeModel.autoCompactTokenLimit {
                    preset["auto_compact_token_limit"] = autoCompactTokenLimit
                }
                response["supported_context_window_presets"] = [preset]
            }
        }

        return response
    }

    static func normalizedResponseBody(
        data: Data,
        request: ProxyRequest,
        response: HTTPURLResponse
    ) -> Data {
        guard isResponsesTarget(request.target) else {
            return data
        }

        guard let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              contentType.contains("text/event-stream"),
              let text = String(data: data, encoding: .utf8) else {
            return data
        }

        let normalized = normalizeResponsesEventStream(text, requestBody: request.body)
        return Data(normalized.utf8)
    }

    static func isResponsesTarget(_ target: String) -> Bool {
        guard let path = requestComponents(for: target)?.path else {
            return false
        }
        return path == "/v1/responses"
            || path.hasPrefix("/v1/responses/")
            || path == "/backend-api/codex/responses"
            || path.hasPrefix("/backend-api/codex/responses/")
    }

    static func normalizeResponsesEventStream(_ text: String, requestBody: Data) -> String {
        let estimatedInputTokens = estimateInputTokens(fromRequestBody: requestBody)
        let lines = text.components(separatedBy: "\n")
        let normalizedLines = lines.map { rawLine -> String in
            let hasCarriageReturn = rawLine.hasSuffix("\r")
            let line = hasCarriageReturn ? String(rawLine.dropLast()) : rawLine
            guard line.hasPrefix("data: ") else {
                return rawLine
            }

            let payload = String(line.dropFirst(6))
            guard let normalizedPayload = normalizeCompletedEventPayload(
                payload,
                estimatedInputTokens: estimatedInputTokens
            ) else {
                return rawLine
            }

            let rebuilt = "data: \(normalizedPayload)"
            return hasCarriageReturn ? rebuilt + "\r" : rebuilt
        }
        return normalizedLines.joined(separator: "\n")
    }

    static func normalizeCompletedEventPayload(
        _ payload: String,
        estimatedInputTokens: Int?
    ) -> String? {
        guard payload != "[DONE]",
              let payloadData = payload.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: payloadData),
              var object = jsonObject as? [String: Any],
              (object["type"] as? String) == "response.completed",
              var response = object["response"] as? [String: Any] else {
            return nil
        }

        let estimatedOutputTokens = estimateOutputTokens(fromResponse: response)
        var usage = response["usage"] as? [String: Any] ?? [:]

        let inputTokens = normalizedUsageInt(usage["input_tokens"]) ?? estimatedInputTokens
        let outputTokens = normalizedUsageInt(usage["output_tokens"]) ?? estimatedOutputTokens
        let existingTotalTokens = normalizedUsageInt(usage["total_tokens"])

        if let inputTokens, inputTokens > 0 {
            usage["input_tokens"] = inputTokens
        }
        if let outputTokens, outputTokens > 0 {
            usage["output_tokens"] = outputTokens
        }
        let synthesizedTotalTokens = (inputTokens ?? 0) + (outputTokens ?? 0)
        let totalTokens = existingTotalTokens ?? (synthesizedTotalTokens > 0 ? synthesizedTotalTokens : nil)
        if let totalTokens, totalTokens > 0 {
            usage["total_tokens"] = max(totalTokens, synthesizedTotalTokens)
        }

        guard !usage.isEmpty else {
            return nil
        }

        response["usage"] = usage
        object["response"] = response

        guard let normalizedData = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return nil
        }
        return String(data: normalizedData, encoding: .utf8)
    }

    static func normalizedUsageInt(_ value: Any?) -> Int? {
        switch value {
        case let intValue as Int:
            return intValue > 0 ? intValue : nil
        case let number as NSNumber:
            let intValue = number.intValue
            return intValue > 0 ? intValue : nil
        case let string as String:
            guard let intValue = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)), intValue > 0 else {
                return nil
            }
            return intValue
        default:
            return nil
        }
    }

    static func estimateInputTokens(fromRequestBody requestBody: Data) -> Int? {
        guard !requestBody.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] else {
            return nil
        }

        var inputCharacterCount = 0
        for key in ["input", "instructions", "messages", "prompt", "content"] {
            if let value = object[key] {
                inputCharacterCount += extractedPromptCharacterCount(from: value)
            }
        }

        if inputCharacterCount == 0 {
            inputCharacterCount = extractedPromptCharacterCount(from: object)
        }

        guard inputCharacterCount > 0 else {
            return nil
        }
        return approximateTokenCount(characterCount: inputCharacterCount)
    }

    static func estimateOutputTokens(fromResponse response: [String: Any]) -> Int? {
        if let usage = response["usage"] as? [String: Any],
           let outputTokens = normalizedUsageInt(usage["output_tokens"]) {
            return outputTokens
        }

        var outputCharacterCount = 0
        if let output = response["output"] {
            outputCharacterCount += extractedOutputCharacterCount(from: output)
        }
        if outputCharacterCount == 0, let outputText = response["output_text"] {
            outputCharacterCount += extractedOutputCharacterCount(from: outputText)
        }
        if outputCharacterCount == 0, let content = response["content"] {
            outputCharacterCount += extractedOutputCharacterCount(from: content)
        }
        guard outputCharacterCount > 0 else {
            return nil
        }
        return approximateTokenCount(characterCount: outputCharacterCount)
    }

    static func estimateOutputTokens(fromEventStreamText text: String) -> Int? {
        var outputCharacterCount = 0

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data: ") else { continue }
            let payload = String(trimmed.dropFirst(6))
            guard payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let eventType = object["type"] as? String ?? ""
            if eventType.contains("output_text.delta"), let delta = object["delta"] {
                outputCharacterCount += extractedOutputCharacterCount(from: delta)
                continue
            }
            if eventType.contains("output_item"), let item = object["item"] {
                outputCharacterCount += extractedOutputCharacterCount(from: item)
                continue
            }
            if let outputText = object["output_text"] {
                outputCharacterCount += extractedOutputCharacterCount(from: outputText)
                continue
            }
            if let content = object["content"] {
                outputCharacterCount += extractedOutputCharacterCount(from: content)
            }
        }

        guard outputCharacterCount > 0 else {
            return nil
        }
        return approximateTokenCount(characterCount: outputCharacterCount)
    }

    static func extractedPromptCharacterCount(from value: Any) -> Int {
        switch value {
        case let string as String:
            return string.count
        case let array as [Any]:
            return array.reduce(0) { $0 + extractedPromptCharacterCount(from: $1) }
        case let dictionary as [String: Any]:
            if let type = dictionary["type"] as? String,
               type.localizedCaseInsensitiveContains("image") || type.localizedCaseInsensitiveContains("audio") {
                return 0
            }

            var count = 0
            for (key, nestedValue) in dictionary {
                let loweredKey = key.lowercased()
                if ["id", "type", "role", "model", "status", "call_id", "tool_name", "name", "index", "metadata", "schema", "json_schema", "headers", "url"].contains(loweredKey) {
                    continue
                }
                if ["input", "instructions", "messages", "prompt", "content", "text", "message", "summary", "description", "arguments"].contains(loweredKey) || nestedValue is [Any] || nestedValue is [String: Any] {
                    count += extractedPromptCharacterCount(from: nestedValue)
                }
            }
            return count
        default:
            return 0
        }
    }

    static func extractedOutputCharacterCount(from value: Any) -> Int {
        switch value {
        case let string as String:
            return string.count
        case let array as [Any]:
            return array.reduce(0) { $0 + extractedOutputCharacterCount(from: $1) }
        case let dictionary as [String: Any]:
            var count = 0
            for (key, nestedValue) in dictionary {
                let loweredKey = key.lowercased()
                if ["text", "delta", "output_text", "content", "summary"].contains(loweredKey) || nestedValue is [Any] || nestedValue is [String: Any] {
                    count += extractedOutputCharacterCount(from: nestedValue)
                }
            }
            return count
        default:
            return 0
        }
    }

    static func extractedCharacterCount(from value: Any) -> Int {
        switch value {
        case let string as String:
            return string.count
        case let array as [Any]:
            return array.reduce(0) { $0 + extractedCharacterCount(from: $1) }
        case let dictionary as [String: Any]:
            return dictionary.values.reduce(0) { $0 + extractedCharacterCount(from: $1) }
        default:
            return 0
        }
    }

    static func approximateTokenCount(characterCount: Int) -> Int? {
        guard characterCount > 0 else {
            return nil
        }
        return max(1, Int(ceil(Double(characterCount) / 4.0)))
    }

    static func shouldForwardRequestHeader(_ name: String) -> Bool {
        let blocked = [
            "authorization",
            "connection",
            "content-length",
            "host",
            "keep-alive",
            "proxy-authenticate",
            "proxy-authorization",
            "te",
            "trailer",
            "transfer-encoding",
            "upgrade",
            requestCredentialBypassHeader.lowercased(),
        ]
        return !blocked.contains(name.lowercased())
    }

    static func wantsRequestCredentialBypass(_ headers: [(name: String, value: String)]) -> Bool {
        guard let value = headerValue(requestCredentialBypassHeader, in: headers)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return value == "1" || value == "true" || value == "yes"
    }

    static func responseHeaders(from response: HTTPURLResponse, bodyLength: Int) -> [(String, String)] {
        var headers = [(String, String)]()
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, shouldForwardResponseHeader(name) else { continue }
            headers.append((name, "\(value)"))
        }
        headers.append(("Content-Length", "\(bodyLength)"))
        return headers + corsHeaders()
    }

    static func shouldForwardResponseHeader(_ name: String) -> Bool {
        let blocked = [
            "connection",
            "content-encoding",
            "content-length",
            "content-md5",
            "etag",
            "keep-alive",
            "proxy-authenticate",
            "proxy-authorization",
            "te",
            "trailer",
            "transfer-encoding",
            "upgrade",
        ]
        return !blocked.contains(name.lowercased())
    }

    static func corsHeaders() -> [(String, String)] {
        [
            ("Access-Control-Allow-Origin", "*"),
            ("Access-Control-Allow-Headers", "authorization, content-type, openai-organization, openai-project"),
            ("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS"),
            ("Connection", "close"),
            ("X-Codex-Profiles-Bar-Proxy", "1"),
        ]
    }

    static func headerValue(_ name: String, in headers: [(name: String, value: String)]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func sendJSON(statusCode: Int, object: [String: Any], to socket: Int32) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try sendResponse(
            statusCode: statusCode,
            headers: [("Content-Type", "application/json; charset=utf-8"), ("Content-Length", "\(data.count)")] + corsHeaders(),
            body: data,
            to: socket
        )
    }

    static func sendResponse(
        statusCode: Int,
        headers: [(String, String)],
        body: Data,
        to socket: Int32
    ) throws {
        var response = "HTTP/1.1 \(statusCode) \(reasonPhrase(for: statusCode))\r\n"
        for (name, value) in headers {
            response += "\(name): \(value)\r\n"
        }
        response += "\r\n"

        try sendAll(Data(response.utf8), to: socket)
        if !body.isEmpty {
            try sendAll(body, to: socket)
        }
    }

    static func sendAll(_ data: Data, to socket: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let result = Darwin.send(socket, baseAddress.advanced(by: sent), data.count - sent, 0)
                guard result > 0 else {
                    if isDisconnectedSocketError(errno) {
                        throw ProxyError.clientDisconnected
                    }
                    throw ProxyError.message("Could not write response: \(posixError()).")
                }
                sent += result
            }
        }
    }

    static func configureNoSigPipe(on socket: Int32) -> Bool {
        var enabled: Int32 = 1
        return setsockopt(
            socket,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0
    }

    static func isDisconnectedSocketError(_ code: Int32) -> Bool {
        [EPIPE, ECONNRESET, ENOTCONN].contains(code)
    }

    static func reasonPhrase(for statusCode: Int) -> String {
        HTTPURLResponse.localizedString(forStatusCode: statusCode)
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    static func posixError() -> String {
        String(cString: strerror(errno))
    }
}
