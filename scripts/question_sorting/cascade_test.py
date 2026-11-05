"""Grades the two-stage sorter: on-device first, Haiku only when that is unsure.

The on-device sorter is free and takes 9ms, and on the blind spoken set it is
right every time it is over 90% sure and wrong most of the time under 50%. So
it decides the questions it is sure of, and the rest go to Claude Haiku, which
runs while the screen is captured and read (about 0.7s) and so adds little or
no wait.

The confidence threshold is chosen on the dev half of spoken_test.json and the
test half is scored once with it, the same discipline as calibrate.py.

usage: python3 -I cascade_test.py      (needs calibrate.py run first)
"""

import json
import pathlib
import subprocess
import sys
import time
from collections import Counter

import anthropic
import numpy

HERE = pathlib.Path(__file__).resolve().parent
# -I leaves the script's folder off the path; calibrate.py is a sibling.
sys.path.insert(0, str(HERE))
import calibrate as sorter  # noqa: E402  runs the on-device variants and their choice

KINDS = sorter.KINDS
DEFINITIONS = json.loads((HERE / "phrasings.json").read_text())["kinds"]

key = subprocess.run(["security", "find-generic-password", "-a", "api-key",
                      "-s", "com.maverickrajeev.clicky-local.anthropic", "-w"],
                     capture_output=True, text=True).stdout.strip()
claude = anthropic.Anthropic(api_key=key)

# The prompt the app sends, kept in one place so the test grades what ships.
SYSTEM = (HERE.parents[1] / "leanring-buddy/Answering/QuestionSorterPrompt.txt").read_text()


def haiku(question: str, after_answer: bool) -> tuple[str, float]:
    situation = ("the helper has already answered something in this conversation."
                 if after_answer else "this is the first thing the student has asked; nothing has been explained yet.")
    start = time.monotonic()
    response = claude.messages.create(
        model="claude-haiku-5-5", max_tokens=8, system=SYSTEM, thinking={"type": "disabled"},
        messages=[{"role": "user", "content": f"{situation}\n\nthe student said: {question}"}])
    elapsed = (time.monotonic() - start) * 1000
    word = "".join(b.text for b in response.content if b.type == "text").strip().lower()
    return next((kind for kind in KINDS if kind in word), "normal"), elapsed


variant, temperature, matrix, kinds, _ = sorter.results[sorter.chosen]


def on_device(question, after_answer):
    probability = sorter.adjust(
        sorter.probabilities(sorter.variant_scores(question, matrix, kinds, variant["split"]), temperature),
        after_answer, variant["lost_means_teach"])
    return KINDS[int(numpy.argmax(probability))], float(probability.max())


def grade(items, label):
    rows = []
    for question, expected, after_answer in items:
        local_kind, confidence = on_device(question, after_answer)
        haiku_kind, milliseconds = haiku(question, after_answer)
        rows.append((expected, local_kind, confidence, haiku_kind, milliseconds))
    haiku_right = sum(e == h for e, _, _, h, _ in rows)
    local_right = sum(e == l for e, l, _, _, _ in rows)
    print(f"\n{label}: on-device {local_right}/{len(rows)}, haiku alone {haiku_right}/{len(rows)}, "
          f"haiku median {numpy.median([m for *_, m in rows]):.0f}ms, p90 {numpy.percentile([m for *_, m in rows], 90):.0f}ms")
    return rows


def cascade(rows, threshold):
    right = sum((l if c >= threshold else h) == e for e, l, c, h, _ in rows)
    asked = sum(c < threshold for _, _, c, _, _ in rows)
    return right, asked


dev_rows = grade(sorter.dev, "dev")
print("threshold  right  sent to haiku")
best = None
for threshold in [0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 1.01]:
    right, asked = cascade(dev_rows, threshold)
    print(f"{threshold:9.2f}  {right:>3}/50  {asked:>3}")
    # Most right; among ties, the one that asks Haiku least.
    if best is None or (right, -asked) > (best[1], -best[2]):
        best = (threshold, right, asked)

test_rows = grade(sorter.test, "test")
right, asked = cascade(test_rows, best[0])
print(f"\nthreshold {best[0]} chosen on dev. test half, scored once: {right}/50, {asked} of 50 sent to Haiku")
mistakes = Counter((e, l if c >= best[0] else h) for e, l, c, h, _ in test_rows if (l if c >= best[0] else h) != e)
print("test mistakes:", mistakes.most_common(8))
false_reexplain = sum((l if c >= best[0] else h) == "reexplain" and e != "reexplain" for e, l, c, h, _ in test_rows)
print("false re-explains:", false_reexplain)
(HERE / "cascade.json").write_text(json.dumps({"threshold": best[0], "test_right": right, "sent_to_haiku": asked}, indent=1))
