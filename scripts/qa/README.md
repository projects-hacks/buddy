# End-to-end QA

Runs real questions through a debug build of Buddy, without a microphone, and collects what the student would see and hear: screenshots including the notch and the drawing, and the log lines for every stage.

```bash
defaults write com.maverickrajeev.clicky-local qaHooksEnabled -bool true   # then relaunch Buddy
zsh scripts/qa/ask.sh hint1 "i'm stuck on this one, how do i solve it"
zsh scripts/qa/qa.sh fakeKey Anthropic && zsh scripts/qa/ask.sh keyfail "what is big o of a hash map lookup"
zsh scripts/qa/qa.sh clearFakeKeys
defaults delete com.maverickrajeev.clicky-local qaHooksEnabled             # then relaunch Buddy
```

Questions are answered aloud and drawn on the screen in front, so put the screen to test in front first: a practice problem, a diagram, code. The channel exists only in debug builds (`leanring-buddy/QAHooks.swift`), is off unless switched on, and never touches the Keychain: `fakeKey` replaces a key in memory only.

**A fresh install** is tested with a copy built under another identity, which gets its own Keychain items, data folder and log (`AppIdentity.swift`), so it starts as empty as a friend's first launch:

```bash
xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Debug \
  -derivedDataPath "$TMPDIR/buddy-qa-derived" CODE_SIGN_IDENTITY="Clicky Local Dev" CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" ENABLE_DEBUG_DYLIB=NO PRODUCT_BUNDLE_IDENTIFIER=com.maverickrajeev.clicky-local.qa \
  INFOPLIST_KEY_CFBundleDisplayName="Buddy QA" build
defaults write com.maverickrajeev.clicky-local.qa qaHooksEnabled -bool true
open "$TMPDIR/buddy-qa-derived/Build/Products/Debug/Buddy.app"
QA_TARGET=com.maverickrajeev.clicky-local.qa zsh scripts/qa/qa.sh state
```

Afterwards, remove everything the copy made: `defaults delete com.maverickrajeev.clicky-local.qa`, its Keychain items (`security delete-generic-password -a api-key -s com.maverickrajeev.clicky-local.qa.anthropic`), `~/Library/Application Support/ClickyLocal-qa` and `~/Library/Logs/ClickyLocal-qa.log`.
