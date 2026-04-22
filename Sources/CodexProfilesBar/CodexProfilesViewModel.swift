import Foundation
import AppKit
import UserNotifications
import ApplicationServices

@MainActor
final class CodexProfilesViewModel: NSObject, ObservableObject {
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
    @Published private(set) var usageHistoryByProfileID: [String: [ProfileUsageHistoryPoint]] = [:]
    @Published private(set) var aggregateUsage: AggregateUsageSummary?
    @Published private(set) var detectedCodexVersion = DetectedCodexVersion(appVersion: nil, cliVersion: nil)
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var isInstallingUpdate = false
    @Published private(set) var availableAppUpdate: AppUpdateRelease?
    @Published private(set) var notificationInboxItems: [NotificationInboxItem] = []
    @Published private(set) var recommendedSwitch: ProfileSwitchRecommendation?
    @Published private(set) var activeImportPreview: PendingImportPreview?
    @Published var banner: BannerMessage?

    private let service = CodexProfilesService.shared
    private let launchAtLoginManager = LaunchAtLoginManager()
    private let notificationCenter = UNUserNotificationCenter.current()
    private let autoRefreshInterval: Duration = .seconds(60)
    private let fileManager = FileManager.default
    private let updateDownloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 15
        return URLSession(configuration: configuration)
    }()
    private let updateFeedURL = URL(string: "https://api.github.com/repos/MinhVuong1997/codex-profiles-bar/releases/latest")!
    private var bannerDismissTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var switchReconcileTask: Task<Void, Never>?
    private var favorites: [String]
    private var orderedProfileIDs: [String]
    private var lowUsageNotifications: [String: Bool] = [:]
    private var resetSoonNotifications: [String: Bool] = [:]
    private var usageHistoryURL: URL?
    private var hasLoadedUsageHistory = false
    private var isPerformingAutomaticSwitch = false
    private var presentedUpdateVersion: String?

    override init() {
        let storedAutoRefresh = UserDefaults.standard.object(forKey: Preferences.autoRefreshKey) as? Bool
        isAutoRefreshEnabled = storedAutoRefresh ?? true
        favorites = UserDefaults.standard.stringArray(forKey: Preferences.favoriteProfileIDsKey) ?? []
        orderedProfileIDs = UserDefaults.standard.stringArray(forKey: Preferences.orderedProfileIDsKey) ?? []
        super.init()
        packagingSupport = Self.resolvePackagingSupport()
        loadNotificationInbox()
        refreshLaunchAtLoginState()
        configureAutoRefreshLoop()
        Task {
            await requestNotificationAuthorizationIfNeeded()
            await refreshDetectedCodexVersion()
            await checkForUpdates(userInitiated: false)
            await refresh(trigger: .manual)
        }
        installNotificationActionObserver()
    }

    deinit {
        switchReconcileTask?.cancel()
        autoRefreshTask?.cancel()
        bannerDismissTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    var menuBarSymbolName: String {
        let warningThreshold = notificationThreshold
        if profiles.contains(where: { $0.isLowUsage(threshold: warningThreshold) }) {
            return "person.crop.circle.badge.exclamationmark"
        }
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

    var menuBarTitle: String {
        guard let current = profiles.first(where: \.isCurrent) else {
            return "Codex"
        }

        let baseName = shortenedMenuBarTitle(for: current.primaryText)
        if let percent = current.usageDisplayPercent {
            return "\(baseName) \(percent)%"
        }
        return baseName
    }

    var notificationThreshold: Int {
        let stored = UserDefaults.standard.integer(forKey: Preferences.usageWarningThresholdKey)
        return stored == 0 ? 10 : stored
    }

    var currentProfile: ProfileStatus? {
        profiles.first(where: \.isCurrent)
    }

    var unreadInboxCount: Int {
        notificationInboxItems.filter(\.isUnread).count
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

    func isFavorite(_ profile: ProfileStatus) -> Bool {
        guard let id = profile.id else { return false }
        return favorites.contains(id)
    }

    func toggleFavorite(_ profile: ProfileStatus) {
        guard let id = profile.id else { return }
        if let index = favorites.firstIndex(of: id) {
            favorites.remove(at: index)
        } else {
            favorites.insert(id, at: 0)
            if !orderedProfileIDs.contains(id) {
                orderedProfileIDs.insert(id, at: 0)
            }
        }
        persistOrdering()
        profiles = sortProfiles(profiles)
        aggregateUsage = makeAggregateUsageSummary(from: profiles)
    }

    func setFavoriteState(for profileIDs: Set<String>, isFavorite: Bool) {
        guard !profileIDs.isEmpty else { return }

        if isFavorite {
            for id in profileIDs where !favorites.contains(id) {
                favorites.insert(id, at: 0)
                if !orderedProfileIDs.contains(id) {
                    orderedProfileIDs.insert(id, at: 0)
                }
            }
        } else {
            favorites.removeAll { profileIDs.contains($0) }
        }

        persistOrdering()
        profiles = sortProfiles(profiles)
        aggregateUsage = makeAggregateUsageSummary(from: profiles)
    }

    @discardableResult
    func cycleToNextProfile() async -> Bool {
        let switchableProfiles = savedProfiles.filter { $0.id != nil }
        guard !switchableProfiles.isEmpty else { return false }

        let currentIndex = switchableProfiles.firstIndex(where: \.isCurrent) ?? -1
        let nextIndex = (currentIndex + 1) % switchableProfiles.count
        let nextProfile = switchableProfiles[nextIndex]

        guard !nextProfile.isCurrent else { return false }
        return await switchToProfile(
            nextProfile,
            mode: .standard,
            shouldPromptReopen: false,
            successTitle: "Cycled profile",
            successBody: "Now using \(nextProfile.primaryText)."
        )
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

            normalizeStoredOrdering()
            profiles = sortProfiles(profiles)

            if let storage = detectedStorage {
                loadUsageHistoryIfNeeded(storage: storage)
            }
            persistUsageSnapshotsIfNeeded()
            aggregateUsage = makeAggregateUsageSummary(from: profiles)
            updateSmartSwitchRecommendation()
            await evaluateUsageAlerts(trigger: trigger)
            if trigger == .automatic {
                await autoSwitchIfNeeded()
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
    func switchToProfile(
        _ profile: ProfileStatus,
        mode: SwitchMode,
        shouldPromptReopen: Bool? = nil,
        successTitle: String = "Profile switched",
        successBody: String? = nil
    ) async -> Bool {
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
            showBanner(
                title: successTitle,
                body: successBody ?? "Now using \(profile.primaryText).",
                tone: .success
            )
            let reopenPromptPreference = UserDefaults.standard.object(forKey: Preferences.promptReopenCodexKey) as? Bool ?? true
            if shouldPromptReopen ?? reopenPromptPreference {
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
    func previewImportBundle(from source: URL) async -> ImportPreviewPayload? {
        isLoading = true
        defer { isLoading = false }

        do {
            return try await service.previewImport(from: source)
        } catch {
            showBanner(title: "Import preview failed", body: error.localizedDescription, tone: .error)
            return nil
        }
    }

    func presentImportPreview(sourceURL: URL, payload: ImportPreviewPayload) {
        activeImportPreview = PendingImportPreview(sourceURL: sourceURL, payload: payload)
    }

    func dismissImportPreview() {
        activeImportPreview = nil
    }

    @discardableResult
    func importBundle(from source: URL) async -> Bool {
        isLoading = true
        defer { isLoading = false }

        do {
            let importPreviewSnapshot = activeImportPreview
            let payload = try await self.service.importProfiles(from: source)
            let descriptor = payload.count == 1 ? "1 profile" : "\(payload.count) profiles"
            let bannerBody = "Imported \(descriptor) from \(source.lastPathComponent)."
            showBanner(title: "Import complete", body: bannerBody, tone: .success)
            await scheduleNotification(
                identifier: "import-complete-\(UUID().uuidString)",
                title: "Codex profiles imported",
                body: importNotificationBody(
                    descriptor: descriptor,
                    sourceFilename: source.lastPathComponent,
                    preview: importPreviewSnapshot
                ),
                inboxTone: .success
            )
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

    @discardableResult
    func deleteProfiles(_ profilesToDelete: [ProfileStatus]) async -> Bool {
        let targets = profilesToDelete.compactMap { profile -> (String, String)? in
            guard let id = profile.id else { return nil }
            return (id, profile.primaryText)
        }
        guard !targets.isEmpty else { return false }

        isLoading = true
        defer { isLoading = false }

        do {
            for (id, _) in targets {
                try await service.deleteProfile(id: id)
            }
            let descriptor = targets.count == 1 ? targets[0].1 : "\(targets.count) profiles"
            showBanner(title: "Profiles deleted", body: "Removed \(descriptor) from saved profiles.", tone: .success)
            await refresh(trigger: .mutation)
            return true
        } catch {
            showBanner(title: "Command failed", body: error.localizedDescription, tone: .error)
            return false
        }
    }

    func markInboxItemRead(_ item: NotificationInboxItem) {
        guard let index = notificationInboxItems.firstIndex(where: { $0.id == item.id }) else { return }
        guard notificationInboxItems[index].isUnread else { return }
        notificationInboxItems[index].isUnread = false
        persistNotificationInbox()
    }

    func markAllInboxItemsRead() {
        guard notificationInboxItems.contains(where: \.isUnread) else { return }
        notificationInboxItems = notificationInboxItems.map { item in
            var updated = item
            updated.isUnread = false
            return updated
        }
        persistNotificationInbox()
    }

    func clearNotificationInbox() {
        notificationInboxItems = []
        persistNotificationInbox()
    }

    @discardableResult
    func performInboxAction(for item: NotificationInboxItem) async -> Bool {
        markInboxItemRead(item)

        guard let actionKind = item.actionKind else { return true }

        switch actionKind {
        case .reopenCodex:
            return await restartCodex()
        case .switchToProfile:
            guard let targetID = item.targetProfileID,
                  let profile = savedProfiles.first(where: { $0.id == targetID }) else {
                showBanner(title: "Profile unavailable", body: "That saved profile is no longer available.", tone: .warning)
                return false
            }
            return await switchToProfile(
                profile,
                mode: .standard,
                shouldPromptReopen: false,
                successTitle: "Recommended profile switched",
                successBody: "Now using \(profile.primaryText)."
            )
        }
    }

    @discardableResult
    func switchToRecommendedProfile() async -> Bool {
        guard let recommendation = recommendedSwitch,
              let profile = savedProfiles.first(where: { $0.id == recommendation.profileID }) else {
            showBanner(title: "No recommendation", body: "There is no recommended fallback profile right now.", tone: .warning)
            return false
        }

        return await switchToProfile(
            profile,
            mode: .standard,
            shouldPromptReopen: true,
            successTitle: "Switched to recommended profile",
            successBody: "Now using \(profile.primaryText) with \(recommendation.usagePercent)% remaining."
        )
    }

    func loadDoctorReport(fix: Bool = false) async {
        isDoctorLoading = true
        defer { isDoctorLoading = false }

        do {
            let report = try await service.doctor(fix: fix)
            doctorReport = await enrichDoctorReport(report)
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
        updateSmartSwitchRecommendation()
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
        updateSmartSwitchRecommendation()
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
        updateSmartSwitchRecommendation()
    }

    private func sortProfiles(_ profiles: [ProfileStatus]) -> [ProfileStatus] {
        let orderLookup = Dictionary(uniqueKeysWithValues: orderedProfileIDs.enumerated().map { ($0.element, $0.offset) })
        return profiles.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent {
                return lhs.isCurrent && !rhs.isCurrent
            }

            let lhsOrder = lhs.id.flatMap { orderLookup[$0] } ?? Int.max
            let rhsOrder = rhs.id.flatMap { orderLookup[$0] } ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }

            let lhsFavorite = isFavorite(lhs)
            let rhsFavorite = isFavorite(rhs)
            if lhsFavorite != rhsFavorite {
                return lhsFavorite && !rhsFavorite
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

    private func shortenedMenuBarTitle(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Codex" }
        let compact = trimmed.replacingOccurrences(of: "@.*$", with: "", options: .regularExpression)
        return String(compact.prefix(12))
    }

    private func persistOrdering() {
        UserDefaults.standard.set(favorites, forKey: Preferences.favoriteProfileIDsKey)
        UserDefaults.standard.set(orderedProfileIDs, forKey: Preferences.orderedProfileIDsKey)
    }

    private func normalizeStoredOrdering() {
        let availableIDs = Set(savedProfiles.compactMap(\.id))
        orderedProfileIDs = orderedProfileIDs.filter { availableIDs.contains($0) }
        favorites = favorites.filter { availableIDs.contains($0) }

        for id in savedProfiles.compactMap(\.id) where !orderedProfileIDs.contains(id) {
            orderedProfileIDs.append(id)
        }

        persistOrdering()
    }

    private func loadNotificationInbox() {
        guard let data = UserDefaults.standard.data(forKey: Preferences.notificationInboxKey) else {
            notificationInboxItems = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let items = try? decoder.decode([NotificationInboxItem].self, from: data) {
            notificationInboxItems = items
        } else {
            notificationInboxItems = []
        }
    }

    private func persistNotificationInbox() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(notificationInboxItems) else { return }
        UserDefaults.standard.set(data, forKey: Preferences.notificationInboxKey)
    }

    private func recordInboxItem(
        tone: NotificationInboxTone,
        title: String,
        body: String,
        actionKind: NotificationInboxActionKind? = nil,
        actionLabel: String? = nil,
        targetProfileID: String? = nil
    ) {
        let item = NotificationInboxItem(
            tone: tone,
            title: title,
            body: body,
            actionKind: actionKind,
            actionLabel: actionLabel,
            targetProfileID: targetProfileID
        )

        notificationInboxItems.insert(item, at: 0)
        notificationInboxItems = Array(notificationInboxItems.prefix(40))
        persistNotificationInbox()
    }

    private func requestNotificationAuthorizationIfNeeded() async {
        let notificationsEnabled = UserDefaults.standard.object(forKey: Preferences.notificationsEnabledKey) as? Bool ?? true
        guard notificationsEnabled else { return }
        _ = try? await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
    }

    private func installNotificationActionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReopenCodexNotificationAction),
            name: .reopenCodexFromNotification,
            object: nil
        )
    }

    @objc
    private func handleReopenCodexNotificationAction() {
        Task { @MainActor in
            _ = await restartCodex()
        }
    }

    private func refreshDetectedCodexVersion() async {
        let appVersion = resolveCodexAppURL()
            .flatMap { Bundle(url: $0) }
            .flatMap { bundle in
                bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            }

        let cliVersion = await detectCLIInstalledVersion()
        detectedCodexVersion = DetectedCodexVersion(appVersion: appVersion, cliVersion: cliVersion)
    }

    private func detectCLIInstalledVersion() async -> String? {
        guard let executable = resolveCodexExecutablePath() else { return nil }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--version"]
            let executableDirectory = executable.deletingLastPathComponent().path
            let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
            process.environment = [
                "PATH": "\(executableDirectory):\(currentPath):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard process.terminationStatus == 0, !output.isEmpty else { return nil }
                let firstLine = output.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let firstLine, !firstLine.isEmpty else { return nil }
                guard !firstLine.localizedCaseInsensitiveContains("no such file or directory"),
                      !firstLine.hasPrefix("env:"),
                      firstLine.localizedCaseInsensitiveContains("codex") else {
                    return nil
                }
                return firstLine
            } catch {
                return nil
            }
        }.value
    }

    private func loadUsageHistoryIfNeeded(storage: StorageResolution) {
        guard !hasLoadedUsageHistory else { return }

        let historyURL = storage.url.appendingPathComponent("profiles-bar-usage-history.json")
        let legacyHistoryURL = storage.url.appendingPathComponent("profiles/usage-history.json")
        usageHistoryURL = historyURL
        defer { hasLoadedUsageHistory = true }

        if fileManager.fileExists(atPath: historyURL.path),
           let data = try? Data(contentsOf: historyURL),
           let store = decodeUsageHistoryStore(from: data) {
            usageHistoryByProfileID = store.entries
            return
        }

        if fileManager.fileExists(atPath: legacyHistoryURL.path),
           let data = try? Data(contentsOf: legacyHistoryURL),
           let store = decodeUsageHistoryStore(from: data) {
            usageHistoryByProfileID = store.entries
            writeUsageHistory()
            return
        }

        guard fileManager.fileExists(atPath: historyURL.path),
              let data = try? Data(contentsOf: historyURL),
              let store = decodeUsageHistoryStore(from: data) else {
            usageHistoryByProfileID = [:]
            return
        }
        usageHistoryByProfileID = store.entries
    }

    private func decodeUsageHistoryStore(from data: Data) -> ProfileUsageHistoryStore? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        if let store = try? decoder.decode(ProfileUsageHistoryStore.self, from: data) {
            return store
        }

        guard let legacyEntries = try? decoder.decode([LegacyProfileUsageEntry].self, from: data) else {
            return nil
        }

        var grouped = [String: [ProfileUsageHistoryPoint]]()
        for entry in legacyEntries {
            let point = ProfileUsageHistoryPoint(
                recordedAt: Date(timeIntervalSince1970: TimeInterval(entry.timestamp)),
                fiveHourPercent: entry.primaryBucket?.fiveHourLeftPercent,
                weeklyPercent: entry.primaryBucket?.weeklyLeftPercent
            )
            grouped[entry.profileID, default: []].append(point)
        }

        for key in grouped.keys {
            grouped[key] = grouped[key]?
                .sorted(by: { $0.recordedAt < $1.recordedAt })
                .reduce(into: [ProfileUsageHistoryPoint]()) { result, point in
                    if result.last?.hourStamp != point.hourStamp {
                        result.append(point)
                    } else {
                        result[result.count - 1] = point
                    }
                }
        }

        return ProfileUsageHistoryStore(entries: grouped)
    }

    private func persistUsageSnapshotsIfNeeded() {
        guard usageHistoryURL != nil || detectedStorage != nil else { return }
        if usageHistoryURL == nil, let detectedStorage {
            usageHistoryURL = detectedStorage.url.appendingPathComponent("profiles-bar-usage-history.json")
        }

        var didChange = false
        let now = Date()

        for profile in profiles {
            guard let id = profile.id, let bucket = profile.primaryUsageBucket else { continue }

            let point = ProfileUsageHistoryPoint(
                recordedAt: now,
                fiveHourPercent: bucket.fiveHour?.leftPercent,
                weeklyPercent: bucket.weekly?.leftPercent
            )
            var entries = usageHistoryByProfileID[id] ?? []
            if let last = entries.last, last.hourStamp == point.hourStamp {
                continue
            }
            entries.append(point)
            entries = Array(entries.suffix(72))
            usageHistoryByProfileID[id] = entries
            didChange = true
        }

        if didChange {
            writeUsageHistory()
        }
    }

    private func writeUsageHistory() {
        guard let usageHistoryURL else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970

        do {
            let data = try encoder.encode(ProfileUsageHistoryStore(entries: usageHistoryByProfileID))
            if !fileManager.fileExists(atPath: usageHistoryURL.deletingLastPathComponent().path) {
                try fileManager.createDirectory(
                    at: usageHistoryURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }
            try data.write(to: usageHistoryURL, options: .atomic)
        } catch {
            // Keep history best-effort so background refresh never fails because of disk writes.
        }
    }

    private struct LegacyProfileUsageEntry: Decodable {
        let timestamp: Int
        let profileID: String
        let buckets: [LegacyProfileUsageBucket]

        var primaryBucket: LegacyProfileUsageBucket? {
            buckets.first
        }
    }

    private struct LegacyProfileUsageBucket: Decodable {
        let fiveHourLeftPercent: Int?
        let weeklyLeftPercent: Int?

        enum CodingKeys: String, CodingKey {
            case fiveHourLeftPercent
            case weeklyLeftPercent
        }
    }

    private func makeAggregateUsageSummary(from profiles: [ProfileStatus]) -> AggregateUsageSummary {
        let buckets = profiles.compactMap(\.primaryUsageBucket)
        return AggregateUsageSummary(
            trackedProfilesCount: buckets.count,
            favoritesCount: savedProfiles.filter { isFavorite($0) }.count,
            totalFiveHourPercent: buckets.compactMap { $0.fiveHour?.leftPercent }.reduce(0, +),
            totalWeeklyPercent: buckets.compactMap { $0.weekly?.leftPercent }.reduce(0, +),
            lowProfilesCount: profiles.filter { $0.isLowUsage(threshold: notificationThreshold) }.count
        )
    }

    private func updateSmartSwitchRecommendation() {
        guard let currentProfile else {
            recommendedSwitch = nil
            return
        }

        let candidates = savedProfiles
            .filter { !$0.isCurrent && $0.canSwitch }
            .compactMap { profile -> (ProfileStatus, Int, Int)? in
                guard let usagePercent = profile.usageDisplayPercent, usagePercent > 0 else { return nil }
                let resetAt = profile.primaryUsageBucket?.nearestResetAt ?? Int.max
                return (profile, usagePercent, resetAt)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                return lhs.2 > rhs.2
            }

        guard let best = candidates.first, let profileID = best.0.id else {
            recommendedSwitch = nil
            return
        }

        let reason: String
        if currentProfile.isUsageDepleted {
            reason = "Best fallback because the active profile is depleted."
        } else if currentProfile.isLowUsage(threshold: notificationThreshold) {
            reason = "Best backup while the active profile is running low."
        } else {
            reason = "Strongest standby profile based on remaining usage."
        }

        recommendedSwitch = ProfileSwitchRecommendation(
            profileID: profileID,
            profileName: best.0.primaryText,
            usagePercent: best.1,
            reason: reason
        )
    }

    private func evaluateUsageAlerts(trigger: RefreshTrigger) async {
        let notificationsEnabled = UserDefaults.standard.object(forKey: Preferences.notificationsEnabledKey) as? Bool ?? true
        guard notificationsEnabled else { return }
        guard let currentProfile = profiles.first(where: \.isCurrent),
              let id = currentProfile.id,
              let bucket = currentProfile.primaryUsageBucket else {
            lowUsageNotifications.removeAll()
            resetSoonNotifications.removeAll()
            return
        }

        lowUsageNotifications = lowUsageNotifications.filter { $0.key == id }
        resetSoonNotifications = resetSoonNotifications.filter { $0.key == id }

        let isLow = currentProfile.isLowUsage(threshold: notificationThreshold)
        let wasLow = lowUsageNotifications[id] ?? false
        if isLow && !wasLow {
            let recommendation = recommendedSwitch
            await scheduleNotification(
                identifier: "low-usage-\(id)",
                title: "Codex profile running low",
                body: "\(currentProfile.primaryText) is at \(currentProfile.usageDisplayPercent ?? 0)% remaining.",
                inboxTone: .warning,
                inboxActionKind: recommendation.map { _ in .switchToProfile },
                inboxActionLabel: recommendation.map { "Switch to \($0.profileName)" },
                inboxTargetProfileID: recommendation?.profileID
            )
        }
        lowUsageNotifications[id] = isLow

        let resetSoon = bucket.nearestResetAt.map {
            Date(timeIntervalSince1970: TimeInterval($0)).timeIntervalSinceNow <= 6 * 3600
        } ?? false
        let wasResetSoon = resetSoonNotifications[id] ?? false
        if resetSoon && !wasResetSoon && trigger != .mutation {
            await scheduleNotification(
                identifier: "reset-soon-\(id)",
                title: "Codex usage resets soon",
                body: "\(currentProfile.primaryText) has a usage bucket resetting within the next 6 hours.",
                inboxTone: .info
            )
        }
        resetSoonNotifications[id] = resetSoon
    }

    private func autoSwitchIfNeeded() async {
        let autoSwitchEnabled = UserDefaults.standard.object(forKey: Preferences.autoSwitchOnDepletionKey) as? Bool ?? false
        guard autoSwitchEnabled, !isPerformingAutomaticSwitch else { return }
        guard let current = profiles.first(where: \.isCurrent), current.isUsageDepleted else { return }

        guard let fallback = savedProfiles
            .filter({ !$0.isCurrent && ($0.usageDisplayPercent ?? 0) > 0 })
            .max(by: { ($0.usageDisplayPercent ?? 0) < ($1.usageDisplayPercent ?? 0) }) else {
            return
        }

        isPerformingAutomaticSwitch = true
        defer { isPerformingAutomaticSwitch = false }

        let switched = await switchToProfile(
            fallback,
            mode: .standard,
            shouldPromptReopen: false,
            successTitle: "Auto-switched profile",
            successBody: "Switched to \(fallback.primaryText) because the current profile ran out of usage."
        )

        if switched {
            await scheduleNotification(
                identifier: "auto-switch-\(fallback.stableID)",
                title: "Codex profile auto-switched",
                body: "Now using \(fallback.primaryText) because the previous profile was depleted.",
                categoryIdentifier: NotificationCategoryIdentifier.autoSwitch,
                inboxTone: .success,
                inboxActionKind: .reopenCodex,
                inboxActionLabel: "Reopen Codex"
            )
        }
    }

    private func scheduleNotification(
        identifier: String,
        title: String,
        body: String,
        categoryIdentifier: String? = nil,
        inboxTone: NotificationInboxTone? = nil,
        inboxActionKind: NotificationInboxActionKind? = nil,
        inboxActionLabel: String? = nil,
        inboxTargetProfileID: String? = nil
    ) async {
        if let inboxTone {
            recordInboxItem(
                tone: inboxTone,
                title: title,
                body: body,
                actionKind: inboxActionKind,
                actionLabel: inboxActionLabel,
                targetProfileID: inboxTargetProfileID
            )
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .active
        if let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        try? await notificationCenter.add(request)
    }

    private func importNotificationBody(
        descriptor: String,
        sourceFilename: String,
        preview: PendingImportPreview?
    ) -> String {
        guard let preview else {
            return "Imported \(descriptor) from \(sourceFilename)."
        }

        let skippedCount = preview.payload.skippedCount
        guard skippedCount > 0 else {
            return "Imported \(descriptor) from \(sourceFilename)."
        }

        let skippedDescriptor = skippedCount == 1 ? "1 item was skipped" : "\(skippedCount) items were skipped"
        return "Imported \(descriptor) from \(sourceFilename). \(skippedDescriptor)."
    }

    private func enrichDoctorReport(_ report: DoctorReport) async -> DoctorReport {
        var checks = report.checks

        if let detectedStorage {
            let authURL = detectedStorage.url.appendingPathComponent("auth.json")
            let profilesURL = detectedStorage.url.appendingPathComponent("profiles", isDirectory: true)
            checks.append(doctorCheckForLoginStatus(authURL: authURL))
            checks.append(doctorCheckForPermissions(name: "auth permissions", url: authURL))
            checks.append(doctorCheckForPermissions(name: "profiles permissions", url: profilesURL))
        }

        checks.append(
            DoctorCheck(
                name: "global shortcut accessibility",
                level: AXIsProcessTrusted() ? "ok" : "warn",
                detail: AXIsProcessTrusted()
                    ? "trusted for global key monitoring"
                    : "grant Accessibility access for Option-Command-P outside the app"
            )
        )

        checks.append(await doctorCheckForAuthNetwork())
        let summary = summarizeDoctorChecks(checks)
        return DoctorReport(checks: checks, summary: summary, repairs: report.repairs, error: report.error)
    }

    private func summarizeDoctorChecks(_ checks: [DoctorCheck]) -> DoctorSummary {
        var ok = 0
        var warn = 0
        var error = 0
        var info = 0

        for check in checks {
            switch check.level {
            case "ok": ok += 1
            case "warn": warn += 1
            case "error": error += 1
            default: info += 1
            }
        }

        return DoctorSummary(ok: ok, warn: warn, error: error, info: info)
    }

    private func doctorCheckForLoginStatus(authURL: URL) -> DoctorCheck {
        guard fileManager.fileExists(atPath: authURL.path) else {
            return DoctorCheck(name: "login status", level: "warn", detail: "auth.json missing")
        }

        guard let data = try? Data(contentsOf: authURL), !data.isEmpty else {
            return DoctorCheck(name: "login status", level: "warn", detail: "auth.json is empty")
        }

        return DoctorCheck(name: "login status", level: "ok", detail: "credentials file present")
    }

    private func doctorCheckForPermissions(name: String, url: URL) -> DoctorCheck {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return DoctorCheck(name: name, level: "warn", detail: "could not read permissions")
        }

        let octal = String(permissions.intValue, radix: 8)
        return DoctorCheck(name: name, level: "info", detail: "mode \(octal)")
    }

    private func doctorCheckForAuthNetwork() async -> DoctorCheck {
        guard let url = URL(string: "https://auth.openai.com") else {
            return DoctorCheck(name: "auth network", level: "error", detail: "invalid auth URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<500).contains(statusCode) {
                return DoctorCheck(name: "auth network", level: "ok", detail: "reachable (\(statusCode))")
            }
            return DoctorCheck(name: "auth network", level: "warn", detail: "unexpected status \(statusCode)")
        } catch {
            return DoctorCheck(name: "auth network", level: "warn", detail: error.localizedDescription)
        }
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

    func checkForUpdates(userInitiated: Bool = true) async {
        guard !isCheckingForUpdates else { return }
        guard let currentVersion = currentProfilesBarVersion() else {
            if userInitiated {
                showBanner(
                    title: "Version unavailable",
                    body: "Update checks require a packaged app build with a bundle version.",
                    tone: .warning
                )
            }
            return
        }

        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        do {
            let release = try await fetchLatestAppRelease()
            guard isVersion(release.version, newerThan: currentVersion) else {
                if userInitiated {
                    showBanner(
                        title: "Up to date",
                        body: "Codex Profiles Bar \(currentVersion) is the latest available release.",
                        tone: .success
                    )
                }
                return
            }

            availableAppUpdate = release

            if !userInitiated, presentedUpdateVersion == release.version {
                return
            }

            presentedUpdateVersion = release.version
            presentUpdateAlert(for: release, currentVersion: currentVersion)
        } catch {
            if userInitiated {
                showBanner(title: "Update check failed", body: error.localizedDescription, tone: .error)
            }
        }
    }

    func showAvailableUpdateDetails() {
        guard let release = availableAppUpdate else { return }
        let currentVersion = currentProfilesBarVersion() ?? "current build"
        presentUpdateAlert(for: release, currentVersion: currentVersion)
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
            process.arguments = ["app", currentWorkspaceURL().path]
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

    private func currentWorkspaceURL() -> URL {
        packagingSupport?.rootURL ?? Self.packageRootURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private func currentProfilesBarVersion() -> String? {
        let bundle = Bundle.main
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmedShortVersion = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedShortVersion, !trimmedShortVersion.isEmpty {
            return normalizeVersionString(trimmedShortVersion)
        }
        return nil
    }

    private func fetchLatestAppRelease() async throws -> AppUpdateRelease {
        var request = URLRequest(url: updateFeedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexProfilesBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexProfilesError.invalidResponse("Update server returned an invalid response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CodexProfilesError.invalidResponse("Update server returned status \(httpResponse.statusCode).")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubReleaseResponse.self, from: data)
        let normalizedVersion = normalizeVersionString(release.tagName)
        guard !normalizedVersion.isEmpty else {
            throw CodexProfilesError.invalidResponse("Latest release is missing a valid version tag.")
        }

        let primaryAssetURL = release.assets.first(where: { $0.name.localizedCaseInsensitiveContains(".dmg") })?.browserDownloadURL
            ?? release.assets.first?.browserDownloadURL

        return AppUpdateRelease(
            version: normalizedVersion,
            title: release.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? release.tagName,
            notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "No release notes were provided for this release.",
            htmlURL: release.htmlURL,
            downloadURL: primaryAssetURL,
            publishedAt: release.publishedAt
        )
    }

    private func normalizeVersionString(_ value: String) -> String {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[^0-9]+", with: "", options: .regularExpression)
        return cleaned.isEmpty ? value.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let lhsComponents = versionComponents(from: lhs)
        let rhsComponents = versionComponents(from: rhs)
        let count = max(lhsComponents.count, rhsComponents.count)

        for index in 0..<count {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
        }
        return false
    }

    private func versionComponents(from value: String) -> [Int] {
        normalizeVersionString(value)
            .split(separator: ".")
            .compactMap { component in
                let digits = component.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
                return Int(digits)
            }
    }

    private func presentUpdateAlert(for release: AppUpdateRelease, currentVersion: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update available: \(release.title)"
        alert.informativeText = "Installed version: \(currentVersion)\nLatest version: \(release.version)"
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")
        alert.accessoryView = makeUpdateNotesView(for: release)

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task { await installUpdate(for: release) }
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func makeUpdateNotesView(for release: AppUpdateRelease) -> NSView {
        UpdateNotesAccessoryView(notes: release.notes)
    }

    private func installUpdate(for release: AppUpdateRelease) async {
        guard !isInstallingUpdate else { return }
        isInstallingUpdate = true

        do {
            let installation = try await prepareSelfUpdateInstallation(for: release)
            try launchSelfUpdateInstaller(installation.scriptURL)
            showBanner(
                title: "Installing update",
                body: "Codex Profiles Bar will relaunch after version \(release.version) is installed.",
                tone: .success
            )
            try? await Task.sleep(for: .milliseconds(350))
            NSApp.terminate(nil)
        } catch {
            isInstallingUpdate = false
            showBanner(title: "Install update failed", body: error.localizedDescription, tone: .error)
        }
    }

    private func prepareSelfUpdateInstallation(for release: AppUpdateRelease) async throws -> SelfUpdateInstallation {
        guard let downloadURL = release.downloadURL else {
            throw CodexProfilesError.commandFailed("This release does not include a direct install asset. Open the release page instead.")
        }

        let targetAppURL = try currentAppBundleURLForSelfUpdate()
        let workDirectory = try makeSelfUpdateWorkspace(for: release.version)
        let diskImageURL = workDirectory.appendingPathComponent(downloadURL.lastPathComponent.nonEmpty ?? "CodexProfilesBar-\(release.version).dmg")
        let logURL = workDirectory.appendingPathComponent("self-update.log")

        try await downloadUpdateDiskImage(from: downloadURL, to: diskImageURL)

        let scriptURL = try writeSelfUpdateScript(
            releaseVersion: release.version,
            workDirectory: workDirectory,
            diskImageURL: diskImageURL,
            targetAppURL: targetAppURL,
            logURL: logURL
        )

        return SelfUpdateInstallation(scriptURL: scriptURL)
    }

    private func currentAppBundleURLForSelfUpdate() throws -> URL {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard bundleURL.pathExtension == "app" else {
            throw CodexProfilesError.commandFailed("Self-update only works from a packaged .app build.")
        }

        let parentDirectory = bundleURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parentDirectory.path) || fileManager.isWritableFile(atPath: bundleURL.path) else {
            throw CodexProfilesError.commandFailed("The current app location is not writable. Move Codex Profiles Bar to a writable folder such as ~/Applications or update it manually.")
        }

        return bundleURL
    }

    private func makeSelfUpdateWorkspace(for version: String) throws -> URL {
        let sanitizedVersion = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("codexprofilesbar-update-\(sanitizedVersion)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        return workDirectory
    }

    private func downloadUpdateDiskImage(from remoteURL: URL, to localURL: URL) async throws {
        var request = URLRequest(url: remoteURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("CodexProfilesBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let (temporaryURL, response) = try await updateDownloadSession.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexProfilesError.invalidResponse("Update download returned an invalid response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CodexProfilesError.invalidResponse("Update download returned status \(httpResponse.statusCode).")
        }

        if fileManager.fileExists(atPath: localURL.path) {
            try fileManager.removeItem(at: localURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: localURL)
    }

    private func writeSelfUpdateScript(
        releaseVersion: String,
        workDirectory: URL,
        diskImageURL: URL,
        targetAppURL: URL,
        logURL: URL
    ) throws -> URL {
        let scriptURL = workDirectory.appendingPathComponent("install-update.sh")
        let script = """
        #!/bin/zsh
        set -euo pipefail

        APP_PID=\(ProcessInfo.processInfo.processIdentifier)
        RELEASE_VERSION=\(shellQuoted(releaseVersion))
        WORK_DIR=\(shellQuoted(workDirectory.path))
        DISK_IMAGE=\(shellQuoted(diskImageURL.path))
        TARGET_APP=\(shellQuoted(targetAppURL.path))
        LOG_FILE=\(shellQuoted(logURL.path))
        MOUNT_POINT="$WORK_DIR/mount"
        STAGED_APP="$WORK_DIR/staged-app"

        exec >>"$LOG_FILE" 2>&1

        cleanup() {
          /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || /usr/bin/hdiutil detach "$MOUNT_POINT" -force -quiet >/dev/null 2>&1 || true
        }
        trap cleanup EXIT

        echo "Installing Codex Profiles Bar $RELEASE_VERSION"

        while /bin/kill -0 "$APP_PID" >/dev/null 2>&1; do
          /bin/sleep 0.5
        done

        /bin/mkdir -p "$MOUNT_POINT"
        /usr/bin/hdiutil attach "$DISK_IMAGE" -nobrowse -quiet -mountpoint "$MOUNT_POINT"

        SOURCE_APP=$(/usr/bin/find "$MOUNT_POINT" -maxdepth 2 -name '*.app' -print -quit)
        if [ -z "$SOURCE_APP" ]; then
          echo "No .app bundle found inside downloaded update image."
          exit 1
        fi

        /bin/rm -rf "$STAGED_APP"
        /usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"
        /bin/rm -rf "$TARGET_APP"
        /usr/bin/ditto "$STAGED_APP" "$TARGET_APP"
        /usr/bin/xattr -cr "$TARGET_APP" || true
        /usr/bin/open "$TARGET_APP"

        ( /bin/sleep 4; /bin/rm -rf "$WORK_DIR" ) >/dev/null 2>&1 &
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func launchSelfUpdateInstaller(_ scriptURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()
        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil
        try process.run()
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private struct SelfUpdateInstallation {
        let scriptURL: URL
    }

    private final class UpdateNotesAccessoryView: NSView {
        private let fixedSize = NSSize(width: 420, height: 252)

        override var intrinsicContentSize: NSSize {
            fixedSize
        }

        init(notes: String) {
            super.init(frame: NSRect(origin: .zero, size: fixedSize))
            translatesAutoresizingMaskIntoConstraints = false

            let titleLabel = NSTextField(labelWithString: "Release notes")
            titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.lineBreakMode = .byTruncatingTail

            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: fixedSize.width - 24, height: 210))
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.font = .systemFont(ofSize: 12)
            textView.string = notes
            textView.textColor = .labelColor
            textView.textContainerInset = NSSize(width: 0, height: 6)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.containerSize = NSSize(width: fixedSize.width - 24, height: .greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true

            let scrollView = NSScrollView()
            scrollView.borderType = .bezelBorder
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.documentView = textView

            let stack = NSStackView(views: [titleLabel, scrollView])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)

            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: fixedSize.width),
                heightAnchor.constraint(equalToConstant: fixedSize.height),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                scrollView.widthAnchor.constraint(equalToConstant: fixedSize.width),
                scrollView.heightAnchor.constraint(equalToConstant: 220),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private struct GitHubReleaseResponse: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL
        let publishedAt: Date?
        let assets: [GitHubReleaseAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
        }
    }

    private struct GitHubReleaseAsset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
