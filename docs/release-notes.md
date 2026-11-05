<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/projects-hacks/buddy/main/docs/images/whats-new/1.5/banner-dark.png">
  <img alt="Buddy 1.5, hears you better. One spoken question: the Mac's recognizer heard posters and Kath, Buddy 1.5 heard Postgres and Kafka" src="https://raw.githubusercontent.com/projects-hacks/buddy/main/docs/images/whats-new/1.5/banner-light.png">
</picture>

<p align="center">
  <a href="https://github.com/projects-hacks/buddy/releases/latest/download/Buddy.dmg"><img alt="Download Buddy for Mac" src="https://img.shields.io/badge/Download_for_Mac-2563eb?style=for-the-badge&logo=apple&logoColor=white" height="44"></a>
</p>

<p align="center">
  <img alt="macOS 14.2 or later" src="https://img.shields.io/badge/macOS-14.2%2B-111111?logo=apple&logoColor=white">
  <img alt="Apple silicon and Intel" src="https://img.shields.io/badge/Apple%20silicon%20%2B%20Intel-555555">
  <img alt="6.3 MB download" src="https://img.shields.io/badge/download-6.3%20MB-555555">
  <img alt="Free and open source, MIT" src="https://img.shields.io/badge/open%20source-MIT-16a34a">
</p>

## <img src="https://raw.githubusercontent.com/projects-hacks/buddy/main/docs/images/icons/hearing.png" width="24" height="24" align="top"> Gets technical words right

With a Deepgram key, Deepgram now hears your questions as well as speaking the answers. The same questions, on the same microphone:

| You said | The Mac's recognizer heard | Buddy 1.5 hears |
|:--|:--|:--|
| Kafka | ~~Kakkar~~ | **Kafka** |
| idempotent | ~~Eden potent~~ | **idempotent** |
| Postgres | ~~posters~~ | **Postgres** |

Before you speak, Buddy tells it which words to expect: the labels on your screen, the terms on cards it just drew, and the ideas you have been learning. About a third of a cent per question, shown in **Spent today**.

> [!TIP]
> No Deepgram key? Nothing changes: the Mac's own recognizer hears you as before. With a key, it still listens alongside, in case the connection drops.

## <img src="https://raw.githubusercontent.com/projects-hacks/buddy/main/docs/images/icons/time.png" width="24" height="24" align="top"> Take your time

| | Before | Now |
|:--|:--|:--|
| Pause to think mid-question | Only the words after the pause arrived | **The whole question arrives** |
| Let go too early, press again | Two separate questions | **Joined into one**, if the answer has not started |

## <img src="https://raw.githubusercontent.com/projects-hacks/buddy/main/docs/images/icons/history.png" width="24" height="24" align="top"> Long sessions stay in view

| | Before | Now |
|:--|:--|:--|
| Questions kept in view | 10 | **40** |
| Older answers | Forgotten | **What was said is kept** |

Recent answers are kept with their drawings; older ones keep what was said, so long sessions stay cheap.

## <img src="https://raw.githubusercontent.com/projects-hacks/buddy/main/docs/images/icons/more.png" width="24" height="24" align="top"> Also in this release

| Area | What changed |
|:--|:--|
| **Fixed** | Buddy could stop responding when the microphone changed, for example AirPods connecting. It now keeps listening. |
| **Spent today** | Counts answers you cut off, and keeps the last cents of the day when Buddy quits. |
| **Mishearings** | When a word is still misheard, Buddy answers what you meant. |
| **Chat** | Long folded answers no longer draw over the messages below. |

## <img src="https://raw.githubusercontent.com/projects-hacks/buddy/main/docs/images/icons/update.png" width="24" height="24" align="top"> Updating

| You have | Do this |
|:--|:--|
| Buddy 1.2 or later | Click **Update** when the notch offers it |
| Buddy 1.0 or 1.1 | Download, drag onto Applications, choose **Replace** |
| Homebrew | `brew upgrade --cask projects-hacks/buddy/buddy` |

> [!NOTE]
> Your keys, memory and permissions stay as they are.

<details>
<summary><img src="https://raw.githubusercontent.com/projects-hacks/buddy/main/docs/images/icons/install.png" width="18" height="18" align="top"> <b>First time installing?</b></summary>
<br>
<p align="center"><img src="https://raw.githubusercontent.com/projects-hacks/buddy/main/docs/images/install-steps.png" alt="Drag Buddy onto Applications; open it and click Done when macOS says it cannot check it; then click Open Anyway in Privacy and Security" width="560"></p>

Or with Homebrew:

```bash
brew tap projects-hacks/buddy https://github.com/projects-hacks/buddy
brew trust projects-hacks/buddy
brew install --cask projects-hacks/buddy/buddy
```

More help: [install guide](https://github.com/projects-hacks/buddy/blob/main/docs/install.md).
</details>

<sub><img src="https://raw.githubusercontent.com/projects-hacks/buddy/main/docs/images/icons/check.png" width="12" height="12"> Every update is checked against <code>Buddy.dmg.sha256</code> and the app's signature before it installs. To check a download by hand: <code>shasum -a 256 -c Buddy.dmg.sha256</code></sub>
