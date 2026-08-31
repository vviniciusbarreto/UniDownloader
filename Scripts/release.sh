#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?Usage: ./Scripts/release.sh VERSION BUILD_NUMBER}"
build_number="${2:?Usage: ./Scripts/release.sh VERSION BUILD_NUMBER}"
release_dir="$project_root/ReleaseAssets/$version"
archive="$release_dir/YTDLPGlass-$version-arm64.zip"
notes="$release_dir/YTDLPGlass-$version-arm64.md"
appcast_source="$project_root/Releases/$version"

VERSION="$version" BUILD_NUMBER="$build_number" "$project_root/Scripts/build-release.sh"

if [[ ! -f "$notes" ]]; then
  printf '%s\n' \
    "# YTDLP Glass $version" "" \
    "- Native Apple Silicon media downloader with a Tahoe Liquid Glass interface." \
    "- Persistent download folders and menu bar drag-and-drop downloads." \
    "- YouTube and Instagram compatibility improvements with automatic FFmpeg/JavaScript runtime detection." \
    "- Signed automatic app updates through Sparkle and verified yt-dlp engine updates." \
    > "$notes"
fi

mkdir -p "$appcast_source"
ditto "$archive" "$appcast_source/YTDLPGlass-$version-arm64.zip"
ditto "$notes" "$appcast_source/YTDLPGlass-$version-arm64.md"

sparkle_tools="$project_root/build-release/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$sparkle_tools/generate_appcast" \
  --account com.vviniciusbarreto.ytdlpglass \
  --download-url-prefix "https://github.com/vviniciusbarreto/YTDLPGlass/releases/download/v$version/" \
  --link "https://github.com/vviniciusbarreto/YTDLPGlass" \
  --embed-release-notes --maximum-versions 5 \
  -o "$project_root/appcast.xml" "$appcast_source"

shasum -a 256 "$archive"
