# Model choice: the measurements

Every model decision in Buddy, in the order it was made, with the numbers behind it. Earlier sections cover the local model that was measured and set aside; later ones cover Claude against Argon, sorting questions, and Auto routing, which is what ships. [how-it-works.md](how-it-works.md) is the shorter tour.

Measured on the target machine, not inferred from benchmarks published elsewhere.

Hardware: MacBook Pro, Apple M4, 10 cores, 16 GB unified memory, macOS 26.5.
Runtime: Ollama 0.40.14 via Homebrew, with `OLLAMA_FLASH_ATTENTION=1` and
`OLLAMA_KV_CACHE_TYPE=q8_0` already set by the Homebrew formula.

Test material: a synthetic 1280x800 screenshot of study content, matching the
resolution the app downscales captures to. It carries a five-box system design
diagram, a thirteen-line Python binary search with a genuine off-by-one bug
(`high = len(buckets)` paired with `while low <= high`), side notes and a toolbar.

## Result

| Model | Runner | Resident | Warm speed | Verdict |
|---|---|---|---|---|
| `qwen3.5:4b` | mlx | 4.5 GB | 8.5 tok/s | selected |
| `qwen3.5:9b` | mlx | 8.8 GB | 1.9 tok/s | too slow, too large |
| `qwen3-vl:8b` | llamacpp | 6.7 GB | timed out at 600s | unusable |

## Why not qwen3-vl, despite it being the obvious pick

Qwen3-VL is the dedicated vision line and its model card advertises GUI element
recognition and 2D spatial grounding, which is exactly this use case. It is still
the wrong choice here, for a reason that only shows up on this hardware: Ollama
runs it on the `llamacpp` runner, while the Qwen3.5 family gets Apple's `mlx`
runner. Both report `100% GPU`, so the distinction is invisible unless the
`RUNNER` column is read. On Apple Silicon the gap is not marginal. The warm test
never completed in ten minutes.

Check `ollama ps` before trusting any local model benchmark on this machine.

## Why not the larger Qwen3.5

Speech plays back at roughly 150 words per minute, which is about 3 tokens per
second of audio. A model must generate faster than that or speech stalls
mid-explanation waiting for text. `qwen3.5:9b` measured 1.9 tok/s on the
grounding task, below the playback floor, so the larger model is not merely
slower but structurally unable to keep a voice loop smooth.

It also leaks reasoning into its response body even with `think` disabled,
emitting phrases such as "Another possibility:" and "So I'll box the answer as".
Those would be spoken aloud.

At 8.8 GB resident it leaves too little headroom on a 16 GB machine that was
already carrying 14 GB of swap under a normal working set.

## The screen index is a correctness fix, not only a pointing mechanism

The sharpest finding. Asked to diagnose the same bug twice, `qwen3.5:4b`:

- Given the image alone, blamed `mid = (low + high) // 2` for integer overflow.
  Wrong. That is the well known Java binary search defect, and Python integers
  do not overflow. The model pattern matched a memorised answer instead of
  reading the screen.
- Given the image plus a text index produced by Apple's on-device text
  recognition, correctly identified `high = len(buckets)` and explained why it
  breaks on the final bucket.

Same model, same image, same question. Small vision models misread dense code
from pixels, and when they do they produce a confident, plausible, wrong answer,
which is the worst failure mode for study material. Supplying machine-read text
alongside the image removes that class of error.

This is why `ScreenIndex` feeds recognised text into every prompt rather than
only consulting it when a pointing tag needs resolving.

## Tag format

`qwen3.5:9b` emitted `[POINT:t23]` correctly. `qwen3.5:4b` emitted `[t23]`,
selecting the right target but not the required syntax, so the system prompt has
to state the format strictly and the parser has to tolerate the bare form.

## Reproducing

Scripts live outside the repo, under the session scratchpad: `make_study_screenshot.py`
builds the fixture, `probe_model.py <model> <vision|teaching|grounding>` runs one case.

## Index behaviour, measured against the same fixture

On-device recognition found 41 usable targets in the test screenshot, with
rectangles accurate enough to circle a single line of code.

Two defects showed up and are worth knowing about.

**Bare numbers were indexed.** The line-number gutter of a code block produced
one target per line (`t11: 10`, `t12: 11`), crowding real content out of the
prompt. Targets of three characters or fewer that are entirely digits are now
dropped. Anything with a non-digit survives, so `94%` and `O(1)` are kept.

**Code is the weakest case for recognition.** `def find_slot(buckets, target):`
came back as `det tind_slot (buckets, target):`, and `high = len(buckets)` lost
the space after the equals sign. Monospace glyphs and punctuation-dense lines
are where the recogniser struggles. The model also receives the image, so it can
cross-check, and the listing is still far better than asking it to read pixels
alone. Do not assume the listing is character-exact.

