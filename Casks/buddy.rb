cask "buddy" do
  version "1.4"
  sha256 "3aa6d60c97c24bfc83f62acfde0beb321fe39a411c09a9c5bdb6a8287d2b77f1"

  url "https://github.com/projects-hacks/buddy/releases/download/v#{version}/Buddy.dmg"
  name "Buddy"
  desc "Study helper in the notch that explains your screen out loud while drawing on it"
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
    "~/Library/Preferences/com.maverickrajeev.clicky-local.plist",
  ]

  caveats <<~EOS
    Buddy is not notarized, so the first time it opens macOS asks once:
    open Buddy, click Done, then click Open Anyway in
    System Settings > Privacy & Security.
  EOS
end
