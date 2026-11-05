"""Grades ways of sorting a spoken question into the kind that picks its brain.

Every sorter gets the same 50 labelled test phrasings, all mid-conversation,
and is scored on how many it puts in the right kind and how long it takes.
The sorters that learn from examples see only the separate example set.

  keywords    the lists in CompanionManager.swift, read out of the source so
              the test grades exactly what the app runs
  apple-*     nearest examples by meaning, using the embedding models built
              into macOS (contextual is the transformer, sentence the older one)
  haiku       claude-haiku-5-5 asked to pick one kind, thinking off
  laya        the open-weight decision model, on the Mac GPU

usage: python3 -I sort_test.py            keywords and the on-device sorters
       <python with laya> -I sort_test.py --all   also Haiku and Laya
"""

import json
import pathlib
import re
import subprocess
import sys
import time
from collections import Counter, defaultdict

import anthropic
import numpy

HERE = pathlib.Path(__file__).resolve().parent
DATA = json.loads((HERE / "phrasings.json").read_text())
# The examples are the app's own file, so the test grades what ships.
DATA["examples"] = json.loads(
    (HERE.parents[1] / "leanring-buddy/Answering/QuestionKindExamples.json").read_text())["examples"]
KINDS = list(DATA["kinds"])
TEST = DATA["test"]
PREVIOUS_ANSWER = DATA["previous_answer"]


# --- keywords: the app's own lists ----------------------------------------------

manager = (HERE.parents[1] / "leanring-buddy/Companion/CompanionManager.swift").read_text()


def string_list_after(marker: str, source: str) -> list[str]:
    start = source.index(marker)
    bracket_open = source.index("[", start)
    bracket_close = source.index("]", bracket_open)
    return re.findall(r'"([^"]*)"', source[bracket_open:bracket_close])


asking_again = string_list_after("let pushBackPhrases = [", manager)
keyword_source = manager[manager.index("private static func questionKindFromKeywords"):]
teach_phrases = string_list_after("if mentions(", keyword_source)
after_teach = keyword_source[keyword_source.index("return .teach"):]
tradeoff_phrases = string_list_after("if mentions(", after_teach)
after_tradeoff = after_teach[after_teach.index("return .tradeOff"):]
quick_phrases = string_list_after("if mentions(", after_tradeoff)


def keywords(question: str) -> str:
    # The app asks "is this push-back" first, and only when there is a
    # previous answer, which every test item has.
    if any(phrase in question for phrase in asking_again):
        return "reexplain"
    if any(phrase in question for phrase in teach_phrases):
        return "teach"
    if any(phrase in question for phrase in tradeoff_phrases):
        return "tradeoff"
    if any(phrase in question for phrase in quick_phrases) and len(question.split()) <= 12:
        return "quick"
    return "normal"


# --- Apple embeddings, nearest examples -----------------------------------------

example_pairs = [(phrase, kind) for kind, phrases in DATA["examples"].items() for phrase in phrases]
sentences = [phrase for phrase, _ in example_pairs] + [question for question, _ in TEST]
embedded = json.loads(subprocess.run(
    ["swift", str(HERE / "embed.swift")], input=json.dumps(sentences),
    capture_output=True, text=True, check=True).stdout)


def nearest_examples_sorter(model_name: str):
    vectors = numpy.array(embedded[model_name]["vectors"], dtype=float)
    vectors /= numpy.linalg.norm(vectors, axis=1, keepdims=True) + 1e-9
    example_vectors = vectors[:len(example_pairs)]
    example_kinds = [kind for _, kind in example_pairs]
    timings = embedded[model_name]["ms"][len(example_pairs):]

    def sort(index: int) -> tuple[str, float]:
        similarities = example_vectors @ vectors[len(example_pairs) + index]
        # Mean of each kind's three closest examples: one stray close example
        # should not decide it, and three is under half of eight.
        per_kind = defaultdict(list)
        for similarity, kind in zip(similarities, example_kinds):
            per_kind[kind].append(similarity)
        scores = {kind: numpy.mean(sorted(values)[-3:]) for kind, values in per_kind.items()}
        return max(scores, key=scores.get), timings[index]
    return sort


# --- Haiku ------------------------------------------------------------------------

key = subprocess.run(["security", "find-generic-password", "-a", "api-key",
                      "-s", "com.maverickrajeev.clicky-local.anthropic", "-w"],
                     capture_output=True, text=True).stdout.strip()
claude = anthropic.Anthropic(api_key=key)
kind_menu = "\n".join(f"{kind}: {description}" for kind, description in DATA["kinds"].items())
haiku_system = (
    "you sort what a student just said to their tutor into one kind. "
    "reply with the kind's name only, nothing else.\n\n" + kind_menu
)


def haiku(question: str) -> str:
    response = claude.messages.create(
        model="claude-haiku-5-5", max_tokens=8, system=haiku_system,
        thinking={"type": "disabled"},
        messages=[{"role": "user", "content":
                   f"the tutor just said: {PREVIOUS_ANSWER}\n\nthe student says: {question}"}],
    )
    word = "".join(b.text for b in response.content if b.type == "text").strip().lower()
    return next((kind for kind in KINDS if kind in word), "normal")


# --- Laya ---------------------------------------------------------------------------

router = None
if "--all" in sys.argv:
    from laya import Router  # only needed, and only installed, for the full run
    router = Router(device="mps")
laya_question = {"kind": {
    "type": "choice",
    "instructions": "What is the student asking the tutor for?",
    "criteria": DATA["kinds"],
}}


def laya_with_context(question: str) -> str:
    state = f"The tutor just said: {PREVIOUS_ANSWER}\nThe student now says: {question}"
    return router.predict(state, laya_question, model="english")["answers"]["kind"]["choice"]


def laya_alone(question: str) -> str:
    return router.predict(question, laya_question, model="english")["answers"]["kind"]["choice"]


if router:
    laya_alone("warm up")  # the first call builds the model; that is load time, not decision time


def timed(function):
    def run(index: int) -> tuple[str, float]:
        start = time.monotonic()
        kind = function(TEST[index][0])
        return kind, (time.monotonic() - start) * 1000
    return run


SORTERS = {
    "keywords": timed(keywords),
    "apple-contextual": nearest_examples_sorter("contextual"),
    "apple-sentence": nearest_examples_sorter("sentence"),
}
if "--all" in sys.argv:
    SORTERS |= {
        "haiku": timed(haiku),
        "laya (question only)": timed(laya_alone),
        "laya (with last answer)": timed(laya_with_context),
    }

print(f"{'sorter':26} {'right':>6} " + " ".join(f"{k[:9]:>9}" for k in KINDS) + f" {'median ms':>10}")
mistakes = {}
for name, sorter in SORTERS.items():
    right = Counter()
    timings = []
    wrong = []
    for index, (question, expected) in enumerate(TEST):
        got, milliseconds = sorter(index)
        timings.append(milliseconds)
        if got == expected:
            right[expected] += 1
        else:
            wrong.append(f"{question!r}: {expected} -> {got}")
    mistakes[name] = wrong
    print(f"{name:26} {sum(right.values()):>3}/50 "
          + " ".join(f"{right[k]:>7}/10" for k in KINDS)
          + f" {numpy.median(timings):>10.1f}", flush=True)

(HERE / "mistakes.json").write_text(json.dumps(mistakes, indent=1))
print("\nevery wrong answer is in mistakes.json")
