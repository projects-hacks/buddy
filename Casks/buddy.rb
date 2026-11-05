cask "buddy" do
  version "2.0"
  sha256 "9de8eeee86aa01c94fc5bce627d5032a814b25580a91c7f6ec681c53a64cc42c"

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
