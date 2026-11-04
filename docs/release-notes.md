Buddy 1.1, for Macs on macOS 14.2 or later, now on both Apple silicon and Intel.

**Install:** download `Buddy-1.1.dmg`, drag Buddy into Applications, and open it. macOS asks once before opening an app that is not notarized: open System Settings > Privacy & Security and click Open Anyway. Full steps in [docs/install.md](https://github.com/projects-hacks/study-buddy/blob/main/docs/install.md). Updating from 1.0 keeps your keys, permissions and memory.

**New**

- The notch says what the wait is spent on: "reading your screen", then "thinking", and which model is answering
- Esc closes the notch, then clears the drawing
- Starting Buddy at login is now your choice, in setup and in Settings, instead of happening on its own
- Buddy's name shows as Buddy in System Settings and in permission prompts

**Fixed**

- The setup window could open behind the app in front, so it was never seen
- The open notch could sit underneath a drawing's cards, and old drawings covered the setup window
- Labels in a drawing could pile up on each other, and cards cut off boxes at their right edge
- A rejected Anthropic key now goes straight to Gemini instead of trying the second Claude model first, and the notch banner clears once the key works again
- Asking without Screen Recording now says what to allow and opens that step, instead of a general error
- Haiku's question sorting and memory recall now stop at their deadline instead of sometimes delaying the answer, and memory gets enough time to recall an earlier lesson
- Learning memory could fail to file a long lesson; it now keeps every idea it could read
- Testing a Google Cloud project now checks the project itself, not only the gcloud sign-in, and never freezes the window
- The Gemini key travels in a header, never in a URL
- Several memory edge cases found in review: a crash when ideas were filed before macOS had its sentence model, forgetting that could come back, and an "I didn't follow" that could mark the wrong lesson

Verify the download with the `.sha256` file attached: `shasum -a 256 -c Buddy-1.1.dmg.sha256`.
