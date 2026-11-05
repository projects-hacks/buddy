<p align="center">
  <img src="docs/images/buddy-icon.png" alt="Buddy" width="112">
</p>

<h1 align="center">Buddy</h1>

<p align="center">
  <b>A study helper in your Mac's notch.</b><br>
  Ask about what is on your screen. Buddy explains it out loud and draws on it while it talks.
</p>

<p align="center">
  <a href="https://github.com/projects-hacks/buddy/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/projects-hacks/buddy?label=release&color=2563eb"></a>
  <img alt="macOS 14.2 or later" src="https://img.shields.io/badge/macOS-14.2%2B-111111?logo=apple&logoColor=white">
  <img alt="Apple silicon and Intel" src="https://img.shields.io/badge/Apple%20silicon%20%7C%20Intel-universal-555555">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-16a34a"></a>
  <img alt="Your own API keys" src="https://img.shields.io/badge/keys-your%20own-b45309">
</p>

<p align="center">
  <a href="https://github.com/projects-hacks/buddy/releases/latest/download/Buddy.dmg"><img alt="Download Buddy for Mac" src="https://img.shields.io/badge/Download_for_Mac-2563eb?style=for-the-badge&logo=apple&logoColor=white" height="52"></a>
</p>

<p align="center"><img src="docs/images/diagram-review.png" alt="Buddy reviewing a system design drawn in Excalidraw: rings around the app servers marked bottleneck, and a Redis cache and a read replica proposed beside the diagram in dashed purple" width="860"></p>

## What it does

<table>
  <tr>
    <td width="33%" valign="top">
      <b>Explains and draws</b><br>
      <sub>Each spoken sentence arrives with its marks: rings and arrows on your code or diagram, hand-drawn cards for the rest.</sub>
    </td>
    <td width="33%" valign="top">
      <b>Talk or type</b><br>
      <sub>Hold <kbd>⌃</kbd> <kbd>⌥</kbd> and speak, or press <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>T</kbd> and type in the notch.</sub>
    </td>
    <td width="33%" valign="top">
      <b>Walks you through apps</b><br>
      <sub>"How do I export this?" One step at a time, pointing at each button, waiting for your click.</sub>
    </td>
  </tr>
  <tr>
    <td valign="top">
      <b>Replays from memory</b><br>
      <sub>Ask for a task it has shown you before, in any words, and it is walked through again without a model call.</sub>
    </td>
    <td valign="top">
      <b>Remembers what you learn</b><br>
      <sub>New answers build on earlier lessons. Stored on your Mac.</sub>
    </td>
    <td valign="top">
      <b>Hints before answers</b><br>
      <sub>On LeetCode and similar sites: a nudge, then the approach, then the code only when you ask.</sub>
    </td>
  </tr>
  <tr>
    <td valign="top">
      <b>Reviews your diagrams</b><br>
      <sub>In Excalidraw, draw.io, Miro or Freeform it marks your boxes and sketches additions beside them.</sub>
    </td>
    <td valign="top">
      <b>Picks a model per question</b><br>
      <sub>Sonnet, Opus or Gemini Argon, from measured quality, wait and cost.</sub>
    </td>
    <td valign="top">
      <b>Shows what it spends</b><br>
      <sub>Today's and this month's spend on your keys, in Settings. A question is one to six cents.</sub>
    </td>
  </tr>
</table>

<table>
  <tr>
    <td width="50%"><img src="docs/images/practice-hint.png" alt="On a LeetCode problem, Buddy rings the inner loop and gives the first hint in the notch, without the solution"></td>
    <td width="50%"><img src="docs/images/lesson-card.png" alt="The open notch showing the last lesson, which builds on hash map lookup, beside a hand-drawn walk through"></td>
  </tr>
  <tr>
    <td align="center"><sub>A first hint on LeetCode: the line that matters, ringed. No solution.</sub></td>
    <td align="center"><sub>The lesson card, built on an earlier lesson, beside its drawing.</sub></td>
  </tr>
</table>

## Install

