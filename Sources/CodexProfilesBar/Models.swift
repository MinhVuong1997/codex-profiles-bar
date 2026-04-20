import Foundation

enum Preferences {
    static let showIDsKey = "CodexProfilesBar.showIDs"
    static let autoRefreshKey = "CodexProfilesBar.autoRefresh"
    static let promptReopenCodexKey = "CodexProfilesBar.promptReopenCodex"
    static let panelThemeKey = "CodexProfilesBar.panelTheme"
    static let compactModeKey = "CodexProfilesBar.compactMode"
    static let groupingKey = "CodexProfilesBar.grouping"
    static let favoriteProfileIDsKey = "CodexProfilesBar.favoriteProfileIDs"
    static let orderedProfileIDsKey = "CodexProfilesBar.orderedProfileIDs"
    static let notificationsEnabledKey = "CodexProfilesBar.notificationsEnabled"
    static let usageWarningThresholdKey = "CodexProfilesBar.usageWarningThreshold"
    static let autoSwitchOnDepletionKey = "CodexProfilesBar.autoSwitchOnDepletion"
    static let accentRedKey = "CodexProfilesBar.accentRed"
    static let accentGreenKey = "CodexProfilesBar.accentGreen"
    static let accentBlueKey = "CodexProfilesBar.accentBlue"
}

enum ProfileFilter: String, CaseIterable, Identifiable {
    case all
    case hasUsage
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "All"
        case .hasUsage:
            "Has Usage"
        case .favorites:
            "Favorites"
        }
    }
}

enum ProfileGrouping: String, CaseIterable, Identifiable {
    case none
    case plan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:
            "Flat"
        case .plan:
            "Plan"
        }
    }
}

struct LaunchAtLoginState: Equatable {
    enum Kind: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable
    }

    let kind: Kind
    let title: String
    let detail: String

    var isEnabled: Bool {
        switch kind {
        case .enabled, .requiresApproval:
            true
        case .disabled, .unavailable:
            false
        }
    }

    var canToggle: Bool {
        kind != .unavailable
    }
}

struct StatusCollection: Decodable {
    let profiles: [ProfileStatus]

    init(profiles: [ProfileStatus]) {
        self.profiles = profiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decodeIfPresent([ProfileStatus].self, forKey: .profiles) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case profiles
    }
}

struct ProfileStatus: Decodable, Hashable, Identifiable {
    let id: String?
    let label: String?
    let email: String?
    let plan: String?
    let isCurrent: Bool
    let isSaved: Bool
    let isApiKey: Bool
    let warnings: [String]
    let usage: UsageSnapshot?
    let error: StatusError?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case email
        case plan
        case isCurrent = "is_current"
        case isSaved = "is_saved"
        case isApiKey = "is_api_key"
        case warnings
        case usage
        case error
    }

    init(
        id: String?,
        label: String?,
        email: String?,
        plan: String?,
        isCurrent: Bool,
        isSaved: Bool,
        isApiKey: Bool,
        warnings: [String],
        usage: UsageSnapshot?,
        error: StatusError?
    ) {
        self.id = id
        self.label = label
        self.email = email
        self.plan = plan
        self.isCurrent = isCurrent
        self.isSaved = isSaved
        self.isApiKey = isApiKey
        self.warnings = warnings
        self.usage = usage
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
        isCurrent = try container.decode(Bool.self, forKey: .isCurrent)
        isSaved = try container.decode(Bool.self, forKey: .isSaved)
        isApiKey = try container.decode(Bool.self, forKey: .isApiKey)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        usage = try container.decodeIfPresent(UsageSnapshot.self, forKey: .usage)
        error = try container.decodeIfPresent(StatusError.self, forKey: .error)
    }

    var stableID: String {
        id ?? "current-unsaved"
    }

    var primaryText: String {
        label ?? email ?? (isCurrent ? "Current session" : "Unnamed profile")
    }

    var sortName: String {
        let candidate = label ?? email ?? id ?? primaryText
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var secondaryText: String {
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedEmail, !trimmedEmail.isEmpty else { return "" }
        return trimmedEmail == primaryText ? "" : trimmedEmail
    }

    var statusLabel: String {
        if let error {
            return error.summary.message
        }
        if !warnings.isEmpty {
            return warnings[0]
        }
        if isCurrent && !isSaved {
            return "Current auth is not saved yet"
        }
        if isCurrent {
            return "Active now"
        }
        return "Ready to switch"
    }

    var tone: ProfileTone {
        if error != nil {
            return .error
        }
        if !warnings.isEmpty || (isCurrent && !isSaved) {
            return .warning
        }
        return .good
    }

    var canSwitch: Bool {
        isSaved && !isCurrent && id != nil && error == nil
    }

    var primaryUsageBucket: UsageBucket? {
        usage?.buckets.first
    }

    var hasRemainingUsage: Bool {
        usage?.buckets.contains(where: { bucket in
            (bucket.fiveHour?.leftPercent ?? 0) > 0 || (bucket.weekly?.leftPercent ?? 0) > 0
        }) == true
    }
}

