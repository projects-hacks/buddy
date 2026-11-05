# Using Buddy

Buddy is a study helper, not a tutor: it explains, draws, remembers and walks you through apps, and it never quizzes or grades.

## Asking

Hold **Control + Option**, ask out loud, and let go. Your words appear under the notch as you speak, so a misheard question can be caught before it is sent. The answer starts within a few seconds: each sentence is spoken with the marks that go with it.

**Typing instead.** Press **Control + Option + T** from any app, or open the notch and click the chat box, then press Return. Shift + Return starts a new line, and Esc puts the box away with what you typed kept for later. A typed question is answered exactly like a spoken one, out loud and drawn on the screen, and both land in the chat tab, which holds the whole day's conversation. The notch closes when you send so the drawing has the whole screen, and the keyboard goes back to the app you were in. Questions can be up to 2,000 characters, enough for a pasted function or error message.

```mermaid
stateDiagram-v2
    direction TB
    [*] --> Idle
    Idle --> Listening: hold Control + Option
    Idle --> Typing: Control + Option + T
    Typing --> Thinking: Return
    Typing --> Idle: Esc
    Listening --> Thinking: let go
    Thinking --> Explaining: first sentence
    Explaining --> Idle: last sentence
    Explaining --> Listening: ask again to interrupt
    Idle --> Open: hover the notch
    Open --> Idle: move away

    classDef idle fill:#e5e7eb,stroke:#4b5563,color:#111
    classDef live fill:#fecaca,stroke:#b91c1c,color:#111
    classDef busy fill:#fde68a,stroke:#b45309,color:#111
    classDef talk fill:#bfdbfe,stroke:#1d4ed8,color:#111
    class Idle,Open,Typing idle
    class Listening live
    class Thinking busy
    class Explaining talk
```

