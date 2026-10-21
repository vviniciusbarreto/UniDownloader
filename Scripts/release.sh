#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?Usage: ./Scripts/release.sh VERSION BUILD_NUMBER}"
build_number="${2:?Usage: ./Scripts/release.sh VERSION BUILD_NUMBER}"
release_dir="$project_root/ReleaseAssets/$version"
archive="$release_dir/UniDownloader-$version-arm64.zip"
notes="$release_dir/UniDownloader-$version-arm64.md"
appcast_source="$project_root/Releases/$version"

# Release notes ship inside the Sparkle appcast and the GitHub Release, so a
# version without its own notes must not be published with generic text.
if [[ ! -f "$notes" ]]; then
  echo "Missing release notes: $notes" >&2
  echo "Write the notes for $version there, then run this script again." >&2
  exit 1
fi

VERSION="$version" BUILD_NUMBER="$build_number" "$project_root/Scripts/build-release.sh"

mkdir -p "$appcast_source"
ditto "$archive" "$appcast_source/UniDownloader-$version-arm64.zip"
ditto "$notes" "$appcast_source/UniDownloader-$version-arm64.md"

sparkle_tools="$project_root/build-release/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$sparkle_tools/generate_appcast" \
  --account com.vviniciusbarreto.ytdlpglass \
  --download-url-prefix "https://github.com/vviniciusbarreto/UniDownloader/releases/download/v$version/" \
  --link "https://github.com/vviniciusbarreto/UniDownloader" \
  --embed-release-notes --maximum-versions 5 \
  -o "$project_root/appcast.xml" "$appcast_source"

# The initial channel predates the rebrand. Keep the visible Sparkle channel
# title aligned with the app without changing its update-compatible identity.
sed -i '' 's#<title>YTDLP Glass</title>#<title>UniDownloader</title>#' "$project_root/appcast.xml"

shasum -a 256 "$archive"
