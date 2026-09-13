cask "mix-recording" do
  version "1.0"
  sha256 "a8a9e91875d5b7568b5716d7f3c04fd3d1a7596a85b5119d17d97ed172c584f8"

  url "https://github.com/dct74/Mix-Recording/releases/download/v#{version}/Mix-Recording-#{version}.zip"
  name "Mix-Recording"
  desc "Record the microphone, the system audio, or both at once"
  homepage "https://github.com/dct74/Mix-Recording"

  # macOS-only app; without this the cask fails Homebrew's cross-platform validation
  depends_on macos: ">= :ventura"

  app "Mix-Recording.app"

  uninstall quit: "io.github.dct74.Mix-Recording"

  zap trash: [
    "~/Library/Containers/io.github.dct74.Mix-Recording",
    "~/Library/Preferences/io.github.dct74.Mix-Recording.plist",
    "~/Library/Saved Application State/io.github.dct74.Mix-Recording.savedState",
  ]
end
