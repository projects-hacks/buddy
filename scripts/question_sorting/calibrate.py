"""Chooses how the sorter decides, without fitting it to its own test.

Three sets, used for three different things:
  examples          QuestionKindExamples.json, its "examples" and, when a variant
                    asks, its "spoken_examples": the only thing the sorter learns from.
  dev               half of spoken_test.json, a blind set written by someone who
                    never saw the examples. Every choice below is made on it.
  test              the other half, scored once at the end and never used to
                    choose. phrasings.json's 50 are reported too, as a second
                    check that a change did not trade one style for another.

Also fits the temperature that turns similarity scores into probabilities, by
leave-one-out over the examples alone, and reports how well calibrated those
probabilities are on the test half: the router weighs models by them, so a
sorter that is 90% sure must be right about 90% of the time.

usage: python3 -I calibrate.py
"""

import json
import pathlib
import subprocess
from collections import Counter, defaultdict

import numpy

HERE = pathlib.Path(__file__).resolve().parent
KINDS = ["quick", "normal", "teach", "reexplain", "tradeoff"]
example_file = json.loads((HERE.parents[1] / "leanring-buddy/QuestionKindExamples.json").read_text())
base_examples = example_file["examples"]
candidates = example_file["spoken_examples"]
old_test = [(q, k, True) for q, k in json.loads((HERE / "phrasings.json").read_text())["test"]]
spoken = json.loads((HERE / "spoken_test.json").read_text())["items"]

# Stratified halves: alternate items within each kind.
dev, test = [], []
seen = Counter()
for item in spoken:
    target = dev if seen[item["kind"]] % 2 == 0 else test
    seen[item["kind"]] += 1
    target.append((item["question"], item["kind"], item["after_answer"]))


def pieces(sentence: str) -> list[str]:
    """Clauses of a long question, split where speech recognition put a stop."""
    parts = [p.strip() for p in sentence.replace("?", ".").replace("!", ".").split(".") if len(p.split()) >= 3]
    return parts if len(parts) > 1 else []


all_sentences = set()
for kind_examples in (base_examples, candidates):
    for phrases in kind_examples.values():
        all_sentences.update(phrases)
for question, _, _ in old_test + dev + test:
    all_sentences.add(question)
    all_sentences.update(pieces(question))
sentence_list = sorted(all_sentences)
embedded = json.loads(subprocess.run(
    ["swift", str(HERE / "embed.swift")], input=json.dumps([s.lower() for s in sentence_list]),
    capture_output=True, text=True, check=True).stdout)["contextual"]["vectors"]
vectors = numpy.array(embedded, dtype=float)
vectors /= numpy.linalg.norm(vectors, axis=1, keepdims=True) + 1e-9
vector_of = dict(zip(sentence_list, vectors))


def example_matrix(use_candidates: bool):
    pairs = [(p, k) for k, ps in base_examples.items() for p in ps]
    if use_candidates:
        pairs += [(p, k) for k, ps in candidates.items() for p in ps]
    return numpy.array([vector_of[p] for p, _ in pairs]), [k for _, k in pairs], [p for p, _ in pairs]


def kind_scores(vector, matrix, kinds, k_nearest=3, exclude=None):
    similarities = matrix @ vector
    per_kind = defaultdict(list)
    for index, (similarity, kind) in enumerate(zip(similarities, kinds)):
        if index != exclude:
            per_kind[kind].append(similarity)
    return numpy.array([numpy.mean(sorted(per_kind[k])[-k_nearest:]) for k in KINDS])


def probabilities(scores, temperature):
    z = (scores - scores.max()) / temperature
    e = numpy.exp(z)
    return e / e.sum()


def variant_scores(question, matrix, kinds, split_long):
    scores = kind_scores(vector_of[question], matrix, kinds)
    if split_long:
        for piece in pieces(question):
            # A long question is as much each of its clauses as it is the
            # whole: "I'm prepping for interviews. I didn't get this. Explain
            # it and draw" is decided by its strongest clause.
            scores = numpy.maximum(scores, kind_scores(vector_of[piece], matrix, kinds))
    return scores


def adjust(probability, after_answer, lost_first_turn_means_teach):
    """Push-back needs something to push back on."""
    if after_answer:
        return probability
    probability = probability.copy()
    moved = probability[KINDS.index("reexplain")]
    probability[KINDS.index("reexplain")] = 0
    probability[KINDS.index("teach" if lost_first_turn_means_teach else "normal")] += moved
    return probability


