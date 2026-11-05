# Talking over an answer

How Buddy reads what it hears while an answer plays (`leanring-buddy/TalkOverHearing.swift`), checked without a microphone.

```bash
zsh scripts/talk_over/run.sh
```

Single utterances (questions, hold on, go on, slower, go back, say that again, echoes, a quiet voice, a video, a phone call), then whole overlaps played through `TalkOverTranscript` on a simulated clock: the recognizer's text as it arrived, timed, beside the sentences Buddy was saying.

- **Live test of 1.6.** Laptop speakers at 50%, "Wait, why does high start at the length of the list?" said five seconds into an answer, delivered in pieces among Buddy's own words with "The guests." from Buddy's next sentence glued on. Buddy must pause at "wait" and send the student's whole sentence without Buddy's words.
- **Hold on** mixed into Buddy's sentence: pause at once, and stay paused.
- **A question with no cue** while Buddy keeps talking, Buddy's words before, inside and after it: the question alone.
- **A video in the room**: no pause, no question.
- **Only Buddy's voice coming back**: nothing.
