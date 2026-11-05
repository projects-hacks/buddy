# Talking over an answer

How Buddy reads what it hears while an answer plays (`leanring-buddy/VoiceIn/TalkOverHearing.swift`), checked without a microphone.

```bash
zsh scripts/talk_over/run.sh
```

Single utterances (questions, hold on, go on, slower, go back, say that again, echoes, a quiet voice, a video, a phone call), then whole overlaps played through `TalkOverTranscript` on a simulated clock: the recognizer's text as it arrived, timed, beside the sentences Buddy was saying.

- **Live test of 1.6.** Laptop speakers at 50%, "Wait, why does high start at the length of the list?" said five seconds into an answer, delivered in pieces among Buddy's own words with "The guests." from Buddy's next sentence glued on. Buddy must pause at "wait" and send the student's whole sentence without Buddy's words.
- **Hold on** mixed into Buddy's sentence: pause at once, and stay paused.
- **A question with no cue** while Buddy keeps talking, Buddy's words before, inside and after it: the question alone.
- **A video in the room**: no pause, no question.
- **Only Buddy's voice coming back**: nothing.
- **The live retest**: macOS `say` speaking the same question over Buddy, with Deepgram's interim text stalling 0.8 s after "Wait." and 0.7 s after "Why does high" (and again with a 1.3 s stall) while the microphone level shows continuous speech. One question with the whole sentence and no hold: once Buddy has paused, the end is read from the microphone (1.2 s below the speech level), then Deepgram is asked to finalize.
- **"Wait" on its own** still holds, but only after 1.5 s with nothing following it.
- **The notch's live line**: the student's own words while Buddy is paused for them, and nothing once the question is sent.
