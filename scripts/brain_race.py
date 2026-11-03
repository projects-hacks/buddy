"""Races the tutor brains on the same screen, prompt and questions.

The question being settled is whether a Claude model would answer sooner and
draw better than gemini-4-argon, so every contender gets the app's real system
prompt, the same screenshot and index, and the app's own length budgets.

Measured per answer, because each maps to something the student feels:
  first text   silence before anything could start
  first say    when the first complete sentence exists, which is when the
               voice can actually start (speech goes sentence by sentence)
  total        when the last mark can be drawn
  marks / bad  marks written, and marks naming an id not in the listing
  board        whether it drew on the board

Keys never touch the command line: the Anthropic key is read from the
Keychain and the Vertex token from gcloud, inside this process.

usage: python3 -I scripts/brain_race.py [runs_per_question] [results.json] [basic|extra]
"""

import base64
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.request

import anthropic

REPOSITORY = pathlib.Path(__file__).resolve().parent.parent
SCREENSHOT = pathlib.Path(
    "/private/tmp/claude-501/-Users-maverickrajeev-Documents-projects/"
    "119fa531-54fe-45f1-a621-6ef52815cceb/scratchpad/study_screen.png"
)
VERTEX_PROJECT = "medi-agent-490106"
RUNS_PER_QUESTION = int(sys.argv[1]) if len(sys.argv) > 1 else 2

# Written to match study_screen.png, in the same shape ScreenIndex renders.
SCREEN_INDEX = """t17: Design a URL Shortener
t18: System Design · Lecture 4 · Scaling reads
t21: Request path
t23: Client
t24: Load Balancer
t25: App Server
t26: Redis Cache
t27: PostgreSQL
t28: cache hit: 94%
t29: cache miss only
t31: Exercise: find the bug
t33: def find_slot(buckets, target):
t34: low = 0
t35: high = len(buckets)
t36: while low <= high:
t37: mid = (low + high) // 2
t38: if buckets[mid] == target:
t39: return mid
t40: elif buckets[mid] < target:
t41: low = mid + 1
t42: else:
t43: high = mid - 1
t44: return -1
t46: Notes
t47: Write path
t48: hash(long_url) -> base62
t49: Read path
t50: cache first, then DB
t51: Bottleneck
t52: DB reads at 50k QPS
t53: Mitigation
t54: Redis, 94% hit rate
t55: Quiz: why does this crash on the last bucket?
t58: Big-O: average O(log n), worst O(log n). Space O(1).
t59: Compare against linear scan O(n) from Lecture 3."""

VALID_IDS = set(re.findall(r"^(t\d+):", SCREEN_INDEX, re.M))


def swift_multiline_after(source: str, marker: str) -> str:
    """Returns the body of the first Swift triple-quoted string after marker."""
    start = source.index(marker)
    open_quote = source.index('"""', start) + 3
    close_quote = source.index('"""', open_quote)
    lines = source[open_quote:close_quote].split("\n")[1:-1]
    indent = min(len(l) - len(l.lstrip()) for l in lines if l.strip())
    return "\n".join(l[indent:] for l in lines)


manager_source = (REPOSITORY / "leanring-buddy/CompanionManager.swift").read_text()
SYSTEM_PROMPT = swift_multiline_after(
    manager_source, "private static func tutorSystemPrompt"
).replace("\\(screenIndexListing)", SCREEN_INDEX)

budget_source = manager_source[manager_source.index("private static func answerBudget"):]
budget_shapes = re.findall(r'shapeInstruction: """\n\s*(.*?)\n\s*"""', budget_source, re.S)
budget_tokens = [int(n) for n in re.findall(r"maximumTokens: (\d+)", budget_source)][:3]
LONG, SHORT, MEDIUM = list(zip(budget_tokens, budget_shapes))

