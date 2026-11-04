"""Races the three brains Auto routing chooses between, on every question kind.

The teach kind was raced in scripts/lesson_race; this covers the other four in
the same drawing-program format, so the router's table of what each brain is
good at comes from measurement rather than from the old tag format.

Every contender gets exactly what the app sends: the system prompt read out
of TutorProgramPrompt.swift, the turn note with that kind's length rule, the
screenshot, the kind's token room, and for re-explanations the previous lesson
as history plus the app's push-back instruction.

Each question runs twice per brain, because time to the first spoken sentence
varies run to run as much as it varies between brains. The programs are saved
for judge.py.

usage: python3 -I route_race.py <screenshot.png> <listing.txt> <previous_lesson.txt> <out_dir>
"""

import os
import base64
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.request

import anthropic

HERE = pathlib.Path(__file__).resolve().parent
VERTEX_PROJECT = os.environ["VERTEX_PROJECT"]  # your Google Cloud project, for Argon on Vertex
REPOSITORY = HERE.parents[1]
SCREENSHOT, LISTING_FILE, PREVIOUS_FILE, OUT = (pathlib.Path(argument) for argument in sys.argv[1:5])
OUT.mkdir(parents=True, exist_ok=True)
RUNS = 2

prompt_source = (REPOSITORY / "leanring-buddy/TutorProgramPrompt.swift").read_text()
system_block = prompt_source[prompt_source.index('static let system = """') + len('static let system = """'):]
system_block = system_block[:system_block.index('    """')]
SYSTEM = "\n".join(line[4:] if line.startswith("    ") else line for line in system_block.strip("\n").split("\n"))


def swift_case(kind: str) -> str:
    return {"quick": "quick", "normal": "normal", "reexplain": "reexplain", "tradeoff": "tradeOff"}[kind]


LENGTH = {kind: re.search(rf'case \.{swift_case(kind)}:\s*return "([^"]*)"', prompt_source).group(1)
          for kind in ["quick", "normal", "reexplain", "tradeoff"]}
TOKENS = {kind: int(re.search(rf'case \.{swift_case(kind)}: return ([\d_]+)', prompt_source).group(1).replace("_", ""))
          for kind in ["quick", "normal", "reexplain", "tradeoff"]}

listing_lines = LISTING_FILE.read_text().strip().split("\n")
width, height = map(int, listing_lines[-1].split()[1:3])
LISTING = "\n".join(listing_lines[:-1])
IMAGE = base64.standard_b64encode(SCREENSHOT.read_bytes()).decode()

PREVIOUS_QUESTION = "walk me through why this code crashes on the last bucket, step by step, I'm a beginner"
PREVIOUS_LESSON = PREVIOUS_FILE.read_text()
# The app's first push-back strategy, worded as CompanionManager words it.
PUSH_BACK = (
    "THE STUDENT STILL DOES NOT FOLLOW. this is attempt 2.\n"
    f'your previous attempt was: "{PREVIOUS_LESSON[:350]}"\n'
    "that did not work. do not restate it and do not paraphrase it.\n"
    "change the approach completely: take one small concrete example with real numbers "
    "and walk it through a step at a time. no definitions."
)

QUESTIONS = [
    ("quick", "else", "what does the else on line eleven do"),
    ("quick", "hitrate", "whats the cache hit rate here"),
    ("quick", "base62", "what does base 62 mean"),
    ("normal", "misses", "why does the database only see the cache misses"),
    ("normal", "balancer", "how does the load balancer decide which app server gets the request"),
    ("normal", "mid", "why is mid computed as low plus high over two"),
    ("tradeoff", "writes", "should the write path also go through redis or straight to postgres"),
    ("tradeoff", "scan", "is binary search even worth it here versus just scanning the buckets"),
    ("tradeoff", "scale", "would it be better to shard postgres or add read replicas for fifty k qps"),
    ("reexplain", "still", "i still don't get why it crashes"),
    ("reexplain", "simpler", "that went over my head can you try a simpler way"),
    ("reexplain", "onepast", "wait what do you mean by one past the end"),
]


def turn_note(kind: str, question: str) -> str:
    lines = [
        "[This turn] 15:51, Tuesday 3 Nov 2026. Front app: Brave Browser.",
        f"CANVAS: W = {width}, H = {height} pixels.",
        "SCREEN TEXT (id [x, y, w, h] text):",
        LISTING, "",
        f"HOW MUCH TO SAY: {LENGTH[kind]}",
    ]
    if kind == "reexplain":
        lines.append(PUSH_BACK)
    lines += ["", f'THE STUDENT SAID: "{question}"']
    return "\n".join(lines)


PRICES = {"claude-opus-5-5": (4, 20), "claude-sonnet-5-5": (2, 10), "gemini-4-argon": (2.5, 15)}

