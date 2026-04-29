import Foundation
import SwiftUI
import AppKit

enum PanelTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }

    func resolvedAppearance(using systemColorScheme: ColorScheme) -> NSAppearance? {
        switch resolvedColorScheme(using: systemColorScheme) {
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        @unknown default:
            NSAppearance(named: .darkAqua)
        }
    }

    func resolvedColorScheme(using systemColorScheme: ColorScheme) -> ColorScheme {
        switch self {
        case .system:
            systemColorScheme
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

final class SystemAppearanceObserver: NSObject, ObservableObject {
    @Published private(set) var colorScheme: ColorScheme

    override init() {
        colorScheme = SystemAppearanceObserver.currentSystemColorScheme()
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSystemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc
    private func handleSystemAppearanceChanged() {
        colorScheme = SystemAppearanceObserver.currentSystemColorScheme()
    }

    static func currentSystemColorScheme() -> ColorScheme {
        let interfaceStyle = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased()
        return interfaceStyle == "dark" ? .dark : .light
    }
}

struct PanelPalette {
    let backgroundStart: Color
    let backgroundEnd: Color
    let cardFill: Color
    let cardStroke: Color
    let subtleFill: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let accent: Color
    let accentSecondary: Color
    let warning: Color
    let danger: Color
    let success: Color
    let shadow: Color
    let chipFill: Color
    let chipStroke: Color
    let iconFill: Color

    static func resolve(for scheme: ColorScheme, accent: Color = AccentTheme.color()) -> PanelPalette {
        let accentSecondary = accent.mix(with: scheme == .dark ? .white.opacity(0.22) : .white.opacity(0.34))
        switch scheme {
        case .dark:
            return PanelPalette(
                backgroundStart: Color(red: 0.07, green: 0.10, blue: 0.16),
                backgroundEnd: Color(red: 0.04, green: 0.06, blue: 0.11),
                cardFill: Color.white.opacity(0.08),
                cardStroke: Color.white.opacity(0.11),
                subtleFill: Color.white.opacity(0.07),
                primaryText: .white,
                secondaryText: Color.white.opacity(0.78),
                tertiaryText: Color.white.opacity(0.60),
                accent: accent,
                accentSecondary: accentSecondary,
                warning: Color(red: 0.98, green: 0.74, blue: 0.23),
                danger: Color(red: 0.97, green: 0.34, blue: 0.39),
                success: Color(red: 0.16, green: 0.82, blue: 0.47),
                shadow: .black.opacity(0.28),
                chipFill: Color.black.opacity(0.18),
                chipStroke: Color.white.opacity(0.08),
                iconFill: Color.white.opacity(0.10)
            )
        case .light:
            return PanelPalette(
                backgroundStart: Color(red: 0.97, green: 0.98, blue: 1.0),
                backgroundEnd: Color(red: 0.92, green: 0.95, blue: 0.99),
                cardFill: Color.white.opacity(0.88),
                cardStroke: Color.black.opacity(0.08),
                subtleFill: Color.black.opacity(0.04),
                primaryText: Color(red: 0.10, green: 0.12, blue: 0.18),
                secondaryText: Color(red: 0.28, green: 0.31, blue: 0.39),
                tertiaryText: Color(red: 0.43, green: 0.46, blue: 0.55),
                accent: accent,
                accentSecondary: accentSecondary,
                warning: Color(red: 0.84, green: 0.58, blue: 0.08),
                danger: Color(red: 0.87, green: 0.24, blue: 0.22),
                success: Color(red: 0.09, green: 0.62, blue: 0.32),
                shadow: .black.opacity(0.08),
                chipFill: Color.white.opacity(0.72),
                chipStroke: Color.black.opacity(0.06),
                iconFill: Color.black.opacity(0.05)
            )
        @unknown default:
            return resolve(for: .dark)
        }
    }
}

enum AccentTheme {
    static let fallback = NSColor(calibratedRed: 0.15, green: 0.44, blue: 0.95, alpha: 1)

    static func color(userDefaults: UserDefaults = .standard) -> Color {
        guard userDefaults.object(forKey: Preferences.accentRedKey) != nil,
              userDefaults.object(forKey: Preferences.accentGreenKey) != nil,
              userDefaults.object(forKey: Preferences.accentBlueKey) != nil else {
            return Color(nsColor: fallback)
        }

        let red = CGFloat(userDefaults.double(forKey: Preferences.accentRedKey))
        let green = CGFloat(userDefaults.double(forKey: Preferences.accentGreenKey))
        let blue = CGFloat(userDefaults.double(forKey: Preferences.accentBlueKey))
        return Color(nsColor: NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1))
    }

    static func cgColor(userDefaults: UserDefaults = .standard) -> CGColor {
        let color = NSColor(AccentTheme.color(userDefaults: userDefaults))
        return color.cgColor
    }

    static func save(_ color: CGColor, userDefaults: UserDefaults = .standard) {
        guard let nsColor = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) else { return }
        userDefaults.set(Double(nsColor.redComponent), forKey: Preferences.accentRedKey)
        userDefaults.set(Double(nsColor.greenComponent), forKey: Preferences.accentGreenKey)
        userDefaults.set(Double(nsColor.blueComponent), forKey: Preferences.accentBlueKey)
    }

    static func reset(userDefaults: UserDefaults = .standard) {
        userDefaults.set(Double(fallback.redComponent), forKey: Preferences.accentRedKey)
        userDefaults.set(Double(fallback.greenComponent), forKey: Preferences.accentGreenKey)
        userDefaults.set(Double(fallback.blueComponent), forKey: Preferences.accentBlueKey)
    }
}

extension Color {
    func mix(with other: Color, amount: Double = 0.35) -> Color {
        let base = NSColor(self).usingColorSpace(.deviceRGB) ?? .systemBlue
        let overlay = NSColor(other).usingColorSpace(.deviceRGB) ?? .white
        let ratio = CGFloat(max(0, min(1, amount)))
        return Color(
            nsColor: NSColor(
                calibratedRed: base.redComponent * (1 - ratio) + overlay.redComponent * ratio,
                green: base.greenComponent * (1 - ratio) + overlay.greenComponent * ratio,
                blue: base.blueComponent * (1 - ratio) + overlay.blueComponent * ratio,
                alpha: 1
            )
        )
    }
}

struct ProfileUsageHistoryPoint: Codable, Hashable {
    let recordedAt: Date
    let fiveHourPercent: Int?
    let weeklyPercent: Int?

    var hourStamp: Int {
        Int(recordedAt.timeIntervalSince1970 / 3600)
    }
}

struct ProfileUsageHistoryStore: Codable {
    var entries: [String: [ProfileUsageHistoryPoint]]
}

struct AggregateUsageSummary {
    let trackedProfilesCount: Int
    let favoritesCount: Int
    let totalFiveHourPercent: Int
    let totalWeeklyPercent: Int
    let lowProfilesCount: Int

    var averageFiveHourPercent: Int {
        guard trackedProfilesCount > 0 else { return 0 }
        return totalFiveHourPercent / trackedProfilesCount
    }

    var averageWeeklyPercent: Int {
        guard trackedProfilesCount > 0 else { return 0 }
        return totalWeeklyPercent / trackedProfilesCount
    }
}

struct ProfileGroup: Identifiable {
    let title: String
    let profiles: [ProfileStatus]

    var id: String { title }
}

struct DetectedCodexVersion {
    let appVersion: String?
    let cliVersion: String?

    var summary: String {
        let parts = [
            appVersion.map { "App \($0)" },
            cliVersion.map { "CLI \($0)" },
        ].compactMap { $0 }

        return parts.isEmpty ? "Version unavailable" : parts.joined(separator: " • ")
    }
}

extension ProfileStatus {
    var searchableText: String {
        [
            label,
            email,
            plan,
            id,
            primaryText,
            secondaryText,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: " ")
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    var usageDisplayPercent: Int? {
        primaryUsageBucket?.effectiveRemainingPercent
    }

    var hasUsageData: Bool {
        usage?.state == "ok" && primaryUsageBucket != nil
    }

    var resetsSoon: Bool {
        guard let resetAt = primaryUsageBucket?.nearestResetAt else { return false }
        return Date(timeIntervalSince1970: TimeInterval(resetAt)).timeIntervalSinceNow <= 6 * 3600
    }

    var isUsageDepleted: Bool {
        guard let bucket = primaryUsageBucket else { return false }
        return bucket.isDepleted
    }

    func isLowUsage(threshold: Int) -> Bool {
        guard let percent = usageDisplayPercent else { return false }
        return percent <= threshold
    }

    var planGroupTitle: String {
        guard let plan, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Unlabeled"
        }
        return plan.capitalized
    }
}

extension UsageBucket {
    var effectiveRemainingPercent: Int? {
        fiveHour?.leftPercent ?? weekly?.leftPercent
    }

    var isDepleted: Bool {
        guard let effectiveRemainingPercent else { return false }
        return effectiveRemainingPercent <= 0
    }

    var nearestResetAt: Int? {
        [fiveHour?.resetAt, weekly?.resetAt].compactMap { $0 }.min()
    }
}

extension Array where Element == ProfileUsageHistoryPoint {
    var sparklinePercentages: [Int] {
        suffix(18).compactMap { point in
            point.fiveHourPercent ?? point.weeklyPercent
        }
    }
}
