# The map of what you know

Checks for the map window (`leanring-buddy/KnowledgeMap*.swift`) and for the relations Claude Haiku names for it.

| File | What it is |
|---|---|
| `make_fixture.py` | Writes `fixture_5.json`, `fixture_40.json` and `fixture_300.json`: seeded memories in the app's own `concepts.json` format, topics with their relations plus ideas with no link yet |
| `map_check.swift` | Offline: layout repeatability, overlaps and timing, strict reading of relations, an older store loading, the one-time relation pass and forgetting one idea (on scratch copies), then the real map view rendered to PNG in light and dark |
| `relation_fixture.json` | 14 known ideas, 6 lessons and the links a textbook would draw between them, written before the prompts were run on it |
| `relation_check.py` | Grades the filing call's `related` list and the one-time pass on that fixture, with the prompts that ship, three runs each |

```bash
python3 -I scripts/knowledge_map/make_fixture.py

mkdir -p /tmp/map_check && cp scripts/knowledge_map/map_check.swift /tmp/map_check/main.swift
xcrun swiftc -O -parse-as-library -o /tmp/map_check/check leanring-buddy/ConceptIndex.swift \
  leanring-buddy/LearningMemory.swift leanring-buddy/KnowledgeMapRelations.swift \
  leanring-buddy/KnowledgeMapLayout.swift leanring-buddy/KnowledgeMapView.swift \
  leanring-buddy/DesignSystem.swift /tmp/map_check/main.swift
/tmp/map_check/check scripts/knowledge_map /tmp/map_check/out

security find-generic-password -a api-key -s com.maverickrajeev.clicky-local.anthropic -w \
  | python3 -I scripts/knowledge_map/relation_check.py
```

## Results

**Layout** (`map_check.swift`, built with `-O`, Apple M4):

| Ideas | Links | Topics | Layout time | Overlapping ideas |
|---|---|---|---|---|
| 5 | 4 | 1 | 0.1 ms | 0 |
| 40 | 27 | 5 | 0.6 ms | 0 |
| 300 | 208 | 28 | 5 ms | 0 |

The same ideas give the same map every time and in any store order, and a month later only the fading changes. Adding one idea to a topic of 40 ideas left every other topic's shape exactly as it was; 13 of the 32 ideas outside it slid over with their topic to make room, which the window animates.

**Relations** (`relation_check.py`, final prompts, three runs of each case):

| Call | Expected links found | Sensible kind | Links to unrelated ideas | Ids not shown | Same idea kept as same_as |
|---|---|---|---|---|---|
| Filing, after each answer | 12/12 | 12/12 | 0 in 18 filings | 0 | 3/3 |
| One-time pass, names and summaries only | 18/18 | 18/18 | 0 in 3 runs | 0 | |

An earlier version of the check gave the ideas sequential ids ("0003a009", "0004a00a"). Haiku then mixed them up: 8 and 11 of 12 links found, 3 ids that were never shown, and one lesson linked to its neighbour's id. Real ids are random, and with random ids those errors went away. The app keeps only links whose ids were in what Haiku was shown, so a mix-up can drop a link but never draw one to an idea that does not exist.

**Filing quality**, measured with `scripts/learning_memory/` before and after the filing prompt asked for relations. Each run files all 50 concepts again (`make_cues.py`), so cues differ run to run; the Haiku stage of recall is then graded on the 80 blind questions. Three runs of the old prompt, two of the final one:

| | Old prompt | Final prompt |
|---|---|---|
| Test half, Haiku stage, found | 32, 32, 33 of 33 | 33, 32 of 33 |
| Test half, Haiku stage, precision | 85, 89, 90% | 82, 88% |
| Dev half, Haiku stage, precision | 84, 80, 75% | 76, 79% |
| Names only, test half | 48 to 51% found at 84 to 94% | 48% found at 94 to 100% |
| Shortlist of 12 holds, test half | 32 to 33 of 33 | 32 to 33 of 33 |
| Filing cost | $0.0018 a lesson | $0.0020 a lesson |

Recall is unchanged. Precision overlaps the old range but sits at its low end; repeating the Haiku stage on one run's own shortlists moved precision by up to 6 points, so the gap is within the noise, and worth watching. `memory_flow_test.swift` passes all its checks, including two new ones for relations, on two runs of the final prompt. A first draft of the prompt let Haiku file "what happens when a server is added" as a new idea linked to consistent hashing instead of as consistent hashing itself, which failed the flow test's merge check; the final prompt says a detail of a known idea is that idea.

## Pictures

`map_check.swift` writes `map-5`, `map-40` and `map-300` in light and dark, `map-40-selected` (an open idea with Re-teach this and Forget this idea, and a hover card), `map-300-zoomed` (one topic at full size), `map-300-search` ("hash") and `map-empty`, each in light and dark.
