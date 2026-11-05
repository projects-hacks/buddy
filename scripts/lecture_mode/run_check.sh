#!/bin/zsh
# Builds lecture mode's pure parts with the check and runs it.
# usage: zsh scripts/lecture_mode/run_check.sh [captions.vtt]
# LECTURE_CHECK_OFFLINE=1 skips the YouTube requests.
set -e
here=${0:A:h}
repository=${here:h:h}
build=$(mktemp -d)
cp "$here/lecture_mode_check.swift" "$build/main.swift"
xcrun swiftc -O -o "$build/lecture_mode_check" \
  "$repository/leanring-buddy/LectureModeCore.swift" \
  "$repository/leanring-buddy/YouTubeCaptions.swift" \
  "$build/main.swift"
"$build/lecture_mode_check" "$@"
