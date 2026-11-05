# The teaching board

Tests for "teach me X from scratch": the full-screen board that a lesson is drawn on over several turns (`BoardState.swift`, `BoardLayout.swift`, `TeachingBoard.swift`, `BoardProgramTranslator.swift`, `BoardProgramPrompt.swift`, `BoardIntent.swift`, `TeachingBoardSession.swift`, `DrawingEngine/draw-board.js`).

## When the board opens: `intent_test.swift`

```bash
swiftc -O -parse-as-library -o /tmp/board_intent scripts/board/intent_test.swift leanring-buddy/BoardIntent.swift
/tmp/board_intent scripts/board/intent_phrasings.json scripts/board/blind_phrasings.json \
    scripts/board/blind_phrasings_2.json scripts/board/blind_phrasings_3.json \
    scripts/question_sorting/phrasings.json scripts/question_sorting/spoken_test.json
```

Grades `BoardIntent.opensBoard` and `BoardIntent.closesBoard` against the exact file the app compiles. Precision matters more than recall: opening the board takes the screen away from a student who was asking about it.

| Set | Written | Opens | Near misses | Precision | Recall |
|---|---|---|---|---|---|
| `intent_phrasings.json` development | with the rules | 32 | 32 | 1.000 | 1.000 |
| `intent_phrasings.json` held out | before the rules | 15 | 15 | 1.000 | 1.000 |
| `blind_phrasings.json`, first look | by a separate model from the feature description only | 40 | 40 | 1.000 | 0.725 |
| `blind_phrasings_2.json`, first look | the same way, asked for indirect phrasings | 40 | 40 | 0.955 | 0.525 |
| `blind_phrasings_3.json`, first look | the same way, after the rules were widened on sets 1 and 2 | 40 | 40 | 0.972 | 0.875 |

The "first look" rows are each set's score the first time it was run, before anything was changed because of it. Sets 1 and 2 were then used to widen the rules (whiteboard phrasings, "assume i know nothing", "day one", "blank slate" and similar); set 3's one false opening ("how do i install postgres from scratch on my mac") added "install" to the words that mean building rather than learning. With the rules as committed every set scores precision 1.000; recall is 1.000 on the development and held-out sets, and 1.000, 0.975 and 0.875 on blind sets 1, 2 and 3. The fair number for a new phrasing is set 3's first look.

Of the question sorter's 150 real study questions, from before the board existed, 3 open it, all asking for a named topic from the start ("explain caching to me from the very beginning").

Closing while the board is open: 30 of 30 (15 that close, 15 follow-ups that must not, such as "thanks, what about when a node leaves" or "is that it").

The sorter's kinds, `QuestionKindExamples.json` and `QuestionSorterPrompt.txt` are unchanged: the board is a check of its own, taken before the sorter, so the existing grading in `scripts/question_sorting/` measures exactly what it did before.

## Real sessions, drawn: `board_harness.swift`

```bash
swiftc -O -parse-as-library -o /tmp/board_harness scripts/board/board_harness.swift \
    leanring-buddy/BoardState.swift leanring-buddy/BoardLayout.swift leanring-buddy/TeachingBoard.swift \
    leanring-buddy/BoardProgramTranslator.swift leanring-buddy/BoardProgramPrompt.swift leanring-buddy/ProgramStream.swift
/tmp/board_harness build/board-runs sonnet     # or opus, or offline for a free drawing check
```

Three scripted five-turn conversations (consistent hashing, binary search, the TCP handshake) against the real model with the real board prompt and turn notes. Each answer is cut into pieces as `ProgramStream` cuts the stream, each piece's board calls are applied by `BoardProgramTranslator` and `TeachingBoard`, and the pieces run in the app's own `DrawingEngine/` page in a web view inside a window placed outside every display. Each turn is saved as a PNG, with the program, the translated program, the turn note and the board state beside it, and `summary.json` with token counts and cost. The Anthropic key is read from the Keychain by the script itself and is never printed.

Nothing is drawn on the screen and nothing captures it: the screen behind the board in the pictures is a placeholder.

`replay <run_dir>` redraws the programs of an earlier run through the current layout with no model call. The model never sees a coordinate, so a replay is exactly what the same answers would look like with the new layout.

### Results, November 2026

Sonnet 5.5 without thinking, the brain a teach question is routed to under the Claude setting (Argon under Auto; the harness reads only the Anthropic key), and Opus 5.5 at low effort for comparison:

| | Turn 1 | Turn 2 | Turn 3 | Turn 4 | Turn 5 | Mean a turn | A 5-turn session |
|---|---|---|---|---|---|---|---|
| Sonnet, output tokens (mean of 3 topics) | 1,011 | 562 | 613 | 641 | 618 | 689 | $0.056 |
| Opus, output tokens (mean of 3 topics), one run earlier, before the prompt's sentence on messages back and forth and the history change | 973 | 790 | 857 | 850 | 761 | 846 | $0.137 |

Across all 30 turns, no board call failed to parse or apply, and the engine reported no error. The model used `update`, `append`, `remove` and `highlight` on what was already drawn rather than redrawing it.

Caching: the board's system prompt (2,159 tokens) is written once and read by every later turn and topic. Shortening one old turn per turn rewrote about 2,000 tokens of cached history at every turn from the fifth; shortening in fours (`BoardProgramPrompt.keepsWholeProgram`) brought turn 5's cache write down to 600 to 700 tokens.

The turn note for a 20-element board with 7 arrows, question and length rule included, is 1,187 characters and 574 tokens.

Known weak spot, visible in the TCP pictures: a lesson of many messages between two parties grows past 20 elements by the third turn, the view has to scroll, and long arrows between far-apart boxes cross other things and leave their labels away from the middle.
