<p align="center">
  <img src="docs/images/buddy-icon.png" alt="Buddy" width="112">
</p>

<h1 align="center">Buddy</h1>

<p align="center">
  <b>Your screen, explained.</b><br>
  Ask about anything on your screen. Buddy explains it out loud and draws on it while it talks.<br>
  Learn something new, get through an app, fix an error, or check your own work, from your Mac's notch.
</p>

<p align="center">
  <a href="https://github.com/projects-hacks/buddy/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/projects-hacks/buddy?label=release&color=2563eb"></a>
  <img alt="macOS 14.2 or later" src="https://img.shields.io/badge/macOS-14.2%2B-111111?logo=apple&logoColor=white">
  <img alt="Apple silicon and Intel" src="https://img.shields.io/badge/Apple%20silicon%20%2B%20Intel-555555">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-16a34a"></a>
  <img alt="Bring your own API keys" src="https://img.shields.io/badge/bring%20your%20own%20keys-b45309">
</p>

<p align="center">
  <a href="https://projects-hacks.github.io/buddy/"><b>projects-hacks.github.io/buddy</b></a>
</p>

<p align="center">
  <a href="https://github.com/projects-hacks/buddy/releases/latest/download/Buddy.dmg"><img alt="Download Buddy for Mac" src="https://img.shields.io/badge/Download_for_Mac-2563eb?style=for-the-badge&logo=apple&logoColor=white" height="52"></a>
</p>

<p align="center"><img src="docs/images/demo.gif" alt="Asked why a binary search crashes, Buddy rings each line in turn while it talks, and draws a trace of the list 3, 7, 9 on a card beside the code, pass by pass, until low and high both reach the missing index three" width="900"></p>
<p align="center"><sub>A real answer, sped up. The words under the notch are what Buddy is saying.</sub></p>

## What it does

<table>
  <tr>
    <td width="25%" valign="top">
      <sub><b>LEARN</b></sub><br>
      <b>Explains anything on screen</b><br>
      <sub>Code, a paper, a dashboard, a config file. It rings what it is talking about, one sentence at a time.</sub>
    </td>
    <td width="25%" valign="top">
      <sub><b>GET IT DONE</b></sub><br>
      <b>Walks you through any app</b><br>
      <sub>"How do I export this?" One step at a time, pointing at each button. Ask again later and it replays from memory.</sub>
    </td>
    <td width="25%" valign="top">
      <sub><b>FIX</b></sub><br>
      <b>Explains the error you just hit</b><br>
      <sub>An error in a terminal or editor makes the notch glow. One tap and it rings the line that caused it.</sub>
    </td>
    <td width="25%" valign="top">
      <sub><b>REVIEW</b></sub><br>
      <b>Reviews your own work</b><br>
      <sub>In Excalidraw, draw.io, Miro or Freeform it marks your boxes and sketches additions beside them.</sub>
    </td>
  </tr>
  <tr>
    <td valign="top">
      <sub><b>LEARN</b></sub><br>
      <b>Teaches from scratch</b><br>
      <sub>"Teach me TCP from scratch" turns the screen into a whiteboard. Then teach it back to check yourself.</sub>
    </td>
    <td valign="top">
      <sub><b>LEARN</b></sub><br>
      <b>Hints before answers</b><br>
      <sub>On LeetCode and similar sites: a nudge, then the approach, then the code only when you ask.</sub>
    </td>
    <td valign="top">
      <sub><b>LEARN</b></sub><br>
      <b>Knows what the lecture said</b><br>
      <sub>Ask about a video lecture and it knows the last minute of what was said.</sub>
    </td>
    <td valign="top">
      <sub><b>REMEMBER</b></sub><br>
      <b>Remembers what you learn</b><br>
      <sub>Answers build on earlier lessons; every lesson is a notebook page, and a map shows what is fading. On your Mac.</sub>
    </td>
  </tr>
</table>

Each question goes to Sonnet, Opus or Gemini Argon, whichever measured best for that kind of question, and Settings shows what you have spent today. A question costs one to six cents.

<table>
  <tr>
    <td width="33%"><img src="docs/images/practice-hint.png" alt="On a LeetCode problem, Buddy rings the inner loop and gives the first hint in the notch, without the solution"></td>
    <td width="33%"><img src="docs/images/diagram-review.png" alt="Buddy reviewing a system design in Excalidraw: the app servers ringed as the bottleneck, a cache and a read replica proposed in dashed purple"></td>
    <td width="33%"><img src="docs/images/lesson-card.png" alt="The open notch showing the last lesson, which builds on hash map lookup, beside a hand-drawn walk through"></td>
  </tr>
  <tr>
    <td align="center"><sub>A first hint, no solution</sub></td>
    <td align="center"><sub>A review of your own design</sub></td>
    <td align="center"><sub>A lesson that builds on an earlier one</sub></td>
  </tr>
</table>

## Install

<p align="center"><img src="docs/images/install-steps.png" alt="The three install steps: drag Buddy onto Applications; open Buddy and click Done when macOS says it cannot check it; then in System Settings, Privacy and Security, click Open Anyway" width="640"></p>

