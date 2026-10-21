cask "uni-downloader" do
  version "1.0.1"
  sha256 "67c183e07e5e9d68fc2a61b066673cf9c24ddc9db3b1c711eb26c069915a3b72"

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
