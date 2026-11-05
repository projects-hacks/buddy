<p align="center">
  <a href="https://github.com/projects-hacks/buddy/releases/latest/download/Buddy.dmg"><img alt="Download Buddy for Mac" src="https://img.shields.io/badge/Download_for_Mac-2563eb?style=for-the-badge&logo=apple&logoColor=white" height="44"></a>
</p>

<h3 align="center">Buddy hears you better</h3>

<p align="center">Technical words, long pauses and half-finished questions now come through whole.</p>

---

### Gets technical words right

With a Deepgram key, Deepgram now hears your questions as well as speaking the answers. The same questions, on the same microphone:

| You said | The Mac's recognizer heard | Buddy 1.5 hears |
|:--|:--|:--|
| Kafka | Kakkar | **Kafka** |
| idempotent | Eden potent | **idempotent** |
| Postgres | posters | **Postgres** |

Before you speak, Buddy tells it which words to expect: the labels on your screen, the terms on cards it just drew, and the ideas you have been learning. About a third of a cent per question, shown in **Spent today**. No Deepgram key? The Mac's recognizer works as before.

### Take your time

| | Before | Now |
|:--|:--|:--|
| Pause to think mid-question | Only the words after the pause arrived | **The whole question arrives** |
| Let go too early, press again | Two separate questions | **Joined into one**, if the answer has not started |

### Long sessions stay in view

Buddy remembers the last **40** questions of a session instead of 10. Recent answers are kept with their drawings; older ones keep what was said, so long sessions stay cheap.

### Also in this release

| Area | What changed |
|:--|:--|
| **Fixed** | Buddy could stop responding when the microphone changed, for example AirPods connecting. It now keeps listening. |
| **Spent today** | Counts answers you cut off, and keeps the last cents of the day when Buddy quits. |
| **Mishearings** | When a word is still misheard, Buddy answers what you meant. |
| **Chat** | Long folded answers no longer draw over the messages below. |

---

### Updating

| You have | Do this |
|:--|:--|
| Buddy 1.2 or later | Click **Update** when the notch offers it |
| Buddy 1.0 or 1.1 | Download, drag onto Applications, choose **Replace** |
| Homebrew | `brew upgrade --cask projects-hacks/buddy/buddy` |

Your keys, memory and permissions stay.

<details>
<summary><b>First time installing?</b></summary>
<br>
<p align="center"><img src="https://raw.githubusercontent.com/projects-hacks/buddy/main/docs/images/install-steps.png" alt="Drag Buddy onto Applications; open it and click Done when macOS says it cannot check it; then click Open Anyway in Privacy and Security" width="560"></p>

Or with Homebrew:

```bash
brew tap projects-hacks/buddy https://github.com/projects-hacks/buddy
brew trust projects-hacks/buddy
brew install --cask projects-hacks/buddy/buddy
```

Needs macOS 14.2 or later, Apple silicon or Intel. More help: [install guide](https://github.com/projects-hacks/buddy/blob/main/docs/install.md).
</details>

<sub>Every update is checked against `Buddy.dmg.sha256` and the app's signature before it installs. To check a download by hand: `shasum -a 256 -c Buddy.dmg.sha256`.</sub>
