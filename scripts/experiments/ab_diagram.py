"""Isolates what offering the positioned grid costs.

Same question, same token budget, same screen index. The only difference is
whether the prompt offers NODE/EDGE at all. Diagram-heavy answers measured
60 to 75 seconds to first byte where the column-only prompt measured about
three, and that gap decides whether richer diagrams are affordable.
"""
import os
import json
import re
import subprocess
import sys
import time
import urllib.request

PROJECT = os.environ["VERTEX_PROJECT"]  # your Google Cloud project
def endpoint(model):
    return (f"https://aiplatform.googleapis.com/v1/projects/{PROJECT}"
            f"/locations/global/publishers/google/models/{model}:streamGenerateContent?alt=sse")

QUESTION = "walk me through how separating storage from compute actually works"

SCREEN_INDEX = """t43: Compute owns its disk
t49: Storage and compute pulled apart
t50: Data lives once, in cheap cloud object storage
t52: Scaling compute is starting a process, not moving bytes"""

LENGTH_RULE = ("\n\nLENGTH: they asked to be taught this properly. take the room: "
               "up to eight sentences, and draw a board if the idea has structure.")


def access_token():
    result = subprocess.run(
        ["gcloud", "auth", "application-default", "print-access-token"],
        capture_output=True, text=True)
    return result.stdout.strip()


def build_prompt(include_grid):
    prompt = open("/tmp/tutor_prompt.txt").read().replace(
        "\\(screenIndexListing)", SCREEN_INDEX)
    if not include_grid:
        start = prompt.find("POSITIONED DIAGRAMS")
        end = prompt.find("example, binary search:")
        if start != -1 and end != -1:
            prompt = prompt[:start] + prompt[end:]
        prompt = re.sub(r"\[NODE:[^\n]*\n", "", prompt)
        prompt = re.sub(r"\[EDGE:[^\n]*\n", "", prompt)
    return prompt + LENGTH_RULE


def run(include_grid, token, model):
    body = {
        "contents": [{"role": "user", "parts": [{"text": QUESTION}]}],
        "systemInstruction": {"parts": [{"text": build_prompt(include_grid)}]},
        "generationConfig": ({"maxOutputTokens": 520,
                              "thinkingConfig": {"thinkingLevel": "LOW"}}
                             if "argon" in model else {"maxOutputTokens": 520}),
    }
    request = urllib.request.Request(
        endpoint(model), data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json"})

    started = time.time()
    first_byte = None
    collected = []
    with urllib.request.urlopen(request, timeout=180) as response:
        for raw in response:
            if first_byte is None:
                first_byte = time.time() - started
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data: "):
                continue
            try:
                payload = json.loads(line[6:])
            except json.JSONDecodeError:
                continue
            for candidate in payload.get("candidates", []):
                for part in candidate.get("content", {}).get("parts", []):
                    collected.append(part.get("text", ""))

    total = time.time() - started
    answer = "".join(collected)
    spoken = re.sub(r"\[[^\]]*\]", "", answer)
    label = f"{model:18s} {'WITH' if include_grid else 'without'} grid"
    node_count = len(re.findall(r"\[NODE:", answer))
    column_count = len(re.findall(r"\[COL:", answer))
    prompt_size = len(build_prompt(include_grid))
    print(f"  {label}: ttfb {first_byte or 0:6.2f}s  total {total:6.2f}s  "
          f"words {len(spoken.split()):4d}  nodes {node_count}  "
          f"cols {column_count}  prompt {prompt_size} chars")


if __name__ == "__main__":
    token = access_token()
    if len(token) < 50:
        print("no token"); sys.exit(1)
    models = sys.argv[1:] or ["gemini-4-argon"]
    for model in models:
        for include in (False, True):
            try:
                run(include, token, model)
            except Exception as error:  # noqa: BLE001
                print(f"  {model} {'WITH' if include else 'without'} grid failed: {error}")
