# Experiments

One-off measurements from building Buddy, kept because their numbers are quoted in [docs/model-choice.md](../../docs/model-choice.md) and anyone should be able to rerun them. None is part of building or testing the app today.

| Script | What it measured |
|---|---|
| `brain_race.py` | Claude against Argon on the same screen, prompt and questions: time to first word, length, marks |
| `latency-compare.sh` | Time to first byte across models with a screenshot attached |
| `stream-check.sh` | Whether Vertex streams, and in what framing |
| `answer-shape.sh` | The shape of a real answer: first byte, length, marks |
| `budget-check.sh` | Whether a per-kind token budget changes the shape of the answer |
| `diagram-check.sh`, `ab-diagram.sh`, `ab_diagram.py` | Whether positioned diagrams were worth their cost (they were 16 times slower and changed nothing) |
| `verify-vertex.sh` | The Vertex path for Gemini 4 Argon, end to end |

All need `gcloud` signed in and your Google Cloud project in `VERTEX_PROJECT`; the Claude ones read the Anthropic key from the Keychain.
