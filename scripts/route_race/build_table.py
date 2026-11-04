"""Turns the race and the blind judging into leanring-buddy/RouteTable.json.

For every kind of question and every brain: the judged quality (both judges,
both passes, every question of that kind), the median seconds to the first
spoken sentence over every run, and the mean cost.

Two numbers decide how the router reads the table:
  noise             measured here: the standard error of the difference
                    between two brains' quality on one kind. Closer than this
                    is a tie, and a tie goes to the cheaper brain.
  seconds_per_point a product decision, passed in: how many seconds of silence
                    before the first word are worth one point of quality.

Because the second is a judgement, the routing is printed for a range of it,
so it is plain whether the choice depends on the exact value or holds across
any reasonable one.

usage: python3 -I build_table.py <route_race_dir> <lesson_race_dir> <seconds_per_point>
"""

import json
import pathlib
import statistics
import sys
from collections import defaultdict

HERE = pathlib.Path(__file__).resolve().parent
RACE, LESSONS = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
SECONDS_PER_POINT = float(sys.argv[3])
BRAINS = ["sonnet", "opus", "argon"]
KINDS = ["quick", "normal", "teach", "reexplain", "tradeoff"]
LESSON_NAMES = {"opus-5.5 low": "opus", "sonnet-5.5 no-think": "sonnet", "argon LOW": "argon"}

timing = defaultdict(list)
cost = defaultdict(list)
for row in json.loads((RACE / "results.json").read_text()):
    if "error" not in row and row.get("first_say"):
        timing[(row["kind"], row["brain"])].append(row["first_say"])
        cost[(row["kind"], row["brain"])].append(row["cost"])
for row in json.loads((LESSONS / "results.json").read_text()):
    brain = LESSON_NAMES.get(row["model"])
    if brain and row.get("first_say"):
        timing[("teach", brain)].append(row["first_say"])
        cost[("teach", brain)].append(row["cost"])

quality = defaultdict(list)
by_judge = defaultdict(list)
pass_gap = []
judgements = json.loads((RACE / "judgements.json").read_text())
passes = defaultdict(dict)
for judgement in judgements:
    for brain in BRAINS:
        score = judgement["scores"][brain]["overall"]
        quality[(judgement["kind"], brain)].append(score)
        by_judge[(judgement["judge"], brain)].append(score)
        passes[(judgement["question"], judgement["judge"], brain)][judgement["pass"]] = score
for scores in passes.values():
    if len(scores) == 2:
        pass_gap.append(abs(scores[1] - scores[2]))

# Standard error of a kind-level difference between two brains.
standard_errors = []
for kind in KINDS:
    for brain in BRAINS:
        scores = quality[(kind, brain)]
        if len(scores) > 1:
            standard_errors.append(statistics.stdev(scores) / len(scores) ** 0.5)
noise = round((2 * statistics.mean(standard_errors) ** 2) ** 0.5, 2)

print(f"judged answers: {len(judgements)}  mean gap between the two shuffled passes: "
      f"{statistics.mean(pass_gap):.2f} points  noise for a difference: {noise}")
print("\neach judge's mean overall score per brain (a judge favouring its own family shows here)")
for judge in ["opus", "argon"]:
    print(f"  {judge:6} judge: " + "  ".join(
        f"{brain} {statistics.mean(by_judge[(judge, brain)]):.2f}" for brain in BRAINS if by_judge[(judge, brain)]))

table = {}
print(f"\n{'kind':10} " + "  ".join(f"{brain:>22}" for brain in BRAINS))
for kind in KINDS:
    table[kind] = {}
    cells = []
    for brain in BRAINS:
        if not quality[(kind, brain)] or not timing[(kind, brain)]:
            cells.append(f"{'missing':>22}")
            continue
        measured = {
            "quality": round(statistics.mean(quality[(kind, brain)]), 2),
            "first_say": round(statistics.median(timing[(kind, brain)]), 2),
            "cost": round(statistics.mean(cost[(kind, brain)]), 4),
        }
        table[kind][brain] = measured
        cells.append(f"q {measured['quality']:4.1f}  {measured['first_say']:4.1f}s  ${measured['cost']:.3f}")
    print(f"{kind:10} " + "  ".join(f"{cell:>22}" for cell in cells))


def route(kind: str, seconds_per_point: float, allowed=BRAINS) -> str:
    values = {brain: m["quality"] - m["first_say"] / seconds_per_point
              for brain, m in table[kind].items() if brain in allowed}
    best = max(values.values())
    close = [brain for brain in values if values[brain] >= best - noise]
    return min(close, key=lambda brain: table[kind][brain]["cost"])


print("\nwhat each kind routes to, by how many seconds of waiting one point of quality is worth")
rates = [1, 2, 3, 4, 6, 8, 12, 1000]
print(f"{'kind':10} " + " ".join(f"{(str(rate) + 's') if rate < 1000 else 'free':>7}" for rate in rates))
for kind in KINDS:
    if len(table[kind]) == len(BRAINS):
        print(f"{kind:10} " + " ".join(f"{route(kind, rate):>7}" for rate in rates))

(HERE.parents[1] / "leanring-buddy/RouteTable.json").write_text(json.dumps({
    "_why": "What ModelRouter.swift decides from. Built by scripts/route_race/build_table.py from the race "
            "(route_race.py, lesson_race.py) and the blind judging (judge.py): quality is the mean overall "
            "score from two judges of different families over two shuffled passes, first_say the median "
            "seconds to the first spoken sentence, cost dollars per answer. noise is measured; "
            "seconds_per_point is a product decision, see docs/model-choice.md.",
    "noise": noise,
    "seconds_per_point": SECONDS_PER_POINT,
    "kinds": table,
}, indent=1) + "\n")
print(f"\nwrote RouteTable.json with seconds_per_point {SECONDS_PER_POINT}")
