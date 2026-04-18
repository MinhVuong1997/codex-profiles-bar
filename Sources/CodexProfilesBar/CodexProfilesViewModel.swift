import Foundation
import AppKit

@MainActor
final class CodexProfilesViewModel: ObservableObject {
    enum RefreshTrigger {
        case manual
        case automatic
        case mutation
    }

    @Published private(set) var profiles: [ProfileStatus] = []
    @Published private(set) var doctorReport: DoctorReport?
    @Published private(set) var detectedStorage: StorageResolution?
    @Published private(set) var launchAtLoginState = LaunchAtLoginState(
        kind: .unavailable,
        title: "Checking…",
        detail: "Resolving login item state."
    )
    @Published private(set) var packagingSupport: PackagingSupport?
    @Published private(set) var isLoading = false
    @Published private(set) var isDoctorLoading = false
    @Published private(set) var isUpdatingLaunchAtLogin = false
    @Published private(set) var isRefreshingProfiles = false
    @Published private(set) var isAutoRefreshEnabled: Bool
    @Published private(set) var switchingProfileID: String?
    @Published private(set) var codexRelaunchPrompt: CodexRelaunchPrompt?
    @Published private(set) var isRestartingCodex = false
    @Published private(set) var lastRefresh: Date?
    @Published var banner: BannerMessage?

    private let service = CodexProfilesService.shared
    private let launchAtLoginManager = LaunchAtLoginManager()
    private let autoRefreshInterval: Duration = .seconds(60)
    private var bannerDismissTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var switchReconcileTask: Task<Void, Never>?

    init() {
        let storedAutoRefresh = UserDefaults.standard.object(forKey: Preferences.autoRefreshKey) as? Bool
        isAutoRefreshEnabled = storedAutoRefresh ?? true
        packagingSupport = Self.resolvePackagingSupport()
        refreshLaunchAtLoginState()
        configureAutoRefreshLoop()
        Task {
            await refresh(trigger: .manual)
        }
    }

    deinit {
        switchReconcileTask?.cancel()
        autoRefreshTask?.cancel()
        bannerDismissTask?.cancel()
    }

    var menuBarSymbolName: String {
        if profiles.contains(where: { $0.isCurrent && !$0.isSaved }) {
            return "person.crop.circle.badge.exclamationmark"
        }
        if profiles.contains(where: { $0.error != nil }) {
            return "person.crop.circle.badge.xmark"
        }
        return "person.crop.circle.badge.checkmark"
    }

    var hasUnsavedCurrentProfile: Bool {
        profiles.contains(where: { $0.isCurrent && !$0.isSaved })
    }

    var savedProfiles: [ProfileStatus] {
        profiles.filter(\.isSaved)
    }

    func refreshLaunchAtLoginState() {
        launchAtLoginState = launchAtLoginManager.currentState()
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        isUpdatingLaunchAtLogin = true
        defer {
            isUpdatingLaunchAtLogin = false
            refreshLaunchAtLoginState()
        }

        do {
            try launchAtLoginManager.setEnabled(enabled)
            showBanner(
                title: enabled ? "Launch at login enabled" : "Launch at login disabled",
                body: enabled
                    ? "Codex Profiles Bar will try to open when you sign in."
                    : "Codex Profiles Bar will stay off at login.",
                tone: .success
            )
        } catch {
            showBanner(
                title: "Launch at login failed",
                body: error.localizedDescription,
                tone: .error
            )
        }
    }

