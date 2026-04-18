import Foundation
import ServiceManagement

struct LaunchAtLoginManager {
    private let fileManager = FileManager.default

    func currentState() -> LaunchAtLoginState {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return LaunchAtLoginState(
                kind: .unavailable,
                title: "Install the app bundle first",
                detail: "Launch at login is available after running CodexProfilesBar as a packaged .app, ideally from /Applications."
            )
        }

        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:
                return LaunchAtLoginState(
                    kind: .enabled,
                    title: "Enabled",
                    detail: "Codex Profiles Bar will open automatically when you log in."
                )
            case .notRegistered:
                if isFallbackEnabled {
                    return LaunchAtLoginState(
                        kind: .enabled,
                        title: "Enabled via LaunchAgent",
                        detail: "Codex Profiles Bar will open automatically using a per-user LaunchAgent fallback."
                    )
                }
                return LaunchAtLoginState(
                    kind: .disabled,
                    title: "Disabled",
                    detail: "The app won't launch automatically at login."
                )
            case .requiresApproval:
                return LaunchAtLoginState(
                    kind: .requiresApproval,
                    title: "Needs approval",
                    detail: "macOS has the login item registered, but you still need to allow it in System Settings > General > Login Items."
                )
            case .notFound:
                if isFallbackEnabled {
                    return LaunchAtLoginState(
                        kind: .enabled,
                        title: "Enabled via LaunchAgent",
                        detail: "Apple’s login item API is unavailable for this local build, so Codex Profiles Bar is using a per-user LaunchAgent fallback."
                    )
                }
                return LaunchAtLoginState(
                    kind: .disabled,
                    title: "Fallback available",
                    detail: "Apple’s login item API is unavailable for this local build. Turn this on and the app will install a per-user LaunchAgent startup fallback."
                )
            @unknown default:
                break
            }
        }

        if isFallbackEnabled {
            return LaunchAtLoginState(
                kind: .enabled,
                title: "Enabled via LaunchAgent",
                detail: "Codex Profiles Bar will open automatically using a per-user LaunchAgent fallback."
            )
        }

        return LaunchAtLoginState(
            kind: .disabled,
            title: "Fallback available",
            detail: "This macOS version will use a per-user LaunchAgent fallback for launch at login."
        )
    }

    func setEnabled(_ enabled: Bool) throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled, .notRegistered, .requiresApproval:
                if enabled {
                    try SMAppService.mainApp.register()
                    try? uninstallFallback()
                } else {
                    try SMAppService.mainApp.unregister()
                    try? uninstallFallback()
                }
                return
            case .notFound:
                break
            @unknown default:
                break
            }
        }

        if enabled {
            try installFallback()
        } else {
            try uninstallFallback()
        }
    }

    private var isFallbackEnabled: Bool {
        fileManager.fileExists(atPath: launchAgentURL.path)
    }

    private var launchAgentURL: URL {
        let home = fileManager.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    private var launchAgentLabel: String {
        "\(bundleIdentifier).launchagent"
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.codexprofiles.bar"
    }

    private func installFallback() throws {
        let launchAgentsDirectory = launchAgentURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)

        let propertyList: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [
                "/usr/bin/open",
                Bundle.main.bundleURL.path,
            ],
            "RunAtLoad": true,
            "LimitLoadToSessionType": [
                "Aqua",
            ],
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: .atomic)

        _ = try? runLaunchctl(arguments: ["bootout", "gui/\(getuid())", launchAgentURL.path])
        _ = try? runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", launchAgentURL.path])
    }

    private func uninstallFallback() throws {
        _ = try? runLaunchctl(arguments: ["bootout", "gui/\(getuid())", launchAgentURL.path])

        if fileManager.fileExists(atPath: launchAgentURL.path) {
            try fileManager.removeItem(at: launchAgentURL)
        }
    }

    private func runLaunchctl(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "LaunchAtLoginManager",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: errorOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "launchctl \(arguments.joined(separator: " ")) failed."
                        : errorOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                ]
            )
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
