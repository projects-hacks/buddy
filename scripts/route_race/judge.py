"""Grades the raced answers blind, so the routing table rests on quality as well as speed.

For each question the three brains' programs are shown together as A, B and C,
with the screenshot, the screen text and the question, and scored 1 to 10 on
what a student would care about. Grading them side by side keeps the scale
steady within a question.

Two things keep the judging honest:
  - Two judges from different families, Claude Opus and Gemini Argon, because
    a model tends to prefer its own family's writing. Each judge's lean
    towards its own brain is reported, not hidden.
  - Every question is judged twice with the letters shuffled differently,
    because judges favour positions. The disagreement between the two passes
    is the noise floor: a difference smaller than it is not a difference.

usage: python3 -I judge.py <screenshot.png> <listing.txt> <route_race_dir> <lesson_race_dir> <previous_lesson.txt>
"""

import os
import base64
VERTEX_PROJECT = os.environ["VERTEX_PROJECT"]  # your Google Cloud project, for Argon on Vertex
import json
import pathlib
import random
import re
import subprocess
import sys
import urllib.request

import anthropic

SCREENSHOT, LISTING_FILE, RACE, LESSONS, PREVIOUS_FILE = (pathlib.Path(argument) for argument in sys.argv[1:6])
IMAGE = base64.standard_b64encode(SCREENSHOT.read_bytes()).decode()
LISTING = LISTING_FILE.read_text().strip()
PREVIOUS = PREVIOUS_FILE.read_text()
BRAINS = ["sonnet", "opus", "argon"]

QUESTIONS = {
    "else": ("quick", "what does the else on line eleven do"),
    "hitrate": ("quick", "whats the cache hit rate here"),
    "base62": ("quick", "what does base 62 mean"),
    "misses": ("normal", "why does the database only see the cache misses"),
    "balancer": ("normal", "how does the load balancer decide which app server gets the request"),
    "mid": ("normal", "why is mid computed as low plus high over two"),
    "writes": ("tradeoff", "should the write path also go through redis or straight to postgres"),
    "scan": ("tradeoff", "is binary search even worth it here versus just scanning the buckets"),
    "scale": ("tradeoff", "would it be better to shard postgres or add read replicas for fifty k qps"),
    "still": ("reexplain", "i still don't get why it crashes"),
    "simpler": ("reexplain", "that went over my head can you try a simpler way"),
    "onepast": ("reexplain", "wait what do you mean by one past the end"),
    "bloom": ("teach", "I am trying to learn about Bloom filter but I not understanding a single word. "
                       "Can you explain it better and if you want to use diagrams on the screen to explain?"),
    "bug": ("teach", "walk me through why this code crashes on the last bucket, step by step, I'm a beginner"),
    "reads": ("teach", "teach me how a read goes through this request path and why the cache matters so much"),
}
LESSON_FILES = {"sonnet": "sonnet-55-no-think", "opus": "opus-55-low", "argon": "argon-LOW"}

WHAT_EACH_KIND_WANTS = {
    "quick": "a small question: the right answer in the first sentence, one or two sentences in all, the one thing marked. rambling is a fault.",
    "normal": "a how or why question: a short clear explanation, three to six sentences, marks on what is discussed.",
    "teach": "a request to be taught properly: a built-up lesson of eight to twelve sentences with a card drawn step by step.",
    "reexplain": "the previous explanation (shown) did not land: a completely new angle, concrete example with real values, not a restatement.",
    "tradeoff": "a judgement between options: the verdict first, then the deciding reason, grounded in the numbers on screen.",
}

RUBRIC = """you are grading answers from a study helper that talks and draws on the student's screen. each answer is a small javascript program: say("...") lines are spoken, the other calls draw. ring(id), underline(id) and similar mark the listed screen text by id; paper(x, y, w, h, ...) opens a card at those canvas pixels and rect, text, arrow and so on draw inside it. the canvas is the screenshot, 1280 by 800; the top 110 and bottom 90 pixels are reserved, and cards must stay inside the canvas.

score each answer from 1 to 10 on:
- correct: are the facts, the reasoning and any traced values right? one wrong step in a trace is a real fault.
- grounded: does it answer from what is on this screen, marking the right ids, rather than a generic textbook answer?
- fits: is it the right length and depth for what this student asked? (what this kind of question wants is given below)
- drawing: would the drawing help, land in the right place, stay on the canvas and avoid covering what is being explained?
- overall: how good this answer is for the student, all things considered.

be strict and use the whole scale. reply with JSON only, no prose:
{"A": {"correct": n, "grounded": n, "fits": n, "drawing": n, "overall": n}, "B": {...}, "C": {...}}"""


