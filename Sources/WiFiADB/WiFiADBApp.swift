import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var reopenWindow: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            reopenWindow?()
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }
}

@main
struct WiFiADBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore()
    var body: some Scene {
        Window("WiFi ADB", id: "main") {
            RootView(store: store, delegate: delegate)
                .frame(minWidth: 820, minHeight: 600)
                .task { await store.loadInitialState() }
        }
        .defaultSize(width: 1000, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加设备") { store.addDraft = AddDeviceDraft() }.keyboardShortcut("n").disabled(store.busy || !store.canSave)
                Button("刷新设备") { Task { await store.refresh() } }.keyboardShortcut("r").disabled(store.busy)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.page = .settings }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .help) { Button("WiFi ADB 连接帮助") { store.showHelp = true } }
        }
    }
}
