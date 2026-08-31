cask "ytdlp-glass" do
  version "1.0.0"
  sha256 "8c2230a40035433c93422b255678457b3012af579edc66dadf82653d0c351091"

  url "https://github.com/vviniciusbarreto/YTDLPGlass/releases/download/v#{version}/YTDLPGlass-#{version}-arm64.zip"
  name "YTDLP Glass"
  desc "Private native interface for yt-dlp with menu bar drag and drop"
  homepage "https://github.com/vviniciusbarreto/YTDLPGlass"

  depends_on arch: :arm64
  depends_on macos: :sequoia
  depends_on formula: "deno"

  app "YTDLP Glass.app"

  caveats <<~EOS
    YTDLP Glass is ad-hoc signed but is not Apple-notarized. If macOS blocks the
    first launch, open System Settings > Privacy & Security and click Open Anyway.
  EOS
end
