cask "uni-downloader" do
  version "1.1.0"
  sha256 "a2de5b3ac60cbe65fbd1632593cdc75281f8a44e7fa063cf8403ce6b0be69fde"

  url "https://github.com/vviniciusbarreto/UniDownloader/releases/download/v#{version}/UniDownloader-#{version}-arm64.zip"
  name "UniDownloader"
  desc "Private native interface for yt-dlp with direct menu bar URL drops"
  homepage "https://github.com/vviniciusbarreto/UniDownloader"

  depends_on arch: :arm64
  depends_on macos: :sequoia
  depends_on formula: "deno"

  app "UniDownloader.app"

  caveats <<~EOS
    UniDownloader is ad-hoc signed but is not Apple-notarized. If macOS blocks the
    first launch, open System Settings > Privacy & Security and click Open Anyway.
  EOS
end