# The re-explanation turn replays a real failed attempt and the instruction the
# app adds on push-back, built the same way reexplanationInstruction() builds it.
FAILED_ATTEMPT = (
    "the crash starts here. high is set to the length, so it points one past the "
    "last real index, and with the loop condition using less than or equal, low "
    "can climb until mid lands exactly on that out of range slot."
)
REEXPLAIN_SHAPE = MEDIUM[1] + f"""


THE STUDENT STILL DOES NOT FOLLOW. this is attempt 2.
your previous attempt was: "{FAILED_ATTEMPT}"
that did not work. do not restate it and do not paraphrase it.
change the approach completely: take one small concrete example with real numbers and walk it through a step at a time. no definitions."""

# (kind, question, (max_tokens, shape), history)
QUESTION_SETS = {
    "basic": [
        ("short", "which line is wrong", SHORT, []),
        ("medium", "why does this crash on the last bucket", MEDIUM, []),
        ("long", "walk me through how a read goes through this request path", LONG, []),
    ],
    "extra": [
        ("reexplain", "i still don't get it",
         (max(MEDIUM[0], 420), REEXPLAIN_SHAPE),
         [("why does this crash on the last bucket", FAILED_ATTEMPT)]),
        ("hard", "should find slot even be a binary search here, or would a hash map "
                 "be the better call for a url shortener",
         MEDIUM, []),
    ],
}
QUESTIONS = QUESTION_SETS[sys.argv[3] if len(sys.argv) > 3 else "basic"]

image_base64 = base64.standard_b64encode(SCREENSHOT.read_bytes()).decode()


def first_sentence_done(text: str) -> bool:
    """True once a spoken sentence is complete, tags removed."""
    spoken = re.sub(r"\[[^\]]*\]", "", text)
    return re.search(r"[a-z0-9][.!?](\s|$)", spoken) is not None


def score(text: str) -> dict:
    tags = re.findall(r"\[([A-Z]+)(?::([^\]]*))?\]", text)
    mark_kinds = {"POINT", "CIRCLE", "BOX", "UNDERLINE", "HIGHLIGHT", "STRIKE",
                  "ARROW", "STEP", "LABEL", "SPOTLIGHT"}
    marks = [(kind, body) for kind, body in tags if kind in mark_kinds]
    named_ids = [i for _, body in marks for i in re.findall(r"t\d+", body or "")]
    spoken = re.sub(r"\[[^\]]*\]", "", text)
    return {
        "words": len(spoken.split()),
        "marks": len(marks),
        "bad_ids": sum(1 for i in named_ids if i not in VALID_IDS),
        "board": any(kind == "BOARD" for kind, _ in tags),
    }


def run_timed(stream_text_chunks):
    """Consumes a generator of text chunks, timing the moments that matter."""
    began = time.monotonic()
    first_text = first_say = None
    text = ""
    for chunk in stream_text_chunks:
        if not chunk:
            continue
        now = time.monotonic() - began
        text += chunk
        if first_text is None:
            first_text = now
        if first_say is None and first_sentence_done(text):
            first_say = now
    total = time.monotonic() - began
    return text, first_text, first_say or total, total


# --- Gemini on Vertex, exactly as GeminiVisionProvider sends it ---------------

vertex_token = subprocess.run(
    ["gcloud", "auth", "application-default", "print-access-token"],
    capture_output=True, text=True,
).stdout.strip()


