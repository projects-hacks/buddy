"""Files each fixture concept the way the app files a lesson, to get its cues.

Calls Claude Haiku with leanring-buddy/Memory/LessonConceptPrompt.txt, exactly the
prompt that ships, giving it each concept as a one-sentence lesson. Writes
concepts_filed.json with the aliases and cues Haiku produced, which
recall_eval.swift then grades against the blind questions. Haiku never sees
the questions.

The key is read from the Keychain on stdin and never printed:
  security find-generic-password -a api-key -s com.maverickrajeev.clicky-local.anthropic -w \
    | python3 -I scripts/learning_memory/make_cues.py
"""

import concurrent.futures
import json
import pathlib
import sys
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
PROMPT = (HERE.parents[1] / "leanring-buddy/Memory/LessonConceptPrompt.txt").read_text()
KEY = sys.stdin.read().strip()
concepts = json.loads((HERE / "concepts.json").read_text())["concepts"]


def file_one(concept):
    lesson = (f"KNOWN:\n(none)\n\nTHE STUDENT ASKED: explain {concept['name']}\n"
              f"LESSON TITLE: {concept['name']}\nTHE EXPLANATION: {concept['summary']}")
    body = {"model": "claude-haiku-5-5", "max_tokens": 1600, "system": PROMPT,
            "thinking": {"type": "disabled"}, "messages": [{"role": "user", "content": lesson}]}
    request = urllib.request.Request(
        "https://api.anthropic.com/v1/messages", data=json.dumps(body).encode(),
        headers={"x-api-key": KEY, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        reply = json.loads(response.read())
    text = "".join(block.get("text", "") for block in reply["content"])
    filed = json.loads(text[text.index("{"):text.rindex("}") + 1])["concepts"]
    first = filed[0] if filed else {}
    return {"name": concept["name"],
            "aliases": sorted(set(concept["aliases"]) | set(first.get("aliases", []))),
            "cues": first.get("cues", []),
            "summary": concept["summary"],
            "usage": reply.get("usage", {})}


with concurrent.futures.ThreadPoolExecutor(8) as pool:
    results = list(pool.map(file_one, concepts))
input_tokens = sum(r["usage"].get("input_tokens", 0) for r in results)
output_tokens = sum(r["usage"].get("output_tokens", 0) for r in results)
for r in results:
    r.pop("usage")
(HERE / "concepts_filed.json").write_text(json.dumps({"concepts": results}, indent=1) + "\n")
print(f"filed {len(results)} concepts, {sum(len(r['cues']) for r in results)} cues; "
      f"{input_tokens} input and {output_tokens} output tokens, "
      f"about ${(input_tokens * 1 + output_tokens * 5) / 1e6 / len(results):.4f} per lesson at Haiku list price")
print("example:", json.dumps(results[39], indent=None)[:400])
