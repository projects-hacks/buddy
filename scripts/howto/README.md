# How-to retrieval

Tests whether a saved how-to is found again when the same task is asked in other words, and, more important, never replayed for a task that only sounds like it. A wrong replay walks the student through the wrong steps; a miss only costs an ordinary answer, so the thresholds allow no wrong replays at all.

`tasks.json` holds eight how-tos across TextEdit, System Settings, Finder, Preview, Safari, Keynote and Notes, as Buddy records them, with questions written without seeing the ways of asking Haiku later writes: right-task rephrasings to find, and near misses in the same app not to find (another file format, the opposite action, a neighbouring control).

```bash
security find-generic-password -a api-key -s com.maverickrajeev.clicky-local.anthropic -w \
  | python3 -I scripts/howto/make_cues.py          # the shipped prompt; about $0.0001 a how-to
swiftc -O -o "$TMPDIR/howto_eval" scripts/howto/eval/*.swift leanring-buddy/HowToMemory.swift \
  leanring-buddy/GuideMode.swift leanring-buddy/AppIdentity.swift
"$TMPDIR/howto_eval"
```

The scorer runs the matching code that ships, with the same on-device sentence model and pooling as the question sorter. Thresholds are swept on half of each list; the other half and a fresh set are reported.

**Results with the shipped settings** (meaning at least 0.88, every content word of the question in one saved phrasing, at least half of that phrasing's words in the question):

| Questions | Found | Wrong task replayed | Near misses replayed |
|---|---|---|---|
| Held-out half | 23 of 32 | 0 | 0 of 25 |
| Fresh set | 30 of 40 | 0 | 0 of 24 |

**What was learned on the way.** Meaning similarity from the on-device model alone is useless here: it rates every short how-to question 0.89 to 0.99 against every other. Words decide, compared both ways against a single saved phrasing; counting the steps' own words ("open the File menu") let "how do I open a PDF" find "save as PDF", so they are left out. A short list of synonyms that mean the same in any app (make, create, add, new; turn on as enable) lifted the held-out half from 18 to 23 found. Because that list was written after seeing the held-out misses, the fresh set, written before it, is the honest figure: 23 of 40 before the list, 30 of 40 after.