def argon_chunks(question: str, max_tokens: int, shape: str, history):
    past_turns = []
    for asked, answered in history:
        past_turns += [{"role": "user", "parts": [{"text": asked}]},
                       {"role": "model", "parts": [{"text": answered}]}]
    body = {
        "contents": past_turns + [{"role": "user", "parts": [
            {"inlineData": {"mimeType": "image/png", "data": image_base64}},
            {"text": question},
        ]}],
        "systemInstruction": {"parts": [{"text": SYSTEM_PROMPT + "\n\n" + shape}]},
        "generationConfig": {"maxOutputTokens": max_tokens,
                             "thinkingConfig": {"thinkingLevel": "LOW"}},
    }
    request = urllib.request.Request(
        f"https://aiplatform.googleapis.com/v1/projects/{VERTEX_PROJECT}/locations/"
        f"global/publishers/google/models/gemini-4-argon:streamGenerateContent?alt=sse",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {vertex_token}",
                 "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        for raw_line in response:
            line = raw_line.decode().strip()
            if not line.startswith("data: "):
                continue
            payload = json.loads(line[6:])
            for candidate in payload.get("candidates", []):
                for part in candidate.get("content", {}).get("parts", []):
                    if not part.get("thought"):
                        yield part.get("text", "")


# --- Claude, first-party API ---------------------------------------------------

anthropic_key = subprocess.run(
    ["security", "find-generic-password", "-a", "api-key",
     "-s", "com.maverickrajeev.clicky-local.anthropic", "-w"],
    capture_output=True, text=True,
).stdout.strip()
claude = anthropic.Anthropic(api_key=anthropic_key)


def claude_chunks(model: str, thinking: dict, effort: str, thinking_headroom: int):
    def chunks(question: str, max_tokens: int, shape: str, history):
        past_turns = []
        for asked, answered in history:
            past_turns += [{"role": "user", "content": asked},
                           {"role": "assistant", "content": answered}]
        with claude.messages.stream(
            model=model,
            # Thinking counts toward max_tokens, so a thinking model gets room
            # for it on top of the spoken budget or its answer is cut short.
            max_tokens=max_tokens + thinking_headroom,
            system=SYSTEM_PROMPT + "\n\n" + shape,
            thinking=thinking,
            extra_body={"output_config": {"effort": effort}},
            messages=past_turns + [{"role": "user", "content": [
                {"type": "image", "source": {"type": "base64",
                                             "media_type": "image/png",
                                             "data": image_base64}},
                {"type": "text", "text": question},
            ]}],
        ) as stream:
            yield from stream.text_stream
            final = stream.get_final_message()
            if final.stop_reason == "refusal":
                yield " [refused]"
    return chunks


ALL_CONTENDERS = {
    "argon LOW": argon_chunks,
    "sonnet-5.5 no-think": claude_chunks("claude-sonnet-5-5", {"type": "between_tools"}, "high", 0),
    "sonnet-5.5 think low": claude_chunks("claude-sonnet-5-5", {"type": "adaptive"}, "low", 1500),
    "opus-5.5 low": claude_chunks("claude-opus-5-5", {"type": "adaptive"}, "low", 1500),
    "opus-5.5 medium": claude_chunks("claude-opus-5-5", {"type": "adaptive"}, "medium", 3000),
    "haiku-5.5 no-think": claude_chunks("claude-haiku-5-5", {"type": "disabled"}, "high", 0),
}
CONTENDER_SETS = {
    "basic": ["argon LOW", "sonnet-5.5 no-think", "opus-5.5 low", "haiku-5.5 no-think"],
    "extra": ["argon LOW", "sonnet-5.5 no-think", "sonnet-5.5 think low",
              "opus-5.5 low", "opus-5.5 medium"],
}
CONTENDERS = {name: ALL_CONTENDERS[name]
              for name in CONTENDER_SETS[sys.argv[3] if len(sys.argv) > 3 else "basic"]}

results = []
for question_kind, question, (max_tokens, shape), history in QUESTIONS:
    for run in range(RUNS_PER_QUESTION):
        for name, contender in CONTENDERS.items():
            try:
                text, first_text, first_say, total = run_timed(
                    contender(question, max_tokens, shape, history))
                row = {"model": name, "q": question_kind, "run": run,
                       "first_text": first_text, "first_say": first_say,
                       "total": total, "text": text, **score(text)}
            except Exception as error:  # a failed contender is a result too
                row = {"model": name, "q": question_kind, "run": run,
                       "error": f"{type(error).__name__}: {str(error)[:160]}"}
            results.append(row)
            if "error" in row:
                print(f"{name:20} {question_kind:6} ERROR {row['error']}", flush=True)
            else:
                print(f"{name:20} {question_kind:6} text {row['first_text'] or 0:5.2f}s  "
                      f"say {row['first_say']:5.2f}s  total {row['total']:5.2f}s  "
                      f"{row['words']:3}w {row['marks']}m {row['bad_ids']}bad "
                      f"{'board' if row['board'] else ''}", flush=True)

out = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else REPOSITORY / "scripts/brain_race_results.json"
out.write_text(json.dumps(results, indent=1))
print(f"\nanswers written to {out}")
