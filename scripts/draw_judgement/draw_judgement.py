"""Does the tutor draw only when a drawing helps?

Sixteen questions, each over a screen made from a listing (the same
`id [x, y, w, h] text` lines the app sends, drawn into a screenshot so the
model gets an image too). Half should get a card, a quarter marks only, a
quarter nothing at all. Each question is asked twice on claude-sonnet-5-5
with thinking off, as the app asks it: once with the prompt at a given git
revision (the old prompt) and once with the prompt in the working tree.

Reported per prompt: how many answers drew a card, marks only or nothing,
against what was expected, and the mean output tokens.

usage: python3 -I draw_judgement.py <old-revision> <out_dir> [old|new]
(the last argument asks one prompt only)
"""

import base64
import io
import json
import pathlib
import re
import subprocess
import sys

import anthropic
from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
REPOSITORY = HERE.parents[1]
OLD_REVISION, OUT = sys.argv[1], pathlib.Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)
PROMPT_FILE = "leanring-buddy/Answering/TutorProgramPrompt.swift"
MODEL = "claude-sonnet-5-5"
CANVAS = (1440, 900)


def prompt_parts(source: str):
    """The cached system prompt and the per-kind length rules, read out of
    TutorProgramPrompt.swift exactly as the app would send them."""
    block = source[source.index('static let system = """') + len('static let system = """'):]
    block = block[:block.index('    """')]
    system = "\n".join(line[4:] if line.startswith("    ") else line for line in block.strip("\n").split("\n"))
    lengths = {kind: re.search(rf'case \.{kind}:\s*return "([^"]*)"', source).group(1)
               for kind in ["quick", "normal", "teach", "reexplain", "tradeOff"]}
    tokens = {kind: int(re.search(rf'case \.{kind}: return ([\d_]+)', source).group(1).replace("_", ""))
              for kind in lengths}
    return system, lengths, tokens


PROMPTS = {
    "old": prompt_parts(subprocess.run(["git", "-C", str(REPOSITORY), "show", f"{OLD_REVISION}:{PROMPT_FILE}"],
                                       capture_output=True, text=True, check=True).stdout),
    "new": prompt_parts((REPOSITORY / PROMPT_FILE).read_text()),
}

