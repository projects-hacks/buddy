# Teach it back

Tests for "let me explain X back to you": the student explains a topic out loud, Buddy draws what they said in purple, then marks the gaps in red on the same board (`TeachBackIntent.swift`, `TeachBackListener.swift`, `TeachBackPrompt.swift`, `TeachBackSession.swift`, the teach-back parts of `TeachingBoard.swift`, `BoardState.swift` and `DrawingEngine/draw-board.js`).

## When it starts: `intent_test.swift`

```bash
swiftc -O -parse-as-library -o /tmp/teach_back_intent scripts/teach_back/intent_test.swift \
    leanring-buddy/TeachBack/TeachBackIntent.swift leanring-buddy/Drawing/Board/BoardIntent.swift
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

What the interface asks (`from_the_interface` in `intent_phrasings.json`): the notch's Teach it back chip and a Notebook page's button send "let me explain {title} back to you", the start tile and the Map's inspector "let me explain {idea} to you". All 12, with lesson titles, ideas and a teach-back page's own "You explain: X" title filled in, start teach-back on the right topic, and none opens the board.

While teach-back is open, asking for another go ("let me try that part again", "let me redo the part about virtual nodes") against board questions that must not listen ("explain that part again", "can you try that again", "fill in the gaps"): 14 of 14. The end of an explanation (`TeachBackHearing`), where "done" and "that's it" end it only as a sentence of their own: 18 of 18 (11 that end, 7 such as "and then the handshake is done" or "that's it for the ring part, now the keys" that keep listening).

## Faithfulness: `faithfulness.swift`

```bash
swiftc -O -parse-as-library -o /tmp/teach_back_faithfulness scripts/teach_back/faithfulness.swift \
    leanring-buddy/Drawing/Board/BoardState.swift leanring-buddy/Drawing/Board/BoardLayout.swift leanring-buddy/Drawing/Board/TeachingBoard.swift \
    leanring-buddy/Drawing/Board/BoardProgramTranslator.swift leanring-buddy/Drawing/ProgramStream.swift leanring-buddy/TeachBack/TeachBackPrompt.swift
