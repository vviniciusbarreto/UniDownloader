# Release path

1. Run `./Scripts/release.sh VERSION BUILD_NUMBER`.
2. Publish the ZIP and DMG from `ReleaseAssets/VERSION/` in a `vVERSION` GitHub Release.
3. Commit the generated `appcast.xml` to the UniDownloader repository only.
4. Update `Casks/ytdlp-glass.rb` in `vviniciusbarreto/homebrew-tap` with the release version and ZIP SHA-256.
5. Retain `LICENSE-ytdlp.txt` and `Documentation/THIRD_PARTY_LICENSES.txt` in every distribution.

The app is ad-hoc signed, not Apple-notarized. Sparkle verifies updates with the private key stored under the separate Keychain account `com.vviniciusbarreto.ytdlpglass`. Never export or commit that private key. The runtime updater modifies only the per-user copy under Application Support and never changes the app bundle.
