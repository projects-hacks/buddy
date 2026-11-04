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
# Create the certificate once in Keychain Access: Certificate Assistant >
# Create a Certificate, named "Clicky Local Dev", Self Signed Root, Code Signing.

set -e

PROJECT_DIR="${0:a:h}/.."
cd "$PROJECT_DIR"

SIGNING_IDENTITY="Clicky Local Dev"

if ! codesign -s "$SIGNING_IDENTITY" --dryrun /dev/null 2>/dev/null; then
  if ! security find-certificate -c "$SIGNING_IDENTITY" >/dev/null 2>&1; then
    echo "Signing certificate '$SIGNING_IDENTITY' not found."
    echo "Create it in Keychain Access > Certificate Assistant > Create a Certificate (Self Signed Root, Code Signing), or permissions will reset on every build."
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
  build > /tmp/buddy-build.log 2>&1 || BUILD_FAILED=1
grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" /tmp/buddy-build.log | head -8

# Stop here on a failed build: carrying on would install the previous
# build's app and look like success.
if [ -n "${BUILD_FAILED:-}" ]; then
  echo "build failed, nothing installed (full log: /tmp/buddy-build.log)"
  exit 1
fi

# The newest build, should another checkout have its own DerivedData folder.
APP_PATH=$(ls -td ~/Library/Developer/Xcode/DerivedData/leanring-buddy-*/Build/Products/Debug/*.app 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
  echo "no app produced"
  exit 1
fi

echo "signed by: $(codesign -dvvv "$APP_PATH" 2>&1 | grep '^Authority=' | head -1)"

# Installed into Applications so there is one copy to launch, keep in the
# Dock, and start at login. The build products folder is not a place to run
# an app from: it is replaced on every build, and Launch Services would list
# two Clickys. The installed copy keeps the same signature, so the Screen
# Recording and Accessibility grants carry over.
INSTALLED_APP="/Applications/Buddy.app"

# Matches this app's binary only, never HeyClicky's.
# Builds before the rename ran as Clicky; either may be running.
pkill -f "Buddy.app/Contents/MacOS/(Buddy|Clicky)$" 2>/dev/null || true
sleep 1

rm -rf "$INSTALLED_APP"
ditto "$APP_PATH" "$INSTALLED_APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP_PATH" 2>/dev/null || true
echo "installed: $INSTALLED_APP"

# Keep the previous session's log: it is the record of the last test, and
# deleting it on rebuild has already destroyed evidence once.
if [ -f ~/Library/Logs/Buddy.log ]; then
  mv ~/Library/Logs/Buddy.log ~/Library/Logs/Buddy.previous.log
fi
open "$INSTALLED_APP"
sleep 4

if pgrep -f "Buddy.app/Contents/MacOS/Buddy$" >/dev/null; then
  echo "running. logs: ~/Library/Logs/Buddy.log"
else
  echo "failed to launch. run the binary directly to see why:"
  echo "  \"$INSTALLED_APP/Contents/MacOS/Buddy\""
  exit 1
fi
