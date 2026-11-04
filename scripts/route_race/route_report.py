"""Reads Buddy's log and reports how routing is doing on real questions.

The race and the judging measure the brains on a handful of questions chosen
in advance. This measures what actually happens: how real questions were
sorted, which brain answered, how often the classifier was too slow or a brain
failed and another stepped in, and how often a brain's answer was followed by
"I didn't follow", the one signal of a bad answer that costs the student
nothing to give.

A router left unwatched degrades quietly, with fallbacks logged as successes,
so this is meant to be run every week or two of use. A brain whose answers are
pushed back on much more than the others' is the cue to rerun the race.

usage: python3 -I route_report.py [log files...]   default: Buddy's current and previous log
"""

import pathlib
import re
import sys
from collections import Counter

LOGS = [pathlib.Path(argument) for argument in sys.argv[1:]] or [
    pathlib.Path.home() / "Library/Logs/Buddy.previous.log",
    pathlib.Path.home() / "Library/Logs/Buddy.log",
]

sorted_by = Counter()
kinds = Counter()
answered_by = Counter()
pushed_back_after = Counter()
late = 0
fallbacks = []
benched = Counter()

for log in LOGS:
    if not log.exists():
        continue
    for line in log.read_text(errors="replace").splitlines():
        if match := re.search(r"🧭 sorted as (\w+) by ([\w ]+?) \(", line):
            kinds[match.group(1)] += 1
            sorted_by[match.group(2)] += 1
        elif match := re.search(r"🧭 answered by (\w+)", line):
            answered_by[match.group(1)] += 1
        elif match := re.search(r"🔁 student still lost after (\w+)", line):
            pushed_back_after[match.group(1)] += 1
        elif "⌛ question classifier late" in line:
            late += 1
        elif "↪️" in line:
            fallbacks.append(line.split("↪️", 1)[1].strip())
        elif match := re.search(r"🪑 router: (\w+) benched", line):
            benched[match.group(1)] += 1

questions = sum(kinds.values())
print(f"questions: {questions}")
if not questions:
    sys.exit(0)
print("kinds:      " + ", ".join(f"{kind} {count}" for kind, count in kinds.most_common()))
print("sorted by:  " + ", ".join(f"{source} {count}" for source, count in sorted_by.most_common())
      + f"   (classifier too late {late} times)")
print("\nbrain     answers  followed by push-back")
for brain, count in answered_by.most_common():
    pushed = pushed_back_after[brain]
    print(f"{brain:9} {count:7}  {pushed:4}  {pushed / count:5.0%}")
print(f"\nfallbacks: {len(fallbacks)}" + "".join(f"\n  {line}" for line in fallbacks[-10:]))
if benched:
    print("benched:   " + ", ".join(f"{brain} {count}" for brain, count in benched.items()))
