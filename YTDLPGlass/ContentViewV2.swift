import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var downloads: DownloadViewModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Label("YTDLP Glass", systemImage: "arrow.down.to.line.compact")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text("Private media downloads on your Mac")
                    .foregroundStyle(.secondary)
                Divider()
                Label("Downloads", systemImage: "tray.full").font(.headline)
                Label("Menu Bar Drop Zone", systemImage: "menubar.rectangle").foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(downloads.isDownloading ? .orange : .green).frame(width: 8, height: 8)
                    Text(downloads.statusMessage).font(.caption).lineLimit(4)
                }.foregroundStyle(.secondary)
            }.padding(20)
        } detail: {
            VStack(spacing: 0) {
                QuickOptionsBar()
                ZStack {
                    LinearGradient(colors: [.cyan.opacity(0.22), .indigo.opacity(0.18), .mint.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                    ScrollView { VStack(spacing: 20) { DownloadComposer(); DownloadQueue() }.padding(28) }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Update yt-dlp", systemImage: "arrow.clockwise") { Task { await downloads.updateRuntime() } }
                        .disabled(downloads.isUpdating || downloads.isDownloading)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct QuickOptionsBar: View {
    @EnvironmentObject private var downloads: DownloadViewModel

    var body: some View {
        HStack(spacing: 10) {
            Button("Paste Link", systemImage: "doc.on.clipboard.fill") { downloads.pasteAndDownload() }
                .buttonStyle(.borderedProminent).controlSize(.large)

            Divider().frame(height: 25)
            Menu {
                ForEach(DownloadKind.allCases) { value in
                    Button { downloads.kind = value } label: {
                        Label(value.rawValue, systemImage: downloads.kind == value ? "checkmark" : value == .video ? "film" : "waveform")
                    }
                }
            } label: {
                Text(downloads.kind.rawValue)
            }

            if downloads.kind == .video {
                Menu {
                    ForEach(["Best", "2160", "1440", "1080", "720", "480"], id: \.self) { value in
                        Button(value == "Best" ? "Best" : "\(value)p") { downloads.quality = value }
                    }
                } label: {
                    Text(downloads.quality == "Best" ? "Best" : "\(downloads.quality)p")
                }
                Menu {
                    ForEach(VideoCompatibility.allCases) { value in
                        Button { downloads.videoCompatibility = value } label: {
                            Label(value.rawValue, systemImage: downloads.videoCompatibility == value ? "checkmark" : "film.stack")
                        }
                    }
                } label: {
                    Text(downloads.videoCompatibility.rawValue)
                }
            } else {
                Menu {
                    ForEach(["Best available", "MP3", "M4A", "Opus", "WAV"], id: \.self) { value in
                        Button(value) { downloads.audioFormat = value }
                    }
                } label: {
                    Text(downloads.audioFormat)
                }
            }

            Menu {
                ForEach(downloads.favoriteFolders) { folder in
                    Button { downloads.selectDestination(folder) } label: {
                        Label(folder.name, systemImage: folder.path == downloads.outputDirectory.path ? "checkmark" : "folder")
                    }
                }
                Divider()
                Button("Add or choose folder…", systemImage: "folder.badge.plus") { downloads.chooseDestination() }
            } label: {
                Label("Save to \(downloads.outputDirectory.lastPathComponent)", systemImage: "folder.fill")
                    .lineLimit(1)
            }.menuStyle(.button).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct DownloadComposer: View {
    @EnvironmentObject private var downloads: DownloadViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("New download").font(.title2.bold())
                    Text("YouTube, Instagram, TikTok and thousands of yt-dlp sources.").foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.cyan)
            }

            HStack(spacing: 10) {
                TextField("https://…", text: $downloads.url)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit { downloads.addDownload() }
                Button("Paste", systemImage: "doc.on.clipboard") { downloads.pasteAndDownload() }
            }

            HStack(spacing: 16) {
                Toggle("Metadata", isOn: $downloads.embedMetadata)
                Toggle("Subtitles", isOn: $downloads.includeSubtitles)
                Toggle("Playlist", isOn: $downloads.downloadPlaylist)
            }

            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(.cyan)
                Text("Current folder: \(downloads.outputDirectory.path)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Show in Finder", systemImage: "finder") { downloads.revealDestination() }
            }.padding(11).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))

            DisclosureGroup("Advanced yt-dlp arguments") {
                TextField("Example: --write-thumbnail", text: $downloads.advancedArguments).textFieldStyle(.roundedBorder).font(.body.monospaced())
            }

            HStack {
                Text("Downloads stay on this Mac. No analytics or telemetry.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Download", systemImage: "arrow.down.circle.fill") { downloads.addDownload() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(downloads.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .modifier(LiquidGlassCard(radius: 24))
        .shadow(color: .black.opacity(0.1), radius: 22, y: 9)
    }
}

private struct DownloadQueue: View {
    @EnvironmentObject private var downloads: DownloadViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity").font(.title3.bold())
                Spacer()
                if downloads.isDownloading { Button("Cancel Current", role: .destructive) { downloads.cancelCurrentDownload() } }
            }
            if downloads.jobs.isEmpty {
                ContentUnavailableView("No downloads yet", systemImage: "tray", description: Text("Your recent downloads will appear here."))
            } else {
                ForEach(downloads.jobs) { job in
                    HStack(spacing: 13) {
                        Image(systemName: job.state.symbol)
                            .foregroundStyle(job.state == .failed ? .red : job.state == .finished ? .green : .secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(job.url).lineLimit(1).truncationMode(.middle)
                            ProgressView(value: job.progress).opacity(job.state == .downloading ? 1 : 0)
                            Text(job.details).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                        }
                        Spacer()
                        Text(job.state.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }.padding(14).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }.padding(22).modifier(LiquidGlassCard(radius: 24))
    }
}

struct MenuBarDropView: View {
    @EnvironmentObject private var downloads: DownloadViewModel

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "arrow.down.to.line.compact").font(.title2).foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("YTDLP Glass").font(.headline)
                    Text(downloads.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }

            VStack(spacing: 8) {
                Image(systemName: downloads.isDropTargeted ? "arrow.down.circle.fill" : "link.badge.plus")
                    .font(.system(size: 34, weight: .medium)).foregroundStyle(downloads.isDropTargeted ? .green : .cyan)
                Text(downloads.isDropTargeted ? "Drop to download" : "Drag a link here")
                    .font(.headline)
                Text("The download starts automatically").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 112)
            .background(downloads.isDropTargeted ? Color.green.opacity(0.14) : Color.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(downloads.isDropTargeted ? Color.green : Color.cyan.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
            .onDrop(of: [UTType.url.identifier, UTType.plainText.identifier], isTargeted: $downloads.isDropTargeted, perform: handleDrop)

            HStack {
                Picker("", selection: $downloads.kind) { ForEach(DownloadKind.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 110)
                Menu {
                    ForEach(downloads.favoriteFolders) { folder in Button(folder.name) { downloads.selectDestination(folder) } }
                    Divider()
                    Button("Choose Folder…") { downloads.chooseDestination() }
                } label: { Label(downloads.outputDirectory.lastPathComponent, systemImage: "folder") }
                Spacer()
            }

            HStack {
                Button("Paste & Download") { downloads.pasteAndDownload() }
                Spacer()
                Button("Open App") { openMainWindow() }
            }
        }.padding(16).frame(width: 360)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSURL.self) {
                provider.loadObject(ofClass: NSURL.self) { object, _ in
                    guard let value = object as? URL else { return }
                    Task { @MainActor in downloads.enqueue(value.absoluteString) }
                }
                return true
            }
            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let value = object as? String else { return }
                    Task { @MainActor in downloads.enqueue(value) }
                }
                return true
            }
        }
        return false
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
}

private struct LiquidGlassCard: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        // Applying Tahoe's live glassEffect to large, scrolling containers can
        // create a recursive backdrop update on macOS 26. Material preserves
        // the native glass appearance without blocking the main thread.
        content
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.94), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1))
    }
}
