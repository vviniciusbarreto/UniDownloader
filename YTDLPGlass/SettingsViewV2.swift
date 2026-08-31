import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var downloads: DownloadViewModel
    @ObservedObject private var updates = UpdateManager.shared

    var body: some View {
        Form {
            Section("UniDownloader updates") {
                Toggle("Automatically check for app updates", isOn: Binding(get: { updates.automaticallyChecksForUpdates }, set: { updates.automaticallyChecksForUpdates = $0 }))
                Toggle("Automatically download app updates", isOn: Binding(get: { updates.automaticallyDownloadsUpdates }, set: { updates.automaticallyDownloadsUpdates = $0 }))
                    .disabled(!updates.automaticallyChecksForUpdates)
                Button("Check for App Update…") { updates.checkForUpdates() }
                Text("Each launch checks for a signed update and shows its release notes before you install. With automatic downloads enabled, the ready-to-install prompt appears as soon as Sparkle has the update.").foregroundStyle(.secondary)
            }

            Section("Quick access") {
                LabeledContent("Menu bar icon", value: "Always available")
                Toggle("Open UniDownloader at login", isOn: $downloads.launchAtLogin)
                Text("Drag a browser link directly onto the UniDownloader arrow in the menu bar. Its drop zone opens automatically and uses your current format and folder.").foregroundStyle(.secondary)
            }

            Section("Saved download folders") {
                ForEach(downloads.favoriteFolders) { folder in
                    HStack {
                        Image(systemName: folder.path == downloads.outputDirectory.path ? "folder.fill" : "folder")
                        VStack(alignment: .leading) { Text(folder.name); Text(folder.path).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if downloads.favoriteFolders.count > 1 { Button("Remove", role: .destructive) { downloads.removeFavorite(folder) } }
                    }
                }
                Button("Add Folder…", systemImage: "folder.badge.plus") { downloads.chooseDestination() }
            }

            Section("YouTube & Instagram compatibility") {
                Toggle("Automatic compatibility mode", isOn: $downloads.useCompatibilityMode)
                Picker("Browser session", selection: $downloads.cookieBrowser) {
                    ForEach(CookieBrowser.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("Browser cookies are optional and remain local. Use them only for media your signed-in account is authorized to access. macOS may ask for browser-data permission.").foregroundStyle(.secondary)
            }

            Section("yt-dlp engine") {
                LabeledContent("Installed version", value: downloads.runtimeVersion)
                Toggle("Keep the yt-dlp engine updated", isOn: $downloads.autoUpdate)
                Toggle("Check at app launch (at most once daily)", isOn: $downloads.updateOnLaunch).disabled(!downloads.autoUpdate)
                Button("Check engine update now") { Task { await downloads.updateRuntime() } }
            }

            Section("FFmpeg") {
                Text("FFmpeg 9.0.1 and FFprobe are bundled for Apple Silicon. They merge high-quality YouTube audio/video, convert audio, embed metadata, and require no separate installation.")
                HStack {
                    Text(downloads.ffmpegPath.isEmpty ? "Not configured" : downloads.ffmpegPath).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose FFmpeg…") { downloads.chooseFFmpeg() }
                }
            }

            Section("Privacy") {
                Text("No account, analytics, telemetry, ad tracking, upload, or download history service. URLs are sent only to the source website through yt-dlp; app and engine update checks go only to their official GitHub repositories.")
            }
        }.formStyle(.grouped).padding(24).frame(width: 680, height: 690)
    }
}
