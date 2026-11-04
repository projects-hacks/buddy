The first downloadable Buddy, for Macs with Apple silicon on macOS 14.2 or later.

**Install:** download `Buddy-1.0.dmg`, drag Buddy into Applications, and open it. macOS asks once before opening an app that is not notarized: open System Settings > Privacy & Security and click Open Anyway. Full steps in [docs/install.md](https://github.com/projects-hacks/clicky-studdy/blob/main/docs/install.md).

**Bring your own keys:** an Anthropic key (recommended), and optionally a Gemini key and a Deepgram key. Setup tests each one as you paste it.

**In this release**

- Explains out loud while drawing on your screen, in step with the voice
- Lives in the notch, with your words live as you speak, the last lesson and the day's transcript
- Auto picks Claude Sonnet, Claude Opus or Gemini Argon per question, from measured quality, wait and cost
- Learning memory: answers build on what you learned in earlier sessions, kept on your Mac
- Hints before answers on LeetCode, HackerRank and similar
- Reviews your own diagrams as a peer, with suggestions drawn beside your boxes
- First-run setup with tested keys, and clear messages when a key stops working

Verify the download with the `.sha256` file attached: `shasum -a 256 -c Buddy-1.0.dmg.sha256`.
