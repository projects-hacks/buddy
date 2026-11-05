# Buddy: notes for working on the code

What every source file does, how the app is put together, and the conventions it follows.

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it on-device via Apple Speech, and sends the transcript, a screenshot, and a machine-read index of the screen to Gemini 4 Argon on Vertex AI. The model answers with text that is spoken by the system voice and carries inline tags that draw on screen: circles, boxes, underlines, highlights, strikethroughs, arrows, numbered steps, callouts and spotlight.

This fork replaces the upstream vendors rather than the architecture: Claude becomes Gemini, AssemblyAI becomes Apple Speech on-device, ElevenLabs becomes Deepgram. There is no Cloudflare Worker. Keys live in the macOS Keychain and Vertex authenticates with a gcloud token, so nothing sensitive is in the repository or the binary. Analytics are disabled.

A fully local path remains behind one switch (Ollama plus Kokoro), but its models are not installed by default. It was measured and abandoned as the primary: a 4B reasons well about what is on screen and invents technical facts that are not, naming three different wrong inventors for quicksort across three runs where Argon answered correctly first time.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **Answers**: `gemini-4-argon` on Vertex AI, SSE streaming, authenticated with a gcloud access token so usage bills the project holding the credits. Falls back to Ollama if switched to local.
- **Speech-to-Text**: Deepgram Nova-3 streaming when a Deepgram key is set, with Apple Speech hearing the same audio as a backup; Apple Speech alone otherwise
- **Text-to-Speech**: Deepgram `aura-2-hera-en`, streamed as PCM into `AVAudioEngine` so speech starts about 0.16s after the request. Falls back to Kokoro, then `AVSpeechSynthesizer`.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Screen Index**: Apple Vision text recognition plus the accessibility tree produce a numbered inventory of everything addressable on screen. This is injected into every prompt and is how marks resolve to exact rectangles.
- **Drawing**: the model answers with a JavaScript drawing program in beats (`step`, `say`, then marks). Screen marks name index ids or screenshot pixels; cards are drawn on calm space. See `DrawingEngine/`. The older inline-tag path (`TeacherResponseParser`) still handles an answer that comes back as prose.
- **Lecture audio**: Core Audio process taps (`CATapDescription`, macOS 14.2+) on the front app only, read through a private aggregate device; needs System Audio Recording (`NSAudioCaptureUsageDescription`). See `LectureAudioBuffer.swift`.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: none. `ClickyAnalytics.swift` is an inert no-op surface.

### Where each capability runs

| Need | Service | Auth |
|------|---------|------|
| Vision + reasoning | `gemini-4-argon` on Vertex AI | gcloud access token, cached 50 min |
| Vision + reasoning, alternative | `claude-sonnet-5-5`, thinking off | Keychain |
| Text-to-speech | Deepgram `aura-2-hera-en` | Keychain |
| Speech-to-text | Deepgram Nova-3, Apple Speech as backup and without a key | Keychain / on-device |
| Text recognition | Apple Vision framework | on-device |
| Element rectangles | Accessibility API | on-device |

Vertex rather than AI Studio because only Vertex bills against a Google Cloud
project, which is where trial credits live. An AI Studio key bills its own
account and cannot draw on those credits however it is configured.

Argon ignores `temperature`, `topP` and `topK`, and returns HTTP 400 for
`frequencyPenalty`, `presencePenalty` and `candidateCount`. Reasoning depth is
set through `thinkingConfig.thinkingLevel` instead, and is set to `LOW` because
the answer is spoken while the student waits.

Upstream's Cloudflare Worker and Sparkle updater are removed: keys are each person's own, entered in setup, and releases are disk images on GitHub (docs/releasing.md).

### Build