# Screens: what is in front of the student. Each item is text at a box; a
# "box" item is also outlined, for diagram nodes and buttons.
SCREENS = {
    "binary_search": {
        "app": "Visual Studio Code", "window": "search.py",
        "items": [
            ("def binary_search(values, wanted):", 120, 160, 420, 26, ""),
            ("    low, high = 0, len(values)", 120, 196, 380, 26, ""),
            ("    while low < high:", 120, 232, 260, 26, ""),
            ("        middle = (low + high) // 2", 120, 268, 400, 26, ""),
            ("        if values[middle] < wanted:", 120, 304, 400, 26, ""),
            ("            low = middle + 1", 120, 340, 330, 26, ""),
            ("        else:", 120, 376, 150, 26, ""),
            ("            high = middle", 120, 412, 290, 26, ""),
            ("    return low", 120, 448, 180, 26, ""),
            ("print(binary_search([3, 7, 9, 12, 15], 9))", 120, 520, 520, 26, ""),
            ("Run", 1280, 90, 60, 30, "box"),
        ],
    },
    "architecture": {
        "app": "Brave Browser", "window": "System design: URL shortener",
        "items": [
            ("Client", 120, 400, 140, 60, "box"),
            ("Load balancer", 360, 400, 180, 60, "box"),
            ("API servers", 640, 400, 170, 60, "box"),
            ("Redis cache", 900, 280, 170, 60, "box"),
            ("Postgres", 900, 520, 170, 60, "box"),
            ("Kafka", 640, 620, 140, 60, "box"),
            ("Analytics worker", 900, 700, 220, 60, "box"),
            ("Reads: 100k/s   Writes: 1k/s", 120, 200, 400, 30, ""),
        ],
    },
    "lecture": {
        "app": "Preview", "window": "OS lecture 6.pdf",
        "items": [
            ("Lecture 6: Processes and Threads", 300, 160, 840, 50, ""),
            ("A process has its own address space", 300, 280, 620, 30, ""),
            ("Threads of one process share memory", 300, 330, 620, 30, ""),
            ("Context switch cost", 300, 380, 360, 30, ""),
            ("fork() vs pthread_create()", 300, 430, 460, 30, ""),
        ],
    },
    "graph_code": {
        "app": "Visual Studio Code", "window": "graph.py",
        "items": [
            ("from collections import deque", 120, 160, 380, 26, ""),
            ("def shortest_hops(graph, start, goal):", 120, 212, 460, 26, ""),
            ("    frontier = deque([start])", 120, 248, 360, 26, ""),
            ("    seen = {start: 0}", 120, 284, 270, 26, ""),
            ("    while frontier:", 120, 320, 240, 26, ""),
            ("        node = frontier.popleft()", 120, 356, 380, 26, ""),
            ("        for nxt in graph[node]:", 120, 392, 360, 26, ""),
            ("            if nxt not in seen:", 120, 428, 330, 26, ""),
            ("                seen[nxt] = seen[node] + 1", 120, 464, 470, 26, ""),
            ("                frontier.append(nxt)", 120, 500, 400, 26, ""),
            ("    return seen.get(goal, -1)", 120, 536, 360, 26, ""),
            ("Run", 1280, 90, 60, 30, "box"),
            ("Debug", 1200, 90, 70, 30, "box"),
        ],
    },
    "coin_change": {
        "app": "Brave Browser", "window": "322. Coin Change - LeetCode",
        "items": [
            ("322. Coin Change", 100, 140, 300, 34, ""),
            ("You are given an integer array coins and an integer amount.", 100, 200, 700, 26, ""),
            ("Return the fewest number of coins that you need to make up that amount.", 100, 236, 820, 26, ""),
            ("Example 1: coins = [1, 2, 5], amount = 11  Output: 3", 100, 300, 640, 26, ""),
            ("dp = [0] + [inf] * amount", 900, 420, 360, 26, ""),
            ("for a in range(1, amount + 1):", 900, 456, 380, 26, ""),
            ("    for c in coins:", 900, 492, 250, 26, ""),
            ("        if c <= a: dp[a] = min(dp[a], dp[a - c] + 1)", 900, 528, 520, 26, ""),
        ],
    },
    "factorial": {
        "app": "Visual Studio Code", "window": "recursion.py",
        "items": [
            ("def factorial(n):", 120, 160, 230, 26, ""),
            ("    if n == 0:", 120, 196, 180, 26, ""),
            ("        return 1", 120, 232, 200, 26, ""),
            ("    return n * factorial(n - 1)", 120, 268, 380, 26, ""),
            ("print(factorial(4))", 120, 340, 250, 26, ""),
        ],
    },
    "error": {
        "app": "Terminal", "window": "zsh",
        "items": [
            ("$ python3 app.py", 60, 120, 220, 24, ""),
            ("Traceback (most recent call last):", 60, 150, 420, 24, ""),
            ('  File "app.py", line 12, in <module>', 60, 180, 460, 24, ""),
            ("    total = price + quantity", 60, 210, 340, 24, ""),
            ('TypeError: unsupported operand type(s) for +: \'int\' and \'str\'', 60, 240, 720, 24, ""),
        ],
    },
    "keynote": {
        "app": "Keynote", "window": "Pitch.key",
        "items": [
            ("File", 80, 4, 40, 20, ""), ("Edit", 140, 4, 40, 20, ""), ("Format", 200, 4, 60, 20, ""),
            ("Play", 600, 60, 60, 30, "box"), ("Text", 700, 60, 60, 30, "box"), ("Shape", 780, 60, 70, 30, "box"),
            ("Format", 1300, 60, 80, 30, "box"),
            ("Our product", 500, 400, 440, 70, ""),
        ],
    },
    "news": {
        "app": "Safari", "window": "Local weather and news",
        "items": [
            ("Rain expected through the weekend", 200, 180, 600, 40, ""),
            ("City council approves new bike lanes", 200, 300, 600, 30, ""),
            ("Farmers market opens on Saturday", 200, 360, 560, 30, ""),
        ],
    },
    "settings_button": {
        "app": "Xcode", "window": "Buddy.xcodeproj",
        "items": [
            ("Buddy", 220, 50, 80, 22, ""),
            ("My Mac", 320, 50, 90, 22, "box"),
            ("Build Succeeded", 640, 50, 180, 22, ""),
            ("Library", 1320, 50, 70, 22, "box"),
            ("Inspectors", 1240, 50, 70, 22, "box"),
            ("import SwiftUI", 300, 200, 200, 22, ""),
            ("struct ContentView: View {", 300, 230, 300, 22, ""),
        ],
    },
    "sql": {
        "app": "DataGrip", "window": "query.sql",
        "items": [
            ("SELECT customer_id, COUNT(*) AS orders", 120, 160, 480, 26, ""),
            ("FROM orders", 120, 196, 160, 26, ""),
            ("WHERE created_at >= '2026-01-01'", 120, 232, 420, 26, ""),
            ("GROUP BY customer_id", 120, 268, 260, 26, ""),
            ("HAVING COUNT(*) > 5;", 120, 304, 260, 26, ""),
        ],
    },
}

