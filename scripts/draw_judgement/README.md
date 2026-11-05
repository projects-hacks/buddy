# Drawing judgement

Whether the tutor draws only when a drawing helps: a card when a picture teaches what words do not, marks when the answer is about something on the screen, and nothing for small talk or a fact that has nothing to do with the screen.

`draw_judgement.py` asks sixteen questions over screens built from listings (the same `id [x, y, w, h] text` lines the app sends, drawn into an image so the model sees one too). Eight should get a card, four marks only, four nothing. Each is asked on `claude-sonnet-5-5` with thinking off, as the app asks it, with the prompt from a given git revision and with the prompt in the working tree, and each answer is sorted by what it drew.

```bash
python3 -I scripts/draw_judgement/draw_judgement.py 404f033 /tmp/draw_eval        # both prompts, about $0.35
python3 -I scripts/draw_judgement/draw_judgement.py 404f033 /tmp/draw_eval new    # the working tree only
```

The key is read from the Keychain inside the script and never printed.

## Results (release 1.5.1)

| Prompt | Card | Marks only | Nothing | As expected | Mean output tokens |
|---|---|---|---|---|---|
| Expected | 8 | 4 | 4 | 16 | |
| 1.5 | 7 | 8 | 1 | 12 | 557 to 595 |
| 1.5.1 | 7 | 5 | 4 | 15 | 539 |

The 1.5 prompt marked the screen for a pronunciation, a history fact and a thank you, because every rule assumed a drawing. The one miss both prompts share is the read path through an architecture diagram that is already on the screen: both numbered and connected the student's own boxes instead of drawing a card, which is arguably the better answer. The token saving is small because cards cost the most and are kept; what goes is the clutter on answers that needed none.