The dot in the notch follows the same colours: grey ready, red listening, amber thinking, blue explaining, and green "your turn" while it waits for you to do a step in an app. The notch says one thing on each side: what Buddy is doing on the left, and on the right what it is about (the lesson's name). Which model answered is in the Chat tab, on the time beside each answer.

## Good questions

Ask about what is on screen, in your own words. Buddy reads the screen, so "this" and "that line" work.

| Ask | Buddy |
|---|---|
| "why does this crash on the last element" | marks the line and walks the failing case |
| "teach me how consistent hashing works properly" | builds a lesson on a card, step by step |
| "should I use Kafka or a queue here" | gives the verdict first, then the reason |
| "I didn't get that" | explains again from a completely different angle |
| "what's a trie" | answers in a sentence or two |
| "how do I export this as a PDF" | points at the first step, then guides you through the rest |

## Learning an app, step by step

Ask how to get something done in the app in front of you, "how do I add a transition here" or "where do I turn on dark mode", and Buddy guides instead of lecturing: it says one step and points at the exact button or menu. Do the step and Buddy notices and says the next one, without being asked, until the task is done. The step it is waiting for shows under the notch; Esc, Stop or a new question ends the guide.

Watching costs nothing. Buddy only looks after you click, type or scroll, and compares a tiny thumbnail of the screen on your Mac; the model is asked again only when the screen has changed, which is one ordinary answer, the same as asking "what next?". A guide stops by itself after 15 steps or 5 minutes without progress.

```mermaid
flowchart LR
    ask([How do I export this?]):::you --> step[One step, spoken<br/>pointer on the button]:::buddy
    step --> wait[Waits on your Mac<br/>no tokens]:::mac
    wait -->|you click and the screen changes| look[Looks again]:::buddy
    look -->|more to do| step
    look -->|done| finished([Says it is done]):::you

    classDef you fill:#fde68a,stroke:#b45309,color:#111
    classDef buddy fill:#bfdbfe,stroke:#1d4ed8,color:#111
    classDef mac fill:#bbf7d0,stroke:#15803d,color:#111
```

If you go the wrong way, the next step says how to get back. If you are mid-step, still typing a name, it stays quiet and keeps waiting. Switching to another app to reply to a message does not count as doing the step.

**Asked before? Answered from memory.** When a walkthrough reaches the end, Buddy keeps it: each step's words and the button it pointed at. Ask for the same thing again in that app, in your own words ("how do I get a PDF of this" after "how do I save this as a PDF"), and it walks you through from memory: the same steps, pointing at the same buttons, with no model asked at all, so only the voice costs anything (well under a cent). It only does this when the request is plainly the same task; something that only sounds like it, "save as PNG" after "save as PDF", gets a fresh answer instead. If the app has changed and a saved step's button is not there, the model takes over from that step and the walkthrough is saved again. The notch shows **from memory** while it replays. Kept on this Mac; Forget everything clears these with the rest of memory.

## The notch

- **Idle**, it disappears into the camera housing.
- **While answering**, it widens to show what is being said. A small mic beside "explaining" means you can just talk over it (Talk over Buddy, in Settings); when you do, it says **Buddy paused** and shows your words.
- **While guiding**, it shows the step it is waiting for, with "esc to stop".
- **When something needs you**, a failed key, an expired Google Cloud sign-in or a missing permission, it says so in amber ("key problem", "can't see the screen") with "hover to fix", and the open notch has the fix.
- **When an error appears** in a terminal, an editor or a judge's page, a soft red glow shows under the notch with "An error on screen." Hover it and the Lesson tab leads with the error as Buddy read it: **Explain this error** asks about it (so does a tap of Control + Option), **Not now** lets it go. Nothing is sent anywhere until you ask, and the same error is never offered twice.
- **When a lecture's sound is being kept** (see lectures below), a small screen glyph shows on the right, even at rest.
- **Hover it** to open it. **Lesson** shows the last lesson as a paper card: its name, what it builds on, your question, the answer, and the next steps (the model's follow-ups, **Teach it back**, and **Go deeper** after a lesson that could go further). **Replay** plays it again, voice and drawing, with no new request; beside it are Open in Notebook and Copy. On a day with nothing asked yet, it shows three ways in instead: learn something new, teach back an idea you are starting to forget, and yesterday's lessons. **Chat** is the whole day's conversation, with Copy all. **Notebook** and **Map** open their windows, and the gear opens Settings.
- **At most one alert** shows above the lesson: a missing permission (Allow), a key or sign-in problem (Fix, or Copy command for the Google Cloud sign-in), or a new Buddy (What's new, Update).

Every conversation is also saved as a Markdown file per day in `~/Library/Application Support/Buddy/Transcripts`, shown in Finder from the Notebook's More menu.

## The Notebook

Every finished lesson is kept as a page. **Notebook**, in the open notch, opens them: lessons down the side grouped by day, the chosen one as a page with its drawing, what was said, and **Teach it back** and **Ask a follow-up**. Search finds a lesson by its name, question or words. **Replay** draws your last lesson again on the screen. **Export PDF** saves this page, this day, a range or everything. **More** shows the transcripts in Finder, turns **Keep new lessons** on or off, and deletes a page, a day or every note, asking first. Up and Down move through the pages, Space replays, Delete deletes.

## Follow-ups

After an answer, the buttons under it ask the most useful next question ("show me the code", "what if the cache dies?") or copy code it offered. Tapping one is the same as asking it.

## Practice problems: hints before answers

On LeetCode, HackerRank, NeetCode and similar sites, Buddy helps in steps, so you still get to solve it.

```mermaid
flowchart TD
    ask([I'm stuck]):::you --> nudge[1. A nudge<br/>the observation that leads to the idea]:::rung
    nudge -->|another hint| approach[2. The approach<br/>idea, data structure, cost, no code]:::rung
    approach -->|walk me through it| walk[3. By hand<br/>the first example, step by step]:::rung
    walk -->|show the code| code[4. The code<br/>explained, with a copy button]:::rung
    ask -. show me the code .-> code
    nudge -. show me the code .-> code

    classDef you fill:#fde68a,stroke:#b45309,color:#111
    classDef rung fill:#bbf7d0,stroke:#15803d,color:#111
```

Saying "show me the code" at any point skips straight there. A question about a concept on the problem page ("what's a heap") is answered normally, without giving the problem away. Your step on each problem is remembered for two days.

## Your own diagrams

Drawing a design in Excalidraw, draw.io, Miro, Freeform or any whiteboard app, ask "what am I missing?" Buddy talks it through like a peer at the whiteboard: it marks your own boxes, and draws anything it would add as a dashed purple box beside where it belongs. It never scores the design.

## Learning memory

Buddy remembers the ideas it explains, across days. When a new question touches one, the answer builds on it ("the same trade-off as the consistent hashing from Tuesday"), and the lesson card shows **Builds on** with the idea's name. If you said you did not follow an explanation, the next one uses a different example.

Memory keeps only the latest explanation of each idea, estimates how well you still remember it, and sets aside ideas met once and unseen for months. It stays on this Mac. Turn **Remember what I learn** off, or **Forget everything**, in Settings.

**The map of what you know.** **Map**, in the open notch or in Settings under Memory, opens every idea Buddy has taught you as a map on paper: each idea its name in a capsule, related ideas joined ("async await" uses "promises"), clusters named by topic. Green is **Strong**, amber **Fading**, and a red dashed outline **Time to review**; the legend says so. **All**, **Fading** and **This week** narrow the map, and Command F finds an idea by name. Drag or scroll to move around, pinch or Command and scroll to zoom. Click an idea and the panel on the right shows how it was last explained, when you learned it, when to look again, what it links to and the lessons it came from (a click opens that page in the Notebook). **Quick recap** asks Buddy for a short recap, spoken and drawn as usual; **Teach it back** puts "let me explain ... to you" in the chat box. **Forget this idea...** removes just that one, after you confirm. Arrow keys move along the links, Return gives a quick recap. The first time the map opens on memory from before 1.6, Buddy finds the links between older ideas once in the background, sending only their names and one-sentence summaries.

## Settings

Hover the notch and open the gear tab.

Nine controls in four groups, with **How to use Buddy** (this guide) and **Quit Buddy** under them.

| Group | Setting | What it does |
|---|---|---|
| Talking | Talk over Buddy | Keeps listening while it explains, so you can cut in without the keys. On by default |
| | Sounds | Soft tones when the mic opens and a question is sent, key taps when the chat box opens, a water drop when the notch opens |
| | Open at login | Whether Buddy starts when you log in |
| Memory | Remember what I learn | On or off, with how many ideas and how-tos are kept |
| | Open Map, Forget everything... | The map of what you know; forgetting asks first |
| Answers | Answers from | **Auto** picks Sonnet, Opus or Argon per question; or always Claude, or always Gemini. One without a key says "add a key" and opens setup |
| | Spent today | What Buddy has spent on your keys today, and this month under it |
| | Name and keys | Reopens setup on the keys |
| Buddy | The update row | When Buddy last looked for a newer version (once a day, always) and Check now, or Update when there is one |

## What it costs

Buddy runs on your own keys, so you pay the providers directly. **Spent today** in Settings shows the running total, worked out from what each reply says it used (tokens in, from the cache, and out, and characters spoken) at the providers' published prices. It counts only what Buddy did; your provider's bill is the exact figure and includes anything else done with the same key. A typical question is one to six cents, a walkthrough step about a cent, and a replayed how-to only its voice.

## Shortcuts

| Keys | Does |
|---|---|
| Hold Control + Option | Ask out loud |
| Control + Option + T | Type a question |
| Return / Shift + Return, in the chat box | Send / new line |
| Esc | Clear the drawing, stop a walkthrough, or put the chat box away |
| Stop, in the notch | Silence the voice |