<p align="center"><img src="docs/images/install-steps.png" alt="The three install steps: drag Buddy onto Applications; open Buddy and click Done when macOS says it cannot check it; then in System Settings, Privacy and Security, click Open Anyway" width="640"></p>

The download window shows these same steps. macOS asks for **Open Anyway** once, because Buddy is not notarized. Setup then asks for your name and keys and walks through three permissions; after that Buddy updates itself.

<p>
  <a href="https://console.anthropic.com/settings/keys"><img alt="Anthropic key: recommended" src="https://img.shields.io/badge/Anthropic-recommended-111111"></a>
  <a href="https://aistudio.google.com/apikey"><img alt="Gemini key: optional" src="https://img.shields.io/badge/Gemini-optional-4285F4"></a>
  <a href="https://console.deepgram.com/"><img alt="Deepgram key: optional, for a natural voice" src="https://img.shields.io/badge/Deepgram-optional%2C%20natural%20voice-13EF93?labelColor=111111"></a>
</p>

Step by step, with troubleshooting: [docs/install.md](docs/install.md).

## Using it

| Keys | Does |
|---|---|
| Hold <kbd>Control</kbd> + <kbd>Option</kbd> | Ask out loud; your words show under the notch |
| <kbd>Control</kbd> + <kbd>Option</kbd> + <kbd>T</kbd> | Type a question; <kbd>Return</kbd> sends, <kbd>Shift</kbd> + <kbd>Return</kbd> adds a line |
| Hover the notch | The last lesson, the day's chat, Settings |
| <kbd>Esc</kbd> | Clear the drawing, or stop a walkthrough |

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

The model answers with a short drawing program, and the first sentence is spoken while the rest is still being written. Details in [docs/how-it-works.md](docs/how-it-works.md).

## Results

<table>
  <tr>
    <td align="center" width="25%"><h3>46 / 50</h3><sub>held-out spoken questions sorted by kind</sub><br><sub><code>scripts/question_sorting</code></sub></td>
    <td align="center" width="25%"><h3>32 / 33</h3><sub>relevant past lessons recalled on 80 blind questions</sub><br><sub><code>scripts/learning_memory</code></sub></td>
    <td align="center" width="25%"><h3>32 / 32</h3><sub>hint and diagram review checks on Sonnet and Argon</sub><br><sub><code>scripts/study_modes</code></sub></td>
    <td align="center" width="25%"><h3>0 / 49</h3><sub>near misses replayed as the wrong how-to (30 of 40 rephrasings found)</sub><br><sub><code>scripts/howto</code></sub></td>
  </tr>
</table>

Which model answers each kind of question comes from a blind-judged race of all three: [docs/model-choice.md](docs/model-choice.md).

## Privacy

| What | Where it goes |
|---|---|
| **Screen** | Captured only when you ask, or after a click while a walkthrough waits; those checks are compared on the Mac and discarded |
| **Voice** | Transcribed on the Mac |
| **Sent** | The screenshot and question, to the model that answers |
| **Kept** | Transcripts, memory and how-tos in `~/Library/Application Support/Buddy`; keys in the Keychain |
| **Analytics** | None |

<details>
<summary><b>Building from source</b></summary>
<br>

Needs Xcode 16 and a self-signed code signing certificate named `Clicky Local Dev` (Keychain Access > Certificate Assistant > Create a Certificate, Self Signed Root, Code Signing). The name predates Buddy and has to stay: installed copies only accept updates signed with it.

```bash
git clone https://github.com/projects-hacks/buddy.git
cd buddy
zsh scripts/build-local.sh
```

Logs go to `~/Library/Logs/Buddy.log`. Releases: [docs/releasing.md](docs/releasing.md). Source map: [AGENTS.md](AGENTS.md). Tests: [scripts/](scripts/README.md).

</details>

## Credits

Started as a fork of [Clicky](https://github.com/farzaa/clicky) by Farza (MIT). Drawing uses [rough.js](https://roughjs.com/) and [perfect-freehand](https://github.com/steveruizok/perfect-freehand) (MIT). Licensed under [MIT](LICENSE).
