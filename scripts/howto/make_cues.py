"""Writes each test how-to's title and ways of asking, the way the app does.

Calls Claude Haiku with leanring-buddy/Guide/HowToCuesPrompt.txt, exactly the
prompt that ships, with the same message the app sends when it saves a
how-to (HowToMemory and LearningMemoryCalls.howToCues). Haiku never sees the
test questions. Writes tasks_with_cues.json for howto_eval.swift.

The key is read from the Keychain on stdin and never printed:
  security find-generic-password -a api-key -s com.maverickrajeev.clicky-local.anthropic -w \\
    | python3 -I scripts/howto/make_cues.py
"""

import concurrent.futures
import json
import pathlib
import sys
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
PROMPT = (HERE.parents[1] / "leanring-buddy/Guide/HowToCuesPrompt.txt").read_text()
KEY = sys.stdin.read().strip()
tasks = json.loads((HERE / "tasks.json").read_text())["tasks"]


def cues_for(task):
    steps = "\n".join(f"{index + 1}. {instruction} (control: {label})"
                      for index, (instruction, label) in enumerate(task["steps"]))
    message = f"app: {task['app_name']}\nthey asked: {task['asked']}\nsteps:\n{steps}"
    body = {"model": "claude-haiku-5-5", "max_tokens": 400, "system": PROMPT,
            "thinking": {"type": "disabled"}, "messages": [{"role": "user", "content": message}]}
    request = urllib.request.Request(
        "https://api.anthropic.com/v1/messages", data=json.dumps(body).encode(),
        headers={"x-api-key": KEY, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        reply = json.loads(response.read())
    text = "".join(block.get("text", "") for block in reply["content"])
    written = json.loads(text[text.index("{"):text.rindex("}") + 1])
    usage = reply.get("usage", {})
    cost = (usage.get("input_tokens", 0) * 0.10 + usage.get("output_tokens", 0) * 0.50) / 1e6
    return {**task, "title": written.get("title", task["asked"]), "cues": written.get("phrasings", [])[:12], "cost": cost}


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    filed = list(pool.map(cues_for, tasks))
(HERE / "tasks_with_cues.json").write_text(json.dumps({"tasks": filed}, indent=1))
for task in filed:
    print(f"{task['title']}: {len(task['cues'])} ways of asking, ${task['cost']:.5f}")
print(f"total ${sum(task['cost'] for task in filed):.4f}")
