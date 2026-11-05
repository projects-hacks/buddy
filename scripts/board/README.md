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
/tmp/board_harness build/board-runs sonnet     # or opus, argon, or offline for a free drawing check
/tmp/board_harness build/board-runs replay build/board-runs/sonnet   # earlier answers, current layout, no calls
python3 -I scripts/board/overlap_check.py build/board-runs/sonnet
```

Three scripted five-turn conversations (consistent hashing, binary search, the TCP handshake) against the real model with the real board prompt and turn notes. Each answer is cut into pieces as `ProgramStream` cuts the stream, each piece's board calls are applied by `BoardProgramTranslator` and `TeachingBoard`, and the pieces run in the app's own `DrawingEngine/` page in a web view inside a window placed outside every display. Each turn is saved as a PNG, with the program, the translated program, the turn note and the board state beside it, and `summary.json` with token counts and cost. The Anthropic key is read from the Keychain by the script itself, and Argon uses gcloud's access token and the app's own `vertexProjectIdentifier` default; neither is ever printed. Nothing is drawn on the screen and nothing captures it.

`replay` redraws the programs of an earlier run through the current layout with no model call. The model never sees a coordinate, so a replay is exactly what the same answers look like with the new layout.

`overlap_check.py` reads every saved board and lists every arrow label or stub tag that touches an element, a group's title or border, another label or another tag, every two elements that touch, and every arrow drawn through a label's words or another arrow's label (on a teach-back board, through any element). It should print 0.

### Results, November 2026

The board's system prompt is 2,324 tokens; the turn note for a 20-element board with 7 arrows, question and length rule included, is 1,187 characters and 574 tokens (both counted with the API's tokenizer).

Output tokens per turn, mean of the three topics:

| Brain | Turn 1 | Turn 2 | Turn 3 | Turn 4 | Turn 5 | Mean a turn | A 5-turn session | Seconds a turn |
|---|---|---|---|---|---|---|---|---|
| Sonnet 5.5, thinking off | 895 | 471 | 644 | 519 | 544 | 614 | $0.051 | 3.6 to 8.8, median 4.8 |
| Argon (gemini-4-argon, thinking LOW, Vertex) | 808 | 379 | 571 | 471 | 377 | 521 | $0.051 | 6.9 to 59.1, median 12.6 |

Seconds are for the whole answer, not streamed; in the app the first sentence is spoken as soon as it closes.

Across every turn of both brains no board call failed to parse or apply and the engine reported no error. Both used `update`, `append`, `remove` and `highlight` on what was already drawn rather than redrawing it.

Argon, where Auto sends teach questions, drew every turn without a failed call, but slowly and unevenly: a first turn of 14 to 48 seconds and later turns up to 59, against Sonnet's 4 to 9 for the whole answer. An earlier Argon run stopped at consistent hashing's fifth turn on HTTP 429 (resource exhausted) and a second crawled through 429 waits. Its boards are looser: in binary search it drew no arrows at all and scattered the parts, where Sonnet walked a concrete search through the drawing. So board turns go to Sonnet first whenever there is an Anthropic key (`CompanionManager.answerTeachingBoardTurn`), with Argon as the fallback; under the Gemini or Claude settings the student's choice holds.

Caching on Sonnet: the system prompt is written once (2,318 tokens) and read by every later turn and topic. Shortening one old turn per turn had rewritten about 2,000 tokens of cached history at every turn from the fifth; shortening in fours (`BoardProgramPrompt.keepsWholeProgram`) keeps turn 5's write at 500 to 600 tokens.

Layout, checked by `overlap_check.py` on the Sonnet answers drawn with the final layout: 0 overlaps in 15 boards. The same answers drawn with the layout before the review had labels on group titles, across group borders and on each other (8 overlaps); the first stub version piled tags on each other around a node with many links (48), which is what led to fanning tags along each side and, when an element is boxed in, badges on its corners.
