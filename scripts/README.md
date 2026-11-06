# Scripts

Every command runs from the repository root. A folder with its own README has the full commands and the measured results.

## Building and testing

| Path | For | How to run |
|---|---|---|
| `build-local.sh` | Building, signing, installing and relaunching Buddy for daily use | `zsh scripts/build-local.sh` |
| `make-release.sh` | The downloadable disk image and the Homebrew cask's version ([docs/releasing.md](../docs/releasing.md)) | `zsh scripts/make-release.sh 2.0` |
| `test.sh` | The unit tests (`leanring-buddyTests`), in their own build that never touches `/Applications/Buddy.app` | `zsh scripts/test.sh` |
| `qa/` | End-to-end runs of the real app through the debug-only QA channel, and the fresh-install test | `zsh scripts/qa/ask.sh <name> "<question>"`, see its README |

## Checks and measurements

| Path | What it checks | How to run |
|---|---|---|
| `board/` | The teaching board: when it opens and closes, real five-turn sessions on Sonnet and Argon drawn to PNGs, tokens, times and cost, and overlaps on every saved board | `intent_test.swift` offline; `board_harness.swift` with a brain or `offline`; `overlap_check.py`. See its README |
| `teach_back/` | Teach it back: when it starts, when an explanation ends, whether the board draws only what was said and finds the planted gaps, and where its marks land | `intent_test.swift` offline; `faithfulness.swift` on Sonnet or `replay`; `mark_placement.py`. See its README |
| `talk_over/` | Reading what is heard while an answer plays: echoes of Buddy's voice, cut-ins, hold on, go on, slower, go back, say that again, a video in the room | `zsh scripts/talk_over/run.sh`, offline |
| `lecture_mode/` | Lecture mode offline: time reading, transcript finding, exclusions, the minute before a time on real lecture captions, the rolling buffer, and YouTube's caption tracks for real videos | `zsh scripts/lecture_mode/run_check.sh [captions.vtt]`; `LECTURE_CHECK_OFFLINE=1` skips YouTube |
| `error_offer/` | Offering to explain an error only for real errors, never for near misses, where the ring lands, and what watching costs | `error_offer_test.swift` with `grade`, `fresh`, `vision` or `show`, offline. See its README |
| `notebook/` | A sample notebook and its PDFs rendered offline from fixture lessons, with checks on cleaning, parsing, paper size and deleting | `main.swift` built with the Notebook sources. See its README |
| `knowledge_map/` | The map of what you know: layout timing, repeatability and overlaps at 5, 40 and 300 ideas with pictures, and the relations Haiku names | `make_fixture.py`, `map_check.swift` offline; `relation_check.py` with the Anthropic key on stdin. See its README |
| `draw_judgement/` | Whether answers draw a card, marks or nothing only when that helps, old prompt against new | `python3 -I scripts/draw_judgement/draw_judgement.py <revision> <out>` |
| `learning_memory/` | Memory's blind recall test, timing at 5,000 ideas, Haiku's choice from the shortlist, an end-to-end test of the real store, and whether a lesson is filed under a known idea only when it is that idea (a live store's misfiled lesson replayed, recorded filing replies graded) | `recall_eval.swift`, then `rerank_eval.py`; `memory_flow_test.swift`; `filing_check.swift grade` offline, `record` with the key. Commands in each file's header |
| `howto/` | Finding saved how-tos again from new wordings, and never for near misses | `make_cues.py`, then the `eval/` scorer. See its README |
| `question_sorting/` | The question sorter's calibration, its blind spoken test, and Haiku's sorting prompt on the blind set and an everyday set of non-study messages | `calibrate.py`, then `cascade_test.py`; `sort_test.py` for the sorter comparison; `haiku_prompt_test.py [prompt]` for the prompt (about 2 cents a run) |
| `study_modes/` | Hint ladder and diagram review, checked on Sonnet and Argon | `print_notes.swift`, then `mode_check.py <notes.json> <out>` |
| `route_race/` | The model race, blind judging, the routing table (`leanring-buddy/Answering/RouteTable.json`), how routing does on real questions from the log, and Haiku against Sonnet on small talk | `route_race.py`, `judge.py`, `build_table.py`; `route_report.py [logs]`; `chat_race.py <screenshot> <listing> <out>` (about 60 cents) |
| `lesson_race/` | The teaching-lesson race the routing table's teach row comes from | `lesson_race.py <screenshot> <listing> <out>` |
| `experiments/` | One-off measurements quoted in docs/model-choice.md | See its README |

## Pictures and sounds

| Path | For | How to run |
|---|---|---|
| `release-art/` | The release page's light and dark banner and section icons (`make_release_art.py`), and the shared-link picture (`make_social_preview.py`) | `python3 -I scripts/release-art/make_release_art.py` |
| `dmg/` | The disk image window's background, the install steps as pictures | `python3 -I scripts/dmg/make_background.py` |
| `sounds/` | Buddy's interface sounds | `python3 -I scripts/sounds/make_sounds.py` |
| `draw_icon.py` | Buddy's app icon | `python3 scripts/draw_icon.py <out.png>` |

Scripts that call Vertex read the Google Cloud project from `VERTEX_PROJECT`; scripts that call Claude read the key from the Keychain, themselves or on stdin, never from an argument.
