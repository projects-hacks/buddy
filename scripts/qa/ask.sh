#!/bin/zsh
# Asks Buddy one question end to end and collects the evidence: screenshots
# while it waits, while it explains and after, and the log lines the answer
# wrote (stages, routing, memory, hints, failures).
#
# usage: ask.sh <name> "<question>"      screenshots go to $QA_OUT (default: a temp folder)
QA="${0:a:h}/qa.sh"
OUT="${QA_OUT:-${TMPDIR%/}/buddy-qa}"
mkdir -p "$OUT"
LOG=~/Library/Logs/ClickyLocal.log
START=$(( $(wc -l < $LOG | tr -d " ") + 1 ))
"$QA" ask "" "$2"
sleep 3;   "$QA" snapshot "$OUT/$1-wait.png"
sleep 7;   "$QA" snapshot "$OUT/$1-during.png"
for i in {1..60}; do
  "$QA" state; sleep 2
  tail -n +$START $LOG | grep -a "🧪 state" | tail -1 | grep -q "activity=ready" && break
done
sleep 1; "$QA" snapshot "$OUT/$1-after.png"; sleep 2
tail -n +$START $LOG | grep -av "🧪 qa:" | grep -a "⏱\|🧭\|🧠\|🧩\|✏️\|🔑\|↪️\|⌛\|📘\|⚠️\|state:\|asked"
echo "screenshots in $OUT"
