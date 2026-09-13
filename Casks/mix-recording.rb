cask "mix-recording" do
  version "1.0.1"
  sha256 "62e9254c0bb88082fc6ee0159db84d7fa25c5a170f995db2134402c1829bf776"

  url "https://github.com/dct74/Mix-Recording/releases/download/v#{version}/Mix-Recording-#{version}.zip"
  name "Mix-Recording"
  desc "Record the microphone, the system audio, or both at once"
  homepage "https://github.com/dct74/Mix-Recording"

  # macOS-only app; without this Homebrew's cross-platform validation rejects the cask
  depends_on macos: :ventura

  app "Mix-Recording.app"

  uninstall quit: "io.github.dct74.Mix-Recording"

  zap trash: [
    "~/Library/Containers/io.github.dct74.Mix-Recording",
    "~/Library/Preferences/io.github.dct74.Mix-Recording.plist",
    "~/Library/Saved Application State/io.github.dct74.Mix-Recording.savedState",
  ]
end
