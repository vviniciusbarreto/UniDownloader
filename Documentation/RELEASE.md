# Release path

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `YTDLPGlass.xcodeproj` and the `VERSION`/`BUILD_NUMBER` defaults in `Scripts/build-release.sh`. The yt-dlp updater reads its User-Agent version from the bundle, so it needs no manual change.
2. Write the release notes to `ReleaseAssets/VERSION/UniDownloader-VERSION-arm64.md`. `Scripts/release.sh` stops before building when this file is missing.
3. Run `./Scripts/release.sh VERSION BUILD_NUMBER`. The build stops if the executable is not arm64-only.
4. Publish the ZIP and DMG from `ReleaseAssets/VERSION/` in a `vVERSION` GitHub Release.
5. Commit the generated `appcast.xml` to the UniDownloader repository only.
6. Update `Casks/uni-downloader.rb` in `vviniciusbarreto/homebrew-tap` with the release version and the SHA-256 printed for the ZIP, and mirror the change in `Packaging/Homebrew/Casks/uni-downloader.rb`. The cask URL derives from `version`.
7. Validate the install with `brew update`, `brew install --cask vviniciusbarreto/tap/uni-downloader` (or `brew upgrade --cask uni-downloader`) on a Mac that does not hold development builds in `/Applications`.
8. Retain `LICENSE-ytdlp.txt` and `Documentation/THIRD_PARTY_LICENSES.txt` in every distribution.

The app is ad-hoc signed, not Apple-notarized. Sparkle verifies updates with the private key stored under the separate Keychain account `com.vviniciusbarreto.ytdlpglass`. Never export or commit that private key. The runtime updater modifies only the per-user copy under Application Support and never changes the app bundle.
