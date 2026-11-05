"""Grades the relations Claude Haiku names for the map, on relation_fixture.json.

Two calls are graded, each with the prompt that ships:
- filing (leanring-buddy/LessonConceptPrompt.txt), the call made after every
  answer: for each lesson, is its new idea linked to the known idea it
  belongs with, with a sensible kind, and nothing else?
- the one-time pass for older stores (leanring-buddy/ConceptRelationsPrompt.txt):
  given only names and summaries, does it find the links between them?

Both are also checked for ids Haiku made up and kinds off the list. The app
drops those (ConceptRelationReading), and the count here says how often it
has to. Each case runs RUNS times, since replies vary.

The key is read from the Keychain on stdin and never printed:
  security find-generic-password -a api-key -s com.maverickrajeev.clicky-local.anthropic -w \
    | python3 -I scripts/knowledge_map/relation_check.py
"""

import concurrent.futures
import hashlib
import json
import pathlib
import sys
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
SOURCES = HERE.parents[1] / "leanring-buddy"
FILING_PROMPT = (SOURCES / "LessonConceptPrompt.txt").read_text()
PASS_PROMPT = (SOURCES / "ConceptRelationsPrompt.txt").read_text()
KINDS = {"uses", "part of", "alternative to", "prerequisite of", "contrasts with"}
RUNS = 3
KEY = sys.stdin.read().strip()
fixture = json.loads((HERE / "relation_fixture.json").read_text())

# Short ids the way the app makes them: the first eight hex characters of a
# random id, which look nothing alike. Sequential ones ("0003a009",
# "0004a00a") get confused with each other, which real ids never are.
known = fixture["known"]
short_id = {concept["key"]: hashlib.sha256(concept["key"].encode()).hexdigest()[:8] for concept in known}
key_for_short_id = {value: key for key, value in short_id.items()}
usage_totals = {"input_tokens": 0, "output_tokens": 0}


def haiku(system, message, maximum_tokens):
    body = {"model": "claude-haiku-5-5", "max_tokens": maximum_tokens, "system": system,
            "thinking": {"type": "disabled"}, "messages": [{"role": "user", "content": message}]}
    request = urllib.request.Request(
        "https://api.anthropic.com/v1/messages", data=json.dumps(body).encode(),
        headers={"x-api-key": KEY, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        reply = json.loads(response.read())
    for name in usage_totals:
        usage_totals[name] += reply.get("usage", {}).get(name, 0)
    text = "".join(block.get("text", "") for block in reply["content"])
    return json.loads(text[text.index("{"):text.rindex("}") + 1])


def file_lesson(lesson):
    """The message LearningMemoryCalls.extractLessonConcepts sends."""
    known_lines = "\n".join(f"{short_id[c['key']]}: {c['name']}" for c in known)
    message = (f"KNOWN:\n{known_lines}\n\nTHE STUDENT ASKED: {lesson['question']}\n"
               f"LESSON TITLE: {lesson['title']}\nTHE EXPLANATION: {lesson['explanation']}")
    return haiku(FILING_PROMPT, message, 1600)


def run_pass():
    """The message RelationPassBatch.message() sends: one batch of all of them."""
    lines = "\n".join(f"{short_id[c['key']]}: {c['name']}: {c['summary']}" for c in known)
    return haiku(PASS_PROMPT, f"IDEAS:\n{lines}\n\nOTHER KNOWN:\n(none)", 1500)


filing_jobs = [(index, lesson) for index, lesson in enumerate(fixture["lessons"]) for _ in range(RUNS)]
with concurrent.futures.ThreadPoolExecutor(6) as pool:
    filing_replies = list(pool.map(lambda job: file_lesson(job[1]), filing_jobs))
    pass_replies = list(pool.map(lambda _: run_pass(), range(RUNS)))

print("FILING (the call after every answer)")
expected_total = found = kind_ok = unexpected = invented = off_list = same_as_right = same_as_cases = 0
for (index, lesson), reply in zip(filing_jobs, filing_replies):
    concepts = reply.get("concepts", [])
    links = []
    for concept in concepts:
        for link in concept.get("related") or []:
            target = key_for_short_id.get(str(link.get("id", "")).lower())
            kind = str(link.get("how", "")).lower().strip()
            if target is None:
                invented += 1
                print(f"  id not in KNOWN in {lesson['title']}: {link}")
                continue
            if kind not in KINDS:
                off_list += 1
                continue
            links.append((target, kind))
    if "same_as" in lesson:
        same_as_cases += 1
        same_as_right += any(key_for_short_id.get(str(c.get("same_as") or "").lower()) == lesson["same_as"] for c in concepts)
    allowed = {key for group in lesson["expected"] for key in group} | set(lesson.get("also_fine", [])) | {lesson.get("same_as")}
    for group in lesson["expected"]:
        expected_total += 1
        hits = [kind for target, kind in links if target in group]
        found += bool(hits)
        if not hits:
            print(f"  missed in {lesson['title']}: named {[c.get('name') for c in concepts]}, linked {links}")
        kind_ok += any(kind in lesson["acceptable_kinds"] for kind in hits)
    wrong = [(target, kind) for target, kind in links if target not in allowed]
    unexpected += len(wrong)
    if wrong:
        print(f"  unexpected in {lesson['title']}: {wrong}")
print(f"  expected links found {found}/{expected_total}, with a sensible kind {kind_ok}/{expected_total}")
print(f"  links to ideas the lesson had nothing to do with: {unexpected} over {len(filing_jobs)} filings")
print(f"  same idea under another name kept as same_as: {same_as_right}/{same_as_cases}")
print(f"  ids not in KNOWN: {invented}; kinds off the list: {off_list} (both dropped by the app)")

print("\nONE-TIME PASS (names and summaries only)")
pairs_found = pairs_kind_ok = pass_unexpected = pass_invented = pass_off_list = 0
expected_pairs = {frozenset(entry["pair"]): entry["ways"] for entry in fixture["pass_expected"]}
also_fine = {frozenset(pair) for pair in fixture["pass_also_fine"]}
for reply in pass_replies:
    seen = {}
    for link in reply.get("links", []):
        source = key_for_short_id.get(str(link.get("from", "")).lower())
        target = key_for_short_id.get(str(link.get("to", "")).lower())
        kind = str(link.get("how", "")).lower().strip()
        if source is None or target is None:
            pass_invented += 1
            continue
        if kind not in KINDS:
            pass_off_list += 1
            continue
        seen.setdefault(frozenset([source, target]), []).append([source, kind])
    for pair, ways in expected_pairs.items():
        if pair in seen:
            pairs_found += 1
            pairs_kind_ok += any(way in ways for way in seen[pair])
    stray = [sorted(pair) for pair in seen if pair not in expected_pairs and pair not in also_fine]
    pass_unexpected += len(stray)
    if stray:
        print(f"  unexpected links: {stray}")
total_pairs = len(expected_pairs) * RUNS
print(f"  expected links found {pairs_found}/{total_pairs}, with a sensible kind {pairs_kind_ok}/{total_pairs}")
print(f"  links between unrelated ideas: {pass_unexpected} over {RUNS} runs")
print(f"  ids not shown: {pass_invented}; kinds off the list: {pass_off_list} (both dropped by the app)")

cost = (usage_totals["input_tokens"] * 1 + usage_totals["output_tokens"] * 5) / 1e6
print(f"\n{usage_totals['input_tokens']} input and {usage_totals['output_tokens']} output tokens, about ${cost:.3f} at Haiku list price")