    func setAutoRefreshEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Preferences.autoRefreshKey)
        isAutoRefreshEnabled = enabled
        configureAutoRefreshLoop()
    }

    func refresh(trigger: RefreshTrigger = .manual) async {
        if isRefreshingProfiles {
            return
        }
        if trigger == .automatic && isLoading {
            return
        }

        isRefreshingProfiles = true
        if trigger != .automatic {
            isLoading = true
        }
        defer {
            isRefreshingProfiles = false
            if trigger != .automatic {
                isLoading = false
            }
        }

        do {
            if trigger == .automatic, !profiles.isEmpty {
                let (activeProfile, storage) = try await service.fetchActiveProfile()
                mergeActiveProfile(activeProfile)
                detectedStorage = storage
                lastRefresh = .now
            } else {
                let (response, storage) = try await service.fetchProfiles()
                profiles = sortProfiles(response.profiles)
                detectedStorage = storage
                lastRefresh = .now
                refreshLaunchAtLoginState()
            }

            if banner?.tone == .error {
                banner = nil
            }
        } catch {
            if trigger == .automatic {
                if banner == nil || banner?.tone != .error {
                    showBanner(title: "Auto-refresh failed", body: error.localizedDescription, tone: .error)
                }
            } else {
                showBanner(title: "Refresh failed", body: error.localizedDescription, tone: .error)
            }
        }
    }

    @discardableResult
    func saveCurrent(label: String?) async -> Bool {
        isLoading = true
        defer { isLoading = false }

        do {
            try await self.service.saveCurrent(label: label)
            showBanner(title: "Profile saved", body: "The current auth state is now stored in Codex Profiles.", tone: .success)
            await refresh(trigger: .mutation)
            return true
        } catch {
            showBanner(title: "Command failed", body: error.localizedDescription, tone: .error)
            return false
        }
    }

    @discardableResult
    func switchToProfile(_ profile: ProfileStatus, mode: SwitchMode) async -> Bool {
        guard let id = profile.id else { return false }
        switchingProfileID = id
        isLoading = true
        defer {
            switchingProfileID = nil
            isLoading = false
        }

        do {
            try await service.loadProfile(id: id, mode: mode)
            applyOptimisticSwitch(to: profile)
            showBanner(title: "Profile switched", body: "Now using \(profile.primaryText).", tone: .success)
            let shouldPromptReopen = UserDefaults.standard.object(forKey: Preferences.promptReopenCodexKey) as? Bool ?? true
            if shouldPromptReopen {
                codexRelaunchPrompt = CodexRelaunchPrompt(profileName: profile.primaryText)
            }
            queueSwitchReconcile(for: profile, mode: mode)
            return true
        } catch {
            showBanner(title: "Switch failed", body: error.localizedDescription, tone: .error)
            return false
        }
    }

    @discardableResult
    func updateLabel(for profile: ProfileStatus, newLabel: String) async -> Bool {
        guard let id = profile.id else { return false }
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showBanner(title: "Empty label", body: "Enter a label before saving.", tone: .warning)
            return false
        }

        isLoading = true
        defer { isLoading = false }

        do {
            if let existing = profile.label, !existing.isEmpty {
                try await self.service.renameLabel(from: existing, to: trimmed)
            } else {
                try await self.service.setLabel(id: id, label: trimmed)
            }

            updateProfileLocally(profile) { current in
                self.profileStatus(current, replacingLabelWith: trimmed)
            }
            showBanner(title: "Label updated", body: "Saved new label for \(trimmed).", tone: .success)
            return true
        } catch {
            showBanner(title: "Command failed", body: error.localizedDescription, tone: .error)
            return false
        }
    }

    @discardableResult
    func clearLabel(for profile: ProfileStatus) async -> Bool {
        guard let id = profile.id else { return false }

        isLoading = true
        defer { isLoading = false }

        do {
            try await self.service.clearLabel(id: id)
            updateProfileLocally(profile) { current in
                self.profileStatus(current, replacingLabelWith: nil)
            }
            showBanner(title: "Label cleared", body: "Removed the saved label.", tone: .success)
            return true
        } catch {
            showBanner(title: "Command failed", body: error.localizedDescription, tone: .error)
            return false
        }
    }

    @discardableResult
    func exportProfiles(ids: [String], to destination: URL, descriptor: String) async -> Bool {
        guard !ids.isEmpty else { return false }

        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await self.service.exportProfiles(ids: ids, to: destination)
            showBanner(title: "Export complete", body: "Wrote \(descriptor) to \(destination.lastPathComponent).", tone: .success)
            return true
        } catch {
            showBanner(title: "Command failed", body: error.localizedDescription, tone: .error)
            return false
        }
    }

    @discardableResult
    func importBundle(from source: URL) async -> Bool {
        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await self.service.importProfiles(from: source)
            showBanner(title: "Import complete", body: "Profiles from \(source.lastPathComponent) are now available.", tone: .success)
            await refresh(trigger: .mutation)
            return true
        } catch {
            showBanner(title: "Command failed", body: error.localizedDescription, tone: .error)
            return false
        }
    }

    @discardableResult
    func deleteProfile(_ profile: ProfileStatus) async -> Bool {
        guard let id = profile.id else { return false }

        isLoading = true
        defer { isLoading = false }

        do {
            try await self.service.deleteProfile(id: id)
            showBanner(title: "Profile deleted", body: "\(profile.primaryText) was removed from saved profiles.", tone: .success)
            await refresh(trigger: .mutation)
            return true
        } catch {
            showBanner(title: "Command failed", body: error.localizedDescription, tone: .error)
            return false
        }
    }

    func loadDoctorReport(fix: Bool = false) async {
        isDoctorLoading = true
        defer { isDoctorLoading = false }

        do {
            doctorReport = try await service.doctor(fix: fix)
            if fix {
                showBanner(title: "Doctor repair finished", body: "Storage checks were re-run with safe repairs enabled.", tone: .success)
                await refresh(trigger: .mutation)
            }
        } catch {
            showBanner(title: "Doctor failed", body: error.localizedDescription, tone: .error)
        }
    }

    private func runMutation(
        successTitle: String,
        successBody: String,
        operation: @escaping () async throws -> Void
    ) async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await operation()
            showBanner(title: successTitle, body: successBody, tone: .success)
            await refresh(trigger: .mutation)
        } catch {
            showBanner(title: "Command failed", body: error.localizedDescription, tone: .error)
        }
    }

    private func configureAutoRefreshLoop() {
        autoRefreshTask?.cancel()
        guard isAutoRefreshEnabled else {
            autoRefreshTask = nil
            return
        }

        autoRefreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: autoRefreshInterval)
                guard !Task.isCancelled else { break }
                await self.refresh(trigger: .automatic)
            }
        }
    }

    private func mergeActiveProfile(_ activeProfile: ProfileStatus) {
        if profiles.isEmpty {
            profiles = [activeProfile]
            return
        }

        var updatedProfiles = profiles.map { profile in
            if profile.stableID == activeProfile.stableID || (profile.isCurrent && activeProfile.isCurrent) {
                return activeProfile
            }

            if profile.isCurrent && profile.stableID != activeProfile.stableID {
                return ProfileStatus(
                    id: profile.id,
                    label: profile.label,
                    email: profile.email,
                    plan: profile.plan,
                    isCurrent: false,
                    isSaved: profile.isSaved,
                    isApiKey: profile.isApiKey,
                    warnings: profile.warnings,
                    usage: profile.usage,
                    error: profile.error
                )
            }

            return profile
        }

        if !updatedProfiles.contains(where: { $0.stableID == activeProfile.stableID }) {
            updatedProfiles.insert(activeProfile, at: 0)
        }

        profiles = sortProfiles(updatedProfiles)
    }

    private func applyOptimisticSwitch(to target: ProfileStatus) {
        guard !profiles.isEmpty else { return }

        profiles = profiles.map { profile in
            if profile.stableID == target.stableID {
                return ProfileStatus(
                    id: profile.id,
                    label: profile.label,
                    email: profile.email,
                    plan: profile.plan,
                    isCurrent: true,
                    isSaved: profile.isSaved,
                    isApiKey: profile.isApiKey,
                    warnings: profile.warnings,
                    usage: profile.usage,
                    error: profile.error
                )
            }

            if profile.isCurrent {
                return ProfileStatus(
                    id: profile.id,
                    label: profile.label,
                    email: profile.email,
                    plan: profile.plan,
                    isCurrent: false,
                    isSaved: profile.isSaved,
                    isApiKey: profile.isApiKey,
                    warnings: profile.warnings,
                    usage: profile.usage,
                    error: profile.error
                )
            }

            return profile
        }
        profiles = sortProfiles(profiles)
        lastRefresh = .now
    }

    private func queueSwitchReconcile(for profile: ProfileStatus, mode: SwitchMode) {
        switchReconcileTask?.cancel()
        switchReconcileTask = Task { [weak self] in
            guard let self else { return }
            await self.reconcileProfilesAfterSwitch(mode: mode)
        }
    }

    private func reconcileProfilesAfterSwitch(mode: SwitchMode) async {
        if Task.isCancelled { return }

        if mode == .saveThenSwitch {
            do {
                let (response, storage) = try await service.fetchProfiles()
                guard !Task.isCancelled else { return }
                profiles = sortProfiles(response.profiles)
                detectedStorage = storage
                lastRefresh = .now
                refreshLaunchAtLoginState()
                return
            } catch {
                return
            }
        }

        do {
            let (activeProfile, storage) = try await service.fetchActiveProfile()
            guard !Task.isCancelled else { return }
            mergeActiveProfile(activeProfile)
            detectedStorage = storage
            lastRefresh = .now
        } catch {
            do {
                let (response, storage) = try await service.fetchProfiles()
                guard !Task.isCancelled else { return }
                profiles = sortProfiles(response.profiles)
                detectedStorage = storage
                lastRefresh = .now
                refreshLaunchAtLoginState()
            } catch {
                return
            }
        }
    }

    private func updateProfileLocally(
        _ target: ProfileStatus,
        transform: (ProfileStatus) -> ProfileStatus
    ) {
        profiles = profiles.map { profile in
            guard profile.stableID == target.stableID else { return profile }
            return transform(profile)
        }
        profiles = sortProfiles(profiles)
    }

    private func sortProfiles(_ profiles: [ProfileStatus]) -> [ProfileStatus] {
        profiles.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent {
                return lhs.isCurrent && !rhs.isCurrent
            }

            let nameComparison = lhs.sortName.compare(
                rhs.sortName,
                options: [.caseInsensitive, .numeric, .diacriticInsensitive, .widthInsensitive],
                range: nil,
                locale: .current
            )
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }

            return lhs.stableID.compare(
                rhs.stableID,
                options: [.caseInsensitive, .numeric, .diacriticInsensitive, .widthInsensitive],
                range: nil,
                locale: .current
            ) == .orderedAscending
        }
    }

    private func profileStatus(
        _ profile: ProfileStatus,
        replacingLabelWith label: String?
    ) -> ProfileStatus {
        ProfileStatus(
            id: profile.id,
            label: label,
            email: profile.email,
            plan: profile.plan,
            isCurrent: profile.isCurrent,
            isSaved: profile.isSaved,
            isApiKey: profile.isApiKey,
            warnings: profile.warnings,
            usage: profile.usage,
            error: profile.error
        )
    }

    private func showBanner(title: String, body: String, tone: BannerMessage.Tone) {
        bannerDismissTask?.cancel()
        let message = BannerMessage(tone: tone, title: title, body: body)
        banner = message

        if tone == .success {
            bannerDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3.5))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self?.banner?.id == message.id else { return }
                    self?.banner = nil
                }
            }
        } else {
            bannerDismissTask = nil
        }
    }

    func dismissBanner() {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        banner = nil
    }

    func dismissCodexRelaunchPrompt() {
        codexRelaunchPrompt = nil
    }

    @discardableResult
    func restartCodex() async -> Bool {
        isRestartingCodex = true
        defer { isRestartingCodex = false }

        do {
            try await restartCodexApplication()
            codexRelaunchPrompt = nil
            showBanner(
                title: "Codex reopened",
                body: "Codex has been reopened with the latest local profile state.",
                tone: .success
            )
            return true
        } catch {
            showBanner(
                title: "Could not reopen Codex",
                body: error.localizedDescription,
                tone: .error
            )
            return false
        }
    }

    func revealScriptsFolder() {
        guard let support = packagingSupport else { return }
        NSWorkspace.shared.activateFileViewerSelecting([support.scriptsURL])
    }

    func revealDistFolder() {
        guard let support = packagingSupport else { return }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: support.distURL.path) {
            try? fileManager.createDirectory(at: support.distURL, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([support.distURL])
    }

    private static func resolvePackagingSupport() -> PackagingSupport? {
        guard let rootURL = packageRootURL else {
            return nil
        }

        let packageFile = rootURL.appendingPathComponent("Package.swift")
        let scriptsURL = rootURL.appendingPathComponent("scripts", isDirectory: true)
        let distURL = rootURL.appendingPathComponent("dist", isDirectory: true)

        guard FileManager.default.fileExists(atPath: packageFile.path) else {
            return nil
        }

        return PackagingSupport(rootURL: rootURL, scriptsURL: scriptsURL, distURL: distURL)
    }

    private static var packageRootURL: URL? {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default

        while current.path != "/" {
            let packageFile = current.appendingPathComponent("Package.swift")
            if fileManager.fileExists(atPath: packageFile.path) {
                return current
            }
            current.deleteLastPathComponent()
        }

        return nil
    }

    private func restartCodexApplication() async throws {
        if let appURL = resolveCodexAppURL() {
            let bundleID = Bundle(url: appURL)?.bundleIdentifier ?? "com.openai.codex"
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            for app in runningApps {
                _ = app.terminate()
            }

            if !runningApps.isEmpty {
                try? await Task.sleep(for: .milliseconds(700))
                for app in runningApps where !app.isTerminated {
                    _ = app.forceTerminate()
                }
                try? await Task.sleep(for: .milliseconds(250))
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            return
        }

        if let executable = resolveCodexExecutablePath() {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["app"]
            try process.run()
            codexRelaunchPrompt = nil
            return
        }

        throw CodexProfilesError.commandFailed("Install Codex.app or make the `codex` command available to reopen it automatically.")
    }

    private func resolveCodexAppURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            return url
        }

        let fileManager = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Codex.app", isDirectory: true),
        ]

        return candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
    }

    private func resolveCodexExecutablePath() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        candidates.append(contentsOf: pathEntries.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") })

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex"),
        ])

        let nvmVersionsRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versionDirs = try? fileManager.contentsOfDirectory(
            at: nvmVersionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: versionDirs.map { $0.appendingPathComponent("bin/codex") })
        }

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }
}
