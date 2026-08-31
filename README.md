# UniDownloader

UniDownloader is a private, native macOS interface for [yt-dlp](https://github.com/yt-dlp/yt-dlp), designed for Apple Silicon. It has no account, ads, analytics, telemetry, or cloud download history.

## Highlights

- Video and audio downloads, resolution selection, playlists, subtitles, metadata, cancellation, and a serial download queue.
- Persistent favorite folders plus a fixed **Save to** control for daily use.
- A native menu-bar drop zone: drag a browser URL straight onto the UniDownloader arrow. The drop area opens automatically and starts the download with the current format and folder.
- A first-launch welcome explaining privacy and workflow, and a Settings gear in the main window.
- Bundled native Apple Silicon FFmpeg 9.0.1 and FFprobe, YouTube JavaScript runtime support, HTTP impersonation, retries, and optional local browser cookies for authenticated Instagram/YouTube media.
- An Advanced Arguments field for yt-dlp options not yet represented by a native control. Arguments are passed directly to `Process`, never a shell.
- A bundled universal `yt-dlp` runtime copied on first launch to `~/Library/Application Support/YTDLPGlass/yt-dlp`. Engine updates fetch the official `yt-dlp_macos` release and verify its published SHA-256 before replacement, never mutating the signed app bundle.
- Signed Sparkle app updates. UniDownloader checks at launch and displays the release notes before installation; its engine update channel remains independent.

## Build

Open `YTDLPGlass.xcodeproj` in Xcode, select **UniDownloader**, then build and run. Or run:

```zsh
./Scripts/build-release.sh
```

Release assets are written to `ReleaseAssets/<version>/`.

## Install with Homebrew

```zsh
brew tap vviniciusbarreto/tap
brew install --cask uni-downloader
```

The cask installs Deno for YouTube JavaScript challenge support. FFmpeg and FFprobe are already bundled in the app.

## Distribution and privacy

The retained bundle ID is `com.vviniciusbarreto.ytdlpglass` so existing 1.0.0 installs can receive the UniDownloader 1.0.1 update. Releases are ad-hoc signed and Sparkle archives are Ed25519-signed, but the app is not Apple-notarized. On first launch macOS may require **System Settings > Privacy & Security > Open Anyway**.

UniDownloader does not bypass DRM or site authorization. Download only material you have permission to save. Browser cookies are opt-in, remain local, and are passed directly to yt-dlp. The included yt-dlp component is released under the Unlicense. The bundled FFmpeg/FFprobe build is GPLv3; build provenance and source links are in `Documentation/FFMPEG.md` and third-party notices are in `Documentation/THIRD_PARTY_LICENSES.txt`.