# The answer "thanks" follows, about the same screen, so a correction of the
# earlier answer is never the reason to draw.
PRIOR_EXCHANGE = (
    "what is the seen dictionary for",
    '```js\nstep(1);\nsay("seen records each node the moment it is queued, so no node is ever queued twice.");\n'
    'ring("t4");\nlessonTitle("why breadth first search keeps seen");\n```',
)

# (name, screen, kind the sorter would give, question, expected drawing)
QUESTIONS = [
    ("teach_binary_search", "binary_search", "teach", "teach me how this binary search finds nine, step by step", "card"),
    ("trace_loop", "binary_search", "normal", "walk me through what low and high do on that example input", "card"),
    ("request_flow", "architecture", "normal", "how does a read request flow through this design", "card"),
    ("process_vs_thread", "lecture", "tradeOff", "what's the actual difference between a process and a thread", "card"),
    ("recursion_again", "factorial", "reexplain", "i still don't get how the recursion here comes back up, explain it differently", "card"),
    ("bfs_trace", "graph_code", "normal", "why does this give the shortest number of hops", "card"),
    ("queue_or_stack", "graph_code", "tradeOff", "should i use a queue or a stack here, what changes", "card"),
    ("coin_change_dp", "coin_change", "teach", "explain how the dp table fills in for this example", "card"),
    ("what_button", "settings_button", "quick", "what does the library button do", "marks"),
    ("is_this_right", "sql", "quick", "is the having line right for customers with more than five orders", "marks"),
    ("where_setting", "keynote", "quick", "how do i change the font of this title", "marks"),
    ("error_meaning", "error", "quick", "what does this error mean", "marks"),
    ("thanks", "graph_code", "quick", "thanks, that makes sense now", "nothing"),
    ("define_idempotent", "news", "quick", "what does idempotent mean", "nothing"),
    ("pronounce", "news", "quick", "how do you pronounce dijkstra", "nothing"),
    ("who_invented", "news", "quick", "who invented the transistor", "nothing"),
]


def listing_for(screen):
    return "\n".join(f"t{index + 1} [{x}, {y}, {w}, {h}] {text}"
                     for index, (text, x, y, w, h, _) in enumerate(screen["items"]))


def image_for(screen) -> str:
    image = Image.new("RGB", CANVAS, (250, 250, 250))
    draw = ImageDraw.Draw(image)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 18)
    except OSError:
        font = ImageFont.load_default()
    for text, x, y, w, h, kind in screen["items"]:
        if kind == "box":
            draw.rounded_rectangle([x, y, x + w, y + h], radius=8, outline=(80, 80, 90), width=2)
            draw.text((x + 10, y + (h - 18) / 2), text, fill=(30, 30, 30), font=font)
        else:
            draw.text((x, y + (h - 18) / 2), text, fill=(30, 30, 30), font=font)
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return base64.standard_b64encode(buffer.getvalue()).decode()


def turn_note(screen, kind, question, lengths):
    return "\n".join([
        f'[This turn] 15:51, Thursday 5 Nov 2026. Front app: {screen["app"]}. Window: "{screen["window"]}".',
        f"CANVAS: W = {CANVAS[0]}, H = {CANVAS[1]} pixels.",
        "SCREEN TEXT (id [x, y, w, h] text):",
        listing_for(screen), "",
        f"HOW MUCH TO SAY: {lengths[kind]}", "",
        f'THE STUDENT SAID: "{question}"',
    ])


