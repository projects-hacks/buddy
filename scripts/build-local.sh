#!/bin/zsh
# Builds and relaunches the app with a stable code signature.
#
# Why these flags, each of which was needed to make a locally signed build run:
#
#   CODE_SIGN_IDENTITY    A self-signed certificate rather than ad-hoc. macOS
#                         ties Screen Recording and Accessibility grants to the
#                         designated requirement, and for an ad-hoc signature
#                         that is the CDHash, which changes on every rebuild.
#                         Permissions therefore had to be re-granted after every
#                         single build. Signed with a certificate the
#                         requirement is identifier + certificate root, which is
#                         stable, so the grants persist.
#
#   ENABLE_DEBUG_DYLIB=NO Xcode splits the app into a separate debug dylib for
#                         previews and signs it independently. With no Team ID
#                         on a self-signed certificate the main binary and the
#                         dylib disagree and dyld refuses to map it.
#
#   The disable-library-validation entitlement, set in the entitlements file,
#   exists for the same reason one level out: the hardened runtime requires
#   embedded frameworks to share the process Team ID, and Sparkle and PostHog
#   have none here.
#
# Create the certificate once with scripts/make-signing-cert.sh.

set -e

PROJECT_DIR="${0:a:h}/.."
cd "$PROJECT_DIR"

SIGNING_IDENTITY="Clicky Local Dev"

if ! codesign -s "$SIGNING_IDENTITY" --dryrun /dev/null 2>/dev/null; then
  if ! security find-certificate -c "$SIGNING_IDENTITY" >/dev/null 2>&1; then
    echo "Signing certificate '$SIGNING_IDENTITY' not found."
    echo "Run scripts/make-signing-cert.sh first, or permissions will reset on every build."
    exit 1
  fi
fi

echo "building..."
xcodebuild -project leanring-buddy.xcodeproj \
  -scheme leanring-buddy \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  ENABLE_DEBUG_DYLIB=NO \
  build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/leanring-buddy-*/Build/Products/Debug \
  -maxdepth 1 -name "*.app" 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
  echo "no app produced"
  exit 1
fi

echo "signed by: $(codesign -dvvv "$APP_PATH" 2>&1 | grep '^Authority=' | head -1)"

pkill -f "Clicky.app/Contents/MacOS" 2>/dev/null || true
sleep 1
# Keep the previous session's log: it is the record of the last test, and
# deleting it on rebuild has already destroyed evidence once.
if [ -f ~/Library/Logs/ClickyLocal.log ]; then
  mv ~/Library/Logs/ClickyLocal.log ~/Library/Logs/ClickyLocal.previous.log
fi
open "$APP_PATH"
sleep 4

if pgrep -f "Clicky.app/Contents/MacOS" >/dev/null; then
  echo "running. logs: ~/Library/Logs/ClickyLocal.log"
else
  echo "failed to launch. run the binary directly to see why:"
  echo "  \"$APP_PATH/Contents/MacOS/Clicky\""
fi
