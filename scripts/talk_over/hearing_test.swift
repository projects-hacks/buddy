// Checks how Buddy reads what it hears while an answer plays
// (leanring-buddy/VoiceIn/TalkOverHearing.swift): single utterances, and whole
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

check("buddy, wait, why? is a question", isQuestion(meaning("buddy, wait, why?")))
check("wait, why? without the name is not for Buddy", isIgnored(meaning("wait, why?")))
// Overlaps take Buddy's words out first and then judge without the echo
// share, so a follow-up may share the answer's words.
check("a follow-up sharing the answer's words is a question",
      isQuestion(TalkOverHearing.meaning(ofUtterance: "Buddy, wait. Why does the database only see misses?", recentlySpoken: [], wasLoudEnough: true)))
check("buddy, hold on holds", meaning("buddy, hold on") == .hold)
check("hold on on its own is said to someone else", isIgnored(meaning("hold on")))
check("hold on, buddy holds", meaning("hold on, buddy") == .hold)
check("okay, go on please resumes, with no name needed", meaning("okay, go on please") == .resume)
check("buddy, slow down slows", meaning("buddy, slow down") == .slower)
check("buddy, go back repeats the sentence", meaning("buddy, go back") == .repeatPreviousSentence)
check("what was that? to a friend changes nothing", isIgnored(meaning("what was that?")))
check("buddy, say that again replays", meaning("Buddy, say that again.") == .replayAnswer)
check("buddy, tell me more about the lock is a question", isQuestion(meaning("buddy, tell me more about the lock")))
check("the name alone asks nothing", isIgnored(meaning("buddy?")))
check("a friend: wait, did you see the game last night?", isIgnored(meaning("wait, did you see the game last night?")))
check("a friend: sorry, what did you say?", isIgnored(meaning("sorry, what did you say?")))
check("a friend: but why would he do that", isIgnored(meaning("but why would he do that")))
check("a friend named bud is not Buddy", isIgnored(meaning("bud, wait, why did you leave")))
check("a clean echo is ignored", isIgnored(meaning("the cache absorbs most reads so the database only sees misses")))
check("a quiet voice is ignored", isIgnored(meaning("buddy, wait, why?", loud: false)))
check("video narration is ignored", isIgnored(meaning("and in tonight's news the council voted to approve the new budget for the coming year after a long debate")))
check("someone on the phone is ignored", isIgnored(meaning("yeah I'll call you back later")))

// MARK: - Overlaps

enum Event {
    case sentenceStarts(String)
    case sentenceEnds
    case heard(String)
    /// The microphone's level, in dBFS, as each buffer arrives.
    case level(Float)
}

/// Microphone levels every 50 ms from `start` to `end`.
func levels(_ decibels: Float, from start: Double, to end: Double) -> [(at: Double, event: Event)] {
    stride(from: start, to: end, by: 0.05).map { ($0, Event.level(decibels)) }
}

/// Plays timed events through the transcript and returns its actions, timed.
/// `finalTextOnFlush` is what Deepgram sends back a quarter of a second
/// after it is asked to finalize, as it does once the student stops.
func play(_ events: [(at: Double, event: Event)], until end: Double, loud: Bool = true,
          finalTextOnFlush: String? = nil, lecture: [SpokenSentence] = []) -> [(at: Double, action: TalkOverTranscript.Action)] {
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
                for action in transcript.heard(text, at: next.at, recentlySpoken: Array(sentences.suffix(3)) + lecture, wasLoudEnough: loud) {
                    actions.append((next.at, action))
                }
            case .level(let decibels):
                transcript.levelHeard(decibels, at: next.at)
            }
        }
        for action in transcript.timePassed(to: clock, recentlySpoken: Array(sentences.suffix(3)) + lecture, wasLoudEnough: loud) {
            actions.append((clock, action))
            if action == .flushRecognizer, let finalTextOnFlush {
                pending.append((clock + 0.25, .heard(finalTextOnFlush)))
                pending.sort { $0.at < $1.at }
            }
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

// 1. The first live test of 2.0 (laptop speakers at 50%). Buddy's first sentence,
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
    (4.4, .heard("Picture the list as a row of seats at a long dinner table. Buddy, wait, why does")),
    (4.9, .sentenceStarts(liveSentenceTwo)),
    (5.0, .heard("Picture the list as a row of seats at a long dinner table. Buddy, wait, why does high start")),
    (5.5, .heard("Picture the list as a row of seats at a long dinner table. Buddy, wait, why does high start the guests")),
    (6.0, .heard("Picture the list as a row of seats at a long dinner table. Buddy, wait, why does high start the guests sit in")),
    (6.6, .heard("Picture the list as a row of seats at a long dinner table. Buddy, wait, why does high start the guests sit in at the length")),
    (7.2, .heard("Picture the list as a row of seats at a long dinner table. Buddy, wait, why does high start the guests sit in at the length the list?")),
    (7.8, .heard("Picture the list as a row of seats at a long dinner table. Buddy, wait, why does high start the guests sit in at the length the list? The guests.")),
]
let liveActions = play(live, until: 12)
print("  live: " + describe(liveActions))
check("live: Buddy pauses at \"buddy, wait\"", (firstYield(in: liveActions) ?? 99) <= 4.6, "at \(firstYield(in: liveActions).map { String(format: "%.1fs", $0) } ?? "never")")
check("live: one question, the student's whole sentence, Buddy's words taken out",
      question(in: liveActions)?.text == "Buddy, wait, why does high start at the length the list?", question(in: liveActions)?.text ?? "none")
