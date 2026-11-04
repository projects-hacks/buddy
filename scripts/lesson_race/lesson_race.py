"""Races the brains on the drawing-program format, on teach questions.

Every contender gets exactly what the app sends: the system prompt read out
of TutorProgramPrompt.swift, the same turn note (canvas size, screen text with
boxes, the teach length rule), the same screenshot, and the app's token room.

Measured per answer:
  first say   when the first say("...") has closed, which is when the app
              starts speaking
  total       when the program is complete
  output      tokens written (thinking included where the model thinks)
  cost        at list prices
Each program is saved, so it can be rendered and the drawings compared.

usage: python3 -I lesson_race.py <screenshot.png> <listing.txt> <out_dir>
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
SCREENSHOT, LISTING_FILE, OUT = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
OUT.mkdir(parents=True, exist_ok=True)

prompt_source = (REPOSITORY / "leanring-buddy/TutorProgramPrompt.swift").read_text()
system_block = prompt_source[prompt_source.index('static let system = """') + len('static let system = """'):]
system_block = system_block[:system_block.index('    """')]
SYSTEM = "\n".join(line[4:] if line.startswith("    ") else line for line in system_block.strip("\n").split("\n"))
TEACH_LENGTH = re.search(r'case \.teach:\s*return "([^"]*)"', prompt_source).group(1)

listing_lines = LISTING_FILE.read_text().strip().split("\n")
width, height = map(int, listing_lines[-1].split()[1:3])
LISTING = "\n".join(listing_lines[:-1])
IMAGE = base64.standard_b64encode(SCREENSHOT.read_bytes()).decode()

def turn_note(question: str) -> str:
    return "\n".join([
        "[This turn] 15:51, Tuesday 3 Nov 2026. Front app: Brave Browser.",
        f"CANVAS: W = {width}, H = {height} pixels.",
        "SCREEN TEXT (id [x, y, w, h] text):",
        LISTING, "",
        f"HOW MUCH TO SAY: {TEACH_LENGTH}", "",
        f'THE STUDENT SAID: "{question}"',
    ])

QUESTIONS = {
    "bloom": "I am trying to learn about Bloom filter but I not understanding a single word. "
             "Can you explain it better and if you want to use diagrams on the screen to explain?",
    "bug": "walk me through why this code crashes on the last bucket, step by step, I'm a beginner",
    "reads": "teach me how a read goes through this request path and why the cache matters so much",
}

PRICES = {  # input, output, cache read, per million tokens
    "claude-opus-5-5": (4, 20), "claude-sonnet-5-5": (2, 10), "gemini-4-argon": (2.5, 15),
}

def first_say_closed(text: str) -> bool:
    return re.search(r'say\(\s*"(?:[^"\\]|\\.)*"\s*\)', text) is not None

key = subprocess.run(["security", "find-generic-password", "-a", "api-key", "-s",
                      "com.maverickrajeev.clicky-local.anthropic", "-w"], capture_output=True, text=True).stdout.strip()
claude = anthropic.Anthropic(api_key=key)
vertex_token = subprocess.run(["gcloud", "auth", "application-default", "print-access-token"],
                              capture_output=True, text=True).stdout.strip()

def claude_answer(model, thinking, effort, headroom):
    def run(question):
        usage = {}
        def chunks():
            with claude.messages.stream(
                model=model, max_tokens=3600 + headroom, system=SYSTEM, thinking=thinking,
                extra_body={"output_config": {"effort": effort}},
                messages=[{"role": "user", "content": [
                    {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": IMAGE}},
                    {"type": "text", "text": turn_note(question)}]}],
            ) as stream:
                yield from stream.text_stream
                final = stream.get_final_message()
                usage.update(input=final.usage.input_tokens, output=final.usage.output_tokens)
        return chunks, usage
    return run

def argon_answer(question):
    usage = {}
    def chunks():
        body = {
            "contents": [{"role": "user", "parts": [
                {"inlineData": {"mimeType": "image/png", "data": IMAGE}}, {"text": turn_note(question)}]}],
            "systemInstruction": {"parts": [{"text": SYSTEM}]},
            "generationConfig": {"maxOutputTokens": 3600, "thinkingConfig": {"thinkingLevel": "LOW"}},
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

CONTENDERS = {
    "opus-5.5 low": ("claude-opus-5-5", claude_answer("claude-opus-5-5", {"type": "adaptive"}, "low", 1500)),
    "sonnet-5.5 no-think": ("claude-sonnet-5-5", claude_answer("claude-sonnet-5-5", {"type": "between_tools"}, "high", 0)),
    "sonnet-5.5 think low": ("claude-sonnet-5-5", claude_answer("claude-sonnet-5-5", {"type": "adaptive"}, "low", 1500)),
    "argon LOW": ("gemini-4-argon", argon_answer),
}

rows = []
for question_name, question in QUESTIONS.items():
    for contender_name, (model, make) in CONTENDERS.items():
        chunks, usage = make(question)
        start = time.monotonic(); first_text = first_say = None; text = ""
        try:
            for piece in chunks():
                if not piece:
                    continue
                now = time.monotonic() - start
                text += piece
                first_text = first_text or now
                if first_say is None and first_say_closed(text):
                    first_say = now
            total = time.monotonic() - start
            input_price, output_price = PRICES[model]
            cost = usage.get("input", 0) * input_price / 1e6 + usage.get("output", 0) * output_price / 1e6
            sentences = len(re.findall(r'\bsay\(', text))
            marks = len(re.findall(r'\b(ring|underline|strike|highlight|frame|num|point|connect|label|spotlight|check|cross|rect|circle|line|arrow|text|path|sticky)\(', text))
            row = dict(question=question_name, model=contender_name, first_say=first_say, total=total,
                       output=usage.get("output", 0), cost=cost, sentences=sentences, marks=marks)
        except Exception as error:
            row = dict(question=question_name, model=contender_name, error=str(error)[:200])
        rows.append(row)
        slug = f"{question_name}--{contender_name.replace(' ', '-').replace('.', '')}"
        (OUT / f"{slug}.txt").write_text(text)
        if "error" in row:
            print(f"{question_name:6} {contender_name:20} ERROR {row['error']}", flush=True)
        else:
            print(f"{question_name:6} {contender_name:20} first say {row['first_say'] or 0:5.1f}s  total {row['total']:5.1f}s  "
                  f"{row['output']:5} tok  ${row['cost']:.3f}  {row['sentences']:2} sentences  {row['marks']:2} marks", flush=True)

(OUT / "results.json").write_text(json.dumps(rows, indent=1))