## Invented identifiers, and why resolution has a fallback

Running the real system prompt against `qwen3.5:4b` fixed the earlier format
drift: it emitted `[UNDERLINE:t25]` and `[SPOTLIGHT:...]` correctly, with no
bare ids. One failure remained. Asked to walk through the five-box diagram it
wrote "the client [POINT:t1] and the load balancer [POINT:t2]", numbering its
own list instead of copying from the listing, where those boxes were `t11` and
`t12`. Four of five marks pointed at nothing.

The prompt now states that ids are neither ordered nor one-based. That reduces
the rate but cannot be relied on at this model size, so resolution falls back to
the words around the mark: an id that fails to resolve is recovered by searching
the spoken phrase for the longest piece of indexed text it contains. Measured
against the exact sentences that failed, all four recovered correctly, and
phrases describing nothing on screen correctly matched nothing.

It also mismarked once, underlining `low = 0` while talking about
`high = len(buckets)`. Adjacent-line errors of that kind are not recoverable
from text and remain a real limitation.

## Positioned diagrams cost 16x latency and changed nothing

Built, measured, and taken back out of the prompt. The rendering code is kept
because it works; only the instruction that offers it is gone.

The board could draw columns over a base bar and nothing else, so a flow, a
fan-out or a tree had no way to be expressed. A grid-based node and edge
vocabulary was added: the model places boxes on a 12 by 7 grid and names
arrows between them, with the app computing pixels, minimum sizes and arrow
routing.

It worked. Asked to explain storage and compute separation it produced four
correctly spaced nodes and three valid edges. It also measured 63 to 75
seconds to first byte against roughly 3 for the column vocabulary.

The controlled comparison is the damning part. Same question, same budget,
same screen index, the only difference being whether the prompt offers the
grid at all:

| | first byte | words | nodes | columns |
|---|---|---|---|---|
| without grid | 2.95s | 184 | 0 | 3 |
| with grid | 49.12s | 151 | 0 | 3 |

With the grid offered the model used none of it and drew the same three
columns, 16 times slower. The 46 extra seconds went on deliberating about a
layout it then declined to use.

The lesson generalises past this feature. Pixels were refused early because a
4B invented them, which read as a limitation of small models. It is not.
Spatial layout is reasoning work, and a frontier model pays for it in latency
rather than in accuracy. Asking a model to decide *what* to draw is cheap;
asking it to decide *where* is expensive, whatever the model.

## Claude against Argon, same screen and prompt

`scripts/experiments/brain_race.py` sends every contender the app's real system prompt
(read out of `CompanionManager.swift`), the same screenshot and index, and the
app's own length budgets, twice per question. "First sentence" is when the
voice can start, since speech goes sentence by sentence.

| Brain | First sentence, short | medium | long | Over the three-mark rule |
|---|---|---|---|---|
| gemini-4-argon, thinking LOW | 9.2 to 13.1s | 3.5 to 6.2s | 4.4 to 5.3s | no |
| claude-sonnet-5-5, thinking off | 2.2 to 2.8s | 2.7 to 2.9s | 2.6 to 2.8s | yes, 5 and 6 marks on the long question |
| claude-opus-5-5, effort low | 2.7 to 3.3s | 4.2 to 5.2s | 2.6 to 2.8s | no |
| claude-haiku-5-5, thinking off | 0.8 to 1.1s | 0.9 to 1.1s | 0.8 to 1.3s | no |

All four found the bug (`high = len(buckets)`) on every run and named no id
outside the listing. The differences are elsewhere:

- Argon is slow specifically on short questions, eight to thirteen seconds of
  silence for a one-sentence answer. On longer ones it is competitive and its
  boards are good.
- Sonnet is the steadiest: under three seconds to the first sentence on every
  question. It over-marks on long answers and drew a board in one of the two
  long runs.
- Opus at low effort teaches best. It was the only one to draw a stepped
  array for the off-by-one, and it drew a board on every long run. It costs
  twice Sonnet per token and is slower to start on medium questions.
- Haiku is fastest and not usable as the tutor: it ignores the spoken-style
  rules (capitals, backticks, "Line 3") and gives a walk-through in 41 words.

Sonnet 5.5 is the default Claude brain. Argon stays selectable in the panel,
and is the one billed against the Google Cloud credits.

### Re-explanations and design judgements

Second run, `brain_race.py 2 <out> extra`, first spoken sentence:

