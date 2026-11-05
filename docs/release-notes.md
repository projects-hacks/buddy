## [Download Buddy for Mac](https://github.com/projects-hacks/buddy/releases/latest/download/Buddy.dmg)

**Install in three steps**

1. Open the downloaded **Buddy.dmg** and drag **Buddy** onto **Applications**.
2. Open Buddy from Applications. The first time only, macOS says it can't check the app: click **Done**, then open **System Settings > Privacy & Security**, scroll down and click **Open Anyway**.
3. Follow the setup window: your name, your keys, three permissions.

Already have Buddy 1.2 or later? It offers this update in the notch by itself: click **Update**. On 1.0 or 1.1, download it once and drag it onto Applications, choosing **Replace**. Your keys, memory and permissions stay.

Or with Homebrew:

```bash
brew tap projects-hacks/buddy https://github.com/projects-hacks/buddy
brew trust projects-hacks/buddy
brew install --cask projects-hacks/buddy/buddy
```

## What's new in 1.5

**Buddy hears you better**

With a Deepgram key, Buddy now uses Deepgram to hear your questions as well as to speak its answers. It gets technical words right far more often: "Kafka" and "idempotent" where the Mac's own recognizer heard "Kakkar" and "Eden potent". Before you speak, Buddy tells it which words to expect: the labels on your screen, the terms on the cards it just drew, and the ideas you have been learning, so jargon is expected even when it is not on screen. Hearing costs about a third of a cent for a 20 second question and shows in Spent today. Without a Deepgram key, Buddy uses the Mac's recognizer as before; with one, the Mac's recognizer still listens alongside as a backup in case the connection drops.

**Take your time**

Pausing to think while you hold the keys no longer loses what you said before the pause. And if you let go mid-thought and press again within a minute and a half, before the answer has started, Buddy joins the two halves into one question.

**Long sessions stay in view**

Buddy now remembers the last 40 questions of a session instead of the last 10. Recent answers are kept whole, with their drawings; older ones keep what was said, which keeps long sessions cheap.

**Also in this release**

- Fixed: Buddy could stop responding when the microphone changed under it, for example AirPods connecting or another app taking the mic for a call. It now picks up the new format and keeps listening.
- Spent today now counts answers you cut off with a new question or Esc, and never loses the last few cents of the day when Buddy quits.
- When a word is misheard anyway, Buddy answers what you meant instead of what it heard.
- Long answers folded in the chat no longer draw over the messages below them.

Works on any Mac with macOS 14.2 or later, Apple silicon or Intel. Step-by-step help: [docs/install.md](https://github.com/projects-hacks/buddy/blob/main/docs/install.md).

<sub>For the careful: each update is checked against `Buddy.dmg.sha256` and against the app's signature before it is installed. To check a download by hand, `shasum -a 256 -c Buddy.dmg.sha256` in the folder holding both.</sub>
