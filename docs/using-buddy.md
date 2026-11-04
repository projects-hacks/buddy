# Using Buddy

Buddy is a study helper, not a tutor: it explains, draws and remembers, and it never quizzes or grades.

## Asking

Hold **Control + Option**, ask out loud, and let go. Your words appear under the notch as you speak, so a misheard question can be caught before it is sent. The answer starts within a few seconds: each sentence is spoken with the marks that go with it.

```mermaid
stateDiagram-v2
    direction TB
    [*] --> Idle
    Idle --> Listening: hold Control + Option
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
    class Idle,Open idle
    class Listening live
    class Thinking busy
    class Explaining talk
```

The dot in the notch follows the same colours: grey ready, red listening, amber thinking, blue explaining. While it thinks, the notch also says which model is answering.

## Good questions

Ask about what is on screen, in your own words. Buddy reads the screen, so "this" and "that line" work.

| Ask | Buddy |
|---|---|
| "why does this crash on the last element" | marks the line and walks the failing case |
| "teach me how consistent hashing works properly" | builds a lesson on a card, step by step |
| "should I use Kafka or a queue here" | gives the verdict first, then the reason |
| "I didn't get that" | explains again from a completely different angle |
| "what's a trie" | answers in a sentence or two |

## The notch

- **Idle**, it disappears into the camera housing.
- **While answering**, it widens to show what is being said.
- **Hover it** for the last lesson as a paper card (title, your question, the answer, follow-ups), the whole day's transcript, and Settings.

Every conversation is also saved as a Markdown file per day in `~/Library/Application Support/ClickyLocal/Transcripts`, opened from the notch with **Open full transcript**.

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

Memory keeps only the latest explanation of each idea, estimates how well you still remember it, and sets aside ideas met once and unseen for months. It stays on this Mac. Turn it off or **Forget all** in Settings.

## Settings

Hover the notch and open the gear tab.

| Setting | What it does |
|---|---|
| Brain | **Auto** picks Sonnet, Opus or Argon per question; or always use Claude, Gemini, or a local model |
| Sounds | Soft tones when the mic opens and a question is sent, a water drop when the notch opens |
| Learning memory | On or off, how many ideas are remembered, Forget all |
| Name and API keys | Reopens setup on the keys |
| Open at login | Whether Buddy starts when you log in |
| Check for updates | The daily check for a newer Buddy, and Check now |

## Shortcuts

| Keys | Does |
|---|---|
| Hold Control + Option | Ask |
| Esc | Clear the drawing |
| Stop, in the notch | Silence the voice |
