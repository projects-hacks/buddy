"""Races Haiku against Sonnet on small talk: greetings, thanks, reactions.

Haiku answers nothing else (it gave a walk-through in 41 words), so the
question here is narrow: when the student is only talking to Buddy, does
Haiku reply as well as Sonnet, and how much sooner and cheaper.

Every contender gets what the app sends for the chat kind: the system prompt
read out of TutorProgramPrompt.swift, the turn note with chat's length rule,
a screenshot full of code (the temptation to explain it unasked), and for
half the messages a previous lesson as history, the way "thanks" arrives.

Then Claude Opus judges each pair blind, twice with the order swapped, on how
a friend sitting beside the student would have replied. Both contenders are
Claude, so one judge has no family to favour.

usage: python3 -I chat_race.py <screenshot.png> <listing.txt> <out_dir>
"""

import base64
import json
import pathlib
import re
import statistics
import subprocess
import sys
import time

import anthropic

HERE = pathlib.Path(__file__).resolve().parent
REPOSITORY = HERE.parents[1]
SCREENSHOT, LISTING_FILE, OUT = (pathlib.Path(argument) for argument in sys.argv[1:4])
OUT.mkdir(parents=True, exist_ok=True)
RUNS = 2

prompt_source = (REPOSITORY / "leanring-buddy/Answering/TutorProgramPrompt.swift").read_text()
system_block = prompt_source[prompt_source.index('static let system = """') + len('static let system = """'):]
system_block = system_block[:system_block.index('    """')]
SYSTEM = "\n".join(line[4:] if line.startswith("    ") else line for line in system_block.strip("\n").split("\n"))
LENGTH = re.search(r'case \.chat:\s*return "([^"]*)"', prompt_source).group(1)
TOKENS = int(re.search(r'case \.chat: return ([\d_]+)', prompt_source).group(1).replace("_", ""))

listing_lines = LISTING_FILE.read_text().strip().split("\n")
width, height = map(int, listing_lines[-1].split()[1:3])
LISTING = "\n".join(listing_lines[:-1])
IMAGE = base64.standard_b64encode(SCREENSHOT.read_bytes()).decode()
MEDIA = "image/png" if SCREENSHOT.suffix == ".png" else "image/jpeg"

PREVIOUS_QUESTION = "why does my two sum return the same index twice"
PREVIOUS_ANSWER = """```js
step(1);
say("your inner loop starts at zero, so it pairs an element with itself.");
ring("t9", "j == i allowed");
step(2);
say("start j at i plus one, and every pair is checked once, never with itself.");
```"""

# (name, message, after an answer)
MESSAGES = [
    ("hello", "hello buddy", False),
    ("morning", "good morning", False),
    ("howareyou", "hey buddy how are you doing", False),
    ("there", "you there?", False),
    ("tired", "ugh i'm so tired today", False),
    ("back", "sorry, i was away for a bit", False),
    ("thanks", "thanks", True),
    ("clicked", "oh that makes sense now, thank you", True),
    ("nice", "nice", True),
    ("lol", "lol okay", True),
    ("awesome", "you're awesome", True),
    ("bye", "ok that's it for today, bye", True),
]

CONTENDERS = {
    "haiku": ("claude-haiku-5-5", {"type": "disabled"}),
    "sonnet": ("claude-sonnet-5-5", {"type": "between_tools"}),
}
PRICES = {"claude-haiku-5-5": (0.10, 0.50), "claude-sonnet-5-5": (2, 10), "claude-opus-5-5": (4, 20)}

key = subprocess.run(["security", "find-generic-password", "-a", "api-key", "-s",
                      "com.maverickrajeev.clicky-local.anthropic", "-w"], capture_output=True, text=True).stdout.strip()
claude = anthropic.Anthropic(api_key=key)


# Half the turns say the student's name, as the app does once it knows it,
# and half do not, which is when a model is tempted to take one off the
# screen: this one shows "Argon" in the notch.
def student_name(message: str) -> str | None:
    return "Rajeev" if MESSAGES.index(next(m for m in MESSAGES if m[1] == message)) % 2 == 0 else None


def turn_note(message: str) -> str:
    called = f" The student is called {student_name(message)}." if student_name(message) else ""
    return "\n".join([
        f"[This turn] 16:40, Thursday 5 Nov 2026.{called} Front app: Preview.",
        f"CANVAS: W = {width}, H = {height} pixels.",
        "SCREEN TEXT (id [x, y, w, h] text):",
        LISTING, "",
        f"HOW MUCH TO SAY: {LENGTH}",
        "", f'THE STUDENT SAID: "{message}"',
    ])


def spoken(program: str) -> list[str]:
    return re.findall(r'say\(\s*"((?:[^"\\]|\\.)*)"\s*\)', program)


MARKS = re.compile(r'\b(ring|underline|strike|highlight|frame|num|point|paper|card|arrow)\(')

