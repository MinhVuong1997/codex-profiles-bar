import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct CodexProfilesBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = CodexProfilesViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView(model: model)
        } label: {
            Label("Codex Profiles", systemImage: model.menuBarSymbolName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: 640, height: 460)
        }
    }
}
