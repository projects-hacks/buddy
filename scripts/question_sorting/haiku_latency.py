"""Times Haiku's question sorting one call at a time, the way the app makes
it, to set how long Buddy waits for it (classifierFloorSeconds in
CompanionManager+QuestionKind.swift). Every other everyday message, on one
warmed connection, half a second apart.

usage: python3 -I haiku_latency.py
"""

import json
import pathlib
import statistics
import subprocess
import sys
import time

import anthropic

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from sorting_message import sorting_message  # noqa: E402

SYSTEM = (HERE.parents[1] / "leanring-buddy/Answering/QuestionSorterPrompt.txt").read_text()
key = subprocess.run(["security", "find-generic-password", "-a", "api-key", "-s",
                      "com.maverickrajeev.clicky-local.anthropic", "-w"], capture_output=True, text=True).stdout.strip()
claude = anthropic.Anthropic(api_key=key)
claude.models.list(limit=1)

items = json.loads((HERE / "everyday_test.json").read_text())["items"][::2]
seconds = []
for item in items:
    start = time.monotonic()
    claude.messages.create(
        model="claude-haiku-5-5", max_tokens=8, system=SYSTEM, thinking={"type": "disabled"},
        messages=[{"role": "user", "content": sorting_message(item["question"], item["after_answer"])}])
    seconds.append(time.monotonic() - start)
    time.sleep(0.5)

seconds.sort()
print(f"{len(seconds)} sorts: median {statistics.median(seconds):.2f}s, slowest tenth from "
      f"{seconds[int(len(seconds) * 0.9)]:.2f}s, slowest {seconds[-1]:.2f}s")
for limit in (0.75, 1.0, 1.1, 1.25):
    print(f"  over {limit}s: {sum(s > limit for s in seconds)}")