/tmp/teach_back_faithfulness build/teach-back-runs/final            # Sonnet 5.5, both calls per fixture
/tmp/teach_back_faithfulness build/teach-back-runs/final replay     # the saved answers again, no calls
python3 -I scripts/board/overlap_check.py build/teach-back-runs/final  # words on words, arrows through words
python3 -I scripts/teach_back/mark_placement.py build/teach-back-runs/final
```

Fourteen spoken explanations in `fixtures.json` (consistent hashing, the TCP handshake, binary search, an LRU cache, photosynthesis, DNS, merge sort, supply and demand, mark and sweep, vaccines, two-phase commit, Newton's second law, hash tables, osmosis), each with deliberate errors and omissions, the parts and relations it states, words for parts it does not state, and the gaps a good check finds; one (hash tables) is meant to be complete. Two also have a second go at one part. Each runs the app's two calls on `claude-sonnet-5-5` with the app's prompts, applies the answers with the app's board, and draws them with the app's page in a web view outside every display, as `scripts/board/board_harness.swift` does. Saved per fixture in `<out>/<fixture>/`: `listening.png` (the calm listening state), `drawing.png` (their version), `check.png` (with the gaps), `again-*.png` for a second go, `notebook-board.svg` and `.png` (the board as the Notebook keeps it, made by the app's own `notebook-snapshot.js`), the programs, notes and board states. The key is read from the Keychain by the script and never printed.

What is counted, from the board after each call: **invented**, purple elements whose words are nowhere in what was said or that name a part listed as unsaid (must be 0); **relations**, stated relations drawn as a purple arrow between the two parts (either way round); **wrong kept**, wrong claims in purple as stated, with no word of the correction in purple beside them; **gaps**, expected gaps whose words are in a red mark or the sentence said with it, and **marks**, how many gaps were marked in all (a missing part and its link count as one). The check can never change the student's drawing: `TeachingBoard` refuses update, remove, unlink, move or relabel of a purple element while it checks, gives a fresh id to a mark that reuses one of theirs, and keeps at most four marks.

### Results, November 2026, first explanations

The final live run, after the review changes (one-beat drawing, the layout rules below, and one line added to the check prompt so a mirror-image mistake is one mark):

| Fixture | Invented | Parts drawn | Relations drawn | Wrong claims as stated | Gaps found / expected | Marks | Student words cut on the paper |
|---|---|---|---|---|---|---|---|
| consistent hashing | 0 | 4/4 | 3/3 | 1/1 | 2/2 | 2 | 1 |
| TCP handshake | 0 | 6/6 | 1/2 | 1/1 | 2/2 | 2 | 0 |
| binary search | 0 | 7/7 | 2/2 | 2/2 | 3/3 | 4 | 0 |
| LRU cache | 0 | 5/5 | 2/2 | 1/1 | 2/2 | 3 | 0 |
| photosynthesis | 0 | 7/7 | 4/4 | 2/2 | 2/2 | 2 | 0 |
| DNS resolution | 0 | 5/5 | 3/3 | 1/1 | 2/2 | 3 | 0 |
| merge sort | 0 | 5/5 | 2/2 | 1/1 | 2/2 | 3 | 0 |
| supply and demand | 0 | 4/4 | 3/3 | 1/1 | 1/1 | 2 | 1 |
| mark and sweep | 0 | 4/4 | 2/2 | 1/1 | 1/1 | 1 | 0 |
| vaccines | 0 | 5/5 | 3/3 | 1/1 | 2/2 | 2 | 0 |
| two-phase commit | 0 | 6/6 | 3/3 | 1/1 | 2/2 | 3 | 0 |
| Newton's second law | 0 | 4/4 | 1/2 | 1/1 | 1/1 | 3 | 0 |
| hash tables (complete) | 0 | 7/7 | 3/3 | none | 0/0 | 2 | 0 |
| osmosis | 0 | 5/5 | 1/1 | 1/1 | 2/2 | 2 | 0 |
| **all** | **0** | **74/74** | **33/35** | **15/15** | **24/24** | **34** | **2 of 71 arrows** |

Read by hand as well: no purple element says anything the student did not, and no wrong claim was quietly corrected in purple. The two relations short are the count's, not the drawing's: the TCP handshake was drawn as message boxes in order ("sends back an ACK" after "sends a SYN"), which has no arrow from the server, and Newton's law as the student's sentence in a label ("force equals mass times velocity"). The two cut labels are correct claims shortened for room ("gets a spot…", "sellers want…"); every wrong claim's words are whole on the paper.

Marks still run above the expected gaps, 34 for 24 (36 before the prompt line, 46 before the check prompt was tightened at all), with all 24 found every time. The extras are a gap a tutor could fairly raise (the hash table stores only the value, so a lookup cannot tell keys apart; the complete explanation drew two marks), or a correction placed on two halves of one misunderstanding (binary search's swapped directions, Newton's law and "moves slower").

A second go at one part: binary search, told again with the directions right, updated only those two boxes, and the check kept the two real gaps (sorted, log n) with no new ones; the TCP handshake, told again with SYN-ACK and a final ACK, redrew just those messages, and the check found both earlier gaps fixed and marked one finer point about sequence numbers.

### Layout of a teach-back board

Checked on every saved board by `scripts/board/overlap_check.py` (which for teach-back boards also tests each arrow's drawn path, curves sampled as the engine draws them, against every element other than its ends and every other arrow's label) and `mark_placement.py`:

- **0 crossings** in the 16 final boards: no arrow through an element or another arrow's label, no label on anything. The boards from the first commit had 15, among them the student's key arrow drawn across "each server". A student or gap arrow crosses nothing (a lesson board's may pass behind one filled shape); the student's boxes are filled solid so a line never shows through their words; an arrow is routed on the curve as drawn, not the straight lines through its points; the student's arrows move other labels out of their way, and when a label has nowhere else to go the arrow goes round it as two numbered stubs instead.
- **Words on arrows**: an arrow with no clear place for all its words is tried as two stubs and kept that way if more of them fit. Arrows drawn with no words fell from 20 of 90 to 1 (a gap's arrow), and student labels shortened or left off to 2 of 71. The drawing is played as one beat, so every part is placed beside what it links to with room for the arrow's words.
- **Corrections**: placed touching their red ring, on whichever side fits, else as close as fits: 13 of 19 touch it, the rest sit 36 to 208 units away where the board around the ring is full.
- **Missing parts**: placed close beside the element the check names, letting the board zoom out to keep it there: 14 of 18 within 70 units (the board's gap between parts is 46), the rest 96 to 229 away.

The first full run, before the check prompt was tightened, found the same 24 of 24 gaps with 46 marks and drew the same 0 invented parts and 15 of 15 wrong claims as stated; its relation count read 33 of 35 only because two fixture keywords missed the LRU cache's own words ("small fast memory"), fixed in `fixtures.json` afterwards. A trial before that found the drawing call writing a second "corrected" block that both ran; the app and this script now run only the first block, and the prompt says so.

Cost: $0.113 for the final run of 14 fixtures and 2 second goes (32 calls), about $0.0065 a fixture for both calls; $0.52 for every run made while building this.
