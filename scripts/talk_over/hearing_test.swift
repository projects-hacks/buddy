// Checks how Buddy reads what it hears while an answer plays
// (leanring-buddy/TalkOverHearing.swift): single utterances, and whole
// overlaps where Buddy's own voice comes back through the speakers into the
// same transcript as the student's. Each overlap is the recognizer's text as
// it arrived, timed, beside the sentences Buddy was saying, played through
// TalkOverTranscript with the clock ticking every 0.2 s as the app does.
//
// usage: zsh scripts/talk_over/run.sh

import Foundation

var failures = 0
func check(_ name: String, _ passed: Bool, _ detail: String = "") {
    if !passed { failures += 1 }
    print(passed ? "ok  " : "FAIL", name, detail.isEmpty ? "" : "(\(detail))")
}

// MARK: - Single utterances

let spokenNow = [SpokenSentence(text: "high starts one slot past the end, and that is the whole bug.", startedAt: 0, endedAt: 3),
                 SpokenSentence(text: "take three buckets, three, seven and nine, and search for twenty.", startedAt: 3, endedAt: 7),
                 SpokenSentence(text: "the cache absorbs most reads, so the database only sees misses.", startedAt: 7, endedAt: nil)]
let spokenText = spokenNow.map(\.text)

func meaning(_ heard: String, loud: Bool = true) -> TalkOverHearing.Meaning {
    TalkOverHearing.meaning(ofUtterance: heard, recentlySpoken: spokenText, wasLoudEnough: loud)
}
func isQuestion(_ meaning: TalkOverHearing.Meaning) -> Bool { if case .question = meaning { return true }; return false }
func isIgnored(_ meaning: TalkOverHearing.Meaning) -> Bool { if case .ignore = meaning { return true }; return false }

check("wait, why? is a question", isQuestion(meaning("wait, why?")))
// Overlaps take Buddy's words out first and then judge without the echo
// share, so a follow-up may share the answer's words.
check("a follow-up sharing the answer's words is a question",
      isQuestion(TalkOverHearing.meaning(ofUtterance: "Wait. Why does the database only see misses?", recentlySpoken: [], wasLoudEnough: true)))
check("hold on holds", meaning("hold on") == .hold)
check("okay, go on please resumes", meaning("okay, go on please") == .resume)
check("slow down slows", meaning("slow down") == .slower)
check("go back repeats the sentence", meaning("go back") == .repeatPreviousSentence)
check("say that again replays", meaning("Say that again.") == .replayAnswer)
check("a clean echo is ignored", isIgnored(meaning("the cache absorbs most reads so the database only sees misses")))
check("a quiet voice is ignored", isIgnored(meaning("wait, why?", loud: false)))
check("video narration is ignored", isIgnored(meaning("and in tonight's news the council voted to approve the new budget for the coming year after a long debate")))
check("someone on the phone is ignored", isIgnored(meaning("yeah I'll call you back later")))

// MARK: - Overlaps

enum Event {
    case sentenceStarts(String)
    case sentenceEnds
    case heard(String)
}

/// Plays timed events through the transcript and returns its actions, timed.
func play(_ events: [(at: Double, event: Event)], until end: Double, loud: Bool = true) -> [(at: Double, action: TalkOverTranscript.Action)] {
    var transcript = TalkOverTranscript()
    var sentences: [SpokenSentence] = []
    var actions: [(Double, TalkOverTranscript.Action)] = []
    var pending = events.sorted { $0.at < $1.at }
    for step in 0...Int(end * 5) {
        let clock = Double(step) / 5
        while let next = pending.first, next.at <= clock {
            pending.removeFirst()
            switch next.event {
            case .sentenceStarts(let text):
                if let last = sentences.last, last.endedAt == nil {
                    sentences[sentences.count - 1] = SpokenSentence(text: last.text, startedAt: last.startedAt, endedAt: next.at)
                }
                sentences.append(SpokenSentence(text: text, startedAt: next.at, endedAt: nil))
            case .sentenceEnds:
                if let last = sentences.last { sentences[sentences.count - 1] = SpokenSentence(text: last.text, startedAt: last.startedAt, endedAt: next.at) }
            case .heard(let text):
                for action in transcript.heard(text, at: next.at, recentlySpoken: Array(sentences.suffix(3)), wasLoudEnough: loud) {
                    actions.append((next.at, action))
                }
            }
        }
        for action in transcript.timePassed(to: clock, recentlySpoken: Array(sentences.suffix(3)), wasLoudEnough: loud) {
            actions.append((clock, action))
        }
    }
    return actions
}

func describe(_ actions: [(at: Double, action: TalkOverTranscript.Action)]) -> String {
    actions.map { String(format: "%.1fs %@", $0.at, String(describing: $0.action)) }.joined(separator: "; ")
}
func question(in actions: [(at: Double, action: TalkOverTranscript.Action)]) -> (at: Double, text: String)? {
    for (at, action) in actions { if case .question(let text) = action { return (at, text) } }
    return nil
}
func firstYield(in actions: [(at: Double, action: TalkOverTranscript.Action)]) -> Double? {
    actions.first { $0.action == .yield }?.at
}