| Brain | "i still don't get it" | "should this be a hash map instead" |
|---|---|---|
| gemini-4-argon, thinking LOW | 5.0 to 15.9s | 4.3 to 5.2s |
| claude-sonnet-5-5, thinking off | 2.0 to 2.5s | 1.8 to 2.0s |
| claude-sonnet-5-5, thinking low | 3.4 to 5.4s | 2.1s |
| claude-opus-5-5, effort low | 4.6 to 4.9s | 3.2 to 3.9s |
| claude-opus-5-5, effort medium | 6.4 to 7.3s | 4.2 to 4.8s |

Every re-explanation switched to a worked example on the board, as the
push-back instruction asks. Opus traced every step of its example exactly;
Sonnet without thinking slipped one step ("low becomes 2, then 3, then 4"
where it goes 3 then 4). On the design question all said hash map, but only
Opus and Argon noticed the function belongs on a consistent hashing ring, and
only Opus that it returns exact matches when a ring needs the next bucket up.

Routing that follows from both runs, in `ClaudeAnswerProfile`:

| Question kind | Model | Thinking |
|---|---|---|
| quick, normal | Sonnet 5.5 | off |
| teach, re-explain, trade-off | Opus 5.5 | low effort |

Medium effort is used for nothing: never better than low, always slower.

## Sorting the question

Which model answers depends on what kind of question it is, so the sorting
was graded on its own: 50 spoken phrasings, 10 per kind, all mid-conversation,
labelled by hand, none of them among the examples the sorters learn from.
`scripts/question_sorting/sort_test.py`, with `--all` for the online ones.

| Sorter | Kind right | Model right | Wrongly decided the student was lost | Median time |
|---|---|---|---|---|
| Keyword lists (the app before) | 30/50 | 35/50 | 0 | 0ms |
| macOS contextual embedding, nearest examples | 40/50 | 45/50 | 1 | 8ms |
| macOS sentence embedding, nearest examples | 36/50 | 42/50 | 1 | 2ms |
| claude-haiku-5-5, thinking off | 43/50 | 45/50 | 3 | 705ms |
| Laya (open Jev-style decision model), question only | 18/50 | 31/50 | 1 | 71ms |
| Laya, with the previous answer | 18/50 | 31/50 | 29 | 101ms |

The contextual embedding ships: as often right about the model as Haiku, on
the machine, free, ninety times faster, and less prone to the expensive
mistake, which tells the tutor its last answer failed. Laya was used
zero-shot; its own documentation says the base checkpoint is weak until
fine-tuned on the domain, and here it never once recognised a quick question.

The labels and phrasings were written by one person who also wrote the keyword
lists, so the margins are indicative. 50 phrasings is enough to separate 30
from 40, not 40 from 43.

## Teaching lessons in the drawing format

`scripts/lesson_race/lesson_race.py` gives each brain exactly what the app
sends (the system prompt read from `TutorProgramPrompt.swift`, the turn note
with the screen text and boxes, the screenshot, the teach length rule) on three
teach questions, and saves each program so it can be drawn and compared.

Time to the first spoken sentence:

| Teach question | Opus 5.5, effort low | Sonnet 5.5, thinking off | Sonnet 5.5, thinking low | Gemini 4 Argon, LOW |
|---|---|---|---|---|
| Bloom filter, from scratch | 16.2s | 1.5s | 1.6s | 7.0s |
| Why the search crashes, for a beginner | 12.0s | 2.4s | 2.1s | 3.7s |
| How a read goes through the path | 8.8s | 1.5s | 2.0s | 3.9s |
| Cost per lesson | ~$0.06 | ~$0.02 | ~$0.02 | ~$0.03, on Cloud credits |

Every lesson ran to 9 to 12 sentences with no drawing errors. Drawn and read:

- Opus and Argon wrote the best lessons. On the crash, both traced every pass
  with exact values and labelled the code ("one too far", "still true",
  "crash here"); on the Bloom filter both tied the idea back to the database on
  screen.
- Sonnet without thinking placed its card too low, so part of it fell off the
  screen, and its Bloom filter switches did not add up. Sonnet with low
  thinking headed its card "search for 9" and then traced a search for 20.
- Argon is the only one of the two strong lessons that starts speaking in a
  few seconds, and it bills the Google Cloud credits.

## Auto routing: which brain answers which question

The Brain setting's default, Auto, sends each question to Sonnet, Opus or
Argon. Routers that hold up in production share a shape: a cheap on-device
first stage, a stronger classifier only when that stage is unsure, decisions
weighed by calibrated probabilities, a fallback with deadlines, and a log that
shows when it drifts. Simple nearest-neighbour routers also lose less accuracy
than learned ones on questions unlike their training (arXiv 2505.12601,
RouterBench), which is why nothing here is trained beyond one temperature.

