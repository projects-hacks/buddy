# Teach it back

Tests for "let me explain X back to you": the student explains a topic out loud, Buddy draws what they said in purple, then marks the gaps in red on the same board (`TeachBackIntent.swift`, `TeachBackListener.swift`, `TeachBackPrompt.swift`, `TeachBackSession.swift`, the teach-back parts of `TeachingBoard.swift`, `BoardState.swift` and `DrawingEngine/draw-board.js`).

## When it starts: `intent_test.swift`

```bash
swiftc -O -parse-as-library -o /tmp/teach_back_intent scripts/teach_back/intent_test.swift \
    leanring-buddy/TeachBackIntent.swift leanring-buddy/BoardIntent.swift
/tmp/teach_back_intent scripts/teach_back/intent_phrasings.json scripts/teach_back/blind_phrasings.json \
    scripts/teach_back/blind_phrasings_2.json scripts/teach_back/blind_phrasings_3.json \
    scripts/teach_back/listening_phrases.json scripts/board/intent_phrasings.json \
    scripts/question_sorting/phrasings.json scripts/question_sorting/spoken_test.json
```

Grades `TeachBackIntent.decide` against the exact file the app compiles, with "the last lesson" standing in for the topic of a bare "teach it back". Precision is the number to hold: a wrong start opens the microphone for minutes on a student who asked a question.

| Set | Written | Starts | Near misses | First look: precision | First look: recall | Now: precision | Now: recall |
|---|---|---|---|---|---|---|---|
| `intent_phrasings.json` development | with the rules | 30 | 30 | 1.000 | 0.933 | 1.000 | 1.000 |
| `intent_phrasings.json` held out | before the rules | 15 | 15 | 1.000 | 0.933 | 1.000 | 1.000 |
| `blind_phrasings.json` | by a separate model from the feature description only, before the rules were tuned | 40 | 40 | 1.000 | 0.950 | 1.000 | 1.000 |
| `blind_phrasings_2.json` | the same way, asked for harder and indirect phrasings, after tuning on set 1 | 40 | 40 | 0.913 | 0.525 | 1.000 | 1.000 |
| `blind_phrasings_3.json` | the same way, an ordinary spread, after all tuning, for the final score | 40 | 40 | 1.000 | 0.950 | 1.000 | 0.975 |

"First look" is each set's score the first time it was run, before anything changed because of it. Sets 1 and 2 were then used to widen the rules: a bare "teach it back" at the start of a sentence, "have a go at explaining", casual forms (lemme, gonna, wanna), asking permission ("would it help if i explained", "is it okay if i explain"), roles ("i'll be the teacher"), "listen while i explain", "say it back to you" with the topic named before it, and a change of mind ("quiz me, no wait, let me explain"); and to refuse more: explaining to someone else ("to my kid", "to my study group"), "tell you about my problem", "what my professor said". The fair number for a new phrasing is set 3's first look: precision 1.000, recall 0.950. Its one miss left as it is, "quiz me by letting me explain depreciation to you", asks for a quiz and a teach-back at once.

The board's own 94 phrasings start teach-back 0 times, none of the 125 starts here opens the board, and of the question sorter's 150 real study questions none starts it.

While teach-back is open, asking for another go ("let me try that part again", "let me redo the part about virtual nodes") against board questions that must not listen ("explain that part again", "can you try that again", "fill in the gaps"): 14 of 14. The end of an explanation (`TeachBackHearing`), where "done" and "that's it" end it only as a sentence of their own: 18 of 18 (11 that end, 7 such as "and then the handshake is done" or "that's it for the ring part, now the keys" that keep listening).

## Faithfulness: `faithfulness.swift`

```bash
swiftc -O -parse-as-library -o /tmp/teach_back_faithfulness scripts/teach_back/faithfulness.swift \
    leanring-buddy/BoardState.swift leanring-buddy/BoardLayout.swift leanring-buddy/TeachingBoard.swift \
    leanring-buddy/BoardProgramTranslator.swift leanring-buddy/ProgramStream.swift leanring-buddy/TeachBackPrompt.swift
/tmp/teach_back_faithfulness build/teach-back-runs/final            # Sonnet 5.5, both calls per fixture
/tmp/teach_back_faithfulness build/teach-back-runs/final replay     # the saved answers again, no calls
```

