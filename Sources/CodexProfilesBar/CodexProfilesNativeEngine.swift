import Foundation
import Darwin

actor CodexProfilesNativeEngine {
    private let fileManager = FileManager.default
    private let session: URLSession

    private let refreshTokenURL = "https://auth.openai.com/oauth/token"
    private let refreshClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let usageUserAgent = "codex-profiles-bar"
    private let usageRetryAttempts = 3
    private let lockTimeout: TimeInterval = 10
    private let lockRetryDelayMicros: useconds_t = 200_000

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        session = URLSession(configuration: configuration)
    }

    nonisolated func resolveStorage() -> StorageResolution {
        let fileManager = FileManager.default
        let homeDirectory: URL
        if let override = ProcessInfo.processInfo.environment["CODEX_PROFILES_HOME"], !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            homeDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            homeDirectory = fileManager.homeDirectoryForCurrentUser
        }
        let path = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        return StorageResolution(url: path, source: "built-in engine")
    }

    func fetchProfiles() async throws -> [ProfileStatus] {
        let paths = try resolvePaths()
        try ensurePaths(paths)

        let snapshot = try loadSnapshot(paths: paths, strictLabels: false)
        let currentSavedID = currentSavedID(paths: paths, tokensByID: snapshot.tokensByID)
        let orderedIDs = orderedProfileIDs(snapshot: snapshot, currentSavedID: currentSavedID)
            .filter { $0 != currentSavedID }

        async let currentProfile = buildCurrentProfile(paths: paths, snapshot: snapshot, currentSavedID: currentSavedID)
        async let savedProfiles = buildSavedProfiles(ids: orderedIDs, paths: paths, snapshot: snapshot, currentSavedID: currentSavedID)

        var profiles = [ProfileStatus]()
        if let current = await currentProfile {
            profiles.append(current)
        }
        profiles.append(contentsOf: await savedProfiles)
        return profiles
    }

    func fetchActiveProfile() async throws -> ProfileStatus {
        let paths = try resolvePaths()
        try ensurePaths(paths)

        let snapshot = try loadSnapshot(paths: paths, strictLabels: false)
        let currentSavedID = currentSavedID(paths: paths, tokensByID: snapshot.tokensByID)
        guard let current = await buildCurrentProfile(paths: paths, snapshot: snapshot, currentSavedID: currentSavedID) else {
            throw CodexProfilesError.commandFailed("No active Codex profile is available.")
        }
        return current
    }

    func saveCurrent(label: String?) async throws {
        let paths = try resolvePaths()
        try ensurePaths(paths)

        try withProfilesLock(paths) {
            var store = try loadStore(paths: paths)
            let tokens = try readTokens(at: paths.auth)
            let id = try resolveSaveID(paths: paths, index: &store.index, tokens: tokens)

            if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try assignLabel(&store.labels, label: label, id: id)
            }

            let target = profilePath(for: id, in: paths.profiles)
            try copyAtomicPrivate(from: paths.auth, to: target)

            let appliedLabel = labelForID(store.labels, id: id)
            updateIndexEntry(&store.index, id: id, tokens: tokens, label: appliedLabel)
            try saveStore(store, paths: paths)
        }
    }

    func loadProfile(id: String, mode: SwitchMode) async throws {
        let paths = try resolvePaths()
        try ensurePaths(paths)

        if mode == .saveThenSwitch {
            try await saveCurrent(label: nil)
        }

        try withProfilesLock(paths) {
            var index = try readProfilesIndexRelaxed(paths)
            try syncCurrent(paths: paths, index: &index)

            let source = profilePath(for: id, in: paths.profiles)
            guard fileManager.fileExists(atPath: source.path) else {
                throw CodexProfilesError.commandFailed("Saved profile `\(id)` was not found.")
            }

            try copyAtomicPrivate(from: source, to: paths.auth)
            let label = labelForID(labelsFromIndex(index), id: id)
            if let tokens = try? readTokens(at: source) {
                updateIndexEntry(&index, id: id, tokens: tokens, label: label)
            }
            try writeProfilesIndex(index, paths: paths)
        }
    }

    func setLabel(id: String, label: String) async throws {
        let paths = try resolvePaths()
        try ensurePaths(paths)

        try withProfilesLock(paths) {
            var store = try loadStore(paths: paths)
            guard store.index.profiles[id] != nil || fileManager.fileExists(atPath: profilePath(for: id, in: paths.profiles).path) else {
                throw CodexProfilesError.commandFailed("Saved profile `\(id)` was not found.")
            }
            try assignLabel(&store.labels, label: label, id: id)
            try saveStore(store, paths: paths)
        }
    }

    func renameLabel(from current: String, to next: String) async throws {
        let paths = try resolvePaths()
        try ensurePaths(paths)

        try withProfilesLock(paths) {
            var store = try loadStore(paths: paths)
            let id = try resolveLabelID(store.labels, label: current)
            try assignLabel(&store.labels, label: next, id: id)
            try saveStore(store, paths: paths)
        }
    }

    func clearLabel(id: String) async throws {
        let paths = try resolvePaths()
        try ensurePaths(paths)

        try withProfilesLock(paths) {
            var store = try loadStore(paths: paths)
            removeLabels(for: id, labels: &store.labels)
            try saveStore(store, paths: paths)
        }
    }

    func exportProfiles(ids: [String], to destination: URL) async throws -> ExportPayload {
        let paths = try resolvePaths()
        try ensurePaths(paths)

        let payload: ExportPayload = try withProfilesLock(paths) {
            let store = try loadStore(paths: paths)
            let existingIDs = try collectProfileIDs(in: paths.profiles)

            let resolvedIDs: [String]
            if ids.isEmpty {
                resolvedIDs = existingIDs.sorted()
            } else {
                var seen = Set<String>()
                resolvedIDs = ids.filter { seen.insert($0).inserted }
                for id in resolvedIDs where !existingIDs.contains(id) {
                    throw CodexProfilesError.commandFailed("Saved profile `\(id)` was not found.")
                }
            }

            let profiles = try resolvedIDs.map { id -> NativeExportedProfile in
                let path = profilePath(for: id, in: paths.profiles)
                let data = try Data(contentsOf: path)
                let contents = try JSONSerialization.jsonObject(with: data)
                guard let json = contents as? [String: Any] else {
                    throw CodexProfilesError.commandFailed("Saved profile `\(id)` is invalid JSON.")
                }
                return NativeExportedProfile(
                    id: id,
                    label: labelForID(store.labels, id: id),
                    contents: json.mapValues(JSONValue.init)
                )
            }

            let bundle = NativeExportBundle(version: 1, profiles: profiles)
            let data = try encoder(pretty: true).encode(bundle)
            try writeAtomicPrivate(data: data.appendingNewline(), to: destination)
            try setPOSIXPermissions(path: destination.path, mode: 0o600)
            return ExportPayload(path: destination.path, count: profiles.count)
        }

        return payload
    }

    func previewImport(from source: URL) async throws -> ImportPreviewPayload {
        let paths = try resolvePaths()
        try ensurePaths(paths)

        let bundle = try loadImportBundle(from: source)
        return try withProfilesLock(paths) {
            let store = try loadStore(paths: paths)
            let existingIDs = try collectProfileIDs(in: paths.profiles)
            return try analyzeImport(bundle: bundle, store: store, existingIDs: existingIDs).preview
        }
    }

    func importProfiles(from source: URL) async throws -> ImportPayload {
        let paths = try resolvePaths()
        try ensurePaths(paths)

        let bundle = try loadImportBundle(from: source)

        return try withProfilesLock(paths) {
            var store = try loadStore(paths: paths)
            let existingIDs = try collectProfileIDs(in: paths.profiles)
            let analysis = try analyzeImport(bundle: bundle, store: store, existingIDs: existingIDs)
            let prepared = analysis.prepared
            guard !prepared.isEmpty else {
                throw CodexProfilesError.commandFailed("No new profiles are available to import from this file.")
            }

            var writtenIDs = [String]()
            do {
                for profile in prepared {
                    let path = profilePath(for: profile.id, in: paths.profiles)
                    try writeAtomicPrivate(data: profile.contents, to: path)
                    writtenIDs.append(profile.id)
                }
            } catch {
                for id in writtenIDs {
                    try? fileManager.removeItem(at: profilePath(for: id, in: paths.profiles))
                }
                throw error
            }

            store.labels = analysis.labels
            for profile in prepared {
                updateIndexEntry(&store.index, id: profile.id, tokens: profile.tokens, label: profile.label)
            }
            try saveStore(store, paths: paths)

            let imported = prepared.map { ImportedProfilePayload(id: $0.id, label: $0.label) }
            return ImportPayload(count: imported.count, profiles: imported)
        }
    }

    private func loadImportBundle(from source: URL) throws -> NativeExportBundle {
        let hasSecurityScope = source.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                source.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: source)
        let bundle = try JSONDecoder().decode(NativeExportBundle.self, from: data)
        guard bundle.version == 1 else {
            throw CodexProfilesError.commandFailed("Import file version \(bundle.version) is not supported.")
        }
        return bundle
    }

    private func analyzeImport(bundle: NativeExportBundle, store: NativeStore, existingIDs: Set<String>) throws -> ImportAnalysis {
        var stagedLabels = store.labels
        var seen = Set<String>()
        var prepared = [PreparedImportProfile]()
        var previewProfiles = [ImportPreviewProfilePayload]()
        var existingCount = 0
        var duplicateCount = 0
        var conflictCount = 0
        var invalidCount = 0

        for profile in bundle.profiles {
            let trimmedLabel = profile.label?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard seen.insert(profile.id).inserted else {
                duplicateCount += 1
                previewProfiles.append(
                    ImportPreviewProfilePayload(
                        id: profile.id,
                        label: trimmedLabel,
                        email: nil,
                        plan: nil,
                        disposition: .duplicate,
                        reason: "Duplicate profile id in the selected file."
                    )
                )
                continue
            }

            do {
                try validateImportProfileID(profile.id)
            } catch {
                invalidCount += 1
                previewProfiles.append(
                    ImportPreviewProfilePayload(
                        id: profile.id,
                        label: trimmedLabel,
                        email: nil,
                        plan: nil,
                        disposition: .invalid,
                        reason: error.localizedDescription
                    )
                )
                continue
            }

            guard !existingIDs.contains(profile.id) else {
                existingCount += 1
                previewProfiles.append(
                    ImportPreviewProfilePayload(
                        id: profile.id,
                        label: trimmedLabel,
                        email: nil,
                        plan: nil,
                        disposition: .existing,
                        reason: "This profile is already saved locally."
                    )
                )
                continue
            }

            let preparedProfile: PreparedImportProfile
            do {
                preparedProfile = try prepareImportProfile(profile)
            } catch {
                invalidCount += 1
                previewProfiles.append(
                    ImportPreviewProfilePayload(
                        id: profile.id,
                        label: trimmedLabel,
                        email: nil,
                        plan: nil,
                        disposition: .invalid,
                        reason: error.localizedDescription
                    )
                )
                continue
            }

            let (email, plan) = extractEmailAndPlan(from: preparedProfile.tokens)
            if let label = preparedProfile.label, !label.isEmpty {
                do {
                    try assignLabel(&stagedLabels, label: label, id: preparedProfile.id)
                } catch {
                    let message = error.localizedDescription
                    let isConflict = message.localizedCaseInsensitiveContains("already assigned")
                    if isConflict {
                        conflictCount += 1
                    } else {
                        invalidCount += 1
                    }
                    previewProfiles.append(
                        ImportPreviewProfilePayload(
                            id: preparedProfile.id,
                            label: preparedProfile.label,
                            email: email,
                            plan: plan,
                            disposition: isConflict ? .conflict : .invalid,
                            reason: message
                        )
                    )
                    continue
                }
            }

            prepared.append(preparedProfile)
            previewProfiles.append(
                ImportPreviewProfilePayload(
                    id: preparedProfile.id,
                    label: preparedProfile.label,
                    email: email,
                    plan: plan,
                    disposition: .ready,
                    reason: nil
                )
            )
        }

        return ImportAnalysis(
            prepared: prepared,
            labels: stagedLabels,
            preview: ImportPreviewPayload(
                totalCount: bundle.profiles.count,
                importableCount: prepared.count,
                existingCount: existingCount,
                duplicateCount: duplicateCount,
                conflictCount: conflictCount,
                invalidCount: invalidCount,
                profiles: previewProfiles
            )
        )
    }

    func deleteProfile(id: String) async throws {
        let paths = try resolvePaths()
        try ensurePaths(paths)

        try withProfilesLock(paths) {
            var store = try loadStore(paths: paths)
            let target = profilePath(for: id, in: paths.profiles)
            guard fileManager.fileExists(atPath: target.path) else {
                throw CodexProfilesError.commandFailed("Saved profile `\(id)` was not found.")
            }
            try fileManager.removeItem(at: target)
            removeLabels(for: id, labels: &store.labels)
            store.index.profiles.removeValue(forKey: id)
            try saveStore(store, paths: paths)
        }
    }

    func doctor(fix: Bool) async throws -> DoctorReport {
        let paths = try resolvePaths()
        var repairs: [String]? = nil

        if fix {
            repairs = try repair(paths: paths)
        }

        let checks = try collectDoctorChecks(paths: paths)
        let summary = summarizeDoctorChecks(checks)
        return DoctorReport(checks: checks, summary: summary, repairs: repairs, error: nil)
    }
}