rows = []
saved = OUT / "results.json"
for run in range(1, RUNS + 1) if not saved.exists() else []:
    for name, message, after_answer in MESSAGES:
        for brain, (model, thinking) in CONTENDERS.items():
            messages = []
            if after_answer:
                messages += [{"role": "user", "content": PREVIOUS_QUESTION},
                             {"role": "assistant", "content": PREVIOUS_ANSWER}]
            messages.append({"role": "user", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": MEDIA, "data": IMAGE}},
                {"type": "text", "text": turn_note(message)}]})
            start = time.monotonic()
            first_say = None
            text = ""
            try:
                with claude.messages.stream(
                    model=model, max_tokens=TOKENS, system=SYSTEM, thinking=thinking,
                    extra_body={"output_config": {"effort": "high"}}, messages=messages,
                ) as stream:
                    for piece in stream.text_stream:
                        text += piece
                        if first_say is None and spoken(text):
                            first_say = time.monotonic() - start
                    final = stream.get_final_message()
                input_price, output_price = PRICES[model]
                cost = (final.usage.input_tokens * input_price + final.usage.output_tokens * output_price) / 1e6
                row = dict(run=run, name=name, brain=brain, first_say=first_say, total=time.monotonic() - start,
                           cost=cost, said=" ".join(spoken(text)), sentences=len(spoken(text)),
                           marks=len(MARKS.findall(text)))
            except Exception as error:
                row = dict(run=run, name=name, brain=brain, error=str(error)[:300])
            rows.append(row)
            (OUT / f"{name}--{brain}--{run}.txt").write_text(text)
            print(json.dumps(row), flush=True)
if saved.exists() and not rows:
    rows = json.loads(saved.read_text())
saved.write_text(json.dumps(rows, indent=1))

# Blind judging: each pair twice, order swapped.
JUDGE = """You are judging two replies from Buddy, a helper that sits beside a student, sees their screen, and talks out loud.
The student was not asking about anything; they were just talking to Buddy. The best reply is what a warm, natural friend sitting beside them would say back: short, fitting what they said and the moment (a thanks after a lesson, a greeting, a goodbye), not robotic, and not explaining or drawing on the screen unasked. Calling the student by a name that is not theirs is a serious mistake.
Score each reply 1 to 10. Reply with JSON only: {"A": n, "B": n}"""
by_key = {(r["run"], r["name"], r["brain"]): r for r in rows if "error" not in r}
scores = {"haiku": [], "sonnet": []}
for run in range(1, RUNS + 1):
    for name, message, after_answer in MESSAGES:
        haiku, sonnet = by_key.get((run, name, "haiku")), by_key.get((run, name, "sonnet"))
        if not haiku or not sonnet:
            continue
        context = f'Buddy had just explained: "{" ".join(spoken(PREVIOUS_ANSWER))}"\n' if after_answer else ""
        context += f"The student's name is {student_name(message)}.\n" if student_name(message) else "Buddy does not know the student's name.\n"
        for order in (["haiku", "sonnet"], ["sonnet", "haiku"]):
            pair = {"A": by_key[(run, name, order[0])]["said"], "B": by_key[(run, name, order[1])]["said"]}
            response = claude.messages.create(
                model="claude-opus-5-5", max_tokens=2000, system=JUDGE, thinking={"type": "adaptive"},
                extra_body={"output_config": {"effort": "low"}},
                messages=[{"role": "user", "content": f'{context}The student said: "{message}"\n\nReply A: "{pair["A"]}"\nReply B: "{pair["B"]}"'}])
            reply = "".join(block.text for block in response.content if block.type == "text")
            verdict = json.loads(re.search(r"\{.*\}", reply, re.S).group(0))
            scores[order[0]].append(verdict["A"])
            scores[order[1]].append(verdict["B"])

summary = {}
for brain in CONTENDERS:
    mine = [r for r in rows if r["brain"] == brain and "error" not in r]
    summary[brain] = dict(
        answers=len(mine), errors=sum(1 for r in rows if r["brain"] == brain and "error" in r),
        quality=round(statistics.mean(scores[brain]), 2) if scores[brain] else None,
        first_say=round(statistics.median(r["first_say"] for r in mine if r["first_say"]), 2),
        cost=round(statistics.mean(r["cost"] for r in mine), 5),
        one_sentence=sum(r["sentences"] == 1 for r in mine), with_marks=sum(r["marks"] > 0 for r in mine),
        wrong_name=sum(bool(re.search(r"\b(Argon|Ananya)\b", r["said"])) or
                       (student_name(next(m[1] for m in MESSAGES if m[0] == r["name"])) is None and "Rajeev" in r["said"])
                       for r in mine))
print(json.dumps(summary, indent=1))
(OUT / "summary.json").write_text(json.dumps(dict(summary=summary, scores=scores), indent=1))
