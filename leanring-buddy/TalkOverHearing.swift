//
//  TalkOverHearing.swift
//  leanring-buddy
//
//  The reading half of talking over an answer, kept apart from the
//  microphone so it can be checked offline (scripts/talk_over/): which heard
//  words are Buddy's own voice coming back, where a cut-in starts, and what
//  the student's words mean. TalkOverListener.swift feeds it.
//

import Foundation

/// One of Buddy's sentences and when it was said, in seconds on one clock,
/// so a heard word is only taken for its echo while that echo can arrive.
struct SpokenSentence: Equatable {
    let text: String
    let startedAt: Double
    /// Nil while it is still being said (or paused).
    let endedAt: Double?
}

/// What something heard while an answer played means. Pure, so it can be
/// checked without a microphone.
enum TalkOverHearing {
    enum Meaning: Equatable {
        case ignore(reason: String)
        case hold
        case resume
        case slower
        case repeatPreviousSentence
        case replayAnswer
        case question(String)
    }

    /// A word counts as Buddy's own when its share of matching words is at
    /// least this. A clean echo comes back almost word for word (0.8 and
    /// up); a student's own question shares a topic noun or two with the
    /// sentence, and its question words never, so it stays well below.
    static let echoShareThreshold = 0.6
    /// A real question has at least this many words, unless it is two
    /// words opened by a cue, like "wait, why?".
    static let minimumQuestionWords = 3
    /// Past this it is a conversation or a video, not a question cutting in.
    static let maximumQuestionWords = 40

