# Buddy: notes for working on the code

What every source file does, how the app is put together, and the conventions it follows.

## Overview

macOS study helper that lives in the notch (no dock icon, no menu bar icon, no main window). Hovering the notch opens its panel: the last lesson, the chat, Settings. Push-to-talk (Control + Option) captures the question, Deepgram or Apple Speech transcribes it, and the transcript, a screenshot and a machine-read index of the screen go to the brain chosen per question (Sonnet, Opus or Argon under Auto). The model answers with a drawing program that is spoken sentence by sentence and drawn on the screen as it is said; an answer that comes back as prose is spoken with inline tags that mark the screen instead.

This fork replaces the upstream vendors rather than the architecture: Claude becomes Gemini, AssemblyAI becomes Apple Speech on-device, ElevenLabs becomes Deepgram. There is no Cloudflare Worker. Keys live in the macOS Keychain and Vertex authenticates with a gcloud token, so nothing sensitive is in the repository or the binary. Analytics are disabled.

A fully local path remains behind one switch (Ollama plus Kokoro), but its models are not installed by default. It was measured and abandoned as the primary: a 4B reasons well about what is on screen and invents technical facts that are not, naming three different wrong inventors for quicksort across three runs where Argon answered correctly first time.

## Architecture

- **App Type**: `LSUIElement=true`, no dock icon or main window; everything is in the notch panel and the windows it opens (setup, Notebook, Map)
- **Framework**: SwiftUI (macOS native) with AppKit bridging for the notch panel, the cursor overlay and the drawing window
- **Pattern**: one `ObservableObject` root, `CompanionManager`, that the views observe; the parts it is made of are their own types, and it forwards their changes (see Code layout below)
- **Answers**: `gemini-4-argon` on Vertex AI, SSE streaming, authenticated with a gcloud access token so usage bills the project holding the credits. Falls back to Ollama if switched to local.
- **Speech-to-Text**: Deepgram Nova-3 streaming when a Deepgram key is set, with Apple Speech hearing the same audio as a backup; Apple Speech alone otherwise
- **Text-to-Speech**: Deepgram `aura-2-hera-en`, streamed as PCM into `AVAudioEngine` so speech starts about 0.16s after the request. Falls back to Kokoro, then `AVSpeechSynthesizer`.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Screen Index**: Apple Vision text recognition plus the accessibility tree produce a numbered inventory of everything addressable on screen. This is injected into every prompt and is how marks resolve to exact rectangles.
- **Drawing**: the model answers with a JavaScript drawing program in beats (`step`, `say`, then marks). Screen marks name index ids or screenshot pixels; cards are drawn on calm space. See `Drawing/DrawingEngine/`. The older inline-tag path (`Drawing/ProsePath/`, `TeacherResponseParser`) still handles an answer that comes back as prose.
- **Lecture audio**: Core Audio process taps (`CATapDescription`, macOS 14.2+) on the front app only, read through a private aggregate device; needs System Audio Recording (`NSAudioCaptureUsageDescription`). See `Lecture/LectureAudioBuffer.swift`.
- **Teaching board**: "teach me X from scratch" turns the whole display into paper and teaches on it over several turns, with the notch saying "On the board", a "Today's board" card of parts and one dark bar (Leave board). The model emits `board.*` operations against a board kept in Swift (`BoardState`); layout is computed on the Mac (`BoardLayout`), and each piece's board calls are replaced by exact strokes before the engine runs it. See `Drawing/Board/TeachingBoardSession.swift` and `scripts/board/`.
- **Teach it back**: "let me explain X back to you" opens the same board titled "You explain: X" and listens hands free (no keys, a visible red meter, ends on "I'm done", Return, eight quiet seconds or three minutes). One call draws only what the student said in their purple ink (`BoardInk.student`), wrong claims as stated; a second call marks the gaps on it in dashed red (`BoardInk.gap`), at most four, while the board refuses any change to the student's drawing. What they got right strengthens those ideas in memory and what they missed counts as lost. See `TeachBack/TeachBackSession.swift` and `scripts/teach_back/`.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: none. Nothing is transmitted about how Buddy is used.

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

### Code layout

The sources are grouped into one folder per feature under `leanring-buddy/` (the Key Files table below lists every file). Both `leanring-buddy/` and `leanring-buddyTests/` are file-system synchronized groups in the Xcode project, so a Swift file added or moved anywhere under them is compiled with no project edit. Resources are flattened into `Contents/Resources` and loaded by name (`Bundle.main.url(forResource:withExtension:)`), so a resource can live in any folder as long as no two share a name; a clash fails the build with "Multiple commands produce". `Info.plist` and `leanring-buddy.entitlements` stay at the top because build settings name them by path. Scripts under `scripts/` read sources and prompts by their paths, so a move updates them in the same commit.

`CompanionManager` is the composition root and the only object the views observe (`SetupWindow`, `CompanionPanelView`, `OverlayWindow`, `QAHooks`, the app delegate). It owns the parts below and wires them in `start()`; where a part publishes state a view reads, the manager forwards that part's `objectWillChange` and exposes the state under its old name, so the views did not change when the parts were split out.

| Part | Owns |
|------|------|
| `BrainLineup` (`Answering/`) | The Brain setting, the brains, how Argon is reached, the probes, routing, the key problem |
| `PermissionMonitor` (`Settings/`) | The four permissions and the 1.5 s poll the manager's periodic work runs on |
| `TalkSessionCoordinator` (`VoiceIn/`) | One press of the talk keys: the wait, the early screen, the pointer, the microphone |
| `ConversationHistory` (`Answering/`) | The exchanges sent to the model and the re-explanation count |
| `QuestionTicket` (`Answering/`) | Which question and which attempt are live, and the answer task |
| `ProseSpeechQueue` (`VoiceOut/`) | The prose path's sentence queue and the three voice engines |
| `MarkCoordinator` (`Drawing/ProsePath/`) | The prose path's marks, spotlight, board, reveal and pointing |
| `GuideCoordinator` (`Guide/`) | A guided task's step, baseline and app, the watcher, how-tos and a replay |

