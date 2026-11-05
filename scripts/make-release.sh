#!/bin/zsh
# Builds a downloadable Buddy for other Macs: a Release build, signed with the
# same local certificate as scripts/build-local.sh, inside a drag-to-install
# disk image, with its checksum.
#
# Why the local certificate and not Developer ID. Developer ID and Apple's
# notarization need a paid Apple Developer account. Without them macOS asks
# once, the first time, before it opens the app (README: Download). A stable
# certificate still matters: macOS ties the Microphone, Screen Recording and
# Accessibility grants to the signature, and the same certificate on every
# release keeps them across updates.
#
# Nothing is published from here. The script prints the GitHub command that
# makes the release, for the repository's owner to run.
#
# usage: zsh scripts/make-release.sh [version]    default: the project's MARKETING_VERSION

set -e
PROJECT_DIR="${0:a:h}/.."
cd "$PROJECT_DIR"

SIGNING_IDENTITY="Clicky Local Dev"
VERSION="${1:-$(grep -m1 'MARKETING_VERSION' leanring-buddy.xcodeproj/project.pbxproj | sed 's/.*= \(.*\);/\1/')}"
BUILD_NUMBER="$(git rev-list --count HEAD)"
OUT="build/release"
# Outside the home folder: compilers write source paths into binaries, and
# a path under /Users/<name> would ship that name to everyone.
DERIVED="${TMPDIR:-/tmp}/buddy-release-derived"

if ! security find-certificate -c "$SIGNING_IDENTITY" >/dev/null 2>&1; then
  echo "Signing certificate '$SIGNING_IDENTITY' not found. See README: Build and run."
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "uncommitted changes; a release should be exactly a commit. Commit or stash first."
  exit 1
fi
# Personal values of whoever is releasing (their Google Cloud project and
# email), looked up on this machine rather than written here, and checked in
# the source before building: a short string can be folded into instructions
# by the optimiser and slip past a binary scan.
PERSONAL_VALUES=()
VERTEX_PROJECT_HERE="$(defaults read com.maverickrajeev.clicky-local vertexProjectIdentifier 2>/dev/null || true)"
[ -n "$VERTEX_PROJECT_HERE" ] && PERSONAL_VALUES+=(-e "$VERTEX_PROJECT_HERE")
EMAIL_HERE="$(git config user.email || true)"
[ -n "$EMAIL_HERE" ] && PERSONAL_VALUES+=(-e "${EMAIL_HERE%@*}")
PERSONAL_VALUES+=(-e "/Users/$USER")
if git grep -n "${PERSONAL_VALUES[@]}" -- leanring-buddy >/dev/null; then
  echo "a personal value is in the app's source:"
  git grep -n "${PERSONAL_VALUES[@]}" -- leanring-buddy
  exit 1
fi

echo "building Buddy $VERSION ($BUILD_NUMBER)..."
rm -rf "$OUT" && mkdir -p "$OUT"
# Its own derived data, so the release never replaces the build installed
# for daily use, nor its permissions.
xcodebuild -project leanring-buddy.xcodeproj \
  -scheme leanring-buddy \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build > "$OUT/build.log" 2>&1 || { grep -E "error:" "$OUT/build.log" | head -8; echo "build failed (log: $OUT/build.log)"; exit 1; }

BUILT_APP="$(find "$DERIVED/Build/Products/Release" -maxdepth 1 -name '*.app' | head -1)"
STAGING="$OUT/staging"
mkdir -p "$STAGING"
ditto "$BUILT_APP" "$STAGING/Buddy.app"
ln -s /Applications "$STAGING/Applications"

codesign --verify --deep --strict "$STAGING/Buddy.app"
echo "signed by: $(codesign -dvvv "$STAGING/Buddy.app" 2>&1 | grep '^Authority=' | head -1)"

