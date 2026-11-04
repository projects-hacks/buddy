#!/bin/zsh
# Sends one command to a running debug build of Buddy through its QA channel
# (leanring-buddy/QAHooks.swift). The channel is off until switched on:
#   defaults write com.maverickrajeev.clicky-local qaHooksEnabled -bool true
# and relaunch. Switch it off again with `defaults delete ... qaHooksEnabled`.
#
# usage: qa.sh <command> [value] [text]
#   ask "" "<question>"        a question, as if spoken
#   snapshot <path.png>        the screen, Buddy's own windows included
#   state                      notch, routing, memory and key state, to the log
#   fakeKey Anthropic          a rejected key, in memory only; clearFakeKeys undoes it
#   notch open|closed, escape, setup <0-3>, closeSetup, forgetMemory
# Results are written to Buddy's log. QA_TARGET=<bundle id> addresses another copy.
osascript -l JavaScript - "$1" "${2:-}" "${3:-}" "${QA_TARGET:-com.maverickrajeev.clicky-local}" <<'JS'
function run(argv) {
  ObjC.import("Foundation");
  var info = $.NSMutableDictionary.alloc.init;
  info.setObjectForKey(argv[0], "command");
  if (argv[1]) info.setObjectForKey(argv[1], "value");
  if (argv[2]) info.setObjectForKey(argv[2], "text");
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(argv[3] + ".qa", $(), info, true);
}
JS
