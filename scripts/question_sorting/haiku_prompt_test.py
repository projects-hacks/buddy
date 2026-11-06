"""Grades Haiku's question sorting prompt alone on two sets: the blind spoken
study questions (spoken_test.json) and everything else people say to Buddy
(everyday_test.json). The on-device sorter is left out: it hands Haiku every
message unlike its examples, so Haiku is what decides these.

usage: python3 -I haiku_prompt_test.py [prompt file]
       (default: the prompt the app ships, leanring-buddy/Answering/QuestionSorterPrompt.txt)
"""

import json
import pathlib
import subprocess
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

import anthropic

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from sorting_message import sorting_message  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent
KINDS = ["reexplain", "tradeoff", "normal", "teach", "quick", "chat"]
prompt_path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parents[1] / "leanring-buddy/Answering/QuestionSorterPrompt.txt"
SYSTEM = prompt_path.read_text()
key = subprocess.run(["security", "find-generic-password", "-a", "api-key", "-s",
                      "com.maverickrajeev.clicky-local.anthropic", "-w"], capture_output=True, text=True).stdout.strip()
claude = anthropic.Anthropic(api_key=key)
usage = Counter()


def sort(item):
    response = claude.messages.create(
        model="claude-haiku-5-5", max_tokens=8, system=SYSTEM, thinking={"type": "disabled"},
        messages=[{"role": "user", "content": sorting_message(item["question"], item["after_answer"])}])
    usage["input"] += response.usage.input_tokens
    usage["output"] += response.usage.output_tokens
    word = "".join(block.text for block in response.content if block.type == "text").strip().lower()
    return next((kind for kind in KINDS if kind in word), "normal")


for name in ["spoken_test.json", "everyday_test.json"]:
    items = json.loads((HERE / name).read_text())["items"]
    with ThreadPoolExecutor(8) as pool:
        answers = list(pool.map(sort, items))
    right = sum(answer == item["kind"] for answer, item in zip(answers, items))
    print(f"{name}: {right} of {len(items)} ({100 * right / len(items):.0f}%)")
    fresh = [(answer, item) for answer, item in zip(answers, items) if item.get("fresh")]
    if fresh:
        print(f"   of which fresh: {sum(a == i['kind'] for a, i in fresh)} of {len(fresh)}")
    # The costly mistake: a real question answered as small talk by the small model.
    swallowed = sum(answer == "chat" and item["kind"] != "chat" for answer, item in zip(answers, items))
    print(f"   real questions sorted as chat: {swallowed}")
    for answer, item in zip(answers, items):
        if answer != item["kind"]:
            print(f"   wanted {item['kind']:9} got {answer:9} {item['question']}")
cost = usage["input"] * 0.10 / 1e6 + usage["output"] * 0.50 / 1e6
print(f"cost about ${cost:.4f} ({usage['input']} in, {usage['output']} out)")