private extension CodexProfilesNativeEngine {
    struct NativePaths {
        let codex: URL
        let auth: URL
        let profiles: URL
        let profilesIndex: URL
        let profilesLock: URL
        let config: URL
    }

    struct NativeSnapshot {
        var labels: [String: String]
        var tokensByID: [String: TokenLoadResult]
        var index: NativeProfilesIndex
    }

    struct NativeStore {
        var labels: [String: String]
        var index: NativeProfilesIndex
    }

    struct NativeProfilesIndex: Codable {
        var version: Int = 3
        var profiles: [String: NativeProfileIndexEntry] = [:]
    }

    struct NativeProfileIndexEntry: Codable {
        var accountID: String?
        var email: String?
        var plan: String?
        var label: String?
        var isAPIKey: Bool?
        var principalID: String?
        var workspaceOrOrgID: String?
        var planTypeKey: String?

        enum CodingKeys: String, CodingKey {
            case accountID = "account_id"
            case email
            case plan
            case label
            case isAPIKey = "is_api_key"
            case principalID = "principal_id"
            case workspaceOrOrgID = "workspace_or_org_id"
            case planTypeKey = "plan_type_key"
        }
    }

    struct NativeAuthFile: Codable {
        var openAIAPIKey: String?
        var tokens: NativeTokens?
        var lastRefresh: String?

        enum CodingKeys: String, CodingKey {
            case openAIAPIKey = "OPENAI_API_KEY"
            case tokens
            case lastRefresh = "last_refresh"
        }
    }

    struct NativeTokens: Codable, Hashable {
        var accountID: String?
        var idToken: String?
        var accessToken: String?
        var refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accountID = "account_id"
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    struct NativeProfileIdentityKey: Equatable {
        let principalID: String
        let workspaceOrOrgID: String
        let planType: String
    }

    struct NativeIDTokenClaims: Decodable {
        let sub: String?
        let email: String?
        let organizationID: String?
        let projectID: String?
        let auth: NativeAuthClaims?

        enum CodingKeys: String, CodingKey {
            case sub
            case email
            case organizationID = "organization_id"
            case projectID = "project_id"
            case auth = "https://api.openai.com/auth"
        }
    }

    struct NativeAuthClaims: Decodable {
        let chatgptPlanType: String?
        let chatgptUserID: String?
        let userID: String?
        let chatgptAccountID: String?

        enum CodingKeys: String, CodingKey {
            case chatgptPlanType = "chatgpt_plan_type"
            case chatgptUserID = "chatgpt_user_id"
            case userID = "user_id"
            case chatgptAccountID = "chatgpt_account_id"
        }
    }

    struct NativeExportBundle: Codable {
        let version: Int
        let profiles: [NativeExportedProfile]
    }

    struct NativeExportedProfile: Codable {
        let id: String
        let label: String?
        let contents: [String: JSONValue]
    }

    struct PreparedImportProfile {
        let id: String
        let label: String?
        let contents: Data
        let tokens: NativeTokens
    }

    struct ImportAnalysis {
        let prepared: [PreparedImportProfile]
        let labels: [String: String]
        let preview: ImportPreviewPayload
    }

    enum TokenLoadResult {
        case success(NativeTokens)
        case failure(String)
    }

    struct NativeRefreshRequest: Encodable {
        let clientID: String
        let grantType = "refresh_token"
        let refreshToken: String
        let scope = "openid profile email"

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case grantType = "grant_type"
            case refreshToken = "refresh_token"
            case scope
        }
    }

    struct NativeRefreshResponse: Decodable {
        let idToken: String?
        let accessToken: String?
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    struct UsagePayload: Decodable {
        let rateLimit: RateLimitDetails?
        let additionalRateLimits: [AdditionalRateLimitDetails]?

        enum CodingKeys: String, CodingKey {
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
        }
    }

    struct RateLimitDetails: Decodable {
        let primaryWindow: RateLimitWindowSnapshot?
        let secondaryWindow: RateLimitWindowSnapshot?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct AdditionalRateLimitDetails: Decodable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: RateLimitDetails?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }
    }

