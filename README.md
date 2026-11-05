# Buddy

A study helper for macOS that lives in the notch. Ask about what is on your screen, out loud or typed, and Buddy explains it out loud while drawing on it: rings and arrows on your code or diagram, and hand-drawn cards for anything the screen does not show. It also walks you through apps you are new to, one step at a time.

<p align="center"><img src="docs/images/diagram-review.png" alt="Buddy reviewing a system design drawn in Excalidraw: rings around the app servers marked bottleneck, and a Redis cache and a read replica proposed beside the diagram in dashed purple" width="820"></p>

## Download

<p align="center">
  <a href="https://github.com/projects-hacks/buddy/releases/latest/download/Buddy.dmg"><img alt="Download Buddy for Mac" src="https://img.shields.io/badge/Download_Buddy_for_Mac-2563eb?style=for-the-badge&logo=apple&logoColor=white" height="56"></a>
</p>

macOS 14.2 or later, Apple silicon or Intel. The download window shows the three install steps; macOS asks once for **Open Anyway** because Buddy is not notarized. Setup then asks for your name and keys and walks through three permissions. After that Buddy updates itself.

Buddy uses your own keys: [Anthropic](https://console.anthropic.com/settings/keys) (recommended), and optionally [Gemini](https://aistudio.google.com/apikey) and [Deepgram](https://console.deepgram.com/) for a better voice. A question costs one to six cents. Help with install: [docs/install.md](docs/install.md).

## What it does

- **Explains and draws at once.** Each spoken sentence arrives with its marks, paced to the voice.
- **Talk or type.** Hold Control + Option to speak, or press Control + Option + T to type in the notch.
- **Walks you through apps.** Ask "how do I export this?" and it points at each button, waits for you to click, and gives the next step.
- **Replays tasks it has shown you.** The same request again, in other words, is walked through from memory without a model call.
- **Remembers what you learned.** New answers build on earlier lessons. Stored on your Mac.
- **Hints before answers.** On LeetCode and similar sites: a nudge, then the approach, then the code only if you ask.
- **Reviews your diagrams.** In Excalidraw, draw.io, Miro or Freeform it marks your boxes and sketches additions beside them. No score.
- **Picks a model per question.** Sonnet, Opus or Gemini Argon, from measured quality, wait and cost.
- **Shows what it spends.** Today's and this month's spend on your keys, in Settings.

<p align="center">
  <img src="docs/images/practice-hint.png" alt="On a LeetCode problem, Buddy rings the inner loop and gives the first hint in the notch, without the solution" width="410">
  <img src="docs/images/lesson-card.png" alt="The open notch showing the last lesson, which builds on hash map lookup, beside a hand-drawn walk through" width="410">
</p>

## Using it

| | |
|---|---|
| Hold Control + Option | Ask out loud |
| Control + Option + T | Type a question (Return sends, Shift + Return adds a line) |
| Hover the notch | Last lesson, the day's chat, Settings |
| Esc | Clear the drawing, or stop a walkthrough |

More in [docs/using-buddy.md](docs/using-buddy.md).

## How it works

```mermaid
flowchart TD
    ask([Spoken or typed question]):::input --> prep
    subgraph prep [On the Mac, in about 0.7 s]
        capture[Screen capture and text index]:::device
        sort[Question sorter]:::device
        recall[Learning memory]:::device
    end
    prep --> route[Router]:::logic --> model{{Sonnet, Opus or Argon}}:::cloud
    model -->|drawing program, streamed| play[Voice and pen, sentence by sentence]:::device
    play --> you([You hear and see it]):::input

    classDef input fill:#fde68a,stroke:#b45309,color:#111
    classDef device fill:#bbf7d0,stroke:#15803d,color:#111
    classDef logic fill:#bfdbfe,stroke:#1d4ed8,color:#111
    classDef cloud fill:#e9d5ff,stroke:#7e22ce,color:#111
    style prep fill:#f0fdf4,stroke:#15803d
```

The model answers with a short drawing program; the first sentence is spoken while the rest is still being written. Details in [docs/how-it-works.md](docs/how-it-works.md).

## Results

| What | Result | Test |
|---|---|---|
| Model per kind of question | Chosen by a blind-judged race of all three models | [docs/model-choice.md](docs/model-choice.md) |
| Question sorting | 46 of 50 held-out spoken questions sorted correctly | `scripts/question_sorting/` |
| Learning memory | 32 of 33 relevant ideas found on 80 blind questions | `scripts/learning_memory/` |
| Hints and diagram review | 32 of 32 checks passed on Sonnet and Argon | `scripts/study_modes/` |
| How-to replay | 30 of 40 new phrasings found; 0 of 49 near misses replayed | `scripts/howto/` |

## Privacy

- The screen is captured only when you ask, or after each click while a walkthrough waits for you. Those checks are compared on the Mac and discarded.
- Speech is transcribed on the Mac. The screenshot and question go to the model that answers.
- Transcripts, memory and how-tos stay in `~/Library/Application Support/Buddy`. Keys stay in the Keychain. No analytics.

## Building from source

Needs Xcode 16 and a self-signed code signing certificate named `Clicky Local Dev` (Keychain Access > Certificate Assistant > Create a Certificate, Self Signed Root, Code Signing). The name predates Buddy and has to stay: installed copies only accept updates signed with it.

```bash
git clone https://github.com/projects-hacks/buddy.git
cd buddy
zsh scripts/build-local.sh
```

Logs go to `~/Library/Logs/Buddy.log`. Releases: [docs/releasing.md](docs/releasing.md). Source map: [AGENTS.md](AGENTS.md). Tests: [scripts/](scripts/README.md).

## Credits

Started as a fork of [Clicky](https://github.com/farzaa/clicky) by Farza (MIT). Drawing uses [rough.js](https://roughjs.com/) and [perfect-freehand](https://github.com/steveruizok/perfect-freehand) (MIT).

## License

MIT. See [LICENSE](LICENSE).
