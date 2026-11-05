"""Checks that the tutor actually follows the practice-hint and diagram-review
instructions, on two drawn screens, with Sonnet and Argon as the app calls them.

The study notes come from the Swift files themselves (print_notes.swift), and
the system prompt from TutorProgramPrompt.swift, so this grades what ships.
Each program is also run through a stub of the drawing engine in node, to
catch calls the engine does not have.

usage: python3 -I scripts/study_modes/mode_check.py <notes.json> <out_dir>
"""

import os
import base64
import json
import pathlib
import re
import subprocess
import sys
import urllib.request

from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
VERTEX_PROJECT = os.environ["VERTEX_PROJECT"]  # your Google Cloud project, for Argon on Vertex
REPOSITORY = HERE.parents[1]
NOTES = json.loads(pathlib.Path(sys.argv[1]).read_text())
OUT = pathlib.Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)

source = (REPOSITORY / "leanring-buddy/Answering/TutorProgramPrompt.swift").read_text()
block = source[source.index('static let system = """') + len('static let system = """'):]
block = block[:block.index('    """')]
SYSTEM = "\n".join(line[4:] if line.startswith("    ") else line for line in block.strip("\n").split("\n"))
NORMAL_LENGTH = re.search(r'case \.normal:\s*return "([^"]*)"', source).group(1)

font = lambda size: ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", size)


def draw_screen(kind):
    """A screen and its listing, the way ScreenIndex lists text: id [x, y, w, h] text."""
    image = Image.new("RGB", (1280, 800), "white")
    pen = ImageDraw.Draw(image)
    listing = []

    def write(x, y, text, size=20, fill="black"):
        pen.text((x, y), text, font=font(size), fill=fill)
        box = pen.textbbox((x, y), text, font=font(size))
        listing.append(f"t{len(listing) + 1} [{box[0]}, {box[1]}, {box[2] - box[0]}, {box[3] - box[1]}] {text}")

    if kind == "practice":
        write(40, 30, "1. Two Sum", 30)
        write(40, 80, "Given an array of integers nums and an integer target, return indices of the")
        write(40, 108, "two numbers such that they add up to target.")
        write(40, 160, "Example 1:", 22)
        write(40, 192, "Input: nums = [2,7,11,15], target = 9")
        write(40, 220, "Output: [0,1]")
        write(40, 280, "Constraints:", 22)
        write(40, 312, "2 <= nums.length <= 10^4")
        pen.rectangle((660, 30, 1240, 700), outline="#cccccc", width=2)
        write(680, 50, "class Solution:", 20, "#333333")
        write(700, 80, "def twoSum(self, nums, target):", 20, "#333333")
        write(720, 110, "for i in range(len(nums)):", 20, "#333333")
        write(740, 140, "for j in range(len(nums)):", 20, "#333333")
        write(760, 170, "if nums[i] + nums[j] == target:", 20, "#333333")
        write(780, 200, "return [i, j]", 20, "#333333")
        write(1100, 720, "Submit", 22)
        window = "1. Two Sum - LeetCode"
    else:
        boxes = [(80, 300, "Client"), (330, 300, "Load Balancer"), (630, 220, "App Server 1"),
                 (630, 380, "App Server 2"), (930, 300, "Postgres")]
        for x, y, label in boxes:
            pen.rounded_rectangle((x, y, x + 200, y + 80), radius=12, outline="black", width=3)
            write(x + 20, y + 28, label)
        for (x1, y1), (x2, y2) in [((280, 340), (330, 340)), ((530, 330), (630, 260)), ((530, 350), (630, 420)),
                                   ((830, 260), (930, 330)), ((830, 420), (930, 350))]:
            pen.line((x1, y1, x2, y2), fill="black", width=3)
        write(80, 60, "url shortener", 34)
        write(80, 110, "POST /shorten  GET /:code  100M urls, 10k reads per second")
        window = "Excalidraw | url shortener"
    path = OUT / f"{kind}.png"
    image.save(path)
    return base64.standard_b64encode(path.read_bytes()).decode(), "\n".join(listing), window


def turn(window, listing, note, question, length):
    return "\n".join([
        f'[This turn] 15:51, Wednesday 4 Nov 2026. Front app: Brave Browser. Window: "{window}".',
        "CANVAS: W = 1280, H = 800 pixels.", "SCREEN TEXT (id [x, y, w, h] text):", listing, "",
        note, "", f"HOW MUCH TO SAY: {length}", "", f'THE STUDENT SAID: "{question}"'])


key = subprocess.run(["security", "find-generic-password", "-a", "api-key", "-s",
                      "com.maverickrajeev.clicky-local.anthropic", "-w"], capture_output=True, text=True).stdout.strip()
vertex_token = subprocess.run(["gcloud", "auth", "application-default", "print-access-token"],
                              capture_output=True, text=True).stdout.strip()


