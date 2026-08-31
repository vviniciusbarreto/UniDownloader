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
    case h264MP4 = "H.264 MP4"
    case h265MP4 = "H.265 HEVC MP4"
    case h264MOV = "Apple MOV (H.264)"
    case best = "Best quality (MKV)"
    case original = "Original source format"
    var id: String { rawValue }
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
    private var storage = ""
    func append(_ value: String) { lock.lock(); storage += value; lock.unlock() }
    func snapshot() -> String { lock.lock(); defer { lock.unlock() }; return storage }
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
    @Published var videoCompatibility: VideoCompatibility = .h264MP4 {
        didSet { UserDefaults.standard.set(videoCompatibility.rawValue, forKey: "videoCompatibility") }
    }
    @Published var includeSubtitles = false
    @Published var embedMetadata = true
    @Published var downloadPlaylist = false
    @Published var audioFormat = "Best available"
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
        videoCompatibility = VideoCompatibility(rawValue: UserDefaults.standard.string(forKey: "videoCompatibility") ?? "") ?? .h264MP4
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
        jobs[index].state = .downloading
        statusMessage = "Downloading…"
        var arguments = makeArguments(for: jobs[index])
        arguments.append(jobs[index].url)
        do {
            let output = try await execute(arguments) { [weak self] line in
                Task { @MainActor [weak self] in
                    guard let self, let i = self.jobs.firstIndex(where: { $0.id == jobID }) else { return }
                    self.jobs[i].details = line
                    if let percent = Self.percentage(in: line) { self.jobs[i].progress = percent / 100 }
                }
            }
            if let i = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[i].state = .finished
                jobs[i].progress = 1
                jobs[i].details = "Saved to \(jobs[i].destinationPath)"
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

    private func makeArguments(for job: DownloadJob) -> [String] {
        var arguments = [
            "--newline", "--progress", "--retries", "10", "--fragment-retries", "10",
            "--retry-sleep", "exp=1:20", "--concurrent-fragments", "4",
            "-P", job.destinationPath, "-o", "%(title).180B [%(id)s].%(ext)s"
        ]
        if !downloadPlaylist { arguments += ["--no-playlist"] }
        let hasFFmpeg = !ffmpegPath.isEmpty && fileManager.isExecutableFile(atPath: ffmpegPath)
        if hasFFmpeg {
            arguments += ["--ffmpeg-location", ffmpegPath]
            if embedMetadata { arguments += ["--embed-metadata"] }
            if includeSubtitles { arguments += ["--write-subs", "--write-auto-subs", "--sub-langs", "all,-live_chat", "--embed-subs"] }
        } else if includeSubtitles {
            arguments += ["--write-subs", "--write-auto-subs", "--sub-langs", "all,-live_chat"]
        }

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

        if job.kind == .video {
            let height = quality == "Best" ? "" : "[height<=\(quality)]"
            if hasFFmpeg {
                switch videoCompatibility {
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
        } else if audioFormat == "Best available" {
            arguments += ["-f", "bestaudio/best"]
        } else if hasFFmpeg {
            let audioExtension = ["MP3 (.mp3)": "mp3", "M4A (.m4a)": "m4a", "Opus (.opus)": "opus", "WAV (.wav)": "wav"][audioFormat] ?? "mp3"
            arguments += ["-x", "--audio-format", audioExtension, "--audio-quality", "0"]
        } else {
            arguments += ["-f", "bestaudio/best"]
        }
        arguments += shellWords(advancedArguments)
        return arguments
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
        request.setValue("UniDownloader/1.0.1", forHTTPHeaderField: "User-Agent")
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

    private func execute(_ arguments: [String], onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try bootstrapRuntime()
        let executable = try applicationSupportDirectory().appendingPathComponent("yt-dlp/yt-dlp_macos")
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let log = ProcessLog()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = String(data: handle.availableData, encoding: .utf8) ?? ""
                guard !chunk.isEmpty else { return }
                log.append(chunk)
                chunk.split(whereSeparator: \.isNewline).map(String.init).forEach { onLine?($0) }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    if finished.terminationReason == .uncaughtSignal { continuation.resume(throwing: CancellationError()) }
                    else if finished.terminationStatus == 0 { continuation.resume(returning: log.snapshot()) }
                    else {
                        let output = log.snapshot()
                        continuation.resume(throwing: NSError(domain: "YTDLPGlass", code: Int(finished.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "yt-dlp exited with status \(finished.terminationStatus)." : output]))
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
        if lower.contains("sign in") || lower.contains("login required") || lower.contains("cookies") { return "This source requires a signed-in session. Choose Safari, Chrome, or Firefox cookies in Settings, then try again." }
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
