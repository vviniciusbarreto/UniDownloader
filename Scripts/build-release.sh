#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${VERSION:-1.0.1}"
build_number="${BUILD_NUMBER:-2}"
derived="$project_root/build-release"
app="$derived/Build/Products/Release/UniDownloader.app"
release_dir="$project_root/ReleaseAssets/$version"

xcodebuild -project "$project_root/YTDLPGlass.xcodeproj" \
  -scheme "UniDownloader" -configuration Release -derivedDataPath "$derived" \
  ARCHS=arm64 MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGNING_ALLOWED=NO build

codesign --force --deep --sign - "$app"
codesign --verify --deep --strict --verbose=2 "$app"

# The cask and bundled FFmpeg require Apple Silicon. Refuse to package anything else.
app_archs="$(lipo -archs "$app/Contents/MacOS/UniDownloader")"
if [[ "$app_archs" != "arm64" ]]; then
  echo "Expected an arm64-only executable, found: $app_archs" >&2
  exit 1
fi

mkdir -p "$release_dir"
ditto "$app" "$release_dir/UniDownloader.app"
ditto -c -k --norsrc --keepParent "$app" "$release_dir/UniDownloader-$version-arm64.zip"

stage="$derived/dmg-stage-$version"
mkdir -p "$stage"
ditto "$app" "$stage/UniDownloader.app"
ln -sfn /Applications "$stage/Applications"
hdiutil create -volname "UniDownloader" -srcfolder "$stage" -ov -format UDZO "$release_dir/UniDownloader-$version-arm64.dmg" >/dev/null

echo "Built: $release_dir"
