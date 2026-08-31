import SwiftUI

@main
struct YTDLPGlassApp: App {
    @StateObject private var downloads = DownloadViewModel()

    init() { _ = UpdateManager.shared }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(downloads)
                .frame(minWidth: 900, minHeight: 660)
                .task { await downloads.prepare() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for App Updates…") { UpdateManager.shared.checkForUpdates() }
                Button("Check yt-dlp Engine Update…") { Task { await downloads.updateRuntime() } }
                    .disabled(downloads.isUpdating || downloads.isDownloading)
            }
        }

        MenuBarExtra("YTDLP Glass", systemImage: "arrow.down.to.line.compact", isInserted: $downloads.showMenuBarIcon) {
            MenuBarDropView().environmentObject(downloads)
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView().environmentObject(downloads) }
    }
}