The question path itself (`CompanionManager+Pipeline.swift`, one long `sendTranscriptToTutorWithScreenshot`) stays on the manager: it reads and writes nearly every part above in a fixed order, so moving it into a type of its own would mean passing the manager in, which separates nothing. The manager's other behaviour is in `CompanionManager+*.swift` extension files, one responsibility each, because an extension cannot hold stored properties; members those files share are internal rather than private for the same reason.

### Build

Always build with `scripts/build-local.sh`. Every flag in it is load-bearing:
a self-signed certificate keeps the designated requirement stable so Screen
Recording and Accessibility grants survive rebuilds, `ENABLE_DEBUG_DYLIB=NO`
and avoids a Team ID mismatch with Xcode's preview dylib. The app links no
third-party packages, so the hardened runtime keeps library validation on:
only Apple's code and Buddy's own can load into it. Diagnostics go to `~/Library/Logs/Buddy.log`, including the
raw model response.

### Key Architecture Decisions

**Notch Panel**: The notch is a fixed, clear, non-activating `NSPanel` that passes the mouse through outside its shape, opened by hover after a short dwell and closed after a grace period (`Notch/TutorControlBar.swift`). Being non-activating, it leaves the studied app frontmost, and it takes the keyboard only for the chat box. Settings is its gear tab; there is no menu bar icon.

**Cursor Overlay**: A full-screen transparent window per screen hosts the blue cursor companion (`Drawing/ProsePath/OverlayWindow.swift`). It's non-activating, joins all Spaces, and never steals focus. The cursor, its waveform and spinner, pointing, and the prose path's marks and board render in it via SwiftUI through `NSHostingView`. Drawing programs are drawn in a separate click-through window (`Drawing/DrawingOverlay.swift`).

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Transient Cursor Mode**: When the cursor overlay is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

Paths are under `leanring-buddy/`, grouped by folder. Prompts (`*.txt`), `QuestionKindExamples.json` and `RouteTable.json` sit beside the code that loads them; `Info.plist`, the entitlements and `Assets.xcassets` stay at the top, since build settings name them by path.

### App/

Launch, identity, the log, the updater, system events.

| File | Lines | Purpose |
|------|-------|---------|
| `App/AppIdentity.swift` | ~69 | Where Buddy keeps its things (Keychain names, data folder, log), derived from the bundle identifier, so a copy under another identifier starts empty and never touches Buddy's own. |
| `App/AppUpdater.swift` | ~310 | Daily check of GitHub's latest release, always (there is no switch); on Update downloads the disk image, verifies its published checksum and that the app inside satisfies this app's own designated requirement (same identifier, same certificate), then a shell helper swaps it in after quit and relaunches. Never automatic on a debug build. |
| `App/SystemEventsObserver.swift` | ~37 | Sleep, wake and display changes in one observer, handed to `CompanionManager`: sleep stops the answer and listening, wake rebuilds the output audio engines and the key taps and probes the brain again, a display change rebuilds the cursor overlay and ends a guide or marks on a display that is gone. |
| `App/TutorDebugLog.swift` | ~230 | Appends diagnostics to `~/Library/Logs/Buddy.log` (local only), with the uncaught exception logger and the main thread watchdog. |
| `App/leanring_buddyApp.swift` | ~130 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which starts `CompanionManager`. No main window and no menu bar icon: the app lives in the notch. |

### Companion/

`CompanionManager`, the root the views talk to, split by responsibility.

| File | Lines | Purpose |
|------|-------|---------|
| `Companion/CompanionManager+Brains.swift` | ~140 | The brains as the views reach them, forwarded from `BrainLineup`, and what a key change touches beyond them: setup's finish, the student's name, the notch's answered-by. |
| `Companion/CompanionManager+Debug.swift` | ~97 | Debug builds only: the QA channel's entry points (`QAHooks`) and the file triggers in `~/Library/Logs`. |
| `Companion/CompanionManager+Guide.swift` | ~150 | Guide mode's next step and the replay of a kept how-to with no model, on `GuideCoordinator`'s state. |
| `Companion/CompanionManager+Interruptions.swift` | ~86 | Stop, Esc, sleep, wake and display changes. |
| `Companion/CompanionManager+Marks.swift` | ~310 | The prose path's marks forwarded from `MarkCoordinator`, the drawing program's marks kept on their items (`MarkFollower`), what clears them (scroll, app switch, Esc, Clear), the cursor switch, transient hide, and the calibration capture. |
| `Companion/CompanionManager+Notch.swift` | ~180 | What the notch, the Map and the Notebook ask of Buddy: the alert row's needs, opening the notch briefly, the Map, the Notebook's buttons, the start tiles, the updater's banner, forgetting memory. |
| `Companion/CompanionManager+Permissions.swift` | ~66 | The permissions forwarded from `PermissionMonitor`, and the work on its 1.5 s tick: the notch's needs, the debug file triggers and the brain probe. |
| `Companion/CompanionManager+Pipeline.swift` | ~1100 | One question from release to the last sentence: capture (or the early screen), sorting, recall, lecture notes, routing, the attempt loop with first-words deadline and stall detection, the program or prose answer, and what is kept of it (history, memory, how-tos, notebook). Also board turns, replay of the last answer, and the spoken failures. `tutorSystemPrompt` is the prose path's old prompt, kept because `scripts/experiments/brain_race.py` reads it. |
| `Companion/CompanionManager+QuestionKind.swift` | ~240 | The question's kind and how much room its answer gets: waiting on the classifier within its grace, the keyword fallback (read by `scripts/question_sorting/sort_test.py`) and the answer budgets (read by `brain_race.py`). |
| `Companion/CompanionManager+Speech.swift` | ~47 | Connects `ProseSpeechQueue` to the notch, the voice state and the marks; clearing the voice for a new answer. |
| `Companion/CompanionManager+Talk.swift` | ~310 | The talk keys' transitions (setup's shortcut trial, teach-back, error offer, then `TalkSessionCoordinator`), what a press clears before listening, the typed question, the dictation state bound to the voice state, and talking over an answer. |
| `Companion/CompanionManager.swift` | ~460 | The composition root the views talk to (`@ObservedObject`). Holds the stored state and the parts below it (`BrainLineup`, `PermissionMonitor`, `ProseSpeechQueue`, `MarkCoordinator`, `TalkSessionCoordinator`, `GuideCoordinator`, `QuestionTicket`, `ConversationHistory`, the notch, drawing overlay, lesson player, teaching board, memory, notebook and error offer), wires them in `start()` and forwards their changes to the views, which read everything through the manager. What it does is in the extension files beside it. |

