cask "mix-recording" do
  version "1.0"
  # Replace with the output of: shasum -a 256 Mix-Recording-<version>.zip
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/dct74/Mix-Recording/releases/download/v#{version}/Mix-Recording-#{version}.zip"
  name "Mix-Recording"
  desc "Record the microphone, the system audio, or both at once"
  homepage "https://github.com/dct74/Mix-Recording"

  app "Mix-Recording.app"

  uninstall quit: "io.github.ianpilon.Mix-Recording"

  zap trash: [
    "~/Library/Containers/io.github.ianpilon.Mix-Recording",
    "~/Library/Preferences/io.github.ianpilon.Mix-Recording.plist",
    "~/Library/Saved Application State/io.github.ianpilon.Mix-Recording.savedState",
  ]
end
