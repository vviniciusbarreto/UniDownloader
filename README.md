# YTDLP Glass

A private, native macOS SwiftUI interface for [yt-dlp](https://github.com/yt-dlp/yt-dlp), designed for Apple Silicon. YTDLP Glass has no account, ads, analytics, telemetry, or cloud download history.

## Included

- Video and audio downloads, resolution selection, playlists, subtitles, metadata, cancellation, and a serial download queue.
- Persistent favorite folders with a fast **Save to** menu.
- A menu bar drop zone: drag a browser link onto it and the download starts with the selected folder and format.
- A fixed quick-options bar for paste-and-download, video/audio type, quality, Mac-compatible format, and destination folder.
- Bundled native Apple Silicon FFmpeg 9.0.1 and FFprobe, YouTube JavaScript runtime support, HTTP impersonation, retries, and optional local browser cookies for authenticated Instagram/YouTube media.
- An Advanced Arguments field for any yt-dlp option not yet represented by a native control. Arguments are passed directly to `Process`, never through a shell.
- A bundled universal `yt-dlp` runtime copied on first launch to `~/Library/Application Support/YTDLPGlass/yt-dlp`. Updates fetch the official `yt-dlp_macos` GitHub release and verify its published SHA-256 before replacement, never mutating the signed app bundle.
- Two independent update channels: signed YTDLP Glass app updates through Sparkle, and SHA-256-verified yt-dlp engine updates from the official yt-dlp GitHub releases.

## Build

Open `YTDLPGlass.xcodeproj` in Xcode, select **YTDLP Glass**, then build and run. Or run:

```zsh
./Scripts/build-release.sh
```

The release app and archives are written to `ReleaseAssets/<version>/`.

## Install with Homebrew

```zsh
brew tap vviniciusbarreto/tap
brew install --cask ytdlp-glass
```

The cask installs Deno for YouTube JavaScript challenge support. FFmpeg and FFprobe are already bundled in the app.

## FFmpeg

Native arm64 FFmpeg and FFprobe are included in the app, so merging, conversion, subtitles, and metadata work without Homebrew. Deno is used by yt-dlp's YouTube JavaScript challenge support; the Homebrew cask installs it automatically.

## Distribution checklist

The bundle ID is `com.vviniciusbarreto.ytdlpglass`. Releases are ad-hoc signed and Sparkle archives are Ed25519-signed, but the app is not Apple-notarized. On first launch macOS may require **System Settings > Privacy & Security > Open Anyway**.

YTDLP Glass does not bypass DRM or site authorization. Download only material you have permission to save. Browser cookies are opt-in, remain local, and are passed directly to yt-dlp. The included yt-dlp component is released under the Unlicense. The bundled FFmpeg/FFprobe build is GPLv3; build provenance and source links are in `Documentation/FFMPEG.md` and third-party notices are in `Documentation/THIRD_PARTY_LICENSES.txt`.
