import AppKit
import CryptoKit
import Foundation
import ServiceManagement

enum DownloadKind: String, CaseIterable, Identifiable, Codable {
    case video = "Video"
    case audio = "Audio"
    var id: String { rawValue }
}

enum VideoCompatibility: String, CaseIterable, Identifiable {
    case macBest = "Best for Mac (MP4)"
    case h264MP4 = "H.264 MP4"
    case h265MP4 = "H.265 HEVC MP4"
    case h264MOV = "Apple MOV (H.264)"
    case best = "Best quality (MKV)"
    case original = "Original source format"
    var id: String { rawValue }

    /// Formats that promise a file macOS opens natively (QuickTime, Quick Look, DaVinci Resolve).
    /// After the download, VP9/VP8 becomes HEVC, an hev1 tag becomes hvc1 and Opus/Vorbis audio becomes AAC.
    var convertsForMac: Bool { self != .best && self != .original }
}

enum MacMedia {
    /// Video codecs macOS plays natively. Within one resolution: H.264 > HEVC > AV1.
    static let appleVideoCodecs = ["avc1", "h264", "hvc1", "hev1", "h265", "hevc", "av01"]
    static let codecPreference: [String: Double] = ["avc1": 3, "h264": 3, "hvc1": 2, "hev1": 2, "h265": 2, "hevc": 2, "av01": 1]
    /// AAC 256 kbps with Apple's AudioToolbox encoder in constrained VBR (iTunes Plus / Apple Music standard).
    static let appleAAC = ["-c:a", "aac_at", "-aac_at_mode", "cvbr", "-b:a", "256k"]
    /// Used only if the selected FFmpeg was built without AudioToolbox.
    static let fallbackAAC = ["-c:a", "aac", "-b:a", "256k"]
    static let fileMarker = "UNIDL_FILE:"

    static func codecFamily(_ vcodec: String) -> String {
        let value = vcodec.lowercased()
        return appleVideoCodecs.first { value.hasPrefix($0) } ?? String(value.split(separator: ".").first ?? "")
    }

    /// Picks the highest resolution; inside it, a codec the Mac opens (then frame rate, H.264 > HEVC > AV1, bitrate).
    /// VP9 is used only when nothing else exists at that resolution. Audio: best track, avoiding YouTube's DRC version.
    static func formatSelection(from formats: [[String: Any]], maxHeight: Int?) -> String? {
        func text(_ format: [String: Any], _ key: String) -> String { format[key] as? String ?? "" }
        func number(_ format: [String: Any], _ key: String) -> Double { (format[key] as? NSNumber)?.doubleValue ?? 0 }
        func hasVideo(_ format: [String: Any]) -> Bool { let codec = text(format, "vcodec"); return !codec.isEmpty && codec != "none" }
        func hasAudio(_ format: [String: Any]) -> Bool { let codec = text(format, "acodec"); return !codec.isEmpty && codec != "none" }

        var videos = formats.filter { hasVideo($0) && !text($0, "format_id").isEmpty }
        if let maxHeight {
            let capped = videos.filter { number($0, "height") <= Double(maxHeight) }
            if !capped.isEmpty { videos = capped }
        }
        func videoRank(_ format: [String: Any]) -> [Double] {
            let family = codecFamily(text(format, "vcodec"))
            return [number(format, "height"), appleVideoCodecs.contains(family) ? 1 : 0, number(format, "fps"), codecPreference[family] ?? 0, number(format, "tbr")]
        }
        guard let video = videos.max(by: { videoRank($0).lexicographicallyPrecedes(videoRank($1)) }) else { return nil }
        let videoID = text(video, "format_id")
        if hasAudio(video) { return videoID }

        let audios = formats.filter { hasAudio($0) && !hasVideo($0) && !text($0, "format_id").isEmpty }
        func audioRank(_ format: [String: Any]) -> [Double] {
            let isDRC = text(format, "format_id").lowercased().contains("drc") || text(format, "format_note").lowercased().contains("drc")
            let bitrate = number(format, "abr") > 0 ? number(format, "abr") : number(format, "tbr")
            return [isDRC ? 0 : 1, number(format, "language_preference"), bitrate]
        }
        guard let audio = audios.max(by: { audioRank($0).lexicographicallyPrecedes(audioRank($1)) }) else { return videoID }
        return "\(videoID)+\(text(audio, "format_id"))"
    }
}