check("live: nothing before the question was dropped as not addressed or judged in pieces",
      !liveActions.contains { if case .ignored = $0.action { return true }; return false })

// 2. "Hold on" said over Buddy's sentence, its words mixed into the same result.
let sentence = "binary search halves the range on every step until one item is left."
let holdOn: [(at: Double, event: Event)] = [
    (0.0, .sentenceStarts(sentence)),
    (0.8, .heard("Binary search halves")),
    (1.4, .heard("Binary search halves the range buddy hold")),
    (1.7, .heard("Binary search halves the range buddy hold on on every")),
    (2.3, .heard("Binary search halves the range buddy hold on on every step")),
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
    (2.9, .heard("A retry sends the same request again after a timeout. Buddy, what does idempotent")),
    (3.4, .heard("A retry sends the same request again after a timeout. Buddy, what does idempotent the server has")),
    (3.9, .heard("A retry sends the same request again after a timeout. Buddy, what does idempotent the server has mean here?")),
    (4.6, .heard("A retry sends the same request again after a timeout. Buddy, what does idempotent the server has mean here? To treat both copies")),
    (5.4, .heard("A retry sends the same request again after a timeout. Buddy, what does idempotent the server has mean here? To treat both copies as one, or the card")),
    (6.2, .heard("A retry sends the same request again after a timeout. Buddy, what does idempotent the server has mean here? To treat both copies as one, or the card is charged twice.")),
]
let idempotentActions = play(idempotent, until: 11)
print("  idempotent: " + describe(idempotentActions))
check("idempotent: the question without Buddy's words",
      question(in: idempotentActions)?.text == "Buddy, what does idempotent mean here?", question(in: idempotentActions)?.text ?? "none")

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

// 6. The live retest of 2.0 after the first fix: Buddy at 50% through the
// speakers, then macOS `say` speaking "Wait, why does high start at the
// length of the list?" without a break but for a short comma after "Wait".
// Deepgram's interim text stalled twice while it found the phrase's end.
// That build took the lone "Wait." as a hold and then sent "Why does high".
// Buddy's voice is loud at the microphone until it pauses at "Wait".
let sentenceSaid = "the guests sit in seats zero to four, and there is no seat five."
let wholeQuestion = "Buddy, wait. Why does high start at the length of the list?"
func sayOverBuddy(stallAfterWait: Double) -> [(at: Double, event: Event)] {
    let firstWords = 5.3, secondWords = firstWords + stallAfterWait, wholeSentence = secondWords + 0.7
    var events: [(at: Double, event: Event)] = [(0.0, .sentenceStarts(sentenceSaid))]
    events += levels(-30, from: 0, to: firstWords)                             // Buddy's own voice
    events += levels(-24, from: 5.0, to: 5.45) + levels(-48, from: 5.45, to: 5.6)   // "Wait", the comma
    events += levels(-24, from: 5.6, to: wholeSentence + 0.3)                  // the rest, without a break
    events += levels(-62, from: wholeSentence + 0.3, to: 14)                   // the room, Buddy paused
    events += [(firstWords, .heard("Buddy, wait.")), (secondWords, .heard("Buddy, wait. Why does high")), (wholeSentence, .heard(wholeQuestion))]
    return events
}
for stall in [0.8, 1.3] {
    let actions = play(sayOverBuddy(stallAfterWait: stall), until: 14, finalTextOnFlush: wholeQuestion)
    print("  say over Buddy, \(stall)s stall after Wait: " + describe(actions))
    check("say over Buddy (\(stall)s stall): pauses at Wait", (firstYield(in: actions) ?? 99) <= 5.4)
    check("say over Buddy (\(stall)s stall): no hold", !actions.contains { $0.action == .hold })
    check("say over Buddy (\(stall)s stall): one question, the whole sentence",
          actions.filter { if case .question = $0.action { return true }; return false }.count == 1
              && question(in: actions)?.text == wholeQuestion, question(in: actions)?.text ?? "none")
    check("say over Buddy (\(stall)s stall): the end read from the microphone, then the final words asked for",
          actions.contains { $0.action == .flushRecognizer })
}

