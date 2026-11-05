#!/bin/zsh
# Runs the unit tests (leanring-buddyTests) with xcodebuild test.
#
# Builds into its own folder, ~/Library/Caches/Buddy-unit-tests, and runs
# the tests inside that build of the app. Not under the repository: a test
# copy reading its own files under ~/Documents (as symbolicating a failure
# does) waits on macOS asking for the Documents folder, and the run hangs.
# /Applications/Buddy.app is never built,
# copied, signed or launched, so its Screen Recording and Accessibility
# grants are untouched, and the app starts nothing while the tests run
# (CompanionAppDelegate.isRunningUnitTests). Signed ad hoc, without the
# hardened runtime, so the test bundle can load into the test copy.
#
# usage: zsh scripts/test.sh [extra xcodebuild arguments]

set -e
here=${0:A:h}
repository=${here:h}
derived_data="$HOME/Library/Caches/Buddy-unit-tests/DerivedData"
test_app="$derived_data/Build/Products/Debug/Buddy.app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# The test copy has Buddy's own identifier; once the tests end it is taken
# out of Launch Services again, so nothing opens it in place of the real one.
unregister_test_copy() {
  if [ -d "$test_app" ]; then
    "$lsregister" -u "$test_app" 2>/dev/null || true
  fi
}
trap unregister_test_copy EXIT

cd "$repository"
xcodebuild test \
  -project leanring-buddy.xcodeproj \
  -scheme leanring-buddy \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  -only-testing:leanring-buddyTests \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  ENABLE_HARDENED_RUNTIME=NO \
  ENABLE_DEBUG_DYLIB=NO \
  "$@"
