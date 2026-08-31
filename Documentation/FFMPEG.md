# Bundled FFmpeg

YTDLP Glass 1.0.0 includes native Apple Silicon builds of FFmpeg and FFprobe so users do not need a separate package manager installation.

- Version: FFmpeg 9.0.1
- Architecture: arm64
- Build provider: https://ffmpeg.martin-riedl.de/
- Reproducible build script and dependency versions: https://git.martin-riedl.de/ffmpeg/build-script
- FFmpeg source: https://github.com/FFmpeg/FFmpeg/tree/n9.0.1
- License reported by the binary: GNU GPL version 3 or later
- FFmpeg binary SHA-256: `393e4c395020a1cb7cbd77fbe00599ce69d1c6466fee0dbd59d13f86a81a1611`
- FFprobe binary SHA-256: `7abc49fb2bdf2204f018e76dc6e0a8ae7643313bae09a9fa43e7eb12442271bc`

The exact configure line can be inspected at any time with `ffmpeg -version`. This application is distributed under GPLv3, and its complete corresponding source is available in the YTDLPGlass GitHub repository.
