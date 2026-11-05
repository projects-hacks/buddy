# Scripts

| Path | For |
|---|---|
| `build-local.sh` | Building, signing, installing and relaunching Buddy for daily use |
| `make-release.sh` | The downloadable disk image ([docs/releasing.md](../docs/releasing.md)) |
| `qa/` | End-to-end runs of the real app, and the fresh-install test |
| `learning_memory/` | Memory's blind recall test, timing at 5,000 ideas, and an end-to-end test of the real store |
| `howto/` | Finding saved how-tos again from new wordings, and never for near misses |
| `notebook/` | A sample notebook and its PDFs rendered offline from fixture lessons, with checks on cleaning, parsing and deleting |
| `study_modes/` | Hint ladder and diagram review, checked on Sonnet and Argon |
| `route_race/` | The model race, blind judging and the routing table (`leanring-buddy/RouteTable.json`) |
| `lesson_race/` | The teaching-lesson race the routing table's teach row comes from |
| `question_sorting/` | The question sorter's calibration and its blind spoken test |
| `sounds/make_sounds.py` | Buddy's interface sounds |
| `draw_icon.py` | Buddy's app icon |
| `experiments/` | One-off measurements quoted in docs/model-choice.md |

Scripts that call Vertex read the Google Cloud project from `VERTEX_PROJECT`; scripts that call Claude read the key from the Keychain on stdin, never from an argument.