# Nothing personal may ship: no Google Cloud project, no home folder paths,
# in the binary or in any resource.
if grep -rIl "${PERSONAL_VALUES[@]}" "$STAGING/Buddy.app" >/dev/null 2>&1 \
   || strings "$STAGING/Buddy.app/Contents/MacOS/"* | grep -q "${PERSONAL_VALUES[@]}"; then
  echo "a personal value or home folder path is in the app; not packaging"
  exit 1
fi
echo "architectures: $(lipo -archs "$STAGING/Buddy.app/Contents/MacOS/"*)"

# Always the same name, so one link downloads the newest release from any
# page: github.com/<repo>/releases/latest/download/Buddy.dmg. The version
# is in the release's title and the app itself.
DMG="$OUT/Buddy.dmg"

# A shortcut straight to the pane with Open Anyway, for the one step of a
# first install that people otherwise cannot find.
cat > "$STAGING/Open Privacy & Security.webloc" <<'WEBLOC'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>URL</key>
	<string>x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension</string>
</dict>
</plist>
WEBLOC
SetFile -a E "$STAGING/Open Privacy & Security.webloc" 2>/dev/null || true
mkdir -p "$STAGING/.background"
cp "scripts/dmg/background.tiff" "$STAGING/.background/background.tiff"

# Laid out by Finder itself, the only thing that writes a window's layout:
# the install steps are the window's background (scripts/dmg/), with the
# icons placed where the picture leaves room for them.
VOLUME="Buddy $VERSION"
WRITABLE="$OUT/Buddy-writable.dmg"
rm -f "$WRITABLE"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGING" -ov -format UDRW "$WRITABLE" >/dev/null
MOUNTED="$(hdiutil attach "$WRITABLE" -readwrite -noverify -noautoopen | grep -o '/Volumes/.*' | head -1)"
# The shortcut wears System Settings' icon, so it reads as "open Settings"
# rather than as a web page.
osascript -l JavaScript >/dev/null 2>&1 <<SETICON || true
ObjC.import('AppKit');
const workspace = \$.NSWorkspace.sharedWorkspace;
const icon = workspace.iconForFile('/System/Applications/System Settings.app');
workspace.setIconForFileOptions(icon, '$MOUNTED/Open Privacy & Security.webloc', 0);
SETICON
# Window points; the background is drawn for this size (scripts/dmg/), plus
# the title bar.
WINDOW_BOUNDS="{200, 100, 960, 772}"
if osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to $WINDOW_BOUNDS
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "Buddy.app" of container window to {210, 130}
    set position of item "Applications" of container window to {550, 130}
    set position of item "Open Privacy & Security.webloc" of container window to {555, 556}
    close
    open
    -- Set again once reopened: the first size is not always the one saved.
    set the bounds of container window to $WINDOW_BOUNDS
    update without registering applications
    delay 2
    close
    delay 1
  end tell
end tell
APPLESCRIPT
then
  echo "disk image window laid out with the install steps"
else
  echo "Finder could not be scripted (allow it in System Settings > Privacy & Security > Automation); the window keeps Finder's default layout"
fi
sync
hdiutil detach "$MOUNTED" -quiet || hdiutil detach "$MOUNTED" -force -quiet
hdiutil convert "$WRITABLE" -format UDZO -ov -o "$DMG" >/dev/null
rm -f "$WRITABLE"
CHECKSUM="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "$CHECKSUM  Buddy.dmg" > "$DMG.sha256"
# Unregistered before deleting: a registered copy that no longer exists is
# where System Settings can go on finding an old name for the app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$STAGING/Buddy.app" "$BUILT_APP" 2>/dev/null || true
rm -rf "$STAGING" "$DERIVED"

echo ""
echo "made $DMG ($(du -h "$DMG" | cut -f1)), sha256 $CHECKSUM"
echo ""
echo "to publish it:"
echo "  gh release create v$VERSION \"$DMG\" \"$DMG.sha256\" --repo projects-hacks/buddy --title \"Buddy $VERSION\" --notes-file docs/release-notes.md"