// 7. A real "wait" on its own still holds, once nothing follows it.
var waitAlone: [(at: Double, event: Event)] = [(0.0, .sentenceStarts(sentenceSaid))]
waitAlone += levels(-30, from: 0, to: 5.3) + levels(-24, from: 5.0, to: 5.45) + levels(-62, from: 5.45, to: 10)
waitAlone += [(5.3, .heard("Buddy, wait."))]
let waitActions = play(waitAlone, until: 10, finalTextOnFlush: "Buddy, wait.")
print("  wait alone: " + describe(waitActions))
check("wait alone: holds, and only after it was left alone for 1.5s",
      waitActions.first { $0.action == .hold }.map { $0.at >= 5.45 + TalkOverTranscript.holdConfirmSeconds } ?? false)
check("wait alone: no question", question(in: waitActions) == nil)

// 8. The notch's live line: the student's own words while Buddy is paused
// for them, Buddy's words left out, and nothing once the question is sent.
var shown = TalkOverTranscript()
let spokenThen = [SpokenSentence(text: sentenceSaid, startedAt: 0, endedAt: nil)]
_ = shown.heard("the guests sit in Buddy, wait.", at: 5.3, recentlySpoken: spokenThen, wasLoudEnough: true)
check("notch line: the cue alone at first", shown.wordsOfTheCutIn(recentlySpoken: spokenThen) == "Buddy, wait.", shown.wordsOfTheCutIn(recentlySpoken: spokenThen))
_ = shown.heard("the guests sit in Buddy, wait. Why does high", at: 6.1, recentlySpoken: spokenThen, wasLoudEnough: true)
check("notch line: grows as words come", shown.wordsOfTheCutIn(recentlySpoken: spokenThen) == "Buddy, wait. Why does high", shown.wordsOfTheCutIn(recentlySpoken: spokenThen))
_ = shown.timePassed(to: 9, recentlySpoken: spokenThen, wasLoudEnough: true)
check("notch line: empty once the question is sent", shown.wordsOfTheCutIn(recentlySpoken: spokenThen).isEmpty)

// 9. The live test of the 2.0 build, laptop speakers at 38%: Buddy said
// "ten is bigger than everything..." and the microphone heard its own voice
// as "10 is The wild". The digits did not match Buddy's spelled-out words,
// and "is" in second place made it a question, so the answer was cut off
// for a question nobody asked.
let echoSentence = "ten is bigger than everything, so low keeps moving right past the nine."
check("digits are read as the words said", TalkOverHearing.words(of: "10 is 42") == ["ten", "is", "forty", "two"])
check("a statement with is in second place is not a question", isIgnored(meaning("10 is the wild")))
check("is opening the sentence still asks", isQuestion(meaning("buddy, is ten bigger than nine")))
check("okay before is still asks", isQuestion(meaning("okay buddy is that the last index")))
var echoOfTen: [(at: Double, event: Event)] = [(0.0, .sentenceStarts(echoSentence))]
echoOfTen += levels(-30, from: 0, to: 6) + levels(-62, from: 6, to: 10)
echoOfTen += [(1.2, .heard("10 is")), (2.4, .heard("10 is The wild"))]
let echoOfTenActions = play(echoOfTen, until: 10, finalTextOnFlush: "10 is The wild")
print("  echo of ten: " + describe(echoOfTenActions))
check("echo of ten: Buddy's own voice heard back with digits is no question", question(in: echoOfTenActions) == nil)
check("echo of ten: Buddy is never paused for it", firstYield(in: echoOfTenActions) == nil)

// 10. The teach-back live test of 2.0: Buddy said "here's what you
// described." as the drawing call ended, the next call began at once, and
// the recognizer wrote its echo as "Here is what you described. knee".
let describedSentence = "here's what you described."
check("contractions are compared spelled out", TalkOverHearing.words(of: "Here's what") == ["here", "is", "what"])
var describedEcho: [(at: Double, event: Event)] = [(0.0, .sentenceStarts(describedSentence)), (1.6, .sentenceEnds)]
describedEcho += levels(-30, from: 0, to: 3) + levels(-62, from: 3, to: 8)
describedEcho += [(1.0, .heard("Here is what")), (2.2, .heard("Here is what you described. knee"))]
let describedActions = play(describedEcho, until: 8, finalTextOnFlush: "Here is what you described. knee")
print("  echo of here's: " + describe(describedActions))
check("echo of here's: Buddy's own sentence written out in full is no question", question(in: describedActions) == nil)