Fourteen spoken explanations in `fixtures.json` (consistent hashing, the TCP handshake, binary search, an LRU cache, photosynthesis, DNS, merge sort, supply and demand, mark and sweep, vaccines, two-phase commit, Newton's second law, hash tables, osmosis), each with deliberate errors and omissions, the parts and relations it states, words for parts it does not state, and the gaps a good check finds; one (hash tables) is meant to be complete. Two also have a second go at one part. Each runs the app's two calls on `claude-sonnet-5-5` with the app's prompts, applies the answers with the app's board, and draws them with the app's page in a web view outside every display, as `scripts/board/board_harness.swift` does. Saved per fixture in `<out>/<fixture>/`: `listening.png` (the calm listening state), `drawing.png` (their version), `check.png` (with the gaps), `again-*.png` for a second go, `notebook-board.svg` and `.png` (the board as the Notebook keeps it, made by the app's own `notebook-snapshot.js`), the programs, notes and board states. The key is read from the Keychain by the script and never printed.

What is counted, from the board after each call: **invented**, purple elements whose words are nowhere in what was said or that name a part listed as unsaid (must be 0); **relations**, stated relations drawn as a purple arrow between the two parts (either way round); **wrong kept**, wrong claims in purple as stated, with no word of the correction in purple beside them; **gaps**, expected gaps whose words are in a red mark or the sentence said with it, and **marks**, how many gaps were marked in all (a missing part and its link count as one). The check can never change the student's drawing: `TeachingBoard` refuses update, remove, unlink, move or relabel of a purple element while it checks, gives a fresh id to a mark that reuses one of theirs, and keeps at most four marks.

### Results, November 2026, first explanations

| Fixture | Invented | Parts drawn | Relations drawn | Wrong claims as stated | Gaps found / expected | Marks |
|---|---|---|---|---|---|---|
| consistent hashing | 0 | 4/4 | 3/3 | 1/1 | 2/2 | 2 |
| TCP handshake | 0 | 6/6 | 2/2 | 1/1 | 2/2 | 2 |
| binary search | 0 | 7/7 | 2/2 | 2/2 | 3/3 | 4 |
| LRU cache | 0 | 5/5 | 2/2 | 1/1 | 2/2 | 3 |
| photosynthesis | 0 | 7/7 | 3/4 | 2/2 | 2/2 | 4 |
| DNS resolution | 0 | 5/5 | 3/3 | 1/1 | 2/2 | 3 |
| merge sort | 0 | 5/5 | 2/2 | 1/1 | 2/2 | 3 |
| supply and demand | 0 | 4/4 | 3/3 | 1/1 | 1/1 | 2 |
| mark and sweep | 0 | 4/4 | 2/2 | 1/1 | 1/1 | 1 |
| vaccines | 0 | 5/5 | 3/3 | 1/1 | 2/2 | 2 |
| two-phase commit | 0 | 6/6 | 3/3 | 1/1 | 2/2 | 3 |
| Newton's second law | 0 | 4/4 | 1/2 | 1/1 | 1/1 | 2 |
| hash tables (complete) | 0 | 7/7 | 3/3 | none | 0/0 | 3 |
| osmosis | 0 | 5/5 | 1/1 | 1/1 | 2/2 | 2 |
| **all** | **0** | **74/74** | **33/35** | **15/15** | **24/24** | **36** |

Read by hand as well: no purple element says anything the student did not, and no wrong claim was quietly corrected in purple. The two relations short: photosynthesis drew "the roots take in water" where the student said the leaves take in water from the roots, the one place the drawing reworded a relation; Newton's law was drawn as the student's sentence in a label ("force equals mass times velocity") rather than as arrows, which the count does not see. Marks run above the expected gaps (36 for 24): the extras are mostly a second correction for the same misunderstanding (binary search's two swapped directions, merge sort's "in place" and "no extra memory") or a gap a tutor could fairly raise (the hash table stores only the value, so a lookup cannot tell keys apart); the "complete" hash table explanation still drew three marks.

A second go at one part: binary search, told again with the directions right, updated only those two boxes, and the check kept the two gaps still there (sorted, log n) with no new ones; the TCP handshake, told again with SYN-ACK and a final ACK, redrew just those messages and the check marked one finer point about sequence numbers.

The first full run, before the check prompt was tightened, found the same 24 of 24 gaps with 46 marks, hash tables getting three, and drew the same 0 invented parts and 15 of 15 wrong claims as stated; its relation count read 33 of 35 only because two fixture keywords missed the LRU cache's own words ("small fast memory"), fixed in `fixtures.json` afterwards. Tightening (depth not attempted is not a gap, one misunderstanding one mark, a good explanation has none) and the four-mark cap brought marks to 36. A trial before that found the drawing call writing a second "corrected" block that both ran; the app and this script now run only the first block, and the prompt says so.

Cost: $0.115 for the final run of 14 fixtures and 2 second goes (32 calls), about $0.0065 a fixture for both calls; $0.41 for every run made while building this.