def fit_temperature(matrix, kinds):
    """Leave-one-out over the examples: each example sorted by the others."""
    loo = [kind_scores(matrix[i], matrix, kinds, exclude=i) for i in range(len(kinds))]
    best = None
    for temperature in numpy.geomspace(0.002, 0.2, 60):
        loss = -numpy.mean([numpy.log(probabilities(s, temperature)[KINDS.index(k)] + 1e-12)
                            for s, k in zip(loo, kinds)])
        if best is None or loss < best[1]:
            best = (temperature, loss)
    accuracy = numpy.mean([KINDS[int(numpy.argmax(s))] == k for s, k in zip(loo, kinds)])
    return best[0], accuracy


def evaluate(items, variant, temperature, matrix, kinds):
    right = 0
    false_reexplain = 0
    confusion = Counter()
    log_loss = 0
    confidences = []
    for question, expected, after_answer in items:
        probability = adjust(probabilities(variant_scores(question, matrix, kinds, variant["split"]), temperature),
                             after_answer, variant["lost_means_teach"])
        got = KINDS[int(numpy.argmax(probability))]
        right += got == expected
        false_reexplain += got == "reexplain" and expected != "reexplain"
        if got != expected:
            confusion[(expected, got)] += 1
        log_loss -= numpy.log(probability[KINDS.index(expected)] + 1e-12)
        confidences.append((probability.max(), got == expected))
    return dict(right=right, n=len(items), false_reexplain=false_reexplain,
                log_loss=log_loss / len(items), confusion=confusion, confidences=confidences)


def calibration_error(confidences, bins=5):
    """Expected calibration error: how far stated confidence is from accuracy."""
    total = 0
    edges = numpy.linspace(0, 1, bins + 1)
    for low, high in zip(edges[:-1], edges[1:]):
        bucket = [(c, ok) for c, ok in confidences if low < c <= high]
        if bucket:
            total += len(bucket) * abs(numpy.mean([c for c, _ in bucket]) - numpy.mean([ok for _, ok in bucket]))
    return total / len(confidences)


VARIANTS = {
    "before: short examples only": dict(candidates=False, split=False, lost_means_teach=False),
    "+ lost first turn is teach": dict(candidates=False, split=False, lost_means_teach=True),
    "+ long questions by clause": dict(candidates=False, split=True, lost_means_teach=True),
    "+ spoken-style examples": dict(candidates=True, split=False, lost_means_teach=True),
    "+ both": dict(candidates=True, split=True, lost_means_teach=True),
}

print(f"{'variant':30} {'temp':>6} {'loo':>5} {'dev':>7} {'dev loss':>8} {'old 50':>7} {'false re':>8}")
results = {}
for name, variant in VARIANTS.items():
    matrix, kinds, _ = example_matrix(variant["candidates"])
    temperature, loo_accuracy = fit_temperature(matrix, kinds)
    on_dev = evaluate(dev, variant, temperature, matrix, kinds)
    on_old = evaluate(old_test, variant, temperature, matrix, kinds)
    results[name] = (variant, temperature, matrix, kinds, on_dev)
    print(f"{name:30} {temperature:6.3f} {loo_accuracy:5.2f} {on_dev['right']:>3}/{on_dev['n']} "
          f"{on_dev['log_loss']:8.2f} {on_old['right']:>4}/50 {on_dev['false_reexplain'] + on_old['false_reexplain']:>8}")

# Chosen on dev only: most right, then lowest log loss.
chosen = max(results, key=lambda n: (results[n][4]["right"], -results[n][4]["log_loss"]))
variant, temperature, matrix, kinds, _ = results[chosen]
final = evaluate(test, variant, temperature, matrix, kinds)
shipped = evaluate(test, VARIANTS["before: short examples only"], results["before: short examples only"][1], *results["before: short examples only"][2:4])
print(f"\nchosen on dev: {chosen}")
print(f"test half, scored once: {final['right']}/{final['n']} (before: {shipped['right']}/{shipped['n']}), "
      f"log loss {final['log_loss']:.2f}, calibration error {calibration_error(final['confidences']):.3f}, "
      f"false re-explains {final['false_reexplain']}")
print("most common test mistakes:", final["confusion"].most_common(6))

# Confidence bands on the test half: how often the top kind was right when the
# sorter said it was this sure. The router's caution rests on this table.
print("\nconfidence  items  right")
for low, high in [(0, 0.5), (0.5, 0.7), (0.7, 0.9), (0.9, 1.01)]:
    bucket = [ok for c, ok in final["confidences"] if low <= c < high]
    if bucket:
        print(f"{low:.1f}-{min(high, 1):.1f}    {len(bucket):5}  {numpy.mean(bucket):5.2f}")

(HERE / "calibration.json").write_text(json.dumps({
    "chosen": chosen, "variant": variant, "temperature": temperature,
    "test_right": final["right"], "test_n": final["n"]}, indent=1))
