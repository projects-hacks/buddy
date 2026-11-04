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

DMG="$OUT/Buddy-$VERSION.dmg"
hdiutil create -volname "Buddy $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
CHECKSUM="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "$CHECKSUM  Buddy-$VERSION.dmg" > "$DMG.sha256"
# Unregistered before deleting: a registered copy that no longer exists is
# where System Settings can go on finding an old name for the app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$STAGING/Buddy.app" "$BUILT_APP" 2>/dev/null || true
rm -rf "$STAGING" "$DERIVED"

echo ""
echo "made $DMG ($(du -h "$DMG" | cut -f1)), sha256 $CHECKSUM"
echo ""
echo "to publish it:"
echo "  gh release create v$VERSION \"$DMG\" \"$DMG.sha256\" --repo projects-hacks/study-buddy --title \"Buddy $VERSION\" --notes-file docs/release-notes.md"
