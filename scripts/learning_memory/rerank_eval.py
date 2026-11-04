"""Grades the second stage of recall: Claude Haiku choosing from the shortlist.

Reads the shortlists recall_eval.swift wrote for every blind question, asks
Haiku with leanring-buddy/MemoryRecallPrompt.txt (the prompt that ships), and
scores what it chose against the blind answers, per half. Also reports how
long each call took, since it has to fit inside the screen capture.

The key is read from the Keychain on stdin and never printed:
  security find-generic-password -a api-key -s com.maverickrajeev.clicky-local.anthropic -w \
    | python3 -I scripts/learning_memory/rerank_eval.py /tmp/shortlists.json
"""

import concurrent.futures
import json
import pathlib
import re
import statistics
import sys
import time
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
PROMPT = (HERE.parents[1] / "leanring-buddy/MemoryRecallPrompt.txt").read_text()
KEY = sys.stdin.read().strip()
rows = json.loads(pathlib.Path(sys.argv[1]).read_text())


def user_message(row):
    """The same shape LearningMemory sends: question, window, numbered ideas."""
    ideas = "\n".join(f"{number}. {c['name']}: {c['summary']}" for number, c in enumerate(row["candidates"], 1))
    window = row["context"].split("|")[0].strip()
    return f"the student said: {row['question']}\nwindow: {window or 'unknown'}\n\nideas:\n{ideas}"


def choose(row):
    if not row["candidates"]:
        return [], 0.0, {}
    body = {"model": "claude-haiku-5-5", "max_tokens": 12, "system": PROMPT,
            "thinking": {"type": "disabled"}, "messages": [{"role": "user", "content": user_message(row)}]}
    request = urllib.request.Request(
        "https://api.anthropic.com/v1/messages", data=json.dumps(body).encode(),
        headers={"x-api-key": KEY, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    started = time.time()
    with urllib.request.urlopen(request, timeout=30) as response:
        reply = json.loads(response.read())
    seconds = time.time() - started
    text = "".join(block.get("text", "") for block in reply["content"]).lower()
    numbers = [int(n) for n in re.findall(r"\d+", text)] if "none" not in text else []
    chosen = [row["candidates"][n - 1]["name"] for n in numbers if 1 <= n <= len(row["candidates"])][:3]
    return chosen, seconds, reply.get("usage", {})


with concurrent.futures.ThreadPoolExecutor(6) as pool:
    results = list(pool.map(choose, rows))

timings = sorted(seconds for _, seconds, _ in results if seconds)
input_tokens = sum(usage.get("input_tokens", 0) for _, _, usage in results)
output_tokens = sum(usage.get("output_tokens", 0) for _, _, usage in results)
for half in ["dev", "test"]:
    found = expected = wrong = surfaced = clean = negatives = 0
    misses, mistakes = [], []
    for row, (chosen, _, _) in zip(rows, results):
        if row["half"] != half:
            continue
        allowed = set(row["expected"]) | set(row["acceptable"])
        found += sum(name in chosen for name in row["expected"])
        expected += len(row["expected"])
        wrong_here = [name for name in chosen if name not in allowed]
        wrong += len(wrong_here)
        surfaced += len(chosen)
        if not row["expected"]:
            negatives += 1
            clean += not chosen
        if any(name not in chosen for name in row["expected"]):
            misses.append(f"{row['question']}  wanted {row['expected']} got {chosen}")
        if wrong_here:
            mistakes.append(f"{row['question']}  wrongly {wrong_here}")
    print(f"{half.upper()}: found {found}/{expected} expected ({100 * found // max(1, expected)}%), "
          f"{wrong} wrong of {surfaced} surfaced (precision {100 - 100 * wrong // max(1, surfaced)}%), "
          f"{clean}/{negatives} unrelated questions left alone")
    if half == "test":
        print("test misses:", *misses, sep="\n  ")
        print("test wrong surfacings:", *mistakes, sep="\n  ")
print(f"\nhaiku call: median {statistics.median(timings):.2f}s, p90 {timings[int(len(timings) * 0.9)]:.2f}s, "
      f"max {timings[-1]:.2f}s over {len(timings)} calls")
print(f"cost: about ${(input_tokens * 1 + output_tokens * 5) / 1e6 / max(1, len(timings)):.5f} per question at Haiku list price")
