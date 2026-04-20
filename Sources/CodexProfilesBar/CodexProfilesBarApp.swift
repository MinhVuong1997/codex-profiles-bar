import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installShortcutMonitors()
        configureNotificationCenter()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
    }

    private func installShortcutMonitors() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.isCycleProfilesShortcut else { return }
            NotificationCenter.default.post(name: .cycleProfilesShortcut, object: nil)
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.isCycleProfilesShortcut else { return event }
            NotificationCenter.default.post(name: .cycleProfilesShortcut, object: nil)
            return nil
        }
    }

    private func configureNotificationCenter() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let reopenAction = UNNotificationAction(
            identifier: NotificationActionIdentifier.reopenCodex,
            title: "Reopen Codex",
            options: [.foreground]
        )
        let autoSwitchCategory = UNNotificationCategory(
            identifier: NotificationCategoryIdentifier.autoSwitch,
            actions: [reopenAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([autoSwitchCategory])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard response.actionIdentifier == NotificationActionIdentifier.reopenCodex,
              response.notification.request.content.categoryIdentifier == NotificationCategoryIdentifier.autoSwitch else {
            return
        }

        NotificationCenter.default.post(name: .reopenCodexFromNotification, object: nil)
    }
}

@main
struct CodexProfilesBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = CodexProfilesViewModel()
    @StateObject private var systemAppearance = SystemAppearanceObserver()
    @AppStorage(Preferences.panelThemeKey) private var panelThemeRaw = PanelTheme.system.rawValue

    private var selectedTheme: PanelTheme {
        PanelTheme(rawValue: panelThemeRaw) ?? .system
    }

    private var resolvedColorScheme: ColorScheme {
        selectedTheme.resolvedColorScheme(using: systemAppearance.colorScheme)
    }

    private var resolvedAppearance: NSAppearance? {
        selectedTheme.resolvedAppearance(using: systemAppearance.colorScheme)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView(model: model, resolvedColorScheme: resolvedColorScheme)
                .preferredColorScheme(resolvedColorScheme)
                .background(WindowAppearanceConfigurator(appearance: resolvedAppearance))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.menuBarSymbolName)
                Text(model.menuBarTitle)
                    .lineLimit(1)
            }
            .accessibilityLabel("Codex Profiles \(model.menuBarTitle)")
        }
        .menuBarExtraStyle(.window)
        .keyboardShortcut(nil)

        Settings {
            SettingsView(model: model, resolvedColorScheme: resolvedColorScheme)
                .preferredColorScheme(resolvedColorScheme)
                .background(WindowAppearanceConfigurator(appearance: resolvedAppearance))
                .frame(width: 640, height: 460)
        }

        Window("Profiles Panel", id: "profiles-panel") {
            MenuBarRootView(model: model, isDetached: true, resolvedColorScheme: resolvedColorScheme)
                .preferredColorScheme(resolvedColorScheme)
                .background(DetachedPanelWindowConfigurator(appearance: resolvedAppearance))
        }
        .windowResizability(.contentMinSize)
    }
}

private extension NSEvent {
    var isCycleProfilesShortcut: Bool {
        modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .option]
            && charactersIgnoringModifiers?.lowercased() == "p"
    }
}

extension Notification.Name {
    static let cycleProfilesShortcut = Notification.Name("CodexProfilesBar.cycleProfilesShortcut")
    static let reopenCodexFromNotification = Notification.Name("CodexProfilesBar.reopenCodexFromNotification")
}

enum NotificationCategoryIdentifier {
    static let autoSwitch = "AUTO_SWITCH_PROFILE"
}

enum NotificationActionIdentifier {
    static let reopenCodex = "REOPEN_CODEX"
}

private struct WindowAppearanceConfigurator: NSViewRepresentable {
    let appearance: NSAppearance?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            applyAppearance(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            applyAppearance(to: nsView.window)
        }
    }

    private func applyAppearance(to window: NSWindow?) {
        guard let window else { return }
        window.appearance = appearance
        window.invalidateShadow()
        window.contentView?.needsDisplay = true
    }
}

private struct DetachedPanelWindowConfigurator: NSViewRepresentable {
    let appearance: NSAppearance?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(for: view, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView, coordinator: context.coordinator)
        }
    }

    private func configureWindow(for view: NSView, coordinator: Coordinator) {
        guard let window = view.window else { return }
        window.identifier = NSUserInterfaceItemIdentifier("profiles-panel")
        window.level = .normal
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = appearance
        coordinator.attach(to: window)
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var observedWindow: NSWindow?

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(to window: NSWindow) {
            guard observedWindow !== window else { return }

            observedWindow = window

            NotificationCenter.default.removeObserver(self)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowBecameFrontmost(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowBecameFrontmost(_:)),
                name: NSWindow.didBecomeMainNotification,
                object: window
            )

            promote(window)
        }

        @objc
        private func handleWindowBecameFrontmost(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            promote(window)
        }

        private func promote(_ window: NSWindow) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeMain()
            if !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
