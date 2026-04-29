import Foundation

actor CodexProfilesService {
    static let shared = CodexProfilesService()

    private let engine = CodexProfilesNativeEngine()

    func fetchProfiles() async throws -> (StatusCollection, StorageResolution) {
        let profiles = try await engine.fetchProfiles()
        return (StatusCollection(profiles: profiles), engine.resolveStorage())
    }

    func fetchActiveProfile() async throws -> (ProfileStatus, StorageResolution) {
        let profile = try await engine.fetchActiveProfile()
        return (profile, engine.resolveStorage())
    }

    func saveCurrent(label: String?) async throws {
        try await engine.saveCurrent(label: label)
    }

    func loadProfile(id: String, mode: SwitchMode) async throws {
        try await engine.loadProfile(id: id, mode: mode)
    }

    func activeModelProxyCredential() async throws -> ModelProxyCredential {
        try await engine.activeModelProxyCredential()
    }

    func currentModelProxyRuntimeModel() async throws -> ModelProxyRuntimeModel {
        try await engine.currentModelProxyRuntimeModel()
    }

    func currentChatGPTBaseURL() async throws -> String {
        try await engine.currentChatGPTBaseURL()
    }

    func setModelProxyRuntimeModel(contextWindow: Int?, autoCompactTokenLimit: Int?) async throws -> ModelProxyRuntimeModel {
        try await engine.setModelProxyRuntimeModel(
            contextWindow: contextWindow,
            autoCompactTokenLimit: autoCompactTokenLimit
        )
    }

    func setChatGPTBaseURL(_ value: String) async throws {
        try await engine.setChatGPTBaseURL(value)
    }

    func currentModelProviderKey() async throws -> String? {
        try await engine.currentModelProviderKey()
    }

    func currentModelProviderBaseURL(key: String) async throws -> String? {
        try await engine.currentModelProviderBaseURL(key: key)
    }

    func setCurrentModelProviderKey(_ value: String?) async throws {
        try await engine.setCurrentModelProviderKey(value)
    }

    func upsertModelProxyProviderConfig(key: String, name: String, baseURL: String) async throws {
        try await engine.upsertModelProxyProviderConfig(key: key, name: name, baseURL: baseURL)
    }

    func removeModelProxyProviderConfig(key: String) async throws {
        try await engine.removeModelProxyProviderConfig(key: key)
    }

    func setLabel(id: String, label: String) async throws {
        try await engine.setLabel(id: id, label: label)
    }

    func renameLabel(from current: String, to next: String) async throws {
        try await engine.renameLabel(from: current, to: next)
    }

    func clearLabel(id: String) async throws {
        try await engine.clearLabel(id: id)
    }

    func exportProfiles(ids: [String], to destination: URL) async throws -> ExportPayload {
        try await engine.exportProfiles(ids: ids, to: destination)
    }

    func previewImport(from source: URL) async throws -> ImportPreviewPayload {
        try await engine.previewImport(from: source)
    }

    func importProfiles(from source: URL) async throws -> ImportPayload {
        try await engine.importProfiles(from: source)
    }

    func deleteProfile(id: String) async throws {
        try await engine.deleteProfile(id: id)
    }

    func doctor(fix: Bool) async throws -> DoctorReport {
        try await engine.doctor(fix: fix)
    }

    nonisolated func resolveStorage() throws -> StorageResolution {
        engine.resolveStorage()
    }
}
