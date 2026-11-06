cask "buddy" do
  version "2.0.1"
  sha256 "e60848fa0f2329d59378f834484491ca915c5db342246fce13a45d50612290ae"

  url "https://github.com/projects-hacks/buddy/releases/download/v#{version}/Buddy.dmg"
  name "Buddy"
  desc "Notch helper that explains your screen out loud while drawing on it"
  homepage "https://projects-hacks.github.io/buddy/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Buddy.app"

  zap trash: [
    "~/Library/Application Support/Buddy",
    "~/Library/Logs/Buddy.log",
    "~/Library/Logs/Buddy.previous.log",
    "~/Library/Logs/Buddy.rotated.log",
    "~/Library/Preferences/com.maverickrajeev.clicky-local.plist",
  ]

  caveats <<~EOS
    Buddy is not notarized, so the first time it opens macOS asks once:
    open Buddy, click Done, then click Open Anyway in
    System Settings > Privacy & Security.
  EOS
end