### Notch/

The notch panel and its Lesson tab.

| File | Lines | Purpose |
|------|-------|---------|
| `Notch/NotchLessonTab.swift` | ~790 | The open notch's Lesson tab: the one alert row (permission, key, sign-in with Copy command, update), the error card while the glow is live with the last lesson folded under it, the empty day's three start tiles built from memory and the Notebook, and the last-lesson paper card (eyebrow with time and app, Replay or Stop, Open in Notebook, Copy, Builds on chip to the Map, answer folded at five lines, the model's follow-ups then Teach it back and Go deeper). |
| `Notch/TutorControlBar.swift` | ~2120 | The notch panel in a fixed clear window that passes the mouse through outside the shape, opened by hover after a short dwell and closed after a grace period. Closed, one thing per side: status (dot and word, a mic glyph while talk-over listens, amber needs-you words for a failed key, expired sign-in or missing permission) and the lesson, "Buddy paused", the error's app or "lecture at 12:40"; a small lecture glyph whenever the front app's sound is kept. Open: labelled Lesson and Chat tabs, Notebook and Map buttons, the gear; the chat box (Command 1, 2 and comma switch tabs, Return on an empty box explains an offered error), Stop and Clear. The model carries every state the views read. The panel takes the keyboard only for the chat box and, being non-activating, leaves the studied app frontmost. Saves each day's transcript to `~/Library/Application Support/Buddy/Transcripts`. |

### VoiceIn/

Push-to-talk, transcription and talking over an answer.

| File | Lines | Purpose |
|------|-------|---------|
| `VoiceIn/AppleSpeechTranscriptionProvider.swift` | ~200 | Apple's Speech framework, on device, with live partial results for the notch. |
| `VoiceIn/BuddyAudioConversionSupport.swift` | ~110 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `VoiceIn/BuddyDictationManager.swift` | ~800 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, the keyboard dictation session, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `VoiceIn/BuddyTranscriptionProvider.swift` | ~49 | The transcription protocol, and a factory that returns the Deepgram-first provider. |
| `VoiceIn/DeepgramTranscriptionProvider.swift` | ~360 | Nova-3 over a WebSocket while the keys are held, told the terms to expect (screen labels, recent card labels, recently learned ideas). Apple Speech hears the same audio; its text is used only when Deepgram fails. Costs about $0.009 a minute of speech, recorded in the meter. |
| `VoiceIn/GlobalPushToTalkShortcutMonitor.swift` | ~390 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions, and Control + Option + T for typing a question. |
| `VoiceIn/TalkOverHearing.swift` | ~440 | The reading half of talk-over, pure so `scripts/talk_over/` checks it offline. `TalkOverTranscript` keeps the last eight seconds of heard words with the times they arrived, takes out runs that follow Buddy's recent sentences in order while their echo can still arrive, pauses Buddy at once on a cue among the student's words (wait, hold on, but why), and judges the student's words as one utterance once the student, not Buddy, has paused. |
| `VoiceIn/TalkOverListener.swift` | ~330 | Talking over an answer without the keys: the microphone is open only while an answer plays (Talk over Buddy in Settings, on by default), shown by the notch's mic glyph, on a fresh engine with the tap rebuilt on format changes, and never on a Bluetooth headset. `TalkOverHearing` reads what was heard: a question (loud enough, addressed to Buddy, short, not an echo of the last three sentences) cuts the answer off; hold on, go on, slower and go back control it. Deepgram when a key is set (about $0.009 a minute, in the meter), Apple Speech otherwise. |
| `VoiceIn/TalkSessionCoordinator.swift` | ~230 | One press of the talk keys: the 0.2 s wait that lets Control + Option + T become typing, the screen read and pointer watched while the student talks, the microphone, handing over the question with its early screen and what "this" pointed at, and taking a press back. Also `speechHints`, the words Deepgram is told to expect. |

### VoiceOut/

Voices and interface sounds (`Sounds/`).

| File | Lines | Purpose |
|------|-------|---------|
| `VoiceOut/DeepgramSpeechClient.swift` | ~360 | Deepgram Aura streamed as linear16 PCM into `AVAudioEngine` as it arrives, about 0.16 s to first audio. |
| `VoiceOut/InterfaceSounds.swift` | ~110 | Short interface sounds made by `scripts/sounds/make_sounds.py` into `Sounds/`: listening and sent on push-to-talk, three key taps when Control + Option + T opens the chat, a water drop when the student opens the notch, a tick on copy, a wipe on Clear or Esc, a low tone on failure. Decorative ones never play over the voice; all respect the Sounds switch and macOS's interface sound setting. |
| `VoiceOut/KokoroSpeechClient.swift` | ~430 | The local neural voice through the long-lived `kokoro_speech_server.py` helper; falls back to the system voice on any failure. |
| `VoiceOut/LocalSpeechSynthesisClient.swift` | ~280 | On-device TTS. Picks the best installed English voice and reports word boundaries, which is what drives mark timing. |
| `VoiceOut/NarrationVoice.swift` | ~610 | Deepgram per sentence: streams the first, downloads each next one while the current plays, reports exact sentence lengths for pen pacing. Falls back to the system voice. Pauses and resumes mid-sentence, says the last sentence again, and slows the rest of an answer (Aura's `speed` for sentences not yet fetched, a pitch-keeping time stretch for audio already downloaded). Restarts its engine after an audio device change instead of playing into a stopped one. |
| `VoiceOut/ProseSpeechQueue.swift` | ~340 | The prose path's voice: complete sentences cut from the stream, queued and spoken one after another by the session's engine (Deepgram, Kokoro with a one-sentence lookahead, or the system voice) under a 45 s ceiling each, each sentence's marks handed back as its words are said. Owns the three engines. |
| `VoiceOut/kokoro_speech_server.py` | ~120 | The Local voice's helper, shipped inside the app and run with uv, so it is found on any Mac. Overridable with the `kokoroHelperScriptPath` default. |

### Screen/

Capture, the screen index, the early capture and what "this" means.

| File | Lines | Purpose |
|------|-------|---------|
| `Screen/CompanionScreenCaptureUtility.swift` | ~140 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `Screen/EarlyScreenCapture.swift` | ~230 | Captures and indexes the screen while the talk keys are held, into its own `ScreenIndex`, so only the work that needs the words is left after release. At release it is checked against the screen (app and window in front, display under the pointer, guide mode's 96x60 thumbnail) and thrown away if anything moved; a capture no question claims (a tap, Control + Option + T, Esc, nothing heard) is dropped, and nothing is kept on disk. |
| `Screen/ScreenIndex.swift` | ~800 | Numbered inventory of on-screen targets from Vision text recognition and the accessibility tree. Pieces of one line that recognition split (same baseline and height, about a word apart) are listed as one line. Recognition runs off the main actor. Renders the listing for prompts and resolves ids back to exact rectangles. |
| `Screen/StudentPointing.swift` | ~230 | What "this" means: text selected in the app in front (accessibility, with its bounds when given), or the listed screen item the pointer rested on for 0.4s or more while the keys were held, as one line of the turn note. Nothing is added when neither is there, so the note is unchanged. |

### Answering/

The brains, routing, the question's kind, the prompts, the conversation.

| File | Lines | Purpose |
|------|-------|---------|
| `Answering/BrainLineup.swift` | ~350 | Who can answer and who does: the Brain setting, the Argon, Claude and local brains, how Argon is reached (key or Google Cloud), `checkGoogleCloud`, the brain probes (at start, every twelve seconds until it answers, after a key change and after waking), routing a question under Auto through `ModelRouter`, and the key that stopped working mid-use with its notch message. |
| `Answering/ClaudeVisionProvider.swift` | ~500 | Claude brain on the first-party Messages API, used by the Claude and Auto settings with Sonnet or Opus per question (`ClaudeAnswerProfile`). Raced against Argon in `docs/model-choice.md`. |
| `Answering/ConversationHistory.swift` | ~120 | The conversation kept for the model: the last ten answers whole, older ones as only what was said, at most 40 exchanges, shortened and trimmed six at a time so the cached history holds still. Also the push-back phrases and the escalating re-explanation instruction. A value type, tested. |
| `Answering/DiagramReview.swift` | ~67 | When the student is drawing their own design (Excalidraw, draw.io, Miro, Freeform...), a peer's review: their boxes marked by id, proposals drawn with `suggest()` beside them, no score. |
| `Answering/GeminiVisionProvider.swift` | ~570 | Argon on Vertex (gcloud access token, cached 50 minutes) or AI Studio (key), SSE streaming, `thinkingLevel` LOW. |
| `Answering/ModelRouter.swift` | ~200 | Under Brain: Auto, picks Sonnet, Opus or Argon per question from `RouteTable.json` (judged quality, time to first word and cost per kind, built by `scripts/route_race/`), weighing every kind by its probability. Ties within the judges' noise go to the cheaper brain. A brain that fails before speaking is benched for five minutes and the next one answers. `scripts/route_race/route_report.py` reads the log for how routing does on real questions. |
| `Answering/OllamaVisionProvider.swift` | ~400 | Local vision chat client. Mirrors `ClaudeAPI`'s method surface so the two are swappable. Parses newline-delimited JSON, not SSE. Handles server probing and model preload. |
| `Answering/PracticeHints.swift` | ~220 | On LeetCode, HackerRank and similar, help in steps: nudge, approach, walk through, code. Reads the step asked for from what was said, keeps each problem's step on disk, and reads `hintLevel(n)` back from the program. Checked by `scripts/study_modes/`. |
| `Answering/QuestionKindClassifier.swift` | ~80 | Second stage: Claude Haiku with `QuestionSorterPrompt.txt`, asked while the screen is captured and dropped if it is more than 0.35s late. Graded by `scripts/question_sorting/cascade_test.py` on a blind spoken set. |
| `Answering/QuestionSorter.swift` | ~220 | First stage of sorting a spoken question into its kind (quick, normal, teach, re-explain, trade-off): macOS's built-in sentence model and the nearest examples in `QuestionKindExamples.json`, returning calibrated probabilities. Decides alone only above 0.95 confidence. Keyword lists in `CompanionManager+QuestionKind.swift` are the last fallback. Graded by `scripts/question_sorting/calibrate.py`. |
| `Answering/QuestionTicket.swift` | ~46 | Which question is being answered, the task answering it, and which try at it is live, so an answer that was replaced writes nothing and a brain given up on at its deadline is not heard. |
| `Answering/TutorBrain.swift` | ~81 | The protocol every brain implements (streaming answer, probe, preload), so nothing downstream knows which one answered. |
| `Answering/TutorProgramPrompt.swift` | ~220 | The cached system prompt (teaching rules and the drawing API) and the per-turn note (time, front app, canvas size, screen text with boxes, length per question kind, and the study notes from memory, practice hints or diagram review). |

### Drawing/

The drawing engine and the window it runs in, the stream, the lesson player and marks that follow their items.

| File | Lines | Purpose |
|------|-------|---------|
| `Drawing/DrawingEngine/` | ~2150 | The tutor answers as a drawing program (`step`/`say` beats plus marks and cards). `draw-engine.js` is Buddy's own engine: runs the program, renders hand-drawn shapes with rough.js and tapered pen strokes with perfect-freehand (both MIT, vendored as `draw-vendor-*.js`), and reveals each sentence's strokes across that sentence's audio. Screen marks go into one anchor group per marked item, which the app moves and fades (`placeAnchors`); arrows between items are drawn again from both ends, a card is moved off any marked item under it, and underlines and rings stay inside the gap to the neighbouring listed lines, so small text is not struck through. `draw-page.html` has no network access. |
| `Drawing/DrawingEngine/draw-board.js` | ~710 | Draws the board with the engine's own pen (`BuddyEngine.boardKit`): full-screen dot-grid paper, title and current part, the "Today's board" card, the dark bottom bar with Leave board, and the commands from `TeachingBoard`, each a mark of the sentence before it. For teach it back (`setTeachBack`, `setLevel`): the invitation under the title, the student's purple and the gaps' dashed red, persistent red rings, and the bar's phases (the live meter with Listening, I'm done and Cancel; Fill the gaps and Try again after). |
| `Drawing/DrawingOverlay.swift` | ~600 | Click-through full-screen window hosting the engine in a WKWebView, with navigation refused and every URL load blocked. Takes the keyboard only while teach-back listens (`takeKeyboard`), for Return and Esc, and passes the teach-back bar's buttons on. |
| `Drawing/LessonProgramPlayer.swift` | ~320 | Ties stream, voice, engine and notch together for one answer, and passes the talk-over requests to the voice. Keeps the last heard answer in memory (`AnswerRecording`: its program, each sentence's audio, the boxes it drew on and a thumbnail of the screen) and replays it with no model or speech request, leaving out marks on the screen's content when the screen has changed. |
| `Drawing/MarkFollower.swift` | ~550 | Keeps an answer's marks on their items: follows the window's frame as it is dragged or resized (accessibility notifications), moves marks with a trackpad scroll and, 200 ms after it stops, captures only that window and finds each marked item's text again near where it should be (`MarkRefinding`: a unique copy anywhere, of several only the nearest and only if near), fading marks whose item left view and bringing them back. Hides marks while the window is covered, on another Space or hidden. No model; nothing runs while nothing moves. |
| `Drawing/ProgramStream.swift` | ~180 | Cuts the streaming program into sentences (spoken the moment a `say(...)` closes) and runnable pieces (cut at each `say`/`step` line). |

### Drawing/Board/

The teaching board.

| File | Lines | Purpose |
|------|-------|---------|
| `Drawing/Board/BoardIntent.swift` | ~210 | Whether a question opens the board (a named topic from scratch, from zero or on a whiteboard, nothing pointing at the screen) and whether one closes it. Graded by `scripts/board/intent_test.swift`. |
| `Drawing/Board/BoardLayout.swift` | ~910 | Where things go, decided on the Mac: words measured in the engine's own Noteworthy, sizes per kind, placement into free space without moving anything, first where the paper shows without zooming, then where the smallest zoom shows (so the board grows sideways before it scrolls); groups that grow only into free space; arrows routed around elements and never off the drawing area, drawn as two numbered stubs when they would cross the board; labels that touch nothing, shortened or left off when there is no clear place. |
| `Drawing/Board/BoardProgramPrompt.swift` | ~160 | The board's own cached system prompt (the normal one is untouched) and its small turn note: board listing, length, the question. |
| `Drawing/Board/BoardProgramTranslator.swift` | ~550 | Reads the literal `board.*(...)` calls in a program piece, applies them through `TeachingBoard`, and replaces each in place with `BuddyBoard.apply([...])`, so the strokes stay with the sentence before them. Unreadable calls are reported, not run. Also teach-back's `missing`, `missingLink`, `wrong` and `verdict`. |
| `Drawing/Board/BoardState.swift` | ~300 | What is on the board across turns: elements with stable ids (box, circle, label, note, list, table, group), arrows, which turn added each, the view, and `compactListing()`, the ids-and-words turn note the model edits the board from. For teach it back, whose pen drew each thing (`BoardInk`: student or gap) and what a correction corrects, both in the listing. Codable. |
| `Drawing/Board/TeachingBoard.swift` | ~1080 | Applies a `BoardOperation` to `BoardState` and returns `BoardDrawCommand`s, the exact strokes for `draw-board.js`. Adding an id that exists updates it, so the model cannot redraw. Teach it back: `inkForNewMarks` is the pen for what is added; `markWrong` rings an element or arrow in red and writes the correction beside it; while the gap pen is on, any change to the student's drawing is refused, a mark reusing one of their ids gets a fresh one, and at most four gaps are marked; `removeGapMarks` clears them for a second go. On a teach-back board no arrow crosses an element (stubs instead), the student's arrows move other labels aside, an arrow whose words do not fit is tried as stubs, a correction is placed touching its ring and a missing part close beside the element it names. Closes up empty bands when the board would scroll, and slides a new element beside the old one it is linked to. Also `BoardSurface`, where paper, title, parts card and bar sit on a screen. |
| `Drawing/Board/TeachingBoardSession.swift` | ~660 | The teaching board's lifecycle: opened by `BoardIntent` (or by `TeachBackIntent` for teach it back, which it hosts), answers every question while open (board turns routed as teach questions, no screenshot, learning memory's recall in the turn note, played by the shared `LessonProgramPlayer` with each piece's board calls translated first). The overlay takes the mouse while it is open; the notch shows "On the board" (`TutorControlBarModel.isBoardOpen`). Esc stops a sentence, then leaves; "done", Leave board or ten idle minutes leave with a fade, and the whole board lesson is filed into memory as one lesson and kept in the Notebook as one page (`keepBoardInNotebook`). `playBoardAnswer` plays one answer on the board for a lesson turn and for teach-back's two calls alike. Hooked into `CompanionManager` at one marked block, one line in the question path, one in Esc, and teach-back's lines in the talk keys and the dictation state. |

### Drawing/ProsePath/

The older inline-tag path for answers that come back as prose, and the cursor overlay it draws in.

| File | Lines | Purpose |
|------|-------|---------|
| `Drawing/ProsePath/DiagramComposer.swift` | ~110 | The prose path's board drawn in a parallel pass on a fast model while the slow one explains; only on Vertex. |
| `Drawing/ProsePath/MarkCoordinator.swift` | ~470 | What the prose path has drawn: marks, spotlight, scratch board and its reveal, and where the cursor buddy points. Resolves each directive to an exact rectangle (recovering a bad id from the words before it), paces marks to the words carrying them, shifts them with a trackpad scroll, dismisses them 30 s after the answer. |
| `Drawing/ProsePath/OverlayWindow.swift` | ~740 | Full-screen transparent overlay, one window per screen, hosting the blue cursor, its waveform and spinner, the prose path's marks (`TeacherAnnotationLayer`) and scratch board. Handles cursor following, flying to a pointed element along a bezier arc, multi-monitor coordinate mapping and fading out. |
| `Drawing/ProsePath/TeacherAnnotationLayer.swift` | ~460 | SwiftUI rendering of every mark: hand-drawn circles, boxes, underlines, highlights, strikethroughs, curved arrows, step badges, callouts, and the spotlight scrim. |
| `Drawing/ProsePath/TeacherResponseParser.swift` | ~740 | Splits a response into spoken text and drawing directives, recording each tag's character offset so marks sync to speech. Also releases complete sentences for progressive speech. |
| `Drawing/ProsePath/TutorWhiteboard.swift` | ~840 | The prose path's scratch board: columns, a base, cells with pointers, nodes and edges, with no coordinates from the model. |

### Memory/

Learning memory and its index.

| File | Lines | Purpose |
|------|-------|---------|
| `Memory/ConceptIndex.swift` | ~500 | Memory's in-memory index: whole-name and alias matching, how much of the question a concept's words cover, one matrix-vector product for meaning. The shortlist and the names-only fallback both come from here. |
| `Memory/LearningMemory.swift` | ~790 | What the student has learned across sessions, in `~/Library/Application Support/Buddy/Memory`. Filed after each answer (Haiku names the ideas, matches known ones, writes plain-words cues), recalled during capture as a cascade (on-device shortlist, Haiku chooses, names-only fallback). Latest explanation replaces the old, FSRS forgetting curve decides build on / remind / re-teach, stale ideas archived, vectors re-embedded if the sentence model changes. `recordTeachBack` strengthens the ideas a teach-back got right (as a successful review) and marks the missed ones lost. Graded by `scripts/learning_memory/`. |
| `Memory/LearningMemoryCalls.swift` | ~180 | The two Haiku calls memory makes, with `LessonConceptPrompt.txt` (filing, which also names how each idea relates to the known ones it was shown) and `MemoryRecallPrompt.txt` (choosing). |

### Memory/Map/

The map of what is known.

| File | Lines | Purpose |
|------|-------|---------|
| `Memory/Map/KnowledgeMapLayout.swift` | ~570 | Where each idea sits on the map, pure and repeatable: clusters from relations and shared lessons, a force layout per cluster seeded from ids, unlinked ideas in a sunflower, no overlapping dots or names, clusters packed on a coarse grid. Also each idea's FSRS strength (remembered, review soon, fading out). |
| `Memory/Map/KnowledgeMapRelations.swift` | ~200 | How remembered ideas relate, for the map: reads the filing call's `related` list and the one-time pass's links strictly (only listed ids, only the five kinds), and runs that pass for stores from before relations on the map's first opening, one Haiku call per 20 ideas with `ConceptRelationsPrompt.txt`, names and summaries only. Graded by `scripts/knowledge_map/`. |
| `Memory/Map/KnowledgeMapView.swift` | ~1460 | The map window's SwiftUI content: dark toolbar (All, Fading, This week with counts; Find an idea), a board-paper canvas drawn in one Canvas (ideas as hand-lettered capsules where there is room and small dots where there is not, coloured Strong, Fading or Time to review, grey links, cluster names, selection ring), legend, zoom, hover card, and the 300pt inspector (state in words, cue, Learned, Next review, Links to, Lessons, Quick recap, Teach it back, Forget this idea). The canvas is also a VoiceOver list of ideas by state. |
| `Memory/Map/KnowledgeMapWindow.swift` | ~290 | The map's real window, opened from the notch and Settings, on an idea when one is named: keeps it in step with memory, scroll to pan and zoom, arrow keys along links, Return for Quick recap, Delete to forget (asking), and steps it aside before Quick recap asks through the normal answer flow. |

### Notebook/

Lessons kept as pages, and the PDF.

| File | Lines | Purpose |
|------|-------|---------|
| `Notebook/NotebookCapture.swift` | ~190 | What the drawing becomes on a page: cards as standalone SVG (the engine already draws SVG, so they stay vectors), and the screen as a JPEG of only the marked region, cut from the question's own screenshot, at most 960 px, with the marks drawn in by an offscreen WebKit view. |
| `Notebook/NotebookDocumentHTML.swift` | ~630 | One lesson as a page of paper for the window (eyebrow, title, idea chips that open the Map, question, the drawing on a lighter panel, what was said, Teach it back and Ask a follow-up as links) and the whole PDF document (cover, contents, one lesson per page, page numbers) as HTML, with the script that lays the PDF into paper-sized sheets so a card is never cut. Cards are `<img>` SVGs, which run nothing; files come through a scheme handler limited to the notebook folder. A4 or US Letter by region. |
| `Notebook/NotebookNotifications.swift` | ~180 | The export's notification with Open PDF (permission asked at the first export only), and the notch's fallback notice when notifications are refused. |
| `Notebook/NotebookPDFExporter.swift` | ~170 | Prints each laid-out sheet with WebKit's `createPDF` (text and drawings stay vector) and joins them with PDFKit off the main thread. |
| `Notebook/NotebookRecorder.swift` | ~270 | Keeps each finished lesson as a notebook page. Holds the lesson (question, what was said, a snapshot of the board taken once the program has run) and writes it only when the answer ends uncancelled; a new question drops it. Guide steps and how-to replays are never held; prose answers are pages of words. Adds the ideas learning memory files for the lesson (`onLessonFiled`). `keepBoard` keeps a board lesson or teach-back as one page when the board is left: the whole board as SVG and what was said. `connectNotebook` is CompanionManager's one setup call. |
| `Notebook/NotebookStore.swift` | ~290 | The notebook on disk, `~/Library/Application Support/Buddy/Notebook/<day>/<time-id>/` with `page.json` (written last), `card-N.svg` and `screen.jpg`. Reads days, sizes, deletes a page, a day or everything, sweeps half-written pages. |
| `Notebook/NotebookWindow.swift` | ~1020 | The Notebook window: a 52pt toolbar (sidebar toggle, Replay for the last lesson, Export PDF menu for this page, this day, a range or everything, More menu with Show transcripts in Finder, Keep new lessons and the deletes, search), lessons down the side grouped by day, the chosen page in a script-free web view whose buttons are intercepted links. Up, Down, Space and Delete through a key monitor that leaves text fields alone. Exports through a save panel, in the background. |
| `Notebook/notebook-snapshot.js` | ~250 | Run in an isolated content world on the drawing board: copies each `paper()` card, the screen marks and an open teaching board (without its bar) out as SVG, writes every reveal in its finished state, and strips anything that is not a drawing (scripts, foreign objects, links, external images, event attributes). |

### Lecture/

Lecture mode.

| File | Lines | Purpose |
|------|-------|---------|
| `Lecture/LectureAudioBuffer.swift` | ~630 | The sound fallback: a Core Audio process tap on the front app and its helper processes only (never the microphone), started only after the permission was asked once and only while that app plays and is not a call (any app using a microphone counts as one), a meeting or a music app. Keeps the last 90 s in memory (the notch shows a glyph whenever a tap is running), empties it on every app switch, stops tapping an app whose sound arrives as silence, rebuilds the tap when the default output device changes. Only the newest 65 s are transcribed, and only for a lecture question (`LectureAudioGate`): by Deepgram Nova-3 prerecorded (recorded in the meter at $0.0077 a minute of audio sent) or Apple Speech on the Mac. |
| `Lecture/LectureMode.swift` | ~250 | Lecture mode, with no switch: when the student asks while a video lecture is in front, the tutor gets the lecturer's last minute as a study note. Transcript first (YouTube's caption track, then a transcript panel in the page, then one recognised on screen), placed by the playback time; the front app's buffered sound as the fallback; nothing during an advert, for an excluded app, or when no words are found. Gathers during capture and waits at most 3 s from the question. Asks for System Audio Recording once, at the first question where the sound would have helped. |
| `Lecture/LectureModeCore.swift` | ~730 | Lecture mode's parts that touch nothing on the Mac, tested by `scripts/lecture_mode/`: playback time from "12:34 / 48:10" or a seek bar's description, finding a timestamped transcript among page texts or screen lines, the call, meeting and music exclusions, the gate on when the sound may be sent (a player's time, or a question about what was said), the minute before a time, the note (under 1500 characters), and the 90 s ring buffer with its 16 kHz downsampler. |
| `Lecture/LecturePageReader.swift` | ~200 | Reads the front window's accessibility tree for lecture mode: the page's address (web area or address bar), the seek bar's time, transcript lines, advert words. Bounded to 6000 elements and 1.2 s, skips YouTube's comments and recommendations, and turns on Chromium's page tree with `AXManualAccessibility`. |
| `Lecture/YouTubeCaptions.swift` | ~260 | The caption tracks listed in a watch page's `ytInitialPlayerResponse`, the best one chosen (human captions in the spoken language, then auto-generated), fetched as json3, cached per video for the session. YouTube now withholds the track body without a proof-of-origin token, which Buddy does not imitate, so this usually ends as "withheld" and the page's transcript panel or the sound is used. |

### ErrorOffer/

Explain this error?

| File | Lines | Purpose |
|------|-------|---------|
| `ErrorOffer/ErrorGlow.swift` | ~140 | The error offer's halo: a click-through window just under the notch's, red at 45% with a fine brighter edge along the shape's bottom, hidden while the notch is open. |
| `ErrorOffer/ErrorOffer.swift` | ~320 | "Explain this error?": when an error appears in front of the student a soft red halo glows under the notch for 20 seconds and the notch says "An error on screen."; hovering opens the Lesson tab on the error card (Explain this error, Not now), and a tap or silent press of the talk keys still accepts. Accepting sends "explain this error" through the normal pipeline with a turn note naming the error's lines and their screen index ids, so the answer rings the line it points to. An offer the student is reading is kept until the notch closes. No model call until then; never while Buddy answers, guides or listens, in a readable Focus, or more than once a minute. No switch. |
| `ErrorOffer/ErrorRecognizer.swift` | ~1020 | Recognizes an error by the shape its tool prints (Python tracebacks, JavaScript and Java frames, rustc, clang, Go panics, pytest, Jest, JUnit, XCTest, judge verdicts), never by the word error; finds where it points in the student's code and fingerprints it. Graded by `scripts/error_offer/`. |
| `ErrorOffer/ErrorWatcher.swift` | ~680 | Finds the error for the offer, event driven: listens only while a terminal, editor, Xcode or a browser on a judge's page (or a separate developer tools window) is in front, starts on Return, a run, build or test shortcut, or a click, waits for the front window to change and hold still 600 ms, then reads only that window, at most once every 3 s: accessibility text of what was printed after Return (Terminal, iTerm2), otherwise text recognition on the rows that changed. A scroll abandons the wait; fingerprints dedupe. |
| `ErrorOffer/ErrorWindowReading.swift` | ~210 | The image side of the watcher, kept testable: window thumbnails and which rows changed, text recognition on those rows, the accessibility range to read, and matching a read line to a screen index id. |

### Guide/

Guide mode and how-tos.

| File | Lines | Purpose |
|------|-------|---------|
| `Guide/GuideCoordinator.swift` | ~100 | A guided task's state: the step waiting, steps given, the screen it was given against, the app, the `GuideWatcher`, the kept how-tos (`HowToMemory`) and a how-to being replayed. |
| `Guide/GuideMode.swift` | ~280 | Guide mode: a task in an app, one step at a time. The model starts it by ending an answer with `waitForStep("step", "done when")`; `GuideWatcher` then waits for a click, key or scroll, compares a 96x60 grey thumbnail of the screen (Buddy's windows and the pointer left out) with the one the step was given against, and asks again only when it changed. No tokens are spent watching. Caps of 15 steps and 5 minutes. |
| `Guide/HowToMemory.swift` | ~450 | Finished walkthroughs kept as how-tos (steps' sentences, control labels, waits) and replayed with no model when the same task is asked in the same app. Matching is on the Mac: a how-to question, a saved phrasing sharing nearly all its words both ways, meaning only as a floor. One Haiku call writes the ways of asking when a how-to is kept (`HowToCuesPrompt.txt`). A control missing on replay hands that step to the model, and the new walkthrough replaces the old. Graded by `scripts/howto/`. |

### TeachBack/

Teach it back.

| File | Lines | Purpose |
|------|-------|---------|
| `TeachBack/TeachBackIntent.swift` | ~390 | Whether the student is offering to explain a topic to Buddy ("let me explain X back to you", "check my understanding of X", "can I teach you X", "teach it back" about the last lesson), never "explain X to me", context before a question, a quiz, or explaining to someone else; the topic it names; "let me try that part again" while open; and `TeachBackHearing`, the closing words ("I'm done", "that's it" as a sentence of its own) that end an explanation. Graded by `scripts/teach_back/intent_test.swift` on four phrasing sets, three of them blind. |
| `TeachBack/TeachBackListener.swift` | ~350 | Teach-back's hands-free microphone: a fresh `AVAudioEngine` with the tap rebuilt on format changes (as `TalkOverListener`), the Deepgram-first provider told the topic and nearby remembered ideas, live words and a level for the meter. Ends on the closing words, `finish()` (Return, I'm done, the talk keys), eight seconds with no new words, fifteen before the first word, or three minutes; keeps what was heard if the recognizer stops. Bluetooth headsets are allowed. Deepgram's session records the minutes in the meter. |
| `TeachBack/TeachBackPrompt.swift` | ~210 | Teach-back's two cached system prompts: the drawing call (a faithful scribe: only what was said, wrong claims as stated, their words, one sentence spoken, a second go changes only that part) and the gap call (at most four marks on their drawing, most important first, one sentence each, never redrawing their version, then `board.verdict` and Fill the gaps / Try that part again). Their turn notes, the board's title ("You explain: X") and invitation; only the first program block runs, and the drawing is played as one beat (`drawingAsOneBeat`). Measured by `scripts/teach_back/faithfulness.swift`. |
| `TeachBack/TeachBackSession.swift` | ~240 | One teach-back on the board: listening (title "You explain: X", the bar's meter, I'm done and Cancel, the overlay taking Return and Esc so they never reach the hidden app), then the drawing call in purple and the gap call in red, then Try again (old marks rubbed out with the next drawing's first sentence) or any board question. Leaves the Notebook page's paragraphs and the record for learning memory. |

### Settings/

Setup, Settings, keys, permissions, spending.

| File | Lines | Purpose |
|------|-------|---------|
| `Settings/APIKeyChecker.swift` | ~190 | Tests a key with the smallest real request each service accepts and turns failures (wrong key, no credit, wrong field, quota, network) into one sentence with the fix. The same reading flags keys that stop working mid-use. |
| `Settings/APIKeyStore.swift` | ~250 | Keys in the macOS Keychain, under names from `AppIdentity`, read through a small cache. |
| `Settings/CompanionPanelView.swift` | ~690 | Settings, the notch's gear tab: nine controls in four groups in two fixed columns, never a scroll. Talking (Talk over Buddy, Sounds, Open at login), Memory (Remember what I learn, Open Map, Forget everything with a native alert), Answers (Answers from as a pop-up, a brain without a key opening setup on Keys; Spent today; Name and keys), Buddy (one update row; checks are always daily). Footer: How to use Buddy, Quit. Switches are drawn (`NotchSwitchStyle`) because AppKit greys every switch in the never-active notch panel. Also the permission rows setup shows. |
| `Settings/PermissionMonitor.swift` | ~130 | Accessibility, Screen Recording, microphone and screen content, read again every 1.5 s so the notch and setup update as soon as one is granted; the screen content request; the tick the manager's periodic work runs on. |
| `Settings/SetupWindow.swift` | ~1230 | First-run setup in four steps with one progress indicator and the accent primary button: Welcome (name, a small scene of the notch over ringed code, three facts), Keys (Anthropic; one Gemini card with the API key or Google Cloud choice in its header; Deepgram), Permissions, and Try it, a real hold of Control + Option heard by Apple Speech on the Mac (`SetupShortcutTrial`; CompanionManager hands it the shortcut while the step shows, so nothing reaches a model). Reopened from Settings, the notch's alert row and when a key fails mid-use. A real window, since the notch never takes the keyboard. |
| `Settings/SpendingMeter.swift` | ~190 | What Buddy spent on the student's keys, from each reply's own usage at published prices (`APIPrices`), per day in `spending.json`, shown as Spent today in Settings. Only listens; never on an answer's path. |
| `Settings/WindowPositionManager.swift` | ~260 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |

### Support/

The design system.

| File | Lines | Purpose |
|------|-------|---------|
| `Support/DesignSystem.swift` | ~960 | Design system tokens, colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.Notch` (the notch's text floor, controls, dots, error glow), `DS.Paper` (lesson and board paper, ink), `DS.Ink`, `DS.CornerRadius`, etc. `textTertiary` is #858D89 (AA on black); the old grey is `textDisabled`. `nativeTooltip` passes clicks through. |

### Debug/

Debug-only test channels.

| File | Lines | Purpose |
|------|-------|---------|
| `Debug/CalibrationSnapshot.swift` | ~96 | Captures the screen with Buddy's own marks included, so whether a mark lands on its text can be checked by looking. Debug triggers and the QA channel use it. |
| `Debug/QAHooks.swift` | ~190 | Debug builds only, off unless switched on: a control channel for scripted end-to-end tests (ask, snapshot, state, fake key, setup steps), driven by `scripts/qa/`. |

## Build & Run

```bash
zsh scripts/build-local.sh          # builds, signs, installs /Applications/Buddy.app, relaunches
zsh scripts/make-release.sh 1.2     # the downloadable disk image, see docs/releasing.md
```

Build only through these scripts. They run `xcodebuild` with the `Clicky Local Dev` certificate, which is what keeps macOS's Screen Recording and Accessibility grants across builds; a plain `xcodebuild` or an Xcode build signs differently and the grants have to be given again.

Known non-blocking warnings: Swift 6 concurrency warnings, the deprecated onChange in `Drawing/ProsePath/OverlayWindow.swift`. Do not try to fix these.

**Testing.** `zsh scripts/test.sh` runs the unit tests (`leanring-buddyTests`, Swift Testing, the shared `leanring-buddy` scheme): pure logic such as version comparison, program stream cutting, speech hints, history shortening, spending arithmetic, key errors, routing and benching, utterance joining, talk-over hearing, error recognition and board layout, plus the drawing engine's time limit in a hidden page. It builds into `~/Library/Caches/Buddy-unit-tests`, signs ad hoc and never touches `/Applications/Buddy.app`; under the tests the app starts nothing and logs to `Buddy-unit-tests.log`. `scripts/` holds every other test and measurement, each with its own readme: memory, routing, question sorting, hints and diagram review, plus `scripts/qa/` for end-to-end runs of the real app through the debug-only QA channel (`Debug/QAHooks.swift`).

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

1. **New files**: Add new source files to the "Key Files" table, under their folder, with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