The download window shows these same steps. macOS asks for **Open Anyway** once, because Buddy is not notarized. Setup then asks for your name and keys and walks through the permissions it needs; after that Buddy updates itself.

<p>
  <a href="https://console.anthropic.com/settings/keys"><img alt="Anthropic key: recommended" src="https://img.shields.io/badge/Anthropic-recommended-111111"></a>
  <a href="https://aistudio.google.com/apikey"><img alt="Gemini key: optional" src="https://img.shields.io/badge/Gemini-optional-4285F4"></a>
  <a href="https://console.deepgram.com/"><img alt="Deepgram key: optional, for a natural voice and sharper hearing" src="https://img.shields.io/badge/Deepgram-optional%2C%20voice%20and%20hearing-13EF93?labelColor=111111"></a>
</p>

Or with Homebrew:

```bash
brew tap projects-hacks/buddy https://github.com/projects-hacks/buddy
brew trust projects-hacks/buddy
brew install --cask projects-hacks/buddy/buddy
```

Step by step, with troubleshooting: [docs/install.md](docs/install.md).

## Using it

| Keys | Does |
|---|---|
| Hold <kbd>Control</kbd> + <kbd>Option</kbd> | Ask out loud; your words show under the notch |
| <kbd>Control</kbd> + <kbd>Option</kbd> + <kbd>T</kbd> | Type a question; <kbd>Return</kbd> sends, <kbd>Shift</kbd> + <kbd>Return</kbd> adds a line |
| Hover the notch | The last lesson with Replay, the day's chat, and Notebook, Map and Settings in its top row |
| Hover the glow, then Explain this error (or tap <kbd>Control</kbd> + <kbd>Option</kbd>) | When the notch glows red and says "An error on screen.", explain the error that just appeared |
| <kbd>Esc</kbd> | Clear the drawing, or stop a walkthrough |

Everything else is in the guide: [How to use Buddy](https://projects-hacks.github.io/buddy/guide/).

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

## Privacy

| What | Where it goes |
|---|---|
| **Screen** | Captured whole only while you hold the keys or ask, and dropped if no question follows, or after a click while a walkthrough waits; those checks are compared on the Mac and discarded |
| **Errors** | While a terminal, editor, Xcode or a coding judge's page is in front, after Return, a run shortcut or a click, the front window alone is read on the Mac (its accessibility text, or text recognition on the part that changed) to spot an error. Nothing is stored; fingerprints of errors already seen stay in memory until Buddy quits, and nothing is sent until you accept the offer |
| **Voice** | The microphone is open while the keys are held and, so you can talk over it, while an answer plays. A small mic beside "explaining" in the notch shows it is open, Esc or Stop ends the answer and closes it, and it never opens on a Bluetooth headset. Heard by Deepgram when a Deepgram key is set; otherwise transcribed on the Mac |
| **Teach it back** | After you ask to explain a topic ("let me explain X back to you"), the microphone stays open hands free until you are done: you say "I'm done", press Return, go quiet for eight seconds, or three minutes pass. The red meter and "Listening" show the whole time, and Esc or Cancel throws it away. Heard like any question (Deepgram with a key, on the Mac without); what you said goes to the model that answers board turns (Sonnet first with an Anthropic key) to be drawn and checked, and is kept on the board's Notebook page and, as every answer is, in the diagnostic log |
| **Lectures** | When you ask while a video is in front, the minute before the playback time is read from the page's transcript or YouTube's captions (only the video's id goes to YouTube). Where there is none, and once you allow System Audio Recording, the front app's own sound is turned into words on your Mac while it plays, never sent anywhere for this, filed by the video's playback time so a question at any point you watched gets the minute before it. The words stay in memory for that app while Buddy runs, and the last 90 seconds of sound until you switch apps (a small screen glyph shows in the notch while sound is kept), never on disk. They are used only when you ask about the video, meaning a player's time is on screen or you ask what was said, and keep the video's voice from being taken for yours. Only if your Mac cannot recognise speech itself is the newest 65 seconds of sound sent to be transcribed when you ask (by Deepgram with a key). For a browser that is all its tabs. Never the microphone; never calls, meetings or music apps, and any app using a microphone counts as a call |
| **Sent** | The screenshot and question, to the model that answers, with the lecture's last minute when there is one |
| **Kept** | Transcripts, memory and how-tos in `~/Library/Application Support/Buddy`; keys in the Keychain |
| **Notebook** | Each finished lesson as a page in `~/Library/Application Support/Buddy/Notebook`: the question, what was said, the cards drawn, and a small JPEG of only the part of the screen that was marked, cut from that question's screenshot (never the whole screen). A board lesson or a teach-back is one page when you leave the board, the whole board kept as one drawing with what was said. About 70 to 150 KB a page, the picture cut from the display's own pixels so code stays sharp, under 2 KB for an answer without a drawing. A cancelled question keeps nothing. Never uploaded; the Notebook window shows each page's size, deletes a page, a day or everything, and can stop keeping new lessons |
| **Map** | Drawn on the Mac from memory. The first time it opens, ideas with no links on record yet (memory from before 2.0) have only their names and one-sentence summaries sent to Claude Haiku, 20 ideas a call, once, to find how they relate; no lesson, question or screen goes with them |
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