SCREEN_MARKS = r"\b(ring|underline|strike|highlight|frame|num|point|connect|label|spotlight|check|cross|suggest)\("
CARD_SHAPES = r"\b(rect|circle|line|arrow|text|path|sticky)\("


def drawing_kind(program: str) -> str:
    code = "\n".join(line for line in program.split("\n") if "say(" not in line and "button(" not in line)
    if "paper(" in code or re.search(CARD_SHAPES, code):
        return "card"
    if re.search(SCREEN_MARKS, code):
        return "marks"
    return "nothing"


key = subprocess.run(["/usr/bin/security", "find-generic-password", "-a", "api-key", "-s",
                      "com.maverickrajeev.clicky-local.anthropic", "-w"], capture_output=True, text=True).stdout.strip()
client = anthropic.Anthropic(api_key=key)
images = {name: image_for(screen) for name, screen in SCREENS.items()}

rows = []
PROMPTS_TO_ASK = [sys.argv[3]] if len(sys.argv) > 3 else list(PROMPTS)
for prompt_name in PROMPTS_TO_ASK:
    system, lengths, tokens = PROMPTS[prompt_name]
    for name, screen_name, kind, question, expected in QUESTIONS:
        screen = SCREENS[screen_name]
        messages = []
        if name == "thanks":
            messages += [{"role": "user", "content": PRIOR_EXCHANGE[0]},
                         {"role": "assistant", "content": PRIOR_EXCHANGE[1]}]
        messages.append({"role": "user", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": images[screen_name]}},
            {"type": "text", "text": turn_note(screen, kind, question, lengths)}]})
        reply = client.messages.create(
            model=MODEL, max_tokens=tokens[kind],
            system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
            thinking={"type": "between_tools"}, extra_body={"output_config": {"effort": "high"}},
            messages=messages)
        program = "".join(block.text for block in reply.content if block.type == "text")
        got = drawing_kind(program)
        row = dict(prompt=prompt_name, question=name, kind=kind, expected=expected, got=got,
                   output_tokens=reply.usage.output_tokens, input_tokens=reply.usage.input_tokens,
                   cache_read=reply.usage.cache_read_input_tokens or 0,
                   cache_write=reply.usage.cache_creation_input_tokens or 0)
        rows.append(row)
        (OUT / f"{prompt_name}--{name}.js").write_text(program)
        print(f"{prompt_name:3} {name:22} expected {expected:7} got {got:7} {row['output_tokens']:5} tokens", flush=True)

(OUT / "results.json").write_text(json.dumps(rows, indent=1))

print()
for prompt_name in PROMPTS_TO_ASK:
    mine = [row for row in rows if row["prompt"] == prompt_name]
    counts = {kind: sum(1 for row in mine if row["got"] == kind) for kind in ["card", "marks", "nothing"]}
    right = sum(1 for row in mine if row["got"] == row["expected"])
    mean_tokens = sum(row["output_tokens"] for row in mine) / len(mine)
    by_expected = {kind: sum(row["output_tokens"] for row in mine if row["expected"] == kind)
                   / max(1, sum(1 for row in mine if row["expected"] == kind)) for kind in ["card", "marks", "nothing"]}
    print(f"{prompt_name}: card {counts['card']}, marks only {counts['marks']}, nothing {counts['nothing']} "
          f"(expected 8, 4, 4); {right}/16 as expected; mean output {mean_tokens:.0f} tokens "
          f"(card questions {by_expected['card']:.0f}, marks {by_expected['marks']:.0f}, nothing {by_expected['nothing']:.0f})")
    for row in mine:
        if row["got"] != row["expected"]:
            print(f"   {row['question']}: expected {row['expected']}, got {row['got']}")

price_input, price_output, price_cache_read, price_cache_write = 2, 10, 0.2, 2.5
cost = sum(row["input_tokens"] * price_input + row["output_tokens"] * price_output
           + row["cache_read"] * price_cache_read + row["cache_write"] * price_cache_write for row in rows) / 1e6
print(f"cost about ${cost:.2f}")