Always build with `scripts/build-local.sh`. Every flag in it is load-bearing:
a self-signed certificate keeps the designated requirement stable so Screen
Recording and Accessibility grants survive rebuilds, `ENABLE_DEBUG_DYLIB=NO`
and avoids a Team ID mismatch with Xcode's preview dylib. The app links no
third-party packages, so the hardened runtime keeps library validation on:
only Apple's code and Buddy's own can load into it. Diagnostics go to `~/Library/Logs/Buddy.log`, including the
raw model response.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Transient Cursor Mode**: When the cursor overlay is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window, the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1026 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~761 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~40 | The transcription protocol, and a factory that returns the Deepgram-first provider. |
| `DeepgramTranscriptionProvider.swift` | ~320 | Nova-3 over a WebSocket while the keys are held, told the terms to expect (screen labels, recent card labels, recently learned ideas). Apple Speech hears the same audio; its text is used only when Deepgram fails. Costs about $0.009 a minute of speech, recorded in the meter. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Apple's Speech framework, on device, with live partial results for the notch. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~140 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions, and Control + Option + T for typing a question. |
| `ClaudeVisionProvider.swift` | ~470 | Claude brain on the first-party Messages API, used by the Claude and Auto settings with Sonnet or Opus per question (`ClaudeAnswerProfile`). Raced against Argon in `docs/model-choice.md`. |
| `DrawingEngine/` | ~1000 | The tutor answers as a drawing program (`step`/`say` beats plus marks and cards). `draw-engine.js` is our own engine: runs the program, renders hand-drawn shapes with rough.js and tapered pen strokes with perfect-freehand (both MIT, vendored as `draw-vendor-*.js`), and reveals each sentence's strokes across that sentence's audio. `draw-page.html` has no network access. |
| `DrawingOverlay.swift` | ~240 | Click-through full-screen window hosting the engine in a WKWebView, with navigation refused and every URL load blocked. |
| `ProgramStream.swift` | ~160 | Cuts the streaming program into sentences (spoken the moment a `say(...)` closes) and runnable pieces (cut at each `say`/`step` line). |
| `NarrationVoice.swift` | ~280 | Deepgram per sentence: streams the first, downloads each next one while the current plays, reports exact sentence lengths for pen pacing. Falls back to the system voice. |
| `LessonProgramPlayer.swift` | ~150 | Ties stream, voice, engine and notch together for one answer. |
| `TutorProgramPrompt.swift` | ~210 | The cached system prompt (teaching rules and the drawing API) and the per-turn note (time, front app, canvas size, screen text with boxes, length per question kind, and the study notes from memory, practice hints or diagram review). |
| `TutorControlBar.swift` | ~1600 | The notch panel in a fixed clear window that passes the mouse through outside the shape, opened by hover after a short dwell and closed after a grace period: status, the sentence being said, and on hover the last lesson as a paper card or the chat (the day's conversation), with the chat box, follow-ups, Stop and Clear. The panel takes the keyboard only for the chat box and, being non-activating, leaves the studied app frontmost; sending closes the notch and hands the keyboard back. Saves each day's transcript to `~/Library/Application Support/Buddy/Transcripts`. |
| `InterfaceSounds.swift` | ~110 | Short interface sounds made by `scripts/sounds/make_sounds.py` into `Sounds/`: listening and sent on push-to-talk, three key taps when Control + Option + T opens the chat, a water drop when the student opens the notch, a tick on copy, a wipe on Clear or Esc, a low tone on failure. Decorative ones never play over the voice; all respect the Sounds switch and macOS's interface sound setting. |
| `QuestionSorter.swift` | ~190 | First stage of sorting a spoken question into its kind (quick, normal, teach, re-explain, trade-off): macOS's built-in sentence model and the nearest examples in `QuestionKindExamples.json`, returning calibrated probabilities. Decides alone only above 0.95 confidence. Keyword lists in `CompanionManager` are the last fallback. Graded by `scripts/question_sorting/calibrate.py`. |
| `QuestionKindClassifier.swift` | ~80 | Second stage: Claude Haiku with `QuestionSorterPrompt.txt`, asked while the screen is captured and dropped if it is more than 0.35s late. Graded by `scripts/question_sorting/cascade_test.py` on a blind spoken set. |
| `ModelRouter.swift` | ~190 | Under Brain: Auto, picks Sonnet, Opus or Argon per question from `RouteTable.json` (judged quality, time to first word and cost per kind, built by `scripts/route_race/`), weighing every kind by its probability. Ties within the judges' noise go to the cheaper brain. A brain that fails before speaking is benched for five minutes and the next one answers. `scripts/route_race/route_report.py` reads the log for how routing does on real questions. |
| `LearningMemory.swift` | ~580 | What the student has learned across sessions, in `~/Library/Application Support/Buddy/Memory`. Filed after each answer (Haiku names the ideas, matches known ones, writes plain-words cues), recalled during capture as a cascade (on-device shortlist, Haiku chooses, names-only fallback). Latest explanation replaces the old, FSRS forgetting curve decides build on / remind / re-teach, stale ideas archived, vectors re-embedded if the sentence model changes. Graded by `scripts/learning_memory/`. |
| `ConceptIndex.swift` | ~450 | Memory's in-memory index: whole-name and alias matching, how much of the question a concept's words cover, one matrix-vector product for meaning. The shortlist and the names-only fallback both come from here. |
| `LearningMemoryCalls.swift` | ~120 | The two Haiku calls memory makes, with `LessonConceptPrompt.txt` (filing) and `MemoryRecallPrompt.txt` (choosing). |
| `PracticeHints.swift` | ~210 | On LeetCode, HackerRank and similar, help in steps: nudge, approach, walk through, code. Reads the step asked for from what was said, keeps each problem's step on disk, and reads `hintLevel(n)` back from the program. Checked by `scripts/study_modes/`. |
| `GuideMode.swift` | ~230 | Guide mode: a task in an app, one step at a time. The model starts it by ending an answer with `waitForStep("step", "done when")`; `GuideWatcher` then waits for a click, key or scroll, compares a 96x60 grey thumbnail of the screen (Buddy's windows and the pointer left out) with the one the step was given against, and asks again only when it changed. No tokens are spent watching. Caps of 15 steps and 5 minutes. |
| `HowToMemory.swift` | ~470 | Finished walkthroughs kept as how-tos (steps' sentences, control labels, waits) and replayed with no model when the same task is asked in the same app. Matching is on the Mac: a how-to question, a saved phrasing sharing nearly all its words both ways, meaning only as a floor. One Haiku call writes the ways of asking when a how-to is kept (`HowToCuesPrompt.txt`). A control missing on replay hands that step to the model, and the new walkthrough replaces the old. Graded by `scripts/howto/`. |
| `SpendingMeter.swift` | ~180 | What Buddy spent on the student's keys, from each reply's own usage at published prices (`APIPrices`), per day in `spending.json`, shown as Spent today in Settings. Only listens; never on an answer's path. |
| `DiagramReview.swift` | ~70 | When the student is drawing their own design (Excalidraw, draw.io, Miro, Freeform...), a peer's review: their boxes marked by id, proposals drawn with `suggest()` beside them, no score. |
| `LectureMode.swift` | ~225 | Lecture mode, with no switch: when the student asks while a video lecture is in front, the tutor gets the lecturer's last minute as a study note. Transcript first (YouTube's caption track, then a transcript panel in the page, then one recognised on screen), placed by the playback time; the front app's buffered sound as the fallback; nothing during an advert, for an excluded app, or when no words are found. Gathers during capture and waits at most 3 s from the question. Asks for System Audio Recording once, at the first question where the sound would have helped. |
| `LectureModeCore.swift` | ~700 | Lecture mode's parts that touch nothing on the Mac, tested by `scripts/lecture_mode/`: playback time from "12:34 / 48:10" or a seek bar's description, finding a timestamped transcript among page texts or screen lines, the call, meeting and music exclusions, the gate on when the sound may be sent (a player's time, or a question about what was said), the minute before a time, the note (under 1500 characters), and the 90 s ring buffer with its 16 kHz downsampler. |
| `LecturePageReader.swift` | ~200 | Reads the front window's accessibility tree for lecture mode: the page's address (web area or address bar), the seek bar's time, transcript lines, advert words. Bounded to 6000 elements and 1.2 s, skips YouTube's comments and recommendations, and turns on Chromium's page tree with `AXManualAccessibility`. |
| `YouTubeCaptions.swift` | ~260 | The caption tracks listed in a watch page's `ytInitialPlayerResponse`, the best one chosen (human captions in the spoken language, then auto-generated), fetched as json3, cached per video for the session. YouTube now withholds the track body without a proof-of-origin token, which Buddy does not imitate, so this usually ends as "withheld" and the page's transcript panel or the sound is used. |
| `LectureAudioBuffer.swift` | ~590 | The sound fallback: a Core Audio process tap on the front app and its helper processes only (never the microphone), started only after the permission was asked once and only while that app plays and is not a call (any app using a microphone counts as one), a meeting or a music app. Keeps the last 90 s in memory, empties it on every app switch, stops tapping an app whose sound arrives as silence, rebuilds the tap when the default output device changes. Only the newest 65 s are transcribed, and only for a lecture question (`LectureAudioGate`): by Deepgram Nova-3 prerecorded (recorded in the meter at $0.0077 a minute of audio sent) or Apple Speech on the Mac. |
| `SetupWindow.swift` | ~720 | First-run setup for anyone who downloads Buddy: name, keys (Anthropic; Gemini by API key or Google Cloud project; Deepgram), permissions, how to start. Reopened from Settings and when a key fails mid-use. A real window, since the notch never takes the keyboard. |
| `APIKeyChecker.swift` | ~200 | Tests a key with the smallest real request each service accepts and turns failures (wrong key, no credit, wrong field, quota, network) into one sentence with the fix. The same reading flags keys that stop working mid-use. |
| `AppUpdater.swift` | ~300 | Daily check of GitHub's latest release; on Update downloads the disk image, verifies its published checksum and that the app inside satisfies this app's own designated requirement (same identifier, same certificate), then a shell helper swaps it in after quit and relaunches. Never automatic on a debug build. |
| `AppIdentity.swift` | ~40 | Where Buddy keeps its things (Keychain names, data folder, log), derived from the bundle identifier, so a copy under another identifier starts empty and never touches Buddy's own. |
| `QAHooks.swift` | ~170 | Debug builds only, off unless switched on: a control channel for scripted end-to-end tests (ask, snapshot, state, fake key, setup steps), driven by `scripts/qa/`. |
| `kokoro_speech_server.py` | ~120 | The Local voice's helper, shipped inside the app and run with uv, so it is found on any Mac. Overridable with the `kokoroHelperScriptPath` default. |
| `OllamaVisionProvider.swift` | ~250 | Local vision chat client. Mirrors `ClaudeAPI`'s method surface so the two are swappable. Parses newline-delimited JSON, not SSE. Handles server probing and model preload. |
| `ScreenIndex.swift` | ~390 | Numbered inventory of on-screen targets from Vision text recognition and the accessibility tree. Recognition runs off the main actor. Renders the listing for prompts and resolves ids back to exact rectangles. |
| `TeacherResponseParser.swift` | ~330 | Splits a response into spoken text and drawing directives, recording each tag's character offset so marks sync to speech. Also releases complete sentences for progressive speech. |
| `TeacherAnnotationLayer.swift` | ~340 | SwiftUI rendering of every mark: hand-drawn circles, boxes, underlines, highlights, strikethroughs, curved arrows, step badges, callouts, and the spotlight scrim. |
| `LocalSpeechSynthesisClient.swift` | ~175 | On-device TTS. Picks the best installed English voice and reports word boundaries, which is what drives mark timing. |
| `DesignSystem.swift` | ~880 | Design system tokens, colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~55 | Inert. Same static surface, every method a no-op, so nothing is transmitted. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |

## Build & Run

```bash
zsh scripts/build-local.sh          # builds, signs, installs /Applications/Buddy.app, relaunches
zsh scripts/make-release.sh 1.2     # the downloadable disk image, see docs/releasing.md
```

Build only through these scripts. They run `xcodebuild` with the `Clicky Local Dev` certificate, which is what keeps macOS's Screen Recording and Accessibility grants across builds; a plain `xcodebuild` or an Xcode build signs differently and the grants have to be given again.

Known non-blocking warnings: Swift 6 concurrency warnings, the deprecated onChange in OverlayWindow.swift. Do not try to fix these.

**Testing.** `scripts/` holds every test and measurement, each with its own readme: memory, routing, question sorting, hints and diagram review, plus `scripts/qa/` for end-to-end runs of the real app through the debug-only QA channel (`QAHooks.swift`).

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not build with plain `xcodebuild` or Xcode: use scripts/build-local.sh, or the permissions reset

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