def sonnet(image, text, tokens):
    # The app's Sonnet profile: thinking only between tools, which with no
    # tools is no thinking.
    body = {"model": "claude-sonnet-5-5", "max_tokens": tokens, "system": SYSTEM,
            "thinking": {"type": "between_tools"},
            "messages": [{"role": "user", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": image}},
                {"type": "text", "text": text}]}]}
    request = urllib.request.Request("https://api.anthropic.com/v1/messages", data=json.dumps(body).encode(), headers={
        "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    with urllib.request.urlopen(request, timeout=180) as response:
        return "".join(b.get("text", "") for b in json.loads(response.read())["content"])


def argon(image, text, tokens):
    body = {"contents": [{"role": "user", "parts": [{"inlineData": {"mimeType": "image/png", "data": image}}, {"text": text}]}],
            "systemInstruction": {"parts": [{"text": SYSTEM}]},
            "generationConfig": {"maxOutputTokens": tokens, "thinkingConfig": {"thinkingLevel": "LOW"}}}
    request = urllib.request.Request(
        f"https://aiplatform.googleapis.com/v1/projects/{VERTEX_PROJECT}/locations/global/publishers/google/models/gemini-4-argon:generateContent",
        data=json.dumps(body).encode(), headers={"Authorization": f"Bearer {vertex_token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=180) as response:
        reply = json.loads(response.read())
    return "".join(p.get("text", "") for c in reply.get("candidates", []) for p in c.get("content", {}).get("parts", [])
                   if not p.get("thought"))


ENGINE_STUB = r"""
const program = require('fs').readFileSync(process.argv[2], 'utf8').match(/```(?:js|javascript)?\n([\s\S]*?)```/);
const calls = [];
const record = name => (...args) => { calls.push(name); return {x: 100, y: 100, w: 300, h: 200}; };
const names = ['step','say','ring','underline','strike','highlight','frame','num','point','connect','label','spotlight',
  'check','cross','paper','rect','circle','line','arrow','text','write','path','sticky','button','lessonTitle','suggest','hintLevel'];
const api = Object.fromEntries(names.map(n => [n, record(n)]));
try {
  new Function('W', 'H', ...names, program ? program[1] : '')(1280, 800, ...names.map(n => api[n]));
  console.log(JSON.stringify({ok: true, calls}));
} catch (error) { console.log(JSON.stringify({ok: false, error: String(error), calls})); }
"""
(OUT / "engine_stub.js").write_text(ENGINE_STUB)


def says(program):
    return " ".join(re.findall(r'say\(\s*"((?:[^"\\]|\\.)*)"', program)).lower()


def check(name, program):
    run = json.loads(subprocess.run(["node", str(OUT / "engine_stub.js"), str(OUT / f"{name}.txt")],
                                    capture_output=True, text=True).stdout or '{"ok": false, "error": "no output"}')
    spoken = says(program)
    code_in_copy = bool(re.search(r'copy:\s*"[^"]*(def |return |for |class )', program))
    results = {"engine runs it": run["ok"]}
    if name.startswith("hint_first"):
        results["writes hintLevel(1)"] = "hintLevel(1)" in program
        results["no solution code"] = not code_in_copy and "def twosum" not in program.lower()
        results["does not name the data structure"] = not re.search(r"hash ?map|hash table|dictionary|\bdict\b|set\b", spoken)
        results["offers another hint and the approach"] = "another hint" in program.lower() and "approach" in program.lower()
    elif name.startswith("hint_code"):
        results["writes hintLevel(4)"] = "hintLevel(4)" in program
        results["offers the code to copy"] = code_in_copy
    elif name.startswith("hint_concept"):
        results["answers the concept, no ladder step"] = "hintLevel(" not in program
        results["no solution code"] = not code_in_copy
    elif name.startswith("diagram"):
        results["proposes with suggest()"] = "suggest" in run["calls"]
        results["marks their own boxes"] = any(c in run["calls"] for c in ["ring", "point", "connect", "frame", "underline"])
        results["no score or praise"] = not re.search(r"out of (ten|10)|good job|great job|score|well done|nice work", spoken)
        results["no card"] = "paper" not in run["calls"]
    return results, run


screens = {kind: draw_screen(kind) for kind in ["practice", "diagram"]}
scenarios = [
    ("hint_first", "practice", "i'm stuck on this one, how do i solve it"),
    ("hint_code", "practice", "ok just show me the code"),
    ("hint_concept", "practice", "wait what's a hash map again"),
    ("diagram", "diagram", "can you look at my design, what am i missing"),
]
passed = total = 0
for brain_name, brain in [("sonnet", sonnet), ("argon", argon)]:
    for name, screen, question in scenarios:
        image, listing, window = screens[screen]
        level = NOTES.get(name + "_level")
        length = "follow the step under THEY ARE PRACTISING, not a usual length." if level not in (None, "none") else NORMAL_LENGTH
        program = brain(image, turn(window, listing, NOTES[name], question, length), 2600)
        label = f"{name}_{brain_name}"
        (OUT / f"{label}.txt").write_text(program)
        results, run = check(label, program)
        print(f"\n{brain_name:6} {name:13} said {question!r}" + (f"  (ladder step {level})" if level else ""))
        print("       spoken:", says(program)[:220])
        for description, ok in results.items():
            print(f"       {'PASS' if ok else 'FAIL'} {description}")
            passed += ok
            total += 1
        if not run["ok"]:
            print("       engine error:", run.get("error"))
print(f"\n{passed}/{total} checks passed; programs in {OUT}")