enum CookieBrowser: String, CaseIterable, Identifiable {
    case none = "Do not use browser cookies"
    case safari = "Safari"
    case chrome = "Chrome"
    case firefox = "Firefox"
    var id: String { rawValue }
    var argument: String? { self == .none ? nil : rawValue.lowercased() }
}

struct SavedFolder: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

enum JobState: Equatable {
    case queued, downloading, finished, failed, cancelled

    var title: String {
        switch self {
        case .queued: "Waiting"
        case .downloading: "Downloading"
        case .finished: "Complete"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var symbol: String {
        switch self {
        case .queued: "clock"
        case .downloading: "arrow.down.circle"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }
}

struct DownloadJob: Identifiable {
    let id = UUID()
    let url: String
    let kind: DownloadKind
    let destinationPath: String
    var progress = 0.0
    var state: JobState = .queued
    var details = "Preparing download…"
    var output: String?
}

private final class ProcessLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    // Bytes are kept raw and decoded once, so a UTF-8 character split across two reads is not lost.
    func append(_ value: Data) { lock.lock(); storage.append(value); lock.unlock() }
    func snapshot() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: storage, as: UTF8.self) }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name; case browserDownloadURL = "browser_download_url" }
    }
    let tagName: String
    let assets: [Asset]
    enum CodingKeys: String, CodingKey { case tagName = "tag_name", assets }
}

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var url = ""
    @Published var outputDirectory: URL {
        didSet { UserDefaults.standard.set(outputDirectory.path, forKey: "outputDirectoryPath") }
    }
    @Published var favoriteFolders: [SavedFolder] = [] {
        didSet { persistFavoriteFolders() }
    }
    @Published var kind: DownloadKind = .video {
        didSet { UserDefaults.standard.set(kind.rawValue, forKey: "downloadKind") }
    }
    @Published var quality = "Best" {
        didSet { UserDefaults.standard.set(quality, forKey: "videoQuality") }
    }
    @Published var videoCompatibility: VideoCompatibility = .macBest {
        didSet { UserDefaults.standard.set(videoCompatibility.rawValue, forKey: "videoCompatibility") }
    }
    @Published var includeSubtitles = false
    @Published var embedMetadata = true
    @Published var downloadPlaylist = false
    @Published var audioFormat = DownloadViewModel.appleAACFormat
    @Published var advancedArguments = ""
    @Published var jobs: [DownloadJob] = []
    @Published var statusMessage = "Preparing yt-dlp…"
    @Published var runtimeVersion = "Not checked"
    @Published var isDownloading = false
    @Published var isUpdating = false
    @Published var isDropTargeted = false
    @Published var showMenuBarIcon = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMenuBarIcon, forKey: "showMenuBarIcon") }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet { updateLaunchAtLogin() }
    }
    @Published var autoUpdate = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate") }
    }
    @Published var updateOnLaunch = UserDefaults.standard.object(forKey: "updateOnLaunch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(updateOnLaunch, forKey: "updateOnLaunch") }
    }
    @Published var useCompatibilityMode = UserDefaults.standard.object(forKey: "compatibilityMode") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useCompatibilityMode, forKey: "compatibilityMode") }
    }
    @Published var cookieBrowser: CookieBrowser {
        didSet { UserDefaults.standard.set(cookieBrowser.rawValue, forKey: "cookieBrowser") }
    }
    @Published var ffmpegPath: String {
        didSet { UserDefaults.standard.set(ffmpegPath, forKey: "ffmpegPath") }
    }

    static let appleAACFormat = "Apple AAC 256 (.m4a)"
    static let audioFormats = [appleAACFormat, "Best available", "MP3 (.mp3)", "M4A (.m4a)", "Opus (.opus)", "WAV (.wav)"]

    private var currentProcess: Process?
    private var pendingJobs: [UUID] = []
    private let fileManager = FileManager.default

    init() {
        let defaultDirectory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fileManager.homeDirectoryForCurrentUser
        outputDirectory = UserDefaults.standard.string(forKey: "outputDirectoryPath").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDirectory
        let storedFFmpeg = UserDefaults.standard.string(forKey: "ffmpegPath")
        ffmpegPath = Self.preferredFFmpegPath(stored: storedFFmpeg)
        kind = DownloadKind(rawValue: UserDefaults.standard.string(forKey: "downloadKind") ?? "") ?? .video
        quality = UserDefaults.standard.string(forKey: "videoQuality") ?? "Best"
        // One-time switch to the new Mac-first default; the user can still pick any other format afterwards.
        if !UserDefaults.standard.bool(forKey: "macFormatDefaultApplied") {
            UserDefaults.standard.removeObject(forKey: "videoCompatibility")
            UserDefaults.standard.set(true, forKey: "macFormatDefaultApplied")
        }
        videoCompatibility = VideoCompatibility(rawValue: UserDefaults.standard.string(forKey: "videoCompatibility") ?? "") ?? .macBest
        cookieBrowser = CookieBrowser(rawValue: UserDefaults.standard.string(forKey: "cookieBrowser") ?? "") ?? .none
        if let data = UserDefaults.standard.data(forKey: "favoriteFolders"), let decoded = try? JSONDecoder().decode([SavedFolder].self, from: data) {
            favoriteFolders = decoded
        } else {
            let home = fileManager.homeDirectoryForCurrentUser
            favoriteFolders = [
                SavedFolder(id: UUID(), name: "Downloads", path: defaultDirectory.path),
                SavedFolder(id: UUID(), name: "Movies", path: home.appendingPathComponent("Movies", isDirectory: true).path),
                SavedFolder(id: UUID(), name: "Desktop", path: home.appendingPathComponent("Desktop", isDirectory: true).path)
            ]
        }
    }

    func prepare() async {
        do {
            try bootstrapRuntime()
            runtimeVersion = try await execute(["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = "yt-dlp \(runtimeVersion) is ready"
            if autoUpdate && shouldCheckForUpdates() { await updateRuntime(silentWhenCurrent: true) }
        } catch { statusMessage = "Runtime unavailable: \(error.localizedDescription)" }
    }

    func chooseDestination(addToFavorites: Bool = true) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let choice = panel.url {
            outputDirectory = choice
            if addToFavorites && !favoriteFolders.contains(where: { $0.path == choice.path }) {
                favoriteFolders.append(SavedFolder(id: UUID(), name: choice.lastPathComponent, path: choice.path))
            }
        }
    }

    func selectDestination(_ folder: SavedFolder) { outputDirectory = folder.url }
    func removeFavorite(_ folder: SavedFolder) { favoriteFolders.removeAll { $0.id == folder.id } }
    func revealDestination() { NSWorkspace.shared.activateFileViewerSelecting([outputDirectory]) }

    func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let choice = panel.url { ffmpegPath = choice.path }
    }

    func addDownload() { enqueue(url) }

    @discardableResult
    func enqueue(_ rawURL: String) -> Bool {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed), let scheme = parsed.scheme, ["http", "https"].contains(scheme.lowercased()) else {
            statusMessage = "Enter a valid http(s) URL first."
            return false
        }
        let job = DownloadJob(url: trimmed, kind: kind, destinationPath: outputDirectory.path)
        jobs.insert(job, at: 0)
        pendingJobs.append(job.id)
        url = ""
        statusMessage = "Added to download queue"
        Task { await processQueue() }
        return true
    }

    func pasteAndDownload() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            statusMessage = "The clipboard does not contain a URL."
            return
        }
        enqueue(value)
    }

    func cancelCurrentDownload() {
        currentProcess?.terminate()
        statusMessage = "Cancelling current download…"
    }

    func updateRuntime(silentWhenCurrent: Bool = false) async {
        guard !isDownloading else { statusMessage = "Finish the current download before updating."; return }
        isUpdating = true
        defer { isUpdating = false }
        statusMessage = "Checking official yt-dlp release…"
        do {
            let release = try await fetchVerifiedRuntime()
            try installRuntime(release.binary)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            runtimeVersion = (try? await execute(["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? runtimeVersion
            statusMessage = silentWhenCurrent ? "yt-dlp \(runtimeVersion) is up to date" : "Installed verified yt-dlp \(release.version)"
        } catch { statusMessage = "Update failed: \(error.localizedDescription)" }
    }

    private func processQueue() async {
        guard !isDownloading else { return }
        isDownloading = true
        while !pendingJobs.isEmpty { await download(jobID: pendingJobs.removeFirst()) }
        currentProcess = nil
        isDownloading = false
    }

    private func download(jobID: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let job = jobs[index]
        jobs[index].state = .downloading
        statusMessage = "Downloading…"
        var infoFile: URL?
        defer { if let infoFile { try? fileManager.removeItem(at: infoFile) } }
        do {
            var preselectedFormat: String?
            if usesMacFormatSelection(for: job) {
                setDetails(jobID, "Reading link…")
                if let choice = try await chooseMacFormat(for: job) {
                    preselectedFormat = choice.format
                    infoFile = choice.infoFile
                }
            }
            var arguments = makeArguments(for: job, preselectedFormat: preselectedFormat)
            // With the saved metadata, yt-dlp does not need to read the link a second time.
            if let infoFile { arguments += ["--load-info-json", infoFile.path] } else { arguments.append(job.url) }
            let output = try await execute(arguments) { [weak self] line in
                Task { @MainActor [weak self] in
                    guard let self, let i = self.jobs.firstIndex(where: { $0.id == jobID }) else { return }
                    self.jobs[i].details = line
                    if let percent = Self.percentage(in: line) { self.jobs[i].progress = percent / 100 }
                }
            }
            let conversionNote = try await adaptForMac(Self.downloadedFiles(in: output), job: job)
            if let i = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[i].state = .finished
                jobs[i].progress = 1
                jobs[i].details = "Saved to \(jobs[i].destinationPath)" + (conversionNote.map { "\n\($0)" } ?? "")
                jobs[i].output = output
            }
            statusMessage = "Download complete"
        } catch {
            if let i = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[i].state = error is CancellationError ? .cancelled : .failed
                jobs[i].details = friendlyError(error.localizedDescription)
            }
            statusMessage = "Download did not complete"
        }
        currentProcess = nil
    }

    private var hasFFmpeg: Bool { !ffmpegPath.isEmpty && fileManager.isExecutableFile(atPath: ffmpegPath) }

    private var ffprobePath: String? {
        let sibling = URL(fileURLWithPath: ffmpegPath).deletingLastPathComponent().appendingPathComponent("ffprobe").path
        if !ffmpegPath.isEmpty, fileManager.isExecutableFile(atPath: sibling) { return sibling }
        return Self.detectExecutable(named: "ffprobe")
    }

    private func usesMacFormatSelection(for job: DownloadJob) -> Bool {
        job.kind == .video && videoCompatibility == .macBest && hasFFmpeg && !downloadPlaylist
    }

    /// Connection options shared by the metadata read and the download itself.
    private func networkArguments(for job: DownloadJob) -> [String] {
        var arguments = ["--retries", "10", "--fragment-retries", "10", "--retry-sleep", "exp=1:20"]
        let host = URL(string: job.url)?.host?.lowercased() ?? ""
        if useCompatibilityMode {
            arguments += ["--impersonate", "chrome"]
            if host.contains("youtube.com") || host == "youtu.be" {
                if let deno = Self.detectExecutable(named: "deno") { arguments += ["--js-runtimes", "deno:\(deno)"] }
                else if let node = Self.detectExecutable(named: "node") { arguments += ["--js-runtimes", "node:\(node)"] }
                arguments += ["--remote-components", "ejs:github"]
            }
        }
        if let browser = cookieBrowser.argument { arguments += ["--cookies-from-browser", browser] }
        return arguments
    }

    /// Reads the link once (-J) and picks the format with the same rules as the Dropzone action.
    /// Returns nil when the link is not a single video, so the download falls back to a format selector.
    private func chooseMacFormat(for job: DownloadJob) async throws -> (format: String, infoFile: URL)? {
        let output: String
        do { output = try await execute(networkArguments(for: job) + ["--no-playlist", "--no-warnings", "-J", job.url]) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil } // The download step reports the real error.
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("{") }),
              let data = String(line).data(using: .utf8),
              let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (info["_type"] as? String ?? "video") == "video",
              let formats = info["formats"] as? [[String: Any]],
              let format = MacMedia.formatSelection(from: formats, maxHeight: Int(quality)) else { return nil }
        let file = fileManager.temporaryDirectory.appendingPathComponent("unidownloader-\(job.id.uuidString).info.json")
        do { try data.write(to: file, options: .atomic) } catch { return nil }
        return (format, file)
    }

    private func makeArguments(for job: DownloadJob, preselectedFormat: String? = nil) -> [String] {
        var arguments = ["--newline", "--progress", "--no-quiet"] + networkArguments(for: job) + [
            "--concurrent-fragments", "4",
            "-P", job.destinationPath, "-o", "%(title).180B [%(id)s].%(ext)s",
            "--print", "after_move:\(MacMedia.fileMarker)%(filepath)s"
        ]
        if !downloadPlaylist { arguments += ["--no-playlist"] }
        if hasFFmpeg {
            arguments += ["--ffmpeg-location", ffmpegPath]
            if embedMetadata { arguments += ["--embed-metadata"] }
            if includeSubtitles { arguments += ["--write-subs", "--write-auto-subs", "--sub-langs", "all,-live_chat", "--embed-subs"] }
        } else if includeSubtitles {
            arguments += ["--write-subs", "--write-auto-subs", "--sub-langs", "all,-live_chat"]
        }

        if job.kind == .video {
            let height = quality == "Best" ? "" : "[height<=\(quality)]"
            if hasFFmpeg {
                switch videoCompatibility {
                case .macBest:
                    if let preselectedFormat { arguments += ["-f", preselectedFormat] }
                    else { arguments += ["-f", "bv*\(height)+ba[format_id!*=drc]/bv*\(height)+ba/b\(height)/b", "-S", "res,vcodec:h264,fps"] }
                    arguments += ["--merge-output-format", "mp4", "--remux-video", "mp4"]
                case .h264MP4:
                    arguments += [
                        "-f", "bv*\(height)[vcodec^=avc1]+ba[acodec^=mp4a]/bv*\(height)+ba/b\(height)",
                        "--merge-output-format", "mp4", "--remux-video", "mp4"
                    ]
                case .h265MP4:
                    arguments += [
                        "-f", "bv*\(height)[vcodec^=hev1]+ba[acodec^=mp4a]/bv*\(height)[vcodec^=hvc1]+ba[acodec^=mp4a]/bv*\(height)+ba/b\(height)",
                        "--merge-output-format", "mp4", "--remux-video", "mp4"
                    ]
                case .h264MOV:
                    arguments += [
                        "-f", "bv*\(height)[vcodec^=avc1]+ba[acodec^=mp4a]/bv*\(height)+ba/b\(height)",
                        "--merge-output-format", "mov", "--remux-video", "mov"
                    ]
                case .best:
                    arguments += ["-f", "bv*\(height)+ba/b\(height)", "--merge-output-format", "mkv"]
                case .original:
                    arguments += ["-f", "bv*\(height)+ba/b\(height)"]
                }
            } else { arguments += ["-f", "b\(height)/b"] }
        } else if audioFormat == Self.appleAACFormat {
            // Best audio the site has (never YouTube's DRC track); converted to AAC after the download.
            arguments += ["-f", "ba[format_id!*=drc]/ba/b"]
        } else if audioFormat == "Best available" {
            arguments += ["-f", "ba[format_id!*=drc]/bestaudio/best"]
        } else if hasFFmpeg {
            let audioExtension = ["MP3 (.mp3)": "mp3", "M4A (.m4a)": "m4a", "Opus (.opus)": "opus", "WAV (.wav)": "wav"][audioFormat] ?? "mp3"
            arguments += ["-x", "--audio-format", audioExtension, "--audio-quality", "0"]
        } else {
            arguments += ["-f", "bestaudio/best"]
        }
        arguments += shellWords(advancedArguments)
        return arguments
    }

    // MARK: - Mac compatibility (same rules as the Dropzone action)

    private func setDetails(_ jobID: UUID, _ text: String) {
        if let i = jobs.firstIndex(where: { $0.id == jobID }) { jobs[i].details = text }
    }

    private static func downloadedFiles(in output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix(MacMedia.fileMarker) else { return nil }
            let path = String(line.dropFirst(MacMedia.fileMarker.count))
            return seen.insert(path).inserted ? path : nil
        }
    }

    /// Returns a note for the activity list when a conversion could not be done.
    private func adaptForMac(_ files: [String], job: DownloadJob) async throws -> String? {
        guard hasFFmpeg, let ffprobe = ffprobePath else { return nil }
        var failed = 0
        for file in files where fileManager.fileExists(atPath: file) {
            let succeeded: Bool
            if job.kind == .video && videoCompatibility.convertsForMac {
                succeeded = try await makeMacCompatible(file, ffprobe: ffprobe, jobID: job.id)
            } else if job.kind == .audio && audioFormat == Self.appleAACFormat {
                succeeded = try await convertToAppleAAC(file, ffprobe: ffprobe, jobID: job.id)
            } else { continue }
            if !succeeded { failed += 1 }
        }
        return failed == 0 ? nil : "The Mac conversion failed, so the original download was kept."
    }

    private func probeStreams(_ path: String, ffprobe: String) async throws -> [[String: Any]] {
        let output = try await execute(["-v", "error", "-show_entries", "stream=codec_type,codec_name,codec_tag_string", "-of", "json", path], executable: URL(fileURLWithPath: ffprobe))
        guard let start = output.firstIndex(of: "{"),
              let json = (try? JSONSerialization.jsonObject(with: Data(output[start...].utf8))) as? [String: Any] else { return [] }
        return json["streams"] as? [[String: Any]] ?? []
    }

    /// Runs FFmpeg once per encoder attempt and replaces or creates the output only on success.
    private func runFFmpeg(input: String, output: String, attempts: [[String]]) async throws -> Bool {
        for arguments in attempts {
            do {
                _ = try await execute(["-y", "-v", "error", "-i", input] + arguments + [output], executable: URL(fileURLWithPath: ffmpegPath))
                let size = (try? fileManager.attributesOfItem(atPath: output)[.size] as? NSNumber)?.intValue ?? 0
                if size > 0 { return true }
            } catch is CancellationError {
                try? fileManager.removeItem(atPath: output)
                throw CancellationError()
            } catch { continue }
        }
        try? fileManager.removeItem(atPath: output)
        return false
    }

    /// VP9/VP8 -> HEVC on the GPU (VideoToolbox), hev1 -> hvc1 tag, any audio other than AAC/MP3/ALAC -> AAC 256 kbps.
    private func makeMacCompatible(_ path: String, ffprobe: String, jobID: UUID) async throws -> Bool {
        let streams = try await probeStreams(path, ffprobe: ffprobe)
        let video = streams.first { $0["codec_type"] as? String == "video" }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        var videoArguments = ["-map", "0:v?", "-c:v", "copy"]
        var message: String?
        if let video {
            let codec = video["codec_name"] as? String ?? ""
            if codec == "vp9" || codec == "vp8" {
                videoArguments = ["-map", "0:V?", "-c:v", "hevc_videotoolbox", "-q:v", "70", "-tag:v", "hvc1"]
                message = "Converting VP9 to HEVC on the GPU so it opens on your Mac…"
            } else if codec == "hevc" && video["codec_tag_string"] as? String != "hvc1" {
                videoArguments += ["-tag:v", "hvc1"]
                message = "Adjusting the HEVC tag for macOS…"
            }
        }
        var audioAttempts = [["-c:a", "copy"]]
        if let audio, !["aac", "mp3", "alac"].contains(audio["codec_name"] as? String ?? "") {
            audioAttempts = [MacMedia.appleAAC, MacMedia.fallbackAAC]
            message = message ?? "Converting audio to AAC 256 kbps…"
        }
        guard let message else { return true }
        setDetails(jobID, message)

        let source = URL(fileURLWithPath: path)
        let temporary = source.deletingPathExtension().appendingPathExtension("unidownloader-tmp").appendingPathExtension(source.pathExtension)
        let attempts = audioAttempts.map { videoArguments + ["-map", "0:a?"] + $0 + ["-map", "0:s?", "-c:s", "copy", "-movflags", "+faststart"] }
        guard try await runFFmpeg(input: path, output: temporary.path, attempts: attempts) else { return false }
        _ = try fileManager.replaceItemAt(source, withItemAt: temporary)
        return true
    }

    /// Best downloaded audio -> M4A. AAC only changes container (lossless);
    /// anything else becomes AAC 256 kbps CVBR at 44.1 kHz with Apple's encoder (Apple Music standard).
    private func convertToAppleAAC(_ path: String, ffprobe: String, jobID: UUID) async throws -> Bool {
        let streams = try await probeStreams(path, ffprobe: ffprobe)
        guard let audio = streams.first(where: { $0["codec_type"] as? String == "audio" }) else { return true }
        let isAAC = audio["codec_name"] as? String == "aac"
        let hasVideo = streams.contains { $0["codec_type"] as? String == "video" }
        if isAAC && !hasVideo && path.lowercased().hasSuffix(".m4a") { return true }

        let base = URL(fileURLWithPath: path).deletingPathExtension().path
        var output = base + ".m4a"
        if output == path { output = base + " (AAC).m4a" }
        setDetails(jobID, isAAC ? "Moving the AAC audio into M4A…" : "Converting to AAC 256 kbps (Apple Music standard)…")
        let codecAttempts = isAAC ? [["-c:a", "copy"]] : [MacMedia.appleAAC + ["-ar", "44100"], MacMedia.fallbackAAC + ["-ar", "44100"]]
        let attempts = codecAttempts.map { ["-vn", "-map", "0:a:0"] + $0 + ["-map_metadata", "0", "-movflags", "+faststart"] }
        guard try await runFFmpeg(input: path, output: output, attempts: attempts) else { return false }
        try? fileManager.removeItem(atPath: path)
        return true
    }

    private func bootstrapRuntime() throws {
        let support = try applicationSupportDirectory()
        let runtime = support.appendingPathComponent("yt-dlp", isDirectory: true)
        let executable = runtime.appendingPathComponent("yt-dlp_macos")
        let legacyInternal = runtime.appendingPathComponent("_internal", isDirectory: true)
        if !fileManager.fileExists(atPath: executable.path) {
            guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("yt-dlp", isDirectory: true), fileManager.fileExists(atPath: bundled.path) else { throw CocoaError(.fileNoSuchFile) }
            try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
            try fileManager.copyItem(at: bundled, to: runtime)
        } else if fileManager.fileExists(atPath: legacyInternal.path), let bundledExecutable = Bundle.main.resourceURL?.appendingPathComponent("yt-dlp/yt-dlp_macos"), fileManager.fileExists(atPath: bundledExecutable.path) {
            // One-time migration from the original unpackaged build to the smaller,
            // self-contained official binary. _internal contains no user data.
            let replacement = runtime.appendingPathComponent("yt-dlp_macos.migration")
            try fileManager.copyItem(at: bundledExecutable, to: replacement)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacement.path)
            _ = try fileManager.replaceItemAt(executable, withItemAt: replacement)
            try fileManager.removeItem(at: legacyInternal)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    private func applicationSupportDirectory() throws -> URL {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw CocoaError(.fileNoSuchFile) }
        return base.appendingPathComponent("YTDLPGlass", isDirectory: true)
    }

    private func fetchVerifiedRuntime() async throws -> (version: String, binary: Data) {
        let endpoint = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.setValue("UniDownloader/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")", forHTTPHeaderField: "User-Agent")
        let (metadata, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: metadata)
        guard let binaryAsset = release.assets.first(where: { $0.name == "yt-dlp_macos" }), let checksumAsset = release.assets.first(where: { $0.name == "SHA2-256SUMS" }) else { throw NSError(domain: "YTDLPGlass", code: 2, userInfo: [NSLocalizedDescriptionKey: "The official release is missing its macOS binary or checksum manifest."]) }
        statusMessage = "Downloading verified yt-dlp \(release.tagName)…"
        async let binaryResponse = URLSession.shared.data(from: binaryAsset.browserDownloadURL)
        async let checksumResponse = URLSession.shared.data(from: checksumAsset.browserDownloadURL)
        let ((binary, binaryHTTP), (checksums, checksumHTTP)) = try await (binaryResponse, checksumResponse)
        guard (binaryHTTP as? HTTPURLResponse)?.statusCode == 200, (checksumHTTP as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard let manifest = String(data: checksums, encoding: .utf8), let expected = manifest.split(whereSeparator: \.isNewline).first(where: { $0.split(whereSeparator: \.isWhitespace).last == "yt-dlp_macos" })?.split(whereSeparator: \.isWhitespace).first else { throw NSError(domain: "YTDLPGlass", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not read the official checksum for yt-dlp_macos."]) }
        let actual = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(String(expected)) == .orderedSame else { throw NSError(domain: "YTDLPGlass", code: 4, userInfo: [NSLocalizedDescriptionKey: "Downloaded binary failed SHA-256 verification and was not installed."]) }
        return (release.tagName, binary)
    }

    private func installRuntime(_ binary: Data) throws {
        let runtime = try applicationSupportDirectory().appendingPathComponent("yt-dlp", isDirectory: true)
        let executable = runtime.appendingPathComponent("yt-dlp_macos")
        let replacement = runtime.appendingPathComponent("yt-dlp_macos.new")
        try binary.write(to: replacement, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacement.path)
        _ = try fileManager.replaceItemAt(executable, withItemAt: replacement)
    }

    private func execute(_ arguments: [String], executable tool: URL? = nil, onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let executable: URL
        if let tool { executable = tool } else {
            try bootstrapRuntime()
            executable = try applicationSupportDirectory().appendingPathComponent("yt-dlp/yt-dlp_macos")
        }
        let toolName = executable.lastPathComponent
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let log = ProcessLog()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                log.append(data)
                String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init).forEach { onLine?($0) }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                // Output still buffered in the pipe when the process exits (large -J JSON, last lines).
                let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                if !remaining.isEmpty { log.append(remaining) }
                Task { @MainActor in
                    if finished.terminationReason == .uncaughtSignal { continuation.resume(throwing: CancellationError()) }
                    else if finished.terminationStatus == 0 { continuation.resume(returning: log.snapshot()) }
                    else {
                        let output = log.snapshot()
                        continuation.resume(throwing: NSError(domain: "YTDLPGlass", code: Int(finished.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "\(toolName) exited with status \(finished.terminationStatus)." : output]))
                    }
                }
            }
            do { try process.run(); currentProcess = process } catch { continuation.resume(throwing: error) }
        }
    }

    private func persistFavoriteFolders() {
        if let data = try? JSONEncoder().encode(favoriteFolders) { UserDefaults.standard.set(data, forKey: "favoriteFolders") }
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin && SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            else if !launchAtLogin && SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        } catch { statusMessage = "Could not change launch-at-login: \(error.localizedDescription)" }
    }

    private func shouldCheckForUpdates() -> Bool {
        guard updateOnLaunch else { return false }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        return Date().timeIntervalSince1970 - last > 86_400
    }

    private func friendlyError(_ log: String) -> String {
        let lower = log.lowercased()
        // Browser cookie read failures mention cookies too, but need a different fix than a missing sign-in.
        let cookieReadFailures = ["could not copy", "cookie database", "failed to decrypt", "keyring", "operation not permitted", "permission denied"]
        if lower.contains("cookie"), cookieReadFailures.contains(where: { lower.contains($0) }) { return "UniDownloader could not read cookies from the selected browser. Allow access when macOS asks (Safari requires Full Disk Access in System Settings > Privacy & Security), or choose another browser in Settings." }
        let signInRequired = ["sign in", "login required", "registered users", "--cookies-from-browser", "account authentication"]
        if signInRequired.contains(where: { lower.contains($0) }) { return "This source requires a signed-in session. Choose Safari, Chrome, or Firefox cookies in Settings, then try again." }
        if lower.contains("ffmpeg") { return "FFmpeg is required for this format. It was not found or could not be executed." }
        if lower.contains("unsupported url") { return "This URL is not currently supported by yt-dlp." }
        return log.split(whereSeparator: \.isNewline).suffix(4).joined(separator: "\n")
    }

    private static func percentage(in text: String) -> Double? {
        let pattern = "([0-9]{1,3}(?:\\.[0-9]+)?)%"
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }

    private static func detectExecutable(named name: String) -> String? {
        ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/opt/local/bin/\(name)", "/usr/bin/\(name)"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func preferredFFmpegPath(stored: String?) -> String {
        let automaticallyDetected = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        if let stored, !stored.isEmpty, !automaticallyDetected.contains(stored), FileManager.default.isExecutableFile(atPath: stored) {
            return stored
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ffmpeg/ffmpeg").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return detectExecutable(named: "ffmpeg") ?? ""
    }

    private func shellWords(_ input: String) -> [String] {
        var results: [String] = []
        var current = ""
        var quote: Character?
        for character in input {
            if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                else { current.append(character) }
            } else if character.isWhitespace && quote == nil {
                if !current.isEmpty { results.append(current); current = "" }
            } else { current.append(character) }
        }
        if !current.isEmpty { results.append(current) }
        return results
    }
}