// 1. The live test of 1.6 (laptop speakers at 50%). Buddy's first sentence,
// then the second from 4.9 s; five seconds in, a voice asked "Wait, why does
// high start at the length of the list?". The recognizer delivered it in
// pieces among Buddy's own words, dropped "of", and glued "The guests." from
// Buddy's second sentence on the end. The 1.5.1 reading split this in five,
// dropped the opening as not addressed, never paused, and sent
// "at the length the list?... The guests.".
let liveSentenceOne = "picture the list as a row of seats at a long dinner table."
let liveSentenceTwo = "the guests sit in seats zero to four, and there is no seat five."
let live: [(at: Double, event: Event)] = [
    (0.0, .sentenceStarts(liveSentenceOne)),
    (1.0, .heard("Picture the list")),
    (2.0, .heard("Picture the list as a row of seats")),
    (3.0, .heard("Picture the list as a row of seats at a long dinner table.")),
    (4.4, .heard("Picture the list as a row of seats at a long dinner table. Wait, why does")),
    (4.9, .sentenceStarts(liveSentenceTwo)),
    (5.0, .heard("Picture the list as a row of seats at a long dinner table. Wait, why does high start")),
    (5.5, .heard("Picture the list as a row of seats at a long dinner table. Wait, why does high start the guests")),
    (6.0, .heard("Picture the list as a row of seats at a long dinner table. Wait, why does high start the guests sit in")),
    (6.6, .heard("Picture the list as a row of seats at a long dinner table. Wait, why does high start the guests sit in at the length")),
    (7.2, .heard("Picture the list as a row of seats at a long dinner table. Wait, why does high start the guests sit in at the length the list?")),
    (7.8, .heard("Picture the list as a row of seats at a long dinner table. Wait, why does high start the guests sit in at the length the list? The guests.")),
]
let liveActions = play(live, until: 12)
print("  live: " + describe(liveActions))
check("live: Buddy pauses at \"wait, why\"", (firstYield(in: liveActions) ?? 99) <= 4.6, "at \(firstYield(in: liveActions).map { String(format: "%.1fs", $0) } ?? "never")")
check("live: one question, the student's whole sentence, Buddy's words taken out",
      question(in: liveActions)?.text == "Wait, why does high start at the length the list?", question(in: liveActions)?.text ?? "none")
check("live: nothing before the question was dropped as not addressed or judged in pieces",
      !liveActions.contains { if case .ignored = $0.action { return true }; return false })

// 2. "Hold on" said over Buddy's sentence, its words mixed into the same result.
let sentence = "binary search halves the range on every step until one item is left."
let holdOn: [(at: Double, event: Event)] = [
    (0.0, .sentenceStarts(sentence)),
    (0.8, .heard("Binary search halves")),
    (1.4, .heard("Binary search halves the range hold")),
    (1.7, .heard("Binary search halves the range hold on on every")),
    (2.3, .heard("Binary search halves the range hold on on every step")),
]
let holdActions = play(holdOn, until: 6)
print("  hold on: " + describe(holdActions))
check("hold on: Buddy pauses as soon as it is heard", (firstYield(in: holdActions) ?? 99) <= 1.8)
check("hold on: and stays paused", holdActions.contains { $0.action == .hold } && !holdActions.contains { $0.action == .endYield })

// 3. A question that names a word on the screen, while Buddy keeps talking
// (no cue, so it does not pause), with Buddy's words before, inside and after it.
let sentenceA = "a retry sends the same request again after a timeout."
let sentenceB = "the server has to treat both copies as one, or the card is charged twice."
let idempotent: [(at: Double, event: Event)] = [
    (0.0, .sentenceStarts(sentenceA)),
    (0.9, .heard("A retry sends the same")),
    (1.8, .heard("A retry sends the same request again after a timeout.")),
    (2.6, .sentenceStarts(sentenceB)),
    (2.9, .heard("A retry sends the same request again after a timeout. What does idempotent")),
    (3.4, .heard("A retry sends the same request again after a timeout. What does idempotent the server has")),
    (3.9, .heard("A retry sends the same request again after a timeout. What does idempotent the server has mean here?")),
    (4.6, .heard("A retry sends the same request again after a timeout. What does idempotent the server has mean here? To treat both copies")),
    (5.4, .heard("A retry sends the same request again after a timeout. What does idempotent the server has mean here? To treat both copies as one, or the card")),
    (6.2, .heard("A retry sends the same request again after a timeout. What does idempotent the server has mean here? To treat both copies as one, or the card is charged twice.")),
]
let idempotentActions = play(idempotent, until: 11)
print("  idempotent: " + describe(idempotentActions))
check("idempotent: the question without Buddy's words",
      question(in: idempotentActions)?.text == "What does idempotent mean here?", question(in: idempotentActions)?.text ?? "none")

// 4. A video in the room over Buddy: never pauses, never asks.
let video: [(at: Double, event: Event)] = [
    (0.0, .sentenceStarts(sentence)),
    (0.8, .heard("Binary search halves and in tonight's")),
    (1.6, .heard("Binary search halves and in tonight's news the range the council voted")),
    (2.6, .heard("Binary search halves and in tonight's news the range the council voted to approve on every step the new budget")),
]
let videoActions = play(video, until: 8)
print("  video: " + describe(videoActions))
check("video: no pause and no question", firstYield(in: videoActions) == nil && question(in: videoActions) == nil)

// 5. Only Buddy's own voice coming back.
let echoOnly: [(at: Double, event: Event)] = [
    (0.0, .sentenceStarts(sentence)),
    (1.0, .heard("Binary search halves the range")),
    (2.5, .heard("Binary search halves the range on every step until one item is left.")),
]
let echoActions = play(echoOnly, until: 6)
check("echo only: nothing at all", echoActions.isEmpty, describe(echoActions))

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
