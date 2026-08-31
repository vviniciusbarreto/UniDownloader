import AppKit
import SwiftUI

final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.windows.first(where: { $0.canBecomeMain })?.delegate = self
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct UniDownloaderApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate
    @StateObject private var downloads = DownloadViewModel()
    @StateObject private var menuBar = MenuBarController()

    init() { _ = UpdateManager.shared }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(downloads)
                .environmentObject(menuBar)
                .frame(minWidth: 900, minHeight: 660)
                .task {
                    menuBar.start(with: downloads)
                    await downloads.prepare()
                    UpdateManager.shared.checkForUpdatesAtLaunch()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for App Updates…") { UpdateManager.shared.checkForUpdates() }
                Button("Check yt-dlp Engine Update…") { Task { await downloads.updateRuntime() } }
                    .disabled(downloads.isUpdating || downloads.isDownloading)
            }
        }

        Settings { SettingsView().environmentObject(downloads) }
    }
}