enum ProfileTone {
    case good
    case warning
    case error
}

struct UsageSnapshot: Decodable, Hashable {
    let state: String
    let buckets: [UsageBucket]
    let statusCode: Int?
    let summary: String?
    let detail: String?

    init(
        state: String,
        buckets: [UsageBucket],
        statusCode: Int? = nil,
        summary: String? = nil,
        detail: String? = nil
    ) {
        self.state = state
        self.buckets = buckets
        self.statusCode = statusCode
        self.summary = summary
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case state
        case buckets
        case statusCode = "status_code"
        case summary
        case detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(String.self, forKey: .state)
        buckets = try container.decodeIfPresent([UsageBucket].self, forKey: .buckets) ?? []
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }
}

struct UsageBucket: Decodable, Hashable {
    let id: String
    let label: String
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?

    init(id: String, label: String, fiveHour: UsageWindow?, weekly: UsageWindow?) {
        self.id = id
        self.label = label
        self.fiveHour = fiveHour
        self.weekly = weekly
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case fiveHour = "five_hour"
        case weekly
    }
}

struct UsageWindow: Decodable, Hashable {
    let leftPercent: Int
    let resetAt: Int

    init(leftPercent: Int, resetAt: Int) {
        self.leftPercent = leftPercent
        self.resetAt = resetAt
    }

    enum CodingKeys: String, CodingKey {
        case leftPercent = "left_percent"
        case resetAt = "reset_at"
    }
}

struct StatusError: Decodable, Hashable {
    let summary: StatusErrorSummary
    let statusCode: Int?
    let detail: String?

    init(summary: StatusErrorSummary, statusCode: Int? = nil, detail: String? = nil) {
        self.summary = summary
        self.statusCode = statusCode
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case summary
        case statusCode = "status_code"
        case detail
    }
}

struct StatusErrorSummary: Decodable, Hashable {
    let message: String

    init(message: String) {
        self.message = message
    }
}

struct DoctorReport: Decodable {
    let checks: [DoctorCheck]
    let summary: DoctorSummary
    let repairs: [String]?
    let error: String?

    init(checks: [DoctorCheck], summary: DoctorSummary, repairs: [String]? = nil, error: String? = nil) {
        self.checks = checks
        self.summary = summary
        self.repairs = repairs
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checks = try container.decodeIfPresent([DoctorCheck].self, forKey: .checks) ?? []
        summary = try container.decode(DoctorSummary.self, forKey: .summary)
        repairs = try container.decodeIfPresent([String].self, forKey: .repairs)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case checks
        case summary
        case repairs
        case error
    }
}

struct DoctorCheck: Decodable, Hashable, Identifiable {
    let name: String
    let level: String
    let detail: String

    init(name: String, level: String, detail: String) {
        self.name = name
        self.level = level
        self.detail = detail
    }

    var id: String {
        "\(name)-\(detail)"
    }
}

struct DoctorSummary: Decodable {
    let ok: Int
    let warn: Int
    let error: Int
    let info: Int

    init(ok: Int, warn: Int, error: Int, info: Int) {
        self.ok = ok
        self.warn = warn
        self.error = error
        self.info = info
    }
}

struct CommandResponse<Payload: Decodable>: Decodable {
    let command: String
    let success: Bool
    let profile: Payload?
}

struct ProfileMutationPayload: Decodable {
    let id: String?
    let label: String?
}

struct ExportPayload: Decodable {
    let path: String
    let count: Int
}

struct ImportedProfilePayload: Decodable {
    let id: String
    let label: String?

    init(id: String, label: String?) {
        self.id = id
        self.label = label
    }
}

struct ImportPayload: Decodable {
    let count: Int
    let profiles: [ImportedProfilePayload]

    init(count: Int, profiles: [ImportedProfilePayload]) {
        self.count = count
        self.profiles = profiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = try container.decode(Int.self, forKey: .count)
        profiles = try container.decodeIfPresent([ImportedProfilePayload].self, forKey: .profiles) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case count
        case profiles
    }
}

struct DeletePayload: Decodable {
    let count: Int
}

struct BannerMessage: Identifiable, Equatable {
    enum Tone {
        case info
        case success
        case warning
        case error
    }

    let id = UUID()
    let tone: Tone
    let title: String
    let body: String
}

struct CodexRelaunchPrompt: Identifiable, Equatable {
    let id = UUID()
    let profileName: String
}

enum SwitchMode {
    case standard
    case force
    case saveThenSwitch
}

struct StorageResolution {
    let url: URL
    let source: String
}

struct PackagingSupport {
    let rootURL: URL
    let scriptsURL: URL
    let distURL: URL
}

struct AppUpdateRelease: Identifiable, Equatable {
    let version: String
    let title: String
    let notes: String
    let htmlURL: URL
    let downloadURL: URL?
    let publishedAt: Date?

    var id: String { version }
}

enum CodexProfilesError: LocalizedError {
    case commandFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message),
             .invalidResponse(let message):
            return message
        }
    }
}

extension UsageWindow {
    func relativeResetText(referenceDate: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(resetAt)), relativeTo: referenceDate)
    }
}