    struct RateLimitWindowSnapshot: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Int
        let resetAt: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
        }
    }

    struct UsageBucketSource {
        let id: String
        let label: String
        let rateLimit: RateLimitDetails?
    }

    struct UsageFetchError: LocalizedError {
        let statusCode: Int?
        let summary: String
        let detail: String?

        var errorDescription: String? {
            if let detail, !detail.isEmpty {
                return "\(summary)\n\(detail)"
            }
            return summary
        }
    }

    enum DoctorLevel: String {
        case ok
        case warn
        case error
        case info
    }

    struct JSONValue: Codable {
        let rawValue: Any

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                rawValue = NSNull()
            } else if let value = try? container.decode(Bool.self) {
                rawValue = value
            } else if let value = try? container.decode(Int.self) {
                rawValue = value
            } else if let value = try? container.decode(Double.self) {
                rawValue = value
            } else if let value = try? container.decode(String.self) {
                rawValue = value
            } else if let value = try? container.decode([String: JSONValue].self) {
                rawValue = value.mapValues(\.rawValue)
            } else if let value = try? container.decode([JSONValue].self) {
                rawValue = value.map(\.rawValue)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch rawValue {
            case is NSNull:
                try container.encodeNil()
            case let value as Bool:
                try container.encode(value)
            case let value as Int:
                try container.encode(value)
            case let value as Double:
                try container.encode(value)
            case let value as String:
                try container.encode(value)
            case let value as [String: Any]:
                try container.encode(value.mapValues(JSONValue.init))
            case let value as [Any]:
                try container.encode(value.map(JSONValue.init))
            default:
                throw EncodingError.invalidValue(rawValue, EncodingError.Context(codingPath: container.codingPath, debugDescription: "Unsupported JSON value"))
            }
        }

        init(_ rawValue: Any) {
            self.rawValue = rawValue
        }
    }

    func resolvePaths() throws -> NativePaths {
        let homeDirectory: URL
        if let override = ProcessInfo.processInfo.environment["CODEX_PROFILES_HOME"], !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            homeDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            homeDirectory = fileManager.homeDirectoryForCurrentUser
        }

        let codex = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let profiles = codex.appendingPathComponent("profiles", isDirectory: true)
        return NativePaths(
            codex: codex,
            auth: codex.appendingPathComponent("auth.json"),
            profiles: profiles,
            profilesIndex: profiles.appendingPathComponent("profiles.json"),
            profilesLock: profiles.appendingPathComponent("profiles.lock"),
            config: codex.appendingPathComponent("config.toml")
        )
    }

    func ensurePaths(_ paths: NativePaths) throws {
        if fileManager.fileExists(atPath: paths.profiles.path), !isDirectory(paths.profiles) {
            throw CodexProfilesError.commandFailed("Profiles storage exists but is not a directory.")
        }

        try fileManager.createDirectory(at: paths.profiles, withIntermediateDirectories: true)
        try setPOSIXPermissions(path: paths.profiles.path, mode: 0o700)

        try ensureFileOrAbsent(paths.profilesIndex)
        try ensureFileOrAbsent(paths.profilesLock)
    }

    func ensureFileOrAbsent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            guard !isDirectory(url) else {
                throw CodexProfilesError.commandFailed("\(url.lastPathComponent) exists but is not a file.")
            }
            return
        }
        fileManager.createFile(atPath: url.path, contents: Data())
        try setPOSIXPermissions(path: url.path, mode: 0o600)
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }

    func withProfilesLock<T>(_ paths: NativePaths, operation: () throws -> T) throws -> T {
        try ensurePaths(paths)

        let fileDescriptor = open(paths.profilesLock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw CodexProfilesError.commandFailed("Could not open profiles lock file.")
        }

        defer { close(fileDescriptor) }

        let deadline = Date().addingTimeInterval(lockTimeout)
        while flock(fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK {
                throw CodexProfilesError.commandFailed("Could not acquire profiles lock.")
            }
            if Date() >= deadline {
                throw CodexProfilesError.commandFailed("Timed out while waiting for the profiles lock.")
            }
            usleep(lockRetryDelayMicros)
        }

        defer { flock(fileDescriptor, LOCK_UN) }
        return try operation()
    }

    func loadSnapshot(paths: NativePaths, strictLabels: Bool) throws -> NativeSnapshot {
        try withProfilesLock(paths) {
            let tokensByID = try loadProfileTokensMap(paths: paths)
            let ids = Set(tokensByID.keys)
            var index = strictLabels ? try readProfilesIndex(paths) : (try readProfilesIndexRelaxed(paths))
            try pruneProfilesIndex(&index, profilesDirectory: paths.profiles)
            for id in ids {
                if index.profiles[id] == nil {
                    index.profiles[id] = NativeProfileIndexEntry()
                }
            }
            return NativeSnapshot(
                labels: labelsFromIndex(index),
                tokensByID: tokensByID,
                index: index
            )
        }
    }

    func loadStore(paths: NativePaths) throws -> NativeStore {
        var index = try readProfilesIndexRelaxed(paths)
        try pruneProfilesIndex(&index, profilesDirectory: paths.profiles)
        for id in try collectProfileIDs(in: paths.profiles) {
            if index.profiles[id] == nil {
                index.profiles[id] = NativeProfileIndexEntry()
            }
        }
        return NativeStore(labels: labelsFromIndex(index), index: index)
    }

    func saveStore(_ store: NativeStore, paths: NativePaths) throws {
        var store = store
        pruneLabels(&store.labels, profilesDirectory: paths.profiles)
        try pruneProfilesIndex(&store.index, profilesDirectory: paths.profiles)
        syncProfilesIndex(&store.index, labels: store.labels)
        try writeProfilesIndex(store.index, paths: paths)
    }

    func readProfilesIndex(_ paths: NativePaths) throws -> NativeProfilesIndex {
        guard fileManager.fileExists(atPath: paths.profilesIndex.path) else {
            return NativeProfilesIndex()
        }
        let data = try Data(contentsOf: paths.profilesIndex)
        if data.isEmpty {
            return NativeProfilesIndex()
        }
        do {
            var index = try JSONDecoder().decode(NativeProfilesIndex.self, from: data)
            if index.version < 3 {
                index.version = 3
            }
            return index
        } catch {
            throw CodexProfilesError.commandFailed("Profiles index is not valid JSON.")
        }
    }

    func readProfilesIndexRelaxed(_ paths: NativePaths) throws -> NativeProfilesIndex {
        (try? readProfilesIndex(paths)) ?? NativeProfilesIndex()
    }

    func writeProfilesIndex(_ index: NativeProfilesIndex, paths: NativePaths) throws {
        let data = try encoder(pretty: true).encode(index)
        try writeAtomicPrivate(data: data.appendingNewline(), to: paths.profilesIndex)
    }

    func loadProfileTokensMap(paths: NativePaths) throws -> [String: TokenLoadResult] {
        var map = [String: TokenLoadResult]()
        for path in try profileFiles(in: paths.profiles) {
            guard let id = profileID(from: path) else { continue }
            do {
                map[id] = .success(try readTokens(at: path))
            } catch {
                map[id] = .failure(error.localizedDescription)
            }
        }
        return map
    }

    func profileFiles(in profilesDirectory: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: profilesDirectory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: profilesDirectory, includingPropertiesForKeys: nil)
            .filter { isProfileFile($0) }
    }

    func isProfileFile(_ url: URL) -> Bool {
        guard url.pathExtension == "json" else { return false }
        let reservedFilenames: Set<String> = [
            "profiles.json",
            "update.json",
            "usage-history.json",
            "profiles-bar-usage-history.json"
        ]
        return !reservedFilenames.contains(url.lastPathComponent) && !url.lastPathComponent.hasPrefix(".")
    }

    func profileID(from url: URL) -> String? {
        let id = url.deletingPathExtension().lastPathComponent
        return id.isEmpty ? nil : id
    }

    func profilePath(for id: String, in profilesDirectory: URL) -> URL {
        profilesDirectory.appendingPathComponent("\(id).json")
    }

    func collectProfileIDs(in profilesDirectory: URL) throws -> Set<String> {
        Set(try profileFiles(in: profilesDirectory).compactMap(profileID(from:)))
    }

    func labelsFromIndex(_ index: NativeProfilesIndex) -> [String: String] {
        var labels = [String: String]()
        for (id, entry) in index.profiles {
            guard let label = entry.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { continue }
            if labels[label] == nil {
                labels[label] = id
            }
        }
        return labels
    }

    func labelForID(_ labels: [String: String], id: String) -> String? {
        labels.first(where: { $0.value == id })?.key
    }

    func resolveLabelID(_ labels: [String: String], label: String) throws -> String {
        let trimmed = try trimLabel(label)
        if let id = labels[trimmed] {
            return id
        }
        throw CodexProfilesError.commandFailed("Label `\(trimmed)` was not found.")
    }

    func trimLabel(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CodexProfilesError.commandFailed("Label cannot be empty.")
        }
        return trimmed
    }

    func assignLabel(_ labels: inout [String: String], label: String, id: String) throws {
        let trimmed = try trimLabel(label)
        if let existing = labels[trimmed], existing != id {
            throw CodexProfilesError.commandFailed("Label `\(trimmed)` is already assigned to another profile.")
        }
        removeLabels(for: id, labels: &labels)
        labels[trimmed] = id
    }

    func removeLabels(for id: String, labels: inout [String: String]) {
        labels = labels.filter { $0.value != id }
    }

    func pruneLabels(_ labels: inout [String: String], profilesDirectory: URL) {
        labels = labels.filter { fileManager.fileExists(atPath: profilePath(for: $0.value, in: profilesDirectory).path) }
    }

    func pruneProfilesIndex(_ index: inout NativeProfilesIndex, profilesDirectory: URL) throws {
        let ids = try collectProfileIDs(in: profilesDirectory)
        index.profiles = index.profiles.filter { ids.contains($0.key) }
    }

    func syncProfilesIndex(_ index: inout NativeProfilesIndex, labels: [String: String]) {
        for id in index.profiles.keys {
            index.profiles[id]?.label = labelForID(labels, id: id)
        }
    }

    func updateIndexEntry(_ index: inout NativeProfilesIndex, id: String, tokens: NativeTokens, label: String?) {
        var entry = index.profiles[id] ?? NativeProfileIndexEntry()
        let (email, plan) = extractEmailAndPlan(from: tokens)
        entry.email = email
        entry.plan = plan
        entry.accountID = tokenAccountID(tokens)
        entry.isAPIKey = isAPIKeyProfile(tokens)
        if let identity = extractProfileIdentity(from: tokens) {
            entry.principalID = identity.principalID
            entry.workspaceOrOrgID = identity.workspaceOrOrgID
            entry.planTypeKey = identity.planType
        }
        if let label {
            entry.label = label
        }
        index.profiles[id] = entry
    }

    func currentSavedID(paths: NativePaths, tokensByID: [String: TokenLoadResult]) -> String? {
        guard let tokens = try? readTokens(at: paths.auth), let identity = extractProfileIdentity(from: tokens) else {
            return nil
        }
        let candidates = tokensByID.compactMap { id, result in
            if case .success(let tokens) = result, matchesIdentity(tokens: tokens, identity: identity) {
                return id
            }
            return nil
        }
        return candidates.sorted().first
    }

    func orderedProfileIDs(snapshot: NativeSnapshot, currentSavedID: String?) -> [String] {
        snapshot.tokensByID.keys.sorted { lhs, rhs in
            if lhs == currentSavedID { return true }
            if rhs == currentSavedID { return false }

            let lhsLabel = labelForID(snapshot.labels, id: lhs)?.lowercased() ?? ""
            let rhsLabel = labelForID(snapshot.labels, id: rhs)?.lowercased() ?? ""
            let lhsEmail = inferredEmail(for: lhs, snapshot: snapshot)?.lowercased() ?? ""
            let rhsEmail = inferredEmail(for: rhs, snapshot: snapshot)?.lowercased() ?? ""

            let lhsMissingLabel = lhsLabel.isEmpty
            let rhsMissingLabel = rhsLabel.isEmpty
            if lhsMissingLabel != rhsMissingLabel {
                return !lhsMissingLabel
            }
            if lhsLabel != rhsLabel {
                return lhsLabel.compare(
                    rhsLabel,
                    options: String.CompareOptions([.caseInsensitive, .numeric]),
                    range: nil,
                    locale: Locale.current
                ) == .orderedAscending
            }
            let lhsMissingEmail = lhsEmail.isEmpty
            let rhsMissingEmail = rhsEmail.isEmpty
            if lhsMissingEmail != rhsMissingEmail {
                return !lhsMissingEmail
            }
            if lhsEmail != rhsEmail {
                return lhsEmail.compare(
                    rhsEmail,
                    options: String.CompareOptions([.caseInsensitive, .numeric]),
                    range: nil,
                    locale: Locale.current
                ) == .orderedAscending
            }
            return lhs.compare(
                rhs,
                options: String.CompareOptions([.caseInsensitive, .numeric]),
                range: nil,
                locale: Locale.current
            ) == .orderedAscending
        }
    }

    func inferredEmail(for id: String, snapshot: NativeSnapshot) -> String? {
        if case .success(let tokens)? = snapshot.tokensByID[id] {
            let email = extractEmailAndPlan(from: tokens).0
            if let email, !email.isEmpty {
                return email
            }
        }
        return snapshot.index.profiles[id]?.email
    }

    func buildSavedProfiles(ids: [String], paths: NativePaths, snapshot: NativeSnapshot, currentSavedID: String?) async -> [ProfileStatus] {
        await withTaskGroup(of: (Int, ProfileStatus).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    let profile = await self.buildSavedProfile(id: id, paths: paths, snapshot: snapshot, currentSavedID: currentSavedID)
                    return (index, profile)
                }
            }

            var collected = [(Int, ProfileStatus)]()
            for await item in group {
                collected.append(item)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    func buildSavedProfile(id: String, paths: NativePaths, snapshot: NativeSnapshot, currentSavedID: String?) async -> ProfileStatus {
        let label = labelForID(snapshot.labels, id: id)
        let indexEntry = snapshot.index.profiles[id]
        let profilePath = profilePath(for: id, in: paths.profiles)
        let isCurrent = currentSavedID == id

        guard let tokensResult = snapshot.tokensByID[id] else {
            return buildErrorProfile(
                id: id,
                label: label,
                email: indexEntry?.email,
                plan: indexEntry?.plan,
                isCurrent: isCurrent,
                isSaved: true,
                isAPIKey: indexEntry?.isAPIKey ?? false,
                message: "Saved profile file is missing."
            )
        }

        switch tokensResult {
        case .failure(let message):
            return buildErrorProfile(
                id: id,
                label: label,
                email: indexEntry?.email,
                plan: indexEntry?.plan,
                isCurrent: isCurrent,
                isSaved: true,
                isAPIKey: indexEntry?.isAPIKey ?? false,
                message: message
            )
        case .success(let tokens):
            return await buildProfileStatus(
                id: id,
                label: label,
                fallbackEmail: indexEntry?.email,
                fallbackPlan: indexEntry?.plan,
                tokens: tokens,
                sourcePath: profilePath,
                paths: paths,
                isCurrent: isCurrent,
                isSaved: true,
                syncSavedIDOnRefresh: nil
            )
        }
    }

    func buildCurrentProfile(paths: NativePaths, snapshot: NativeSnapshot, currentSavedID: String?) async -> ProfileStatus? {
        guard fileManager.fileExists(atPath: paths.auth.path) else { return nil }

        do {
            let tokens = try readTokens(at: paths.auth)
            let resolvedSavedID = currentSavedID ?? ({ () -> String? in
                guard let identity = extractProfileIdentity(from: tokens) else { return nil }
                let matches = snapshot.tokensByID.compactMap { id, result in
                    if case .success(let savedTokens) = result, matchesIdentity(tokens: savedTokens, identity: identity) {
                        return id
                    }
                    return nil
                }
                return matches.sorted().first
            })()
            let label = resolvedSavedID.flatMap { labelForID(snapshot.labels, id: $0) }
            let fallbackEntry = resolvedSavedID.flatMap { snapshot.index.profiles[$0] }
            let status = await buildProfileStatus(
                id: resolvedSavedID,
                label: label,
                fallbackEmail: fallbackEntry?.email,
                fallbackPlan: fallbackEntry?.plan,
                tokens: tokens,
                sourcePath: paths.auth,
                paths: paths,
                isCurrent: true,
                isSaved: resolvedSavedID != nil,
                syncSavedIDOnRefresh: resolvedSavedID
            )

            if resolvedSavedID == nil && isProfileReady(tokens) {
                return ProfileStatus(
                    id: nil,
                    label: status.label,
                    email: status.email,
                    plan: status.plan,
                    isCurrent: true,
                    isSaved: false,
                    isApiKey: status.isApiKey,
                    warnings: status.warnings,
                    usage: status.usage,
                    error: status.error
                )
            }

            return status
        } catch {
            return buildErrorProfile(
                id: currentSavedID,
                label: currentSavedID.flatMap { labelForID(snapshot.labels, id: $0) },
                email: currentSavedID.flatMap { snapshot.index.profiles[$0]?.email },
                plan: currentSavedID.flatMap { snapshot.index.profiles[$0]?.plan },
                isCurrent: true,
                isSaved: currentSavedID != nil,
                isAPIKey: false,
                message: error.localizedDescription
            )
        }
    }

    func buildProfileStatus(
        id: String?,
        label: String?,
        fallbackEmail: String?,
        fallbackPlan: String?,
        tokens: NativeTokens,
        sourcePath: URL,
        paths: NativePaths,
        isCurrent: Bool,
        isSaved: Bool,
        syncSavedIDOnRefresh: String?
    ) async -> ProfileStatus {
        let isAPIKey = isAPIKeyProfile(tokens)
        var effectiveTokens = tokens
        var usage: UsageSnapshot?
        var error: StatusError?

        if isAPIKey {
            usage = UsageSnapshot(
                state: "unavailable",
                buckets: [],
                summary: "Data not available",
                detail: "Usage is not available for API key profiles."
            )
        } else {
            let usageOutcome = await buildUsageSnapshot(
                tokens: tokens,
                sourcePath: sourcePath,
                paths: paths,
                syncSavedIDOnRefresh: syncSavedIDOnRefresh
            )
            effectiveTokens = usageOutcome.tokens
            usage = usageOutcome.usage
            error = usageOutcome.error
        }

        let extracted = extractEmailAndPlan(from: effectiveTokens)
        let email = extracted.0 ?? fallbackEmail
        let plan = extracted.1 ?? fallbackPlan

        if error == nil, let validationMessage = profileValidationMessage(
            tokens: effectiveTokens,
            email: email,
            plan: plan
        ) {
            error = StatusError(summary: StatusErrorSummary(message: validationSummary(for: validationMessage)), detail: validationMessage)
        }

        let warnings = isCurrent && !isSaved ? ["Current auth is not saved yet"] : []
        return ProfileStatus(
            id: id,
            label: label,
            email: email,
            plan: plan,
            isCurrent: isCurrent,
            isSaved: isSaved,
            isApiKey: isAPIKey,
            warnings: warnings,
            usage: usage,
            error: error
        )
    }

    struct UsageBuildOutcome {
        let tokens: NativeTokens
        let usage: UsageSnapshot?
        let error: StatusError?
    }

    func buildUsageSnapshot(
        tokens: NativeTokens,
        sourcePath: URL,
        paths: NativePaths,
        syncSavedIDOnRefresh: String?
    ) async -> UsageBuildOutcome {
        guard let accessToken = nonEmpty(tokens.accessToken), let accountID = tokenAccountID(tokens) else {
            return UsageBuildOutcome(tokens: tokens, usage: nil, error: nil)
        }

        let baseURL: String
        do {
            baseURL = try readBaseURL(paths: paths)
        } catch {
            let message = error.localizedDescription
            return UsageBuildOutcome(
                tokens: tokens,
                usage: UsageSnapshot(state: "error", buckets: [], summary: usageSummary(from: message), detail: usageDetail(from: message)),
                error: StatusError(summary: StatusErrorSummary(message: validationSummary(for: message)), detail: message)
            )
        }

        do {
            let buckets = try await fetchUsageSnapshot(baseURL: baseURL, accessToken: accessToken, accountID: accountID)
            return UsageBuildOutcome(tokens: tokens, usage: UsageSnapshot(state: "ok", buckets: buckets), error: nil)
        } catch let fetchError as UsageFetchError where fetchError.statusCode == 401 {
            do {
                let refreshed = try await refreshProfileTokens(at: sourcePath, currentTokens: tokens)
                if let syncSavedIDOnRefresh {
                    try? syncCurrentProfile(paths: paths, savedID: syncSavedIDOnRefresh, tokens: refreshed)
                }
                let refreshedAccessToken = nonEmpty(refreshed.accessToken) ?? accessToken
                let refreshedAccountID = tokenAccountID(refreshed) ?? accountID
                let buckets = try await fetchUsageSnapshot(baseURL: baseURL, accessToken: refreshedAccessToken, accountID: refreshedAccountID)
                return UsageBuildOutcome(tokens: refreshed, usage: UsageSnapshot(state: "ok", buckets: buckets), error: nil)
            } catch {
                let message = error.localizedDescription
                return UsageBuildOutcome(
                    tokens: tokens,
                    usage: UsageSnapshot(state: "error", buckets: [], summary: usageSummary(from: message), detail: usageDetail(from: message)),
                    error: StatusError(summary: StatusErrorSummary(message: validationSummary(for: message)), detail: message)
                )
            }
        } catch {
            let message = error.localizedDescription
            return UsageBuildOutcome(
                tokens: tokens,
                usage: UsageSnapshot(state: "error", buckets: [], summary: usageSummary(from: message), detail: usageDetail(from: message)),
                error: StatusError(summary: StatusErrorSummary(message: validationSummary(for: message)), detail: message)
            )
        }
    }

    func usageSummary(from message: String) -> String {
        message
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? message
    }

    func usageDetail(from message: String) -> String? {
        let lines = message
            .split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst()
            .map(String.init)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func validationSummary(for message: String) -> String {
        usageSummary(from: message)
    }

    func buildErrorProfile(
        id: String?,
        label: String?,
        email: String?,
        plan: String?,
        isCurrent: Bool,
        isSaved: Bool,
        isAPIKey: Bool,
        message: String
    ) -> ProfileStatus {
        ProfileStatus(
            id: id,
            label: label,
            email: email,
            plan: plan,
            isCurrent: isCurrent,
            isSaved: isSaved,
            isApiKey: isAPIKey,
            warnings: [],
            usage: UsageSnapshot(state: "error", buckets: [], summary: usageSummary(from: message), detail: usageDetail(from: message)),
            error: StatusError(summary: StatusErrorSummary(message: validationSummary(for: message)), detail: message)
        )
    }

    func readAuthStoreMode(for authPath: URL) throws -> String {
        guard authPath.lastPathComponent == "auth.json" else { return "file" }
        guard let configContents = try? String(contentsOf: authPath.deletingLastPathComponent().appendingPathComponent("config.toml"), encoding: .utf8) else {
            return "file"
        }
        for line in configContents.split(whereSeparator: \.isNewline) {
            if let value = parseConfigValue(String(line), key: "cli_auth_credentials_store_mode") {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["file", "keyring", "auto", "ephemeral"].contains(normalized) {
                    return normalized
                }
                throw CodexProfilesError.commandFailed("Unsupported auth store mode `\(normalized)`.")
            }
        }
        return "file"
    }

    func readAuthFile(at path: URL) throws -> NativeAuthFile {
        let storeMode = try readAuthStoreMode(for: path)
        guard storeMode == "file" else {
            throw CodexProfilesError.commandFailed("This app only supports file-backed Codex auth. Current mode is `\(storeMode)`.")
        }
        let data = try Data(contentsOf: path)
        if data.isEmpty {
            throw CodexProfilesError.commandFailed("Auth file is empty.")
        }
        do {
            return try JSONDecoder().decode(NativeAuthFile.self, from: data)
        } catch {
            throw CodexProfilesError.commandFailed("Auth file is not valid JSON.")
        }
    }

    func readTokens(at path: URL) throws -> NativeTokens {
        let auth = try readAuthFile(at: path)
        if let tokens = auth.tokens {
            return tokens
        }
        if let apiKey = nonEmpty(auth.openAIAPIKey) {
            return tokensFromAPIKey(apiKey)
        }
        throw CodexProfilesError.commandFailed("Auth file is missing tokens.")
    }

    func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func tokenAccountID(_ tokens: NativeTokens) -> String? {
        nonEmpty(tokens.accountID)
    }

    func isAPIKeyProfile(_ tokens: NativeTokens) -> Bool {
        (tokens.accountID ?? "").hasPrefix("api-key-")
            && nonEmpty(tokens.idToken) == nil
            && nonEmpty(tokens.accessToken) == nil
            && nonEmpty(tokens.refreshToken) == nil
    }

    func tokensFromAPIKey(_ apiKey: String) -> NativeTokens {
        NativeTokens(
            accountID: apiKeyProfileID(apiKey),
            idToken: nil,
            accessToken: nil,
            refreshToken: nil
        )
    }

    func isProfileReady(_ tokens: NativeTokens) -> Bool {
        if isAPIKeyProfile(tokens) { return true }
        guard tokenAccountID(tokens) != nil, nonEmpty(tokens.accessToken) != nil else {
            return false
        }
        let (email, plan) = extractEmailAndPlan(from: tokens)
        return email != nil && plan != nil
    }

    func extractEmailAndPlan(from tokens: NativeTokens) -> (String?, String?) {
        if isAPIKeyProfile(tokens) {
            return (apiKeyDisplayLabel(tokens) ?? "Key", "Key")
        }
        guard let claims = decodeIDTokenClaims(tokens.idToken) else {
            return (nil, nil)
        }
        let email = nonEmpty(claims.email)
        let rawPlan = claims.auth?.chatgptPlanType
        return (email, rawPlan.map(formatPlan))
    }

    func extractProfileIdentity(from tokens: NativeTokens) -> NativeProfileIdentityKey? {
        if isAPIKeyProfile(tokens), let principal = tokenAccountID(tokens) {
            return NativeProfileIdentityKey(principalID: principal, workspaceOrOrgID: principal, planType: "key")
        }

        let claims = decodeIDTokenClaims(tokens.idToken)
        let principal = nonEmpty(claims?.auth?.chatgptUserID)
            ?? nonEmpty(claims?.auth?.userID)
            ?? nonEmpty(claims?.sub)
            ?? tokenAccountID(tokens)
        guard let principal else { return nil }

        let workspace = nonEmpty(claims?.auth?.chatgptAccountID)
            ?? nonEmpty(claims?.organizationID)
            ?? nonEmpty(claims?.projectID)
            ?? tokenAccountID(tokens)
            ?? "unknown"

        let planType = nonEmpty(claims?.auth?.chatgptPlanType)?.lowercased()
            ?? extractEmailAndPlan(from: tokens).1?.lowercased()
            ?? "unknown"

        return NativeProfileIdentityKey(principalID: principal, workspaceOrOrgID: workspace, planType: planType)
    }

    func decodeIDTokenClaims(_ token: String?) -> NativeIDTokenClaims? {
        guard let token = nonEmpty(token) else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONDecoder().decode(NativeIDTokenClaims.self, from: data)
    }

    func formatPlan(_ value: String) -> String {
        let words = value.split(whereSeparator: { $0 == "_" || $0 == "-" })
        let output = words.map { word -> String in
            guard let first = word.first else { return "" }
            return String(first).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
        return output.isEmpty ? "Unknown" : output
    }

    func apiKeyProfileID(_ apiKey: String) -> String {
        let prefix = String(apiKey.prefix(12)).map { character -> Character in
            if character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_" || character == ".") {
                return character
            }
            return "-"
        }
        let prefixString = String(prefix)
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in apiKey.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "api-key-\(prefixString)~" + String(format: "%016llx", hash)
    }

    func apiKeyDisplayLabel(_ tokens: NativeTokens) -> String? {
        guard let accountID = tokens.accountID, accountID.hasPrefix("api-key-") else { return nil }
        let rest = accountID.dropFirst("api-key-".count)
        let parts = rest.split(separator: "~", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let suffix = String(parts[1].suffix(16))
        return suffix.isEmpty ? nil : "~\(suffix)"
    }

    func profileValidationMessage(tokens: NativeTokens, email: String?, plan: String?) -> String? {
        if isAPIKeyProfile(tokens) {
            return nil
        }
        if email == nil || plan == nil {
            return "Saved profile is missing email or plan metadata."
        }
        if tokenAccountID(tokens) == nil {
            return "Saved profile is missing account information."
        }
        if nonEmpty(tokens.accessToken) == nil {
            return "Saved profile is missing an access token."
        }
        return nil
    }

    func matchesIdentity(tokens: NativeTokens, identity: NativeProfileIdentityKey) -> Bool {
        extractProfileIdentity(from: tokens) == identity
    }

    func resolveSaveID(paths: NativePaths, index: inout NativeProfilesIndex, tokens: NativeTokens) throws -> String {
        let (accountID, email, plan) = try requireIdentity(tokens)
        _ = accountID
        guard let identity = extractProfileIdentity(from: tokens) else {
            throw CodexProfilesError.commandFailed("Current auth is missing account information.")
        }
        let desiredBase = profileBase(email: email, plan: plan)
        let desired = try uniqueProfileID(base: desiredBase, identity: identity, profilesDirectory: paths.profiles)
        let candidates = try scanProfileIDs(profilesDirectory: paths.profiles, identity: identity)
        if let primary = candidates.sorted().first, primary != desired {
            return try renameProfileID(paths: paths, index: &index, from: primary, targetBase: desiredBase, identity: identity)
        }
        return desired
    }

    func resolveSyncID(paths: NativePaths, index: inout NativeProfilesIndex, tokens: NativeTokens) throws -> String? {
        guard let identity = extractProfileIdentity(from: tokens) else {
            return nil
        }
        let extracted = extractEmailAndPlan(from: tokens)
        guard let email = extracted.0, let plan = extracted.1 else {
            return nil
        }
        let desiredBase = profileBase(email: email, plan: plan)
        let desired = try uniqueProfileID(base: desiredBase, identity: identity, profilesDirectory: paths.profiles)
        let candidates = try scanProfileIDs(profilesDirectory: paths.profiles, identity: identity)
        if candidates.count == 1 {
            return candidates.first
        }
        if candidates.contains(desired) {
            return desired
        }
        guard let primary = candidates.sorted().first else {
            return nil
        }
        if primary != desired {
            return try renameProfileID(paths: paths, index: &index, from: primary, targetBase: desiredBase, identity: identity)
        }
        return primary
    }

    func requireIdentity(_ tokens: NativeTokens) throws -> (String, String, String) {
        guard let accountID = tokenAccountID(tokens) else {
            throw CodexProfilesError.commandFailed("Current auth is missing account information.")
        }
        let extracted = extractEmailAndPlan(from: tokens)
        guard let email = extracted.0 else {
            throw CodexProfilesError.commandFailed("Current auth is missing an email address.")
        }
        guard let plan = extracted.1 else {
            throw CodexProfilesError.commandFailed("Current auth is missing a plan.")
        }
        return (accountID, email, plan)
    }

    func profileBase(email: String, plan: String) -> String {
        let emailPart = sanitizePart(email)
        let planPart = sanitizePart(plan)
        let safeEmail = emailPart.isEmpty ? "unknown" : emailPart
        let safePlan = planPart.isEmpty ? "unknown" : planPart
        return "\(safeEmail)-\(safePlan)"
    }

    func sanitizePart(_ value: String) -> String {
        var output = ""
        var lastDash = false
        for character in value {
            let next: Character
            if character.isASCII && character.isLetter || character.isNumber {
                next = Character(character.lowercased())
            } else if "@.-_+".contains(character) {
                next = character
            } else {
                next = "-"
            }
            if next == "-" {
                if lastDash { continue }
                lastDash = true
            } else {
                lastDash = false
            }
            output.append(next)
        }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    func uniqueProfileID(base: String, identity: NativeProfileIdentityKey, profilesDirectory: URL) throws -> String {
        var candidate = base
        let suffix = shortIdentitySuffix(identity)
        var attempt = 0
        while true {
            let path = profilePath(for: candidate, in: profilesDirectory)
            if !fileManager.fileExists(atPath: path.path) {
                return candidate
            }
            if let tokens = try? readTokens(at: path), matchesIdentity(tokens: tokens, identity: identity) {
                return candidate
            }
            attempt += 1
            candidate = attempt == 1 ? "\(base)-\(suffix)" : "\(base)-\(suffix)-\(attempt)"
        }
    }

    func shortIdentitySuffix(_ identity: NativeProfileIdentityKey) -> String {
        let source = identity.workspaceOrOrgID == "unknown" ? identity.principalID : identity.workspaceOrOrgID
        let suffix = String(source.prefix(6))
        return suffix.isEmpty ? "id" : suffix
    }

    func scanProfileIDs(profilesDirectory: URL, identity: NativeProfileIdentityKey) throws -> [String] {
        try profileFiles(in: profilesDirectory).compactMap { path in
            guard let tokens = try? readTokens(at: path), matchesIdentity(tokens: tokens, identity: identity) else {
                return nil
            }
            return profileID(from: path)
        }
    }

    func renameProfileID(paths: NativePaths, index: inout NativeProfilesIndex, from: String, targetBase: String, identity: NativeProfileIdentityKey) throws -> String {
        let desired = try uniqueProfileID(base: targetBase, identity: identity, profilesDirectory: paths.profiles)
        guard from != desired else { return desired }

        let source = profilePath(for: from, in: paths.profiles)
        let target = profilePath(for: desired, in: paths.profiles)
        guard fileManager.fileExists(atPath: source.path) else {
            throw CodexProfilesError.commandFailed("Saved profile `\(from)` was not found.")
        }
        try fileManager.moveItem(at: source, to: target)
        if let entry = index.profiles.removeValue(forKey: from) {
            index.profiles[desired] = entry
        }
        return desired
    }

    func syncCurrent(paths: NativePaths, index: inout NativeProfilesIndex) throws {
        guard let tokens = try? readTokens(at: paths.auth), let id = try resolveSyncID(paths: paths, index: &index, tokens: tokens) else {
            return
        }
        let target = profilePath(for: id, in: paths.profiles)
        try copyAtomicPrivate(from: paths.auth, to: target)
        let label = labelForID(labelsFromIndex(index), id: id)
        updateIndexEntry(&index, id: id, tokens: tokens, label: label)
        try writeProfilesIndex(index, paths: paths)
    }

    func syncCurrentProfile(paths: NativePaths, savedID: String, tokens: NativeTokens) throws {
        try withProfilesLock(paths) {
            let target = profilePath(for: savedID, in: paths.profiles)
            try copyAtomicPrivate(from: paths.auth, to: target)
            var index = try readProfilesIndexRelaxed(paths)
            let label = labelForID(labelsFromIndex(index), id: savedID)
            updateIndexEntry(&index, id: savedID, tokens: tokens, label: label)
            try writeProfilesIndex(index, paths: paths)
        }
    }

    func readBaseURL(paths: NativePaths) throws -> String {
        guard let contents = try? String(contentsOf: paths.config, encoding: .utf8) else {
            return "https://chatgpt.com/backend-api"
        }
        for line in contents.split(whereSeparator: \.isNewline) {
            if let value = parseConfigValue(String(line), key: "chatgpt_base_url") {
                return try validateBaseURL(value)
            }
        }
        return "https://chatgpt.com/backend-api"
    }

    func parseConfigValue(_ line: String, key: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let configKey = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        guard configKey == key else { return nil }
        let rawValue = trimmed[trimmed.index(after: separator)...]
        let value = stripInlineComment(String(rawValue)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let stripped = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    func stripInlineComment(_ value: String) -> String {
        var inSingle = false
        var inDouble = false
        var result = ""
        for character in value {
            switch character {
            case "\"" where !inSingle:
                inDouble.toggle()
            case "'" where !inDouble:
                inSingle.toggle()
            case "#" where !inSingle && !inDouble:
                return result.trimmingCharacters(in: .whitespaces)
            default:
                break
            }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    func validateBaseURL(_ value: String) throws -> String {
        let normalized = normalizeBaseURL(value)
        guard let components = URLComponents(string: normalized), let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased() else {
            throw CodexProfilesError.commandFailed("Unsupported chatgpt_base_url `\(normalized)`.")
        }
        if isLoopbackHost(host) {
            guard scheme == "http" || scheme == "https" else {
                throw CodexProfilesError.commandFailed("Unsupported chatgpt_base_url `\(normalized)`.")
            }
            return normalized
        }
        guard scheme == "https", ["chatgpt.com", "chat.openai.com"].contains(host) else {
            throw CodexProfilesError.commandFailed("Unsupported chatgpt_base_url `\(normalized)`.")
        }
        return normalized
    }

    func normalizeBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasPrefix("https://chatgpt.com") || trimmed.hasPrefix("https://chat.openai.com") {
            if trimmed.contains("/backend-api") {
                return trimmed
            }
            return trimmed + "/backend-api"
        }
        return trimmed
    }

    func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" {
            return true
        }
        if host.hasPrefix("127.") {
            return true
        }
        return false
    }

    func usageEndpoint(baseURL: String) -> URL {
        if baseURL.contains("/backend-api") {
            return URL(string: baseURL + "/wham/usage")!
        }
        return URL(string: baseURL + "/api/codex/usage")!
    }

    func fetchUsageSnapshot(baseURL: String, accessToken: String, accountID: String) async throws -> [UsageBucket] {
        let endpoint = usageEndpoint(baseURL: baseURL)
        var lastError: UsageFetchError?

        for attempt in 0..<usageRetryAttempts {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "GET"
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
                request.setValue(usageUserAgent, forHTTPHeaderField: "User-Agent")

                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw UsageFetchError(statusCode: nil, summary: "Service returned an unexpected response.", detail: "URL: \(endpoint.absoluteString)")
                }

                if usageShouldRetry(statusCode: httpResponse.statusCode), attempt + 1 < usageRetryAttempts {
                    try? await Task.sleep(nanoseconds: retryDelayNanos(attempt: attempt, retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After")))
                    continue
                }

                guard (200..<300).contains(httpResponse.statusCode) else {
                    throw UsageFetchError(
                        statusCode: httpResponse.statusCode,
                        summary: "Unexpected status \(httpResponse.statusCode) while fetching usage.",
                        detail: "URL: \(endpoint.absoluteString)"
                    )
                }

                let payload = try JSONDecoder().decode(UsagePayload.self, from: data)
                return usageSnapshotBuckets(from: payload)
            } catch let error as UsageFetchError {
                lastError = error
                if let code = error.statusCode, usageShouldRetry(statusCode: code), attempt + 1 < usageRetryAttempts {
                    try? await Task.sleep(nanoseconds: retryDelayNanos(attempt: attempt, retryAfter: nil))
                    continue
                }
                throw error
            } catch {
                let wrapped = UsageFetchError(statusCode: nil, summary: "Usage service is unreachable.", detail: error.localizedDescription)
                lastError = wrapped
                if attempt + 1 < usageRetryAttempts {
                    try? await Task.sleep(nanoseconds: retryDelayNanos(attempt: attempt, retryAfter: nil))
                    continue
                }
                throw wrapped
            }
        }

        throw lastError ?? UsageFetchError(statusCode: nil, summary: "Usage service is unreachable.", detail: nil)
    }

    func usageShouldRetry(statusCode: Int) -> Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }

    func retryDelayNanos(attempt: Int, retryAfter: String?) -> UInt64 {
        if let retryAfter, let delay = parseRetryAfter(retryAfter) {
            return delay
        }
        let milliseconds = min(3000, 250 * Int(pow(2.0, Double(min(attempt, 5)))))
        return UInt64(milliseconds) * 1_000_000
    }

    func parseRetryAfter(_ value: String) -> UInt64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed) {
            return UInt64(max(0, seconds) * 1_000_000_000)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        if let date = formatter.date(from: trimmed) {
            return UInt64(max(0, date.timeIntervalSinceNow) * 1_000_000_000)
        }
        return nil
    }

    func usageSnapshotBuckets(from payload: UsagePayload) -> [UsageBucket] {
        orderedUsageBuckets(usageBuckets(from: payload)).compactMap { bucket in
            let limits = buildUsageWindows(rateLimit: bucket.rateLimit)
            if limits.fiveHour == nil && limits.weekly == nil {
                return nil
            }
            return UsageBucket(
                id: bucket.id,
                label: bucket.label,
                fiveHour: limits.fiveHour,
                weekly: limits.weekly
            )
        }
    }

    func usageBuckets(from payload: UsagePayload) -> [UsageBucketSource] {
        var buckets = [UsageBucketSource]()
        if let rateLimit = payload.rateLimit {
            buckets.append(UsageBucketSource(id: "codex", label: "codex", rateLimit: rateLimit))
        }
        for item in payload.additionalRateLimits ?? [] {
            let id = nonEmpty(item.meteredFeature) ?? "unknown"
            let label = nonEmpty(item.limitName) ?? id
            buckets.append(UsageBucketSource(id: id, label: label, rateLimit: item.rateLimit))
        }
        return buckets
    }

    func orderedUsageBuckets(_ buckets: [UsageBucketSource]) -> [UsageBucketSource] {
        guard let index = buckets.firstIndex(where: { $0.id == "codex" }), index != 0 else {
            return buckets
        }
        var copy = buckets
        let preferred = copy.remove(at: index)
        copy.insert(preferred, at: 0)
        return copy
    }

    func buildUsageWindows(rateLimit: RateLimitDetails?) -> (fiveHour: UsageWindow?, weekly: UsageWindow?) {
        guard let rateLimit else { return (nil, nil) }
        let windows = [rateLimit.primaryWindow, rateLimit.secondaryWindow]
            .compactMap { $0 }
            .sorted { $0.limitWindowSeconds < $1.limitWindowSeconds }
            .map { snapshot in
                UsageWindow(
                    leftPercent: max(0, min(100, Int((100.0 - snapshot.usedPercent).rounded()))),
                    resetAt: snapshot.resetAt
                )
            }
        return (
            windows.indices.contains(0) ? windows[0] : nil,
            windows.indices.contains(1) ? windows[1] : nil
        )
    }

    func refreshProfileTokens(at path: URL, currentTokens: NativeTokens) async throws -> NativeTokens {
        let diskTokens = try readTokens(at: path)
        if diskTokens != currentTokens {
            if sameProfileRefreshTarget(diskTokens, currentTokens) {
                return diskTokens
            }
            throw CodexProfilesError.commandFailed("Auth state changed while refreshing tokens. Please refresh again.")
        }

        guard let refreshToken = nonEmpty(currentTokens.refreshToken) else {
            throw CodexProfilesError.commandFailed("Saved profile is missing a refresh token.")
        }

        let refreshed = try await refreshAccessToken(refreshToken: refreshToken)
        var updatedTokens = currentTokens
        try applyRefresh(into: &updatedTokens, refreshed: refreshed)
        try updateAuthTokens(at: path, refreshed: refreshed)
        return updatedTokens
    }

    func sameProfileRefreshTarget(_ lhs: NativeTokens, _ rhs: NativeTokens) -> Bool {
        guard tokenAccountID(lhs) == tokenAccountID(rhs) else { return false }
        return extractProfileIdentity(from: lhs) == extractProfileIdentity(from: rhs)
    }

    func refreshAccessToken(refreshToken: String) async throws -> NativeRefreshResponse {
        let requestBody = NativeRefreshRequest(clientID: refreshClientID, refreshToken: refreshToken)
        var request = URLRequest(url: URL(string: refreshTokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexProfilesError.commandFailed("Refresh service returned an unexpected response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CodexProfilesError.commandFailed("Could not refresh the Codex session (status \(httpResponse.statusCode)).")
        }
        do {
            return try JSONDecoder().decode(NativeRefreshResponse.self, from: data)
        } catch {
            throw CodexProfilesError.commandFailed("Refresh service returned invalid JSON.")
        }
    }

    func applyRefresh(into tokens: inout NativeTokens, refreshed: NativeRefreshResponse) throws {
        guard let accessToken = nonEmpty(refreshed.accessToken) else {
            throw CodexProfilesError.commandFailed("Refresh response did not include an access token.")
        }
        tokens.accessToken = accessToken
        if let idToken = nonEmpty(refreshed.idToken) {
            tokens.idToken = idToken
            if let accountID = accountIDFromIDToken(idToken) {
                tokens.accountID = accountID
            }
        }
        if let refreshToken = nonEmpty(refreshed.refreshToken) {
            tokens.refreshToken = refreshToken
        }
    }

    func accountIDFromIDToken(_ idToken: String) -> String? {
        let claims = decodeIDTokenClaims(idToken)
        return nonEmpty(claims?.auth?.chatgptAccountID)
            ?? nonEmpty(claims?.organizationID)
            ?? nonEmpty(claims?.projectID)
    }

    func updateAuthTokens(at path: URL, refreshed: NativeRefreshResponse) throws {
        let data = try Data(contentsOf: path)
        let rootObject = try JSONSerialization.jsonObject(with: data)
        guard var root = rootObject as? [String: Any] else {
            throw CodexProfilesError.commandFailed("Auth file is not a JSON object.")
        }
        var tokens = (root["tokens"] as? [String: Any]) ?? [:]
        if let idToken = nonEmpty(refreshed.idToken) {
            tokens["id_token"] = idToken
            if let accountID = accountIDFromIDToken(idToken) {
                tokens["account_id"] = accountID
            }
        }
        if let accessToken = nonEmpty(refreshed.accessToken) {
            tokens["access_token"] = accessToken
        }
        if let refreshToken = nonEmpty(refreshed.refreshToken) {
            tokens["refresh_token"] = refreshToken
        }
        root["tokens"] = tokens
        let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try writeAtomicPrivate(data: output.appendingNewline(), to: path)
    }

    func prepareImportProfile(_ profile: NativeExportedProfile) throws -> PreparedImportProfile {
        let dictionary = profile.contents.mapValues(\.rawValue)
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys])
        let authData = try JSONSerialization.data(withJSONObject: dictionary, options: [])
        let auth = try JSONDecoder().decode(NativeAuthFile.self, from: authData)
        let tokens: NativeTokens
        if let parsedTokens = auth.tokens {
            tokens = parsedTokens
        } else if let apiKey = nonEmpty(auth.openAIAPIKey) {
            tokens = tokensFromAPIKey(apiKey)
        } else {
            throw CodexProfilesError.commandFailed("Imported profile `\(profile.id)` is missing tokens or an API key.")
        }
        guard isProfileReady(tokens) else {
            throw CodexProfilesError.commandFailed("Imported profile `\(profile.id)` is incomplete.")
        }
        return PreparedImportProfile(id: profile.id, label: profile.label, contents: data.appendingNewline(), tokens: tokens)
    }

    func validateImportProfileID(_ id: String) throws {
        guard !id.isEmpty,
              !id.contains("/"),
              !id.contains(":"),
              !id.contains(".."),
              id != "profiles",
              id != "update" else {
            throw CodexProfilesError.commandFailed("Imported profile id `\(id)` is not safe.")
        }
    }

    func setPOSIXPermissions(path: String, mode: Int16) throws {
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path)
    }

    func writeAtomicPrivate(data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp, options: .atomic)
            try setPOSIXPermissions(path: temp.path, mode: 0o600)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: destination)
            }
            try setPOSIXPermissions(path: destination.path, mode: 0o600)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    func copyAtomicPrivate(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        try writeAtomicPrivate(data: data, to: destination)
    }

    func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return encoder
    }

    func repair(paths: NativePaths) throws -> [String] {
        var repairs = [String]()
        if !fileManager.fileExists(atPath: paths.profiles.path) {
            try fileManager.createDirectory(at: paths.profiles, withIntermediateDirectories: true)
            try setPOSIXPermissions(path: paths.profiles.path, mode: 0o700)
            repairs.append("Created profiles directory")
        }
        if !fileManager.fileExists(atPath: paths.profilesLock.path) {
            fileManager.createFile(atPath: paths.profilesLock.path, contents: Data())
            try setPOSIXPermissions(path: paths.profilesLock.path, mode: 0o600)
            repairs.append("Created profiles lock file")
        }

        let indexRepairs = try withProfilesLock(paths) {
            var repairs = [String]()
            let ids = try collectProfileIDs(in: paths.profiles)
            var index: NativeProfilesIndex
            if let data = try? Data(contentsOf: paths.profilesIndex), !data.isEmpty, let decoded = try? JSONDecoder().decode(NativeProfilesIndex.self, from: data) {
                index = decoded
            } else {
                index = NativeProfilesIndex()
                repairs.append(fileManager.fileExists(atPath: paths.profilesIndex.path) ? "Rebuilt invalid profiles index" : "Initialized profiles index")
            }

            let previousCount = index.profiles.count
            try pruneProfilesIndex(&index, profilesDirectory: paths.profiles)
            let pruned = previousCount - index.profiles.count
            if pruned > 0 {
                repairs.append("Pruned \(pruned) stale profile index entr\(pruned == 1 ? "y" : "ies")")
            }

            var indexed = 0
            for id in ids where index.profiles[id] == nil {
                let path = profilePath(for: id, in: paths.profiles)
                if let tokens = try? readTokens(at: path), isProfileReady(tokens) {
                    index.profiles[id] = NativeProfileIndexEntry()
                    indexed += 1
                }
            }
            if indexed > 0 {
                repairs.append("Indexed \(indexed) saved profile\(indexed == 1 ? "" : "s")")
            }

            try writeProfilesIndex(index, paths: paths)
            return repairs
        }
        repairs.append(contentsOf: indexRepairs)
        return repairs
    }

    func collectDoctorChecks(paths: NativePaths) throws -> [DoctorCheck] {
        var checks = [DoctorCheck]()
        checks.append(DoctorCheck(name: "engine", level: DoctorLevel.info.rawValue, detail: "Built-in profile engine"))

        if !fileManager.fileExists(atPath: paths.auth.path) {
            checks.append(DoctorCheck(name: "auth file", level: DoctorLevel.warn.rawValue, detail: "missing"))
        } else {
            do {
                let tokens = try readTokens(at: paths.auth)
                checks.append(DoctorCheck(name: "auth file", level: isProfileReady(tokens) ? DoctorLevel.ok.rawValue : DoctorLevel.warn.rawValue, detail: isProfileReady(tokens) ? "valid" : "incomplete"))
            } catch {
                checks.append(DoctorCheck(name: "auth file", level: DoctorLevel.error.rawValue, detail: error.localizedDescription))
            }
        }

        if fileManager.fileExists(atPath: paths.profiles.path), isDirectory(paths.profiles) {
            checks.append(DoctorCheck(name: "profiles directory", level: DoctorLevel.ok.rawValue, detail: paths.profiles.path))
        } else {
            checks.append(DoctorCheck(name: "profiles directory", level: DoctorLevel.warn.rawValue, detail: "missing"))
        }

        if !fileManager.fileExists(atPath: paths.profilesIndex.path) {
            checks.append(DoctorCheck(name: "profiles index", level: DoctorLevel.info.rawValue, detail: "missing"))
        } else if let index = try? readProfilesIndex(paths) {
            checks.append(DoctorCheck(name: "profiles index", level: DoctorLevel.ok.rawValue, detail: "\(index.profiles.count) entries"))
        } else {
            checks.append(DoctorCheck(name: "profiles index", level: DoctorLevel.error.rawValue, detail: "invalid JSON"))
        }

        if fileManager.fileExists(atPath: paths.profilesLock.path), !isDirectory(paths.profilesLock) {
            checks.append(DoctorCheck(name: "profiles lock", level: DoctorLevel.ok.rawValue, detail: "ready"))
        } else {
            checks.append(DoctorCheck(name: "profiles lock", level: DoctorLevel.warn.rawValue, detail: "missing"))
        }

        let snapshot = try loadSnapshot(paths: paths, strictLabels: false)
        let validProfiles = snapshot.tokensByID.values.filter {
            if case .success(let tokens) = $0 { return isProfileReady(tokens) }
            return false
        }.count
        let invalidProfiles = snapshot.tokensByID.count - validProfiles

        if validProfiles > 0 {
            checks.append(DoctorCheck(name: "saved profiles", level: DoctorLevel.ok.rawValue, detail: "\(validProfiles) entries"))
        } else if invalidProfiles > 0 {
            checks.append(DoctorCheck(name: "saved profiles", level: DoctorLevel.warn.rawValue, detail: "\(invalidProfiles) invalid entries"))
        } else {
            checks.append(DoctorCheck(name: "saved profiles", level: DoctorLevel.info.rawValue, detail: "none"))
        }

        let currentSaved = currentSavedID(paths: paths, tokensByID: snapshot.tokensByID)
        if !fileManager.fileExists(atPath: paths.auth.path) {
            checks.append(DoctorCheck(name: "current profile", level: DoctorLevel.info.rawValue, detail: "no auth file"))
        } else if let tokens = try? readTokens(at: paths.auth) {
            let detail = currentSaved != nil ? "saved profile active" : (isProfileReady(tokens) ? "current auth not saved yet" : "incomplete")
            let level: DoctorLevel = currentSaved != nil ? .ok : (isProfileReady(tokens) ? .warn : .warn)
            checks.append(DoctorCheck(name: "current profile", level: level.rawValue, detail: detail))
        } else {
            checks.append(DoctorCheck(name: "current profile", level: DoctorLevel.error.rawValue, detail: "invalid auth"))
        }

        return checks
    }

    func summarizeDoctorChecks(_ checks: [DoctorCheck]) -> DoctorSummary {
        var ok = 0
        var warn = 0
        var error = 0
        var info = 0
        for check in checks {
            switch check.level {
            case DoctorLevel.ok.rawValue: ok += 1
            case DoctorLevel.warn.rawValue: warn += 1
            case DoctorLevel.error.rawValue: error += 1
            default: info += 1
            }
        }
        return DoctorSummary(ok: ok, warn: warn, error: error, info: info)
    }
}

private extension Data {
    func appendingNewline() -> Data {
        var copy = self
        copy.append(0x0A)
        return copy
    }
}