key = subprocess.run(["security", "find-generic-password", "-a", "api-key", "-s",
                      "com.maverickrajeev.clicky-local.anthropic", "-w"], capture_output=True, text=True).stdout.strip()
claude = anthropic.Anthropic(api_key=key)
vertex_token = subprocess.run(["gcloud", "auth", "application-default", "print-access-token"],
                              capture_output=True, text=True).stdout.strip()


def claude_answer(model, thinking, effort, headroom):
    def run(kind, question):
        usage = {}

        def chunks():
            messages = []
            if kind == "reexplain":
                messages += [{"role": "user", "content": PREVIOUS_QUESTION},
                             {"role": "assistant", "content": PREVIOUS_LESSON}]
            messages.append({"role": "user", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": IMAGE}},
                {"type": "text", "text": turn_note(kind, question)}]})
            with claude.messages.stream(
                model=model, max_tokens=TOKENS[kind] + headroom, system=SYSTEM, thinking=thinking,
                extra_body={"output_config": {"effort": effort}}, messages=messages,
            ) as stream:
                yield from stream.text_stream
                final = stream.get_final_message()
                usage.update(input=final.usage.input_tokens, output=final.usage.output_tokens)
        return chunks, usage
    return run


def argon_answer(kind, question):
    usage = {}

    def chunks():
        contents = []
        if kind == "reexplain":
            contents += [{"role": "user", "parts": [{"text": PREVIOUS_QUESTION}]},
                         {"role": "model", "parts": [{"text": PREVIOUS_LESSON}]}]
        contents.append({"role": "user", "parts": [
            {"inlineData": {"mimeType": "image/png", "data": IMAGE}}, {"text": turn_note(kind, question)}]})
        body = {
            "contents": contents,
            "systemInstruction": {"parts": [{"text": SYSTEM}]},
            "generationConfig": {"maxOutputTokens": TOKENS[kind], "thinkingConfig": {"thinkingLevel": "LOW"}},
        }
        request = urllib.request.Request(
            f"https://aiplatform.googleapis.com/v1/projects/{VERTEX_PROJECT}/locations/global/"
            "publishers/google/models/gemini-4-argon:streamGenerateContent?alt=sse",
            data=json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {vertex_token}", "Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=180) as response:
            for raw in response:
                line = raw.decode().strip()
                if not line.startswith("data: "):
                    continue
                payload = json.loads(line[6:])
                meta = payload.get("usageMetadata") or {}
                if meta:
                    usage.update(input=meta.get("promptTokenCount", 0),
                                 output=meta.get("candidatesTokenCount", 0) + meta.get("thoughtsTokenCount", 0))
                for candidate in payload.get("candidates", []):
                    for part in candidate.get("content", {}).get("parts", []):
                        if not part.get("thought"):
                            yield part.get("text", "")
    return chunks, usage


# The app's own profiles: Sonnet without thinking, Opus at low effort with
# room for its thinking, Argon at LOW.
CONTENDERS = {
    "sonnet": ("claude-sonnet-5-5", claude_answer("claude-sonnet-5-5", {"type": "between_tools"}, "high", 0)),
    "opus": ("claude-opus-5-5", claude_answer("claude-opus-5-5", {"type": "adaptive"}, "low", 1500)),
    "argon": ("gemini-4-argon", argon_answer),
}


def first_say_closed(text: str) -> bool:
    return re.search(r'say\(\s*"(?:[^"\\]|\\.)*"\s*\)', text) is not None


rows = []
for run in range(1, RUNS + 1):
    for kind, name, question in QUESTIONS:
        for brain, (model, make) in CONTENDERS.items():
            chunks, usage = make(kind, question)
            start = time.monotonic()
            first_say = None
            text = ""
            try:
                for piece in chunks():
                    if not piece:
                        continue
                    text += piece
                    if first_say is None and first_say_closed(text):
                        first_say = time.monotonic() - start
                total = time.monotonic() - start
                input_price, output_price = PRICES[model]
                cost = usage.get("input", 0) * input_price / 1e6 + usage.get("output", 0) * output_price / 1e6
                row = dict(run=run, kind=kind, question=name, brain=brain, first_say=first_say, total=total,
                           output=usage.get("output", 0), cost=cost, sentences=len(re.findall(r'\bsay\(', text)))
            except Exception as error:
                row = dict(run=run, kind=kind, question=name, brain=brain, error=str(error)[:200])
            rows.append(row)
            (OUT / f"{kind}--{name}--{brain}--{run}.txt").write_text(text)
            if "error" in row:
                print(f"{run} {kind:9} {name:9} {brain:6} ERROR {row['error']}", flush=True)
            else:
                print(f"{run} {kind:9} {name:9} {brain:6} first say {row['first_say'] or 0:5.1f}s  "
                      f"total {row['total']:5.1f}s  ${row['cost']:.3f}  {row['sentences']:2} sentences", flush=True)
            (OUT / "results.json").write_text(json.dumps(rows, indent=1))