// 11. Lecture mode's live test of 2.0.1: a lecture on the speakers while
// Buddy answered, and the microphone's "data that's persisted and exchanged
// throughout our system?" was taken for the student and answered. The
// lecture's own recognizer had heard the same words a moment before.
func lecturePhrase(_ text: String, _ start: Double, _ end: Double) -> SpokenSentence {
    SpokenSentence(text: text, startedAt: start, endedAt: end, isFromTheLecture: true)
}
let roadmapLecture = [lecturePhrase("these are the core entities, the data that's persisted", 2.5, 4.5),
                      lecturePhrase("and exchanged throughout our system.", 4.5, 6.0)]
var lectureInTheRoom: [(at: Double, event: Event)] = [(0.0, .sentenceStarts("the road map is five steps in order.")), (2.0, .sentenceEnds),
                                                      (2.1, .sentenceStarts("first, requirements: what it must do."))]
lectureInTheRoom += levels(-30, from: 0, to: 9)
lectureInTheRoom += [(4.0, .heard("data that's persisted")), (5.6, .heard("data that's persisted and exchanged throughout our system?"))]
let lectureActions = play(lectureInTheRoom, until: 12, lecture: roadmapLecture)
print("  lecture in the room: " + describe(lectureActions))
check("lecture in the room: the video's words are no question", question(in: lectureActions) == nil)
check("lecture in the room: Buddy is never paused for them", firstYield(in: lectureActions) == nil)
// Since the name rule, the lecture's words would be ignored without the
// filter too; the filter still keeps them out of a question that names Buddy.

// 12. The student cuts in while the lecture plays: the lecturer's words go,
// the student's stay.
let apiLecture = [lecturePhrase("so the next step is the api, the endpoints", 1.0, 3.5)]
var cutInOverLecture: [(at: Double, event: Event)] = [(0.0, .sentenceStarts("core entities are the nouns of the system."))]
cutInOverLecture += levels(-30, from: 0, to: 9)
cutInOverLecture += [(2.5, .heard("so the next step is the api")), (4.2, .heard("so the next step is the api buddy wait why do we need an api"))]
let cutInOverLectureActions = play(cutInOverLecture, until: 12, lecture: apiLecture)
print("  cut in over the lecture: " + describe(cutInOverLectureActions))
check("cut in over the lecture: the student's question is kept, the lecturer's words are not",
      question(in: cutInOverLectureActions)?.text.lowercased() == "buddy wait why do we need an api")

// 13. Quoting the lecture is the student's own: two or three of its words
// in a row are a term, not the video.
let termLecture = [lecturePhrase("we use eventual consistency for the search index", 1.0, 3.5)]
let quotedWords = TalkOverHearing.words(of: "what does eventual consistency mean")
let quotedMask = TalkOverHearing.lectureWordMask(quotedWords, heardAt: quotedWords.map { _ in 5.0 }, spoken: termLecture)
check("a term quoted from the lecture stays the student's", !quotedMask.contains(true))

// 14. The same words long after the lecture said them are the student's.
let echoedLate = TalkOverHearing.words(of: "the data that's persisted and exchanged")
let lateMask = TalkOverHearing.lectureWordMask(echoedLate, heardAt: echoedLate.map { _ in 40.0 }, spoken: roadmapLecture)
check("lecture words said long before are not taken out", !lateMask.contains(true))
let onTimeMask = TalkOverHearing.lectureWordMask(echoedLate, heardAt: echoedLate.map { _ in 5.0 }, spoken: roadmapLecture)
check("the same run heard while the video said it is taken out", onTimeMask.allSatisfy { $0 })

// 15. Lecture phrases never count as Buddy's own voice.
let lectureOnlyMask = TalkOverHearing.buddyWordMask(echoedLate, heardAt: echoedLate.map { _ in 5.0 }, spoken: roadmapLecture)
check("lecture phrases are not Buddy's echo", !lectureOnlyMask.contains(true))

// 16. Talking to a friend while Buddy explains, the 2.0.2 report: "wait",
// "sorry" and "but why" said to someone else used to pause Buddy.
var friendInTheRoom: [(at: Double, event: Event)] = [(0.0, .sentenceStarts(sentenceSaid))]
friendInTheRoom += levels(-30, from: 0, to: 6) + levels(-24, from: 6, to: 9) + levels(-62, from: 9, to: 14)
friendInTheRoom += [(6.4, .heard("Wait,")), (7.2, .heard("Wait, did you see the")), (8.6, .heard("Wait, did you see the game last night? Sorry, but why"))]
let friendActions = play(friendInTheRoom, until: 14, finalTextOnFlush: "Wait, did you see the game last night? Sorry, but why")
print("  a friend in the room: " + describe(friendActions))
check("a friend in the room: Buddy never pauses", firstYield(in: friendActions) == nil)
check("a friend in the room: nothing is asked", question(in: friendActions) == nil)

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