### Sorting, measured on questions it had never seen

The sorter's first test (above) was written by the same hand as its examples.
A blind set of 100 spoken questions, written without seeing the examples and
in the long, padded way real questions arrived
(`scripts/question_sorting/spoken_test.json`), was split in two: every choice
was made on the dev half and the test half was scored once.

| Sorter | Test half right | Wrongly decided the student was lost |
|---|---|---|
| On-device, as it shipped | 32/50 | 1 |
| On-device, plus spoken-style examples | 33/50 | 1 |
| Claude Haiku, `QuestionSorterPrompt.txt` | 46/50 | 0 |
| Shipped: on-device when over 0.95 sure, else Haiku | 46/50 | 0 |

The on-device sorter had been fitted to the phrasing of its examples: 40 of 50 on
its own test, 32 of 50 on a blind one. Its confidence is still honest (right
every time above 0.9, a quarter of the time below 0.5, calibration error
0.08), which is what makes it a usable first stage. Haiku takes 0.66s median
and 0.8 to 1.1s at the slowest tenth; it runs while the screen is captured and
read (0.7s), and is dropped if more than 0.35s late. Reproduce with
`calibrate.py` and `cascade_test.py`.

### What each brain is good at

`scripts/route_race/route_race.py` raced the three brains on twelve questions
across quick, normal, trade-off and re-explain in the drawing format, twice
each; teach comes from the lesson race above. `judge.py` graded every answer
blind: the three answers to a question side by side, shuffled, twice with
different orders, by two judges of different families (Opus and Argon).

| Kind | Sonnet, thinking off | Opus, effort low | Argon, LOW |
|---|---|---|---|
| quick | 8.6, 1.5s, $0.011 | 7.4, 1.5s, $0.025 | 9.5, 6.5s, $0.013 |
| normal | 6.8, 1.8s, $0.016 | 7.0, 1.7s, $0.034 | 8.0, 4.1s, $0.021 |
| teach | 6.2, 1.5s, $0.022 | 8.8, 12.0s, $0.059 | 8.0, 3.9s, $0.028 |
| re-explain | 5.2, 1.8s, $0.021 | 8.0, 9.0s, $0.054 | 8.6, 3.2s, $0.026 |
| trade-off | 5.1, 1.6s, $0.017 | 7.0, 5.7s, $0.042 | 6.8, 12.0s, $0.023 |

Each cell is judged quality out of 10, median seconds to the first spoken
sentence, and cost per answer. The two passes differed by 0.48 points on
average, and a difference between two brains under 0.38 is treated as a tie.
The Argon judge rated Argon 0.8 above Opus where the Opus judge rated it 0.3
above, so each judge's scores were also routed alone: quick, teach and
re-explain route the same either way. Opus padded quick answers, which is why
it scores lowest there. Argon went silent for 20, 27 and once 138 seconds on
three of its 30 raced answers.

### The decision

Each brain's value is quality minus its wait, at four seconds of silence
before the first word per point of quality, summed over the question's kind
probabilities. Within the noise of the best, the cheaper brain wins.

| Seconds per point | 1 | 2 | 3 | 4 | 6 | 8 | 12 |
|---|---|---|---|---|---|---|---|
| quick | Sonnet | Sonnet | Sonnet | **Sonnet** | Sonnet | Sonnet | Argon |
| normal | Sonnet | Sonnet | Argon | **Argon** | Argon | Argon | Argon |
| teach | Sonnet | Argon | Argon | **Argon** | Argon | Argon | Argon |
| re-explain | Argon | Argon | Argon | **Argon** | Argon | Argon | Argon |
| trade-off | Sonnet | Sonnet | Opus | **Opus** | Opus | Opus | Opus |

The rate is a product decision, not a fitted number, so the table shows that
the routing holds anywhere from 3 to 8 seconds per point. At 4: quick goes to
Sonnet, trade-offs to Opus, and everything else to Argon.

Around that: a brain that has not started talking by twice its usual time
for the kind (at least 8s) loses the question to the next one, a brain that
errors before speaking is benched for five minutes, and without an Anthropic
key Auto uses Argon alone. `scripts/route_race/route_report.py` reads the log
for how real questions were sorted and routed, the fallbacks, and which
brain's answers were followed by "I didn't follow", the cue to rerun the race.

What this does not show: twelve raced questions on one screen and one judging
rubric. The ties between Argon and Opus on teaching are inside what a few
more questions could move. The race scripts take any screenshot, and rerunning
them on a different study screen is the cheapest way to strengthen it.