    private static let fillerWords: Set<String> = ["um", "uh", "er", "erm", "hmm", "mm", "mhm", "ah", "oh", "like"]
    /// Words that carry no topic, left out when comparing with what Buddy said.
    private static let commonWords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "it", "its", "this", "that", "these", "those",
        "to", "of", "in", "on", "at", "for", "and", "or", "so", "you", "i", "we", "they", "he", "she",
        "do", "does", "did", "has", "have", "had", "with", "as", "by", "from", "if", "then", "there", "here",
        "can", "will", "just", "not", "no", "yes", "one", "all", "what"
    ]
    private static let cueOpenings = ["wait", "hold on", "hang on", "sorry", "but", "actually", "excuse me", "hey", "so"]
    private static let questionWords: Set<String> = [
        "why", "what", "how", "when", "where", "which", "who", "whats", "hows", "huh", "really",
        "is", "does", "do", "can", "could", "should", "would", "are", "isnt", "doesnt", "explain"
    ]

    private static let holdPhrases: Set<String> = ["wait", "hold on", "hang on", "one sec", "one second", "pause", "wait a second", "wait a sec", "hold on a second", "just a second", "wait wait"]
    private static let resumePhrases: Set<String> = ["go on", "continue", "keep going", "carry on", "go ahead", "resume", "ok go on", "okay go on", "ok continue", "okay continue", "yes go on", "yeah go on", "go on please", "please continue"]
    private static let slowerPhrases: Set<String> = ["slower", "slow down", "more slowly", "a bit slower", "a little slower", "slower please", "slow down please", "can you slow down", "could you slow down", "talk slower", "speak slower"]
    private static let replayPhrases: Set<String> = ["say that again", "say it again", "can you say that again", "could you say that again", "say all that again", "repeat the answer", "repeat your answer", "repeat the whole thing", "one more time", "from the top", "start again", "play that again"]
    private static let repeatPhrases: Set<String> = ["go back", "go back one", "back", "repeat that", "repeat", "repeat that sentence", "say that sentence again", "what was that", "come again"]

    /// The whole of something heard, once its speaker paused.
    static func meaning(ofUtterance utterance: String, recentlySpoken: [String], wasLoudEnough: Bool) -> Meaning {
        let words = Self.words(of: utterance)
        guard !words.isEmpty else { return .ignore(reason: "nothing") }
        guard wasLoudEnough else { return .ignore(reason: "too quiet to be the student at the Mac") }

        let phrase = commandPhrase(from: words)
        if holdPhrases.contains(phrase) { return .hold }
        if resumePhrases.contains(phrase) { return .resume }
        if slowerPhrases.contains(phrase) { return .slower }
        if repeatPhrases.contains(phrase) { return .repeatPreviousSentence }
        if replayPhrases.contains(phrase) { return .replayAnswer }

        let realWords = words.filter { !fillerWords.contains($0) }
        if echoShare(of: realWords, recentlySpoken: recentlySpoken) >= echoShareThreshold {
            return .ignore(reason: "Buddy's own voice")
        }
        guard realWords.count <= maximumQuestionWords else { return .ignore(reason: "too long to be cutting in") }
        let opensWithCue = opensWithCue(realWords)
        let asksSomething = utterance.contains("?") || realWords.prefix(3).contains { questionWords.contains($0) }
        if realWords.count >= minimumQuestionWords, opensWithCue || asksSomething {
            return .question(utterance.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if realWords.count == 2, opensWithCue, questionWords.contains(realWords[1]) {
            return .question(utterance.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .ignore(reason: "not addressed to Buddy")
    }

    /// Whether a question asked the usual way is only asking to hear the
    /// last answer again, which is replayed rather than answered.
    static func isReplayRequest(_ question: String) -> Bool {
        replayPhrases.contains(commandPhrase(from: words(of: question)))
    }

    /// The share of the heard topic words that are also in what Buddy just
    /// said. Common words are left out: "is", "the", "it" are in every
    /// sentence and would make any question look like an echo.
    static func echoShare(of heardWords: [String], recentlySpoken: [String]) -> Double {
        let spokenWords = recentlySpoken.flatMap(words(of:))
        guard !spokenWords.isEmpty else { return 0 }
        var comparedWords = heardWords.filter { !commonWords.contains($0) }
        if comparedWords.count < 2 { comparedWords = heardWords }
        guard !comparedWords.isEmpty else { return 0 }
        let matching = comparedWords.filter { heard in spokenWords.contains { spoken in sameWord(heard, spoken) } }
        return Double(matching.count) / Double(comparedWords.count)
    }

    /// The same word, allowing for the recognizer's endings ("caches" for
    /// "cache", "returned" for "returns").
    private static func sameWord(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        // A plural or a verb ending heard differently: "list" and "lists".
        if first.count >= 3, second.count >= 3, first + "s" == second || second + "s" == first { return true }
        guard first.count >= 5, second.count >= 5 else { return false }
        return first.prefix(5) == second.prefix(5)
    }

    /// Cues that open a cut-in and stop Buddy at once. Narrower than the
    /// openings that make a question count: "so" and "but" alone are in
    /// every other sentence of a video, "but why" is not.
    private static let yieldCues = ["wait", "hold on", "hang on", "sorry", "excuse me", "but why", "but how", "but what", "but wait"]
    /// Never taken for Buddy's words, so a cut-in keeps its opening and its
    /// question even when Buddy happens to say "what" or "wait" too.
    private static let protectedWords: Set<String> = ["wait", "hold", "hang", "sorry", "excuse", "why", "how", "what", "when",
                                                       "where", "which", "who", "huh", "does", "do", "is", "can", "could", "should"]

    /// How long after Buddy finished a sentence its echo can still arrive
    /// in the transcript. Deepgram's results trail the audio by well under a
    /// second and Apple Speech's by up to about one and a half; past this,
    /// the same words heard again are the student quoting Buddy.
    static let echoArrivesWithinSeconds: Double = 2.0

    /// Which heard words are Buddy's own voice coming back: a word that,
    /// with a word beside it, follows two words of one of Buddy's recent
    /// sentences in order (one dropped word allowed, as recognizers drop
    /// "of" and "the"). Only words
    /// heard while that sentence was being said, or just after, count. A
    /// single matching word among the student's own ("why does high
    /// start", with Buddy talking about high) stays the student's.
    static func buddyWordMask(_ heardWords: [String], heardAt heardTimes: [Double], spoken: [SpokenSentence]) -> [Bool] {
        let sentences = spoken.map { (words: words(of: $0.text), startedAt: $0.startedAt, endedAt: $0.endedAt) }
            .filter { !$0.words.isEmpty }
        var isBuddys = [Bool](repeating: false, count: heardWords.count)
        guard !sentences.isEmpty, heardTimes.count == heardWords.count else { return isBuddys }
        func couldBeEcho(_ heardIndex: Int, of sentence: (words: [String], startedAt: Double, endedAt: Double?)) -> Bool {
            let heardAt = heardTimes[heardIndex]
            return heardAt >= sentence.startedAt - 0.5
                && (sentence.endedAt.map { heardAt <= $0 + echoArrivesWithinSeconds } ?? true)
        }
        func matches(_ heardIndex: Int, _ sentence: (words: [String], startedAt: Double, endedAt: Double?), _ spokenIndex: Int) -> Bool {
            heardIndex >= 0 && heardIndex < heardWords.count && spokenIndex >= 0 && spokenIndex < sentence.words.count
                && couldBeEcho(heardIndex, of: sentence)
                && sameWord(heardWords[heardIndex], sentence.words[spokenIndex])
        }
        for heardIndex in heardWords.indices where !protectedWords.contains(heardWords[heardIndex]) {
            search: for sentence in sentences {
                for spokenIndex in sentence.words.indices where matches(heardIndex, sentence, spokenIndex) {
                    let neighbourFollows = matches(heardIndex - 1, sentence, spokenIndex - 1) || matches(heardIndex - 1, sentence, spokenIndex - 2)
                        || matches(heardIndex + 1, sentence, spokenIndex + 1) || matches(heardIndex + 1, sentence, spokenIndex + 2)
                    if neighbourFollows { isBuddys[heardIndex] = true; break search }
                }
            }
        }
        // A question word in the middle of Buddy's own run ("until one item
        // is left") is Buddy's too; one at the edge of the student's words
        // stays theirs.
        for heardIndex in heardWords.indices where protectedWords.contains(heardWords[heardIndex]) {
            let betweenBuddys = heardIndex > 0 && heardIndex + 1 < heardWords.count
                && isBuddys[heardIndex - 1] && isBuddys[heardIndex + 1]
            let saidThen = sentences.contains { sentence in
                couldBeEcho(heardIndex, of: sentence) && sentence.words.contains { sameWord(heardWords[heardIndex], $0) }
            }
            if betweenBuddys && saidThen { isBuddys[heardIndex] = true }
        }
        return isBuddys
    }

    /// Where in the student's words a cut-in cue starts, if one does.
    static func yieldCueStart(inStudentWords studentWords: [String]) -> Int? {
        let realWords = studentWords.map { fillerWords.contains($0) ? "" : $0 }
        for index in realWords.indices where !realWords[index].isEmpty {
            let opening = realWords[index...].filter { !$0.isEmpty }.prefix(2).joined(separator: " ")
            if yieldCues.contains(where: { cue in opening == cue || opening.hasPrefix(cue + " ") }) { return index }
        }
        return nil
    }

    private static func opensWithCue(_ realWords: [String]) -> Bool {
        let opening = realWords.prefix(2).joined(separator: " ")
        return cueOpenings.contains { cue in opening == cue || opening.hasPrefix(cue + " ") }
    }

    /// The words with "okay", "buddy" and "please" around a command taken
    /// off, so "okay buddy, go on please" is "go on".
    private static func commandPhrase(from words: [String]) -> String {
        var trimmed = words.filter { !fillerWords.contains($0) }
        while let first = trimmed.first, ["okay", "ok", "buddy", "hey", "alright", "right"].contains(first) { trimmed.removeFirst() }
        while let last = trimmed.last, ["please", "buddy", "thanks"].contains(last), trimmed.count > 1 { trimmed.removeLast() }
        return trimmed.joined(separator: " ")
    }

    static func words(of text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

/// The words heard while an answer plays, kept for a few seconds and read as
/// a whole rather than in chunks. Pure: fed the recognizer's text as it
/// arrives, with the time, and asked again as time passes, so the whole
/// sequence can be checked offline.
struct TalkOverTranscript {
    enum Action: Equatable {
        case yield, endYield, hold, resume, slower, repeatPreviousSentence, replayAnswer
        case question(String)
        case ignored(wordCount: Int, reason: String)
        /// Ask the recognizer for its final words now: the student stopped.
        case flushRecognizer
    }

    /// "Wait" or "hold on" alone pauses Buddy, but it is also how most
    /// cut-ins start ("wait, why does..."). It counts as a hold only once
    /// nothing has followed it for this long.
    static let holdConfirmSeconds: Double = 1.5
    /// Once Buddy has paused, the microphone hears the student alone, so
    /// the end of what they said is read from it: this long below the
    /// speech level. Deepgram's interim text can stall for longer than a
    /// comma while it decides where a phrase ends, so the text is not used.
    static let silenceEndsUtteranceSeconds: Double = 1.2
    /// After asking the recognizer for its final words, how long to wait
    /// for them before using the text there is.
    static let finalWordsWaitSeconds: Double = 0.6
    /// Speech the student is still making, as loud as TalkOverListener's
    /// loudness gate: a person at the Mac.
    static let speechDecibels: Float = -40
    /// A room too noisy for the level to drop: judged this long after the
    /// student's last word all the same.
    static let longestUtteranceAfterLastWordSeconds: Double = 4.0

    /// The student has finished when none of their words has arrived for
    /// this long. Buddy's words arriving meanwhile do not count, so the
    /// student's own pause, not a gap in the recognizer's results while two
    /// voices overlap, ends what they said. Longer than the 0.6s this used
    /// to be, which cut a question in three when results came in bursts.
    static let studentPauseSeconds: Double = 1.1
    /// While Buddy's voice overlaps, the recognizer can hold the rest of a
    /// student's sentence back for a second or more. So the words are also
    /// left until the transcript has stopped changing for this long...
    static let recognizerSettledSeconds: Double = 0.6
    /// ...unless Buddy's voice keeps it changing: the student's words are
    /// judged anyway this long after the last of them.
    static let longestWaitForTheRecognizerSeconds: Double = 3.0
    /// How far back heard words are kept, so a question judged once its end
    /// arrives still has the opening heard a few seconds earlier.
    static let keptForSeconds: Double = 8

    private struct HeardToken {
        var raw: String
        var word: String
        var heardAt: Double
    }
    private var tokens: [HeardToken] = []
    private var lastFullText = ""
    /// Tokens before this are done with: acted on, or too old.
    private var firstLiveToken = 0
    private var lastStudentWordAt: Double?
    private var lastChangeAt: Double?
    private var studentWordsSeenCount = 0
    private var needsJudging = false
    private(set) var isYielding = false
    /// When the microphone last heard speech, and whether any level has
    /// been heard at all (offline sequences may have none).
    private var lastSpeechAt: Double?
    private var hasHeardLevels = false
    private var flushRequestedAt: Double?
    private var changedSinceFlush = false

    /// The loudness of the latest buffer from the microphone.
    mutating func levelHeard(_ decibels: Float, at time: Double) {
        hasHeardLevels = true
        if decibels >= Self.speechDecibels {
            lastSpeechAt = time
            // Speaking again while the final words were awaited: not the end.
            if flushRequestedAt != nil, isYielding { flushRequestedAt = nil }
        }
    }

    /// The recognizer's whole text so far. Words it revises keep the time
    /// they were first heard.
    mutating func heard(_ fullText: String, at time: Double, recentlySpoken: [SpokenSentence], wasLoudEnough: Bool) -> [Action] {
        if fullText != lastFullText {
            lastChangeAt = time
            if flushRequestedAt != nil { changedSinceFlush = true }
        }
        lastFullText = fullText
        var updated: [HeardToken] = []
        for raw in fullText.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            let word = TalkOverHearing.words(of: raw).joined()
            guard !word.isEmpty else { continue }
            let index = updated.count
            let heardAt = index < tokens.count ? tokens[index].heardAt : time
            updated.append(HeardToken(raw: raw, word: word, heardAt: heardAt))
        }
        tokens = updated
        if firstLiveToken > tokens.count { firstLiveToken = tokens.count }
        forgetOldTokens(now: time)

        let studentIndices = studentTokenIndices(recentlySpoken: recentlySpoken)
        if studentIndices.count > studentWordsSeenCount {
            lastStudentWordAt = time
            needsJudging = true
        }
        studentWordsSeenCount = studentIndices.count

        var actions: [Action] = []
        if !isYielding, wasLoudEnough,
           TalkOverHearing.yieldCueStart(inStudentWords: studentIndices.map { tokens[$0].word }) != nil {
            isYielding = true
            actions.append(.yield)
        }
        return actions
    }

    /// Called as time passes: judges the student's words once they paused.
    mutating func timePassed(to time: Double, recentlySpoken: [SpokenSentence], wasLoudEnough: Bool) -> [Action] {
        forgetOldTokens(now: time)
        guard needsJudging, let lastStudentWordAt else { return [] }
        let tooLongSinceTheLastWord = time - lastStudentWordAt >= Self.longestUtteranceAfterLastWordSeconds
        if isYielding && hasHeardLevels {
            // Buddy is silent: the microphone says when the student stopped.
            let silentFor = time - (lastSpeechAt ?? lastStudentWordAt)
            guard silentFor >= Self.silenceEndsUtteranceSeconds || tooLongSinceTheLastWord else { return [] }
            guard let flushRequestedAt else {
                flushRequestedAt = time
                changedSinceFlush = false
                return [.flushRecognizer]
            }
            // The final words, or as long as they may take.
            let finalWordsArrived = changedSinceFlush && time - (lastChangeAt ?? time) >= 0.15
            guard finalWordsArrived || time - flushRequestedAt >= Self.finalWordsWaitSeconds else { return [] }
        } else {
            // Buddy still talking: its words keep the transcript moving, so
            // the student's pause and the text settling decide.
            guard time - lastStudentWordAt >= Self.studentPauseSeconds else { return [] }
            let recognizerHasSettled = time - (lastChangeAt ?? lastStudentWordAt) >= Self.recognizerSettledSeconds
            guard recognizerHasSettled || time - lastStudentWordAt >= Self.longestWaitForTheRecognizerSeconds else { return [] }
        }
        let studentIndices = studentTokenIndices(recentlySpoken: recentlySpoken)
        var studentWords = studentIndices.map { tokens[$0].word }
        var studentRaw = studentIndices.map { tokens[$0].raw }
        // Whatever came before a cue was something else: the cut-in starts there.
        if let cueStart = TalkOverHearing.yieldCueStart(inStudentWords: studentWords) {
            studentWords = Array(studentWords[cueStart...])
            studentRaw = Array(studentRaw[cueStart...])
        }
        let utterance = studentRaw.joined(separator: " ")
        // Buddy's words are already taken out, so the echo share is not
        // asked again: a question may share the answer's topic words.
        let meaning = TalkOverHearing.meaning(ofUtterance: utterance, recentlySpoken: [], wasLoudEnough: wasLoudEnough)
        // A hold is only a hold once nothing has followed it for a while:
        // until then it may be the first word of a question.
        if meaning == .hold {
            // While Buddy talks the microphone hears Buddy too, so only once
            // it has paused does the level say the student went quiet.
            let microphoneSaysQuietSince = isYielding && hasHeardLevels ? (lastSpeechAt ?? lastStudentWordAt) : lastStudentWordAt
            let quietSince = max(lastStudentWordAt, microphoneSaysQuietSince)
            if time - quietSince < Self.holdConfirmSeconds { return [] }
        }
        needsJudging = false
        flushRequestedAt = nil
        let wasYielding = isYielding
        var actions: [Action] = []
        switch meaning {
        case .ignore(let reason):
            // Kept a while longer: it may be the start of what comes next.
            actions.append(.ignored(wordCount: studentWords.count, reason: reason))
            if wasYielding { actions.append(.endYield) }
            isYielding = false
            return actions
        case .hold: actions.append(.hold)
        case .resume: actions.append(.resume)
        case .slower:
            if wasYielding { actions.append(.endYield) }
            actions.append(.slower)
        case .repeatPreviousSentence:
            if wasYielding { actions.append(.endYield) }
            actions.append(.repeatPreviousSentence)
        case .replayAnswer: actions.append(.replayAnswer)
        case .question(let question): actions.append(.question(question))
        }
        isYielding = false
        firstLiveToken = tokens.count
        studentWordsSeenCount = 0
        self.lastStudentWordAt = nil
        return actions
    }

    private mutating func forgetOldTokens(now: Double) {
        while firstLiveToken < tokens.count, now - tokens[firstLiveToken].heardAt > Self.keptForSeconds {
            firstLiveToken += 1
            studentWordsSeenCount = max(0, studentWordsSeenCount - 1)
        }
    }

    /// The student's own words while Buddy is paused for them, Buddy's
    /// words taken out and from the cue on, for the notch to show live.
    /// Empty when Buddy is not paused for a cut-in.
    func wordsOfTheCutIn(recentlySpoken: [SpokenSentence]) -> String {
        guard isYielding else { return "" }
        let studentIndices = studentTokenIndices(recentlySpoken: recentlySpoken)
        var raw = studentIndices.map { tokens[$0].raw }
        if let cueStart = TalkOverHearing.yieldCueStart(inStudentWords: studentIndices.map { tokens[$0].word }) {
            raw = Array(raw[cueStart...])
        }
        return raw.joined(separator: " ")
    }

    /// The live tokens that are the student's: not Buddy's, not filler.
    private func studentTokenIndices(recentlySpoken: [SpokenSentence]) -> [Int] {
        guard firstLiveToken < tokens.count else { return [] }
        let liveWords = tokens[firstLiveToken...].map(\.word)
        let liveTimes = tokens[firstLiveToken...].map(\.heardAt)
        let isBuddys = TalkOverHearing.buddyWordMask(liveWords, heardAt: liveTimes, spoken: recentlySpoken)
        return liveWords.indices.filter { !isBuddys[$0] }.map { $0 + firstLiveToken }
    }
}
