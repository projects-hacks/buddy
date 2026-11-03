# Local model choice

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