def program(name: str, kind: str, brain: str) -> str:
    if kind == "teach":
        return (LESSONS / f"{name}--{LESSON_FILES[brain]}.txt").read_text()
    return (RACE / f"{kind}--{name}--{brain}--1.txt").read_text()


def prompt_for(name: str, order: list[str]) -> str:
    kind, question = QUESTIONS[name]
    parts = [RUBRIC, "", f"WHAT THIS KIND OF QUESTION WANTS: {WHAT_EACH_KIND_WANTS[kind]}", "",
             "SCREEN TEXT (id [x, y, w, h] text):", LISTING, ""]
    if kind == "reexplain":
        parts += ["THE PREVIOUS EXPLANATION, WHICH DID NOT LAND:", PREVIOUS, ""]
    parts.append(f'THE STUDENT SAID: "{question}"')
    for letter, brain in zip("ABC", order):
        parts += ["", f"=== ANSWER {letter} ===", program(name, kind, brain)]
    return "\n".join(parts)


key = subprocess.run(["security", "find-generic-password", "-a", "api-key", "-s",
                      "com.maverickrajeev.clicky-local.anthropic", "-w"], capture_output=True, text=True).stdout.strip()
claude = anthropic.Anthropic(api_key=key)
vertex_token = subprocess.run(["gcloud", "auth", "application-default", "print-access-token"],
                              capture_output=True, text=True).stdout.strip()


def opus_judge(prompt: str) -> str:
    response = claude.messages.create(
        model="claude-opus-5-5", max_tokens=6000, thinking={"type": "adaptive"},
        extra_body={"output_config": {"effort": "medium"}},
        messages=[{"role": "user", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": IMAGE}},
            {"type": "text", "text": prompt}]}])
    return "".join(block.text for block in response.content if block.type == "text")


def argon_judge(prompt: str) -> str:
    body = {
        "contents": [{"role": "user", "parts": [
            {"inlineData": {"mimeType": "image/png", "data": IMAGE}}, {"text": prompt}]}],
        "generationConfig": {"maxOutputTokens": 6000, "thinkingConfig": {"thinkingLevel": "MEDIUM"},
                             "responseMimeType": "application/json"},
    }
    request = urllib.request.Request(
        f"https://aiplatform.googleapis.com/v1/projects/{VERTEX_PROJECT}/locations/global/"
        "publishers/google/models/gemini-4-argon:generateContent",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {vertex_token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=240) as response:
        payload = json.load(response)
    return "".join(part.get("text", "") for part in payload["candidates"][0]["content"]["parts"]
                   if not part.get("thought"))


JUDGES = {"opus": opus_judge, "argon": argon_judge}
out_file = RACE / "judgements.json"
judgements = json.loads(out_file.read_text()) if out_file.exists() else []
done = {(j["question"], j["judge"], j["pass"]) for j in judgements}

for name in QUESTIONS:
    for pass_number in (1, 2):
        # A fixed seed per question and pass, so a rerun asks the same thing.
        order = BRAINS[:]
        random.Random(f"{name}-{pass_number}").shuffle(order)
        if pass_number == 2:
            # The second pass must not repeat the first pass's positions.
            first = BRAINS[:]
            random.Random(f"{name}-1").shuffle(first)
            while order == first:
                order = order[1:] + order[:1]
        prompt = prompt_for(name, order)
        for judge_name, judge in JUDGES.items():
            if (name, judge_name, pass_number) in done:
                continue
            try:
                reply = judge(prompt)
                scores = json.loads(re.search(r"\{.*\}", reply, re.S).group(0))
                by_brain = {brain: scores[letter] for letter, brain in zip("ABC", order)}
            except Exception as error:
                print(f"{name:9} {judge_name:6} pass {pass_number} ERROR {str(error)[:160]}", flush=True)
                continue
            judgements.append({"question": name, "kind": QUESTIONS[name][0], "judge": judge_name,
                               "pass": pass_number, "order": order, "scores": by_brain})
            out_file.write_text(json.dumps(judgements, indent=1))
            print(f"{name:9} {judge_name:6} pass {pass_number} " +
                  "  ".join(f"{brain} {by_brain[brain]['overall']}" for brain in BRAINS), flush=True)
