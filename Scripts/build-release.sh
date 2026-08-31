#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${VERSION:-1.0.0}"
build_number="${BUILD_NUMBER:-1}"
derived="$project_root/build-release"
app="$derived/Build/Products/Release/YTDLP Glass.app"
release_dir="$project_root/ReleaseAssets/$version"

xcodebuild -project "$project_root/YTDLPGlass.xcodeproj" \
  -scheme "YTDLP Glass" -configuration Release -derivedDataPath "$derived" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGNING_ALLOWED=NO build

codesign --force --deep --sign - "$app"
codesign --verify --deep --strict --verbose=2 "$app"

mkdir -p "$release_dir"
ditto "$app" "$release_dir/YTDLP Glass.app"
ditto -c -k --norsrc --keepParent "$app" "$release_dir/YTDLPGlass-$version-arm64.zip"

stage="$derived/dmg-stage"
mkdir -p "$stage"
ditto "$app" "$stage/YTDLP Glass.app"
ln -sfn /Applications "$stage/Applications"
hdiutil create -volname "YTDLP Glass" -srcfolder "$stage" -ov -format UDZO "$release_dir/YTDLPGlass-$version-arm64.dmg" >/dev/null

echo "Built: $release_dir"
