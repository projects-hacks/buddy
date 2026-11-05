#!/bin/zsh
# Builds and runs the talk-over reading checks against the app's own file.
# Top-level code has to be in a file named main.swift when compiled with others.
set -e
here=${0:A:h}
out=$(mktemp -d)
cp "$here/hearing_test.swift" "$out/main.swift"
swiftc -o "$out/hearing_test" "$here/../../leanring-buddy/VoiceIn/TalkOverHearing.swift" "$out/main.swift"
"$out/hearing_test"
