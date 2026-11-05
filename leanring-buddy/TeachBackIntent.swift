//
//  TeachBackIntent.swift
//  leanring-buddy
//
//  Whether what the student said asks to explain a topic to Buddy ("let me
//  explain consistent hashing back to you", "check my understanding of
//  binary search", "teach it back"), and, while teach-back is open, whether
//  they want another go at a part.
//
//  The direction is the whole decision. "Explain X to me" and "let me
//  explain X" share nearly every word and mean opposite things: in one
//  Buddy talks, in the other the microphone stays open for minutes. So the
//  student has to be the one explaining (let me, can i, i want to, i'll),
//  to Buddy, about a topic, and the utterance must be the request itself:
//  "let me explain what i'm trying to do, ..." is context for a question,
//  not an offer to teach. A phrase that does not clearly ask for this stays
//  a normal question, which costs the student nothing.
//
//  Graded by scripts/teach_back/intent_test.swift.
//

import Foundation

enum TeachBackIntent {
    enum Decision: Equatable {
        case opens(topic: String, reason: String)
        case staysNormal(reason: String)

        var opensTeachBack: Bool { if case .opens = self { return true }; return false }
        var topic: String? { if case .opens(let topic, _) = self { return topic }; return nil }
    }

    /// `fallbackTopic` is what "teach it back" or "let me explain it" is
    /// about: the lesson just given, or the board's title. Without one, a
    /// request with no topic stays a normal question.
    static func decide(_ transcript: String, fallbackTopic: String?) -> Decision {
        let words = spokenWords(transcript)
        guard !words.isEmpty else { return .staysNormal(reason: "nothing said") }

        let asksPermissionToExplain = matchesAny(words, permissionToExplainPatterns)
        guard let opener = firstMatch(words, studentExplainsPatterns + permissionToExplainPatterns)
                ?? listenerTailOpener(words) else {
            return .staysNormal(reason: "the student is not offering to explain")
        }
        if matchesAny(words, helperExplainsPatterns) {
            return .staysNormal(reason: "Buddy is asked to explain")
        }
        if matchesAny(words, contextNotTopicPatterns) {
            return .staysNormal(reason: "context for a question, not a topic to teach")
        }
        if !asksPermissionToExplain, startsAsQuestionAboutIt(words) {
            return .staysNormal(reason: "a question about teaching, not a request")
        }
        // "let me explain, i opened the file and clicked run": the request
        // word ends a clause and a story follows.
        if transcript.range(of: #"(?i)\b(explain|teach)\s*[,:;\u{2014}-]\s*\S+(\s+\S+){3,}"#, options: .regularExpression) != nil,
           !matchesAny(words, teachBackNamedPatterns) {
            return .staysNormal(reason: "a story follows the request")
        }
        let wordCount = words.split(separator: " ").count
        guard wordCount <= maximumRequestWords else {
            return .staysNormal(reason: "too long to be the request itself")
        }

        var topicWords = topic(after: opener, in: words)
        // "i think i get big o notation now, can i say it back to you": the
        // topic came before the request.
        if topicWords.isEmpty || placeholderTopics.contains(topicWords),
           let earlier = topicNamedBefore(opener, in: words) {
            topicWords = earlier
        }
        if !topicWords.isEmpty, !placeholderTopics.contains(topicWords) {
            if matchesAny(topicWords, pointsAtScreenPatterns) {
                return .staysNormal(reason: "about something on the screen")
            }
            return .opens(topic: topicWords, reason: "offers to explain")
        }
        if let fallbackTopic, !fallbackTopic.trimmingCharacters(in: .whitespaces).isEmpty {
            return .opens(topic: fallbackTopic, reason: "offers to explain the last lesson")
        }
        return .staysNormal(reason: "no topic, and no lesson to teach back")
    }

    static func opensTeachBack(_ transcript: String, fallbackTopic: String?) -> Bool {
        decide(transcript, fallbackTopic: fallbackTopic).opensTeachBack
    }

    /// While teach-back is open: "let me try that part again", "let me
    /// explain the replication part again", "try again". The student wants
    /// the microphone again; anything else on the board is a question.
    static func asksToExplainAgain(_ transcript: String) -> Bool {
        let words = spokenWords(transcript)
        if matchesAny(words, helperExplainsPatterns) { return false }
        if matchesAny(words, explainAgainPatterns) { return true }
        // A fresh "let me explain the second part" counts as another go.
        return firstMatch(words, studentExplainsPatterns) != nil && !startsAsQuestionAboutIt(words)
            && !matchesAny(words, contextNotTopicPatterns)
    }

    /// The words as spoken, with casual forms written out and anything
    /// before a change of mind dropped: in "quiz me, no wait, actually let
    /// me explain bonds to you" only the second request counts.
    static func spokenWords(_ transcript: String) -> String {
        var words = " " + BoardIntent.normalized(transcript) + " "
        for (casual, written) in [(" lemme ", " let me "), (" gonna ", " going to "), (" wanna ", " want to "),
                                  (" gimme ", " give me "), (" i m ", " i'm "), (" ima ", " i'm going to ")] {
            words = words.replacingOccurrences(of: casual, with: written)
        }
        if let change = words.range(of: #"\b(no wait|actually no|scratch that|no no|never mind|nevermind|no actually)\b"#,
                                    options: [.regularExpression, .backwards]) {
            words = String(words[change.upperBound...])
        }
        return words.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"^(actually|wait) "#, with: "", options: .regularExpression)
    }

    /// "i wanna go through the doppler effect myself and you tell me what i
    /// miss": no request verb of the usual kind, but the student talking
    /// and Buddy listening for what is missing says the same thing.
    private static func listenerTailOpener(_ words: String) -> Range<String.Index>? {
        guard matchesAny(words, listenerTailPatterns) else { return nil }
        return words.range(of: #"\bi('m| am)? ?(want to |going to |'ll |will |'d like to |would like to |)(try to )?(go through|run through|talk through|break down|describe|say|explain|teach)\b"#,
                           options: .regularExpression)
    }

    /// The topic said before the request: "i get stack versus heap now".
    private static func topicNamedBefore(_ opener: Range<String.Index>, in words: String) -> String? {
        let before = String(words[..<opener.lowerBound])
        guard let match = before.range(of: #"\b(understand|get|got|know|learned|figured out) (.+?) (now|finally|i think)\b"#,
                                       options: .regularExpression) else {
            // "flag anything i get wrong about photosynthesis": named at the end.
            let after = String(words[opener.upperBound...])
            guard let aboutMatch = after.range(of: #"\babout ([a-z0-9' ]+)$"#, options: .regularExpression) else { return nil }
            let named = String(after[aboutMatch]).replacingOccurrences(of: "about ", with: "")
            return named.isEmpty ? nil : named
        }
        var named = String(before[match])
        named = named.replacingOccurrences(of: #"^(understand|get|got|know|learned|figured out) "#, with: "", options: .regularExpression)
        named = named.replacingOccurrences(of: #" (now|finally|i think)$"#, with: "", options: .regularExpression)
        named = named.replacingOccurrences(of: #"^(how |what )?(a |an |the )?"#, with: "", options: .regularExpression)
        return named.isEmpty || placeholderTopics.contains(named) ? nil : named
    }

    // MARK: - Patterns

    /// A request to explain is short; past this it is a question with a
    /// preamble, or the explanation itself.
    static let maximumRequestWords = 20

    /// The student offering to do the explaining.
    private static let studentExplainsPatterns = [
        #"\bteach(ing)? (it )?back\b"#,
        #"\bteach back\b"#,
        #"\blet me (try (to )?|have a go at |have another go at |take a shot at |have a crack at |have a stab at |see if i can |attempt to |quickly )?(explain|teach|walk you through|talk you through|break down|tell you (about|how))\b"#,
        #"\blet me (try|have a go at|have another go at|take a shot at|have a crack at|have a stab at) (explaining|teaching)\b"#,
        #"\blet me (say|describe|go through|run through|recap|summarise|summarize) (how|what|why)\b"#,
        #"\b(let me|can i|could i) (say|tell you|explain) (it |that |this )?back to you\b"#,
        #"\b(can|could|may|should) i (go first and |first )?(try (to )?|quickly )?(explain|teach|walk you through|talk you through|break down|tell you (about|how))\b"#,
        #"\b(can|could|may) i try (explaining|teaching)\b"#,
        #"\bi('d| would)? (like|want) to (try (to )?)?(explain|teach|walk you through|talk you through|break down)\b"#,
        #"\bi('d| would)? (like|want) to (try explaining|try teaching|say it back|say that back)\b"#,
        #"\b(i('ll| will|'m going to| am going to)|going to) (try to |now )?(explain|teach|walk you through|talk you through|break down)\b"#,
        #"\b(check|test) (my understanding|whether i (really )?(understand|understood|get|got)|if i (really )?(understand|understood|get|got)|that i (understand|get))\b"#,
        #"\b(check|see) (if|whether) i('ve| have)? (got|understood)\b"#,
        #"\b(by )?letting me (explain|teach)\b"#,
        #"\blet me do the (explaining|teaching)( about| on| of)?\b"#,
        #"\b(time for me to|my turn to) (explain|teach)\b"#,
        // Roles: the student is the teacher for a minute.
        #"\b(i('ll| will) be the teacher|i'm the teacher|you('re| are) my student|you be the student|you be my student)\b"#,
        #"\b(listen|hear me out)( to me)?( while| as| and)? i('ll| will)? (explain|teach|walk|go through|talk)\b"#
    ]

    /// Asked as a question, and still an offer: "would it help if i
    /// explained recursion to you", "is it okay if i explain mortgages".
    private static let permissionToExplainPatterns = [
        #"\b(would it help|is it ok(ay)?|would it be ok(ay)?|how about|what if|do you mind|mind) (if )?i (explain|explained|teach|taught|try|tried|walk|walked|break|talk|went|go) "#
    ]

    /// Buddy is asked to listen for what is missing.
    private static let listenerTailPatterns = [
        #"\b(and|then|so) (you|u) (tell|check|see|mark|point|flag|fill|correct|listen|catch)\b"#,
        #"\b(see|tell me|show me) what i (missed|miss|left out|got wrong|skipped|skip)\b"#,
        #"\bwhere i('m| am) (off|wrong)\b"#
    ]

    /// Any of these names teach-back outright, whatever follows.
    private static let teachBackNamedPatterns = [
        #"\bteach(ing)? (it )?back\b"#,
        #"\bteach back\b"#
    ]

    /// Buddy is the one asked to explain.
    private static let helperExplainsPatterns = [
        #"\b(explain|teach|walk|tell|show)\b[a-z' ]*\b(back )?to me\b"#,
        #"\bteach me\b"#,
        #"\b(can|could|would|will|do) you (please )?(explain|teach|try|walk|tell|show|go over|break)\b"#,
        // "teach it back" said alone is the request itself.
        #"^(please )?(explain|teach(?! (it )?back)|describe|walk me|tell me)\b"#,
        #"\bhelp me (understand|explain)\b"#,
        #"\b(quiz|test) me\b"#,
        #"\bexplain later\b"#,
        #"\bteach my\b"#,
        // Explaining it to someone else: "to my kid", "to my study group".
        #"\b(explain|teach|explaining|teaching)\b[a-z' ]* to (my|our|his|her|their) \w+"#,
        #"\b(explain|teach|explaining|teaching)\b[a-z' ]* to (a|some|the) (friend|kid|child|student|students|class|group|colleague|coworker|interviewer|beginner|five year old|team)\b"#,
        #"\b(if|when|while) you (explain|explained|teach|taught)\b"#,
        #"\byou('re| are)? (going to|gonna) (explain|teach)\b"#,
        #"\b(ask|asking) me (questions|a question|something)\b"#
    ]

    /// "let me explain what i'm trying to do", "my problem", "the
    /// situation": the student is setting up a question about their work.
    private static let contextNotTopicPatterns = [
        #"\bwhat (my|the|our) \w+ (said|says|told|wrote|asked|meant)\b"#,
        #"\b(and then|then|before i) ask (you )?(a |my )?question\b"#,
        #"\b(explain|teach|tell you|describe|say)( to you)?( about)? (what i('m| am| was)|what i (want|need|did|tried|meant)|what('s| is) (going on|happening|wrong)|what happened|my (problem|issue|situation|setup|code|bug|question|error|project|homework|assignment)|the (problem|issue|situation|context|setup|error|bug|question)|why (this|it|my|the code|the test|that)|what (this|it|that) (says|does|means)|how i (got|ended|did))\b"#,
        #"\b(this|that) (error|test|code|function|file|bug)\b"#,
        #"\b(what|how|why|where|when) (is|are|does|do|did|should|can|would) (i|it|this|that|a|an|the|my)\b.*$"#
    ]

    /// Topic words that mean "what is on screen" rather than an idea.
    private static let pointsAtScreenPatterns = [
        #"\b(this|these|those|here)\b"#,
        #"\bon (my|the) screen\b"#,
        #"\bline \d+\b"#
    ]

    private static let explainAgainPatterns = [
        #"^(okay |ok |so |um |hmm |wait )*(let me |can i |could i |i'll |i will |i want to |i'd like to )?(try|have (another|a) go|redo|do)( (that|it|this|the \w+( \w+)?))?( part| bit)?( (again|over))$"#,
        #"\b(let me|can i|could i|i('ll| will| want to|'d like to)) (try|redo|explain|do|have another go at|have a go at|go over)\b.*\b(again|part|bit|over|one more time)\b"#,
        #"\blet me (redo|retry|try again|start over|correct)\b"#,
        #"^(try again|again|one more time|let me try|take two)$"#
    ]

    /// Words that are the request and not its topic.
    private static let requestWords: Set<String> = [
        "let", "me", "try", "to", "explain", "explaining", "teach", "teaching", "walk", "talk", "you", "through",
        "tell", "about", "how", "it", "back", "can", "could", "may", "should", "i", "i'd", "id", "would", "like",
        "want", "wanna", "i'll", "ill", "will", "i'm", "im", "going", "gonna", "am", "check", "test", "my",
        "understanding", "of", "whether", "if", "understand", "understood", "get", "got", "that", "have", "a", "go",
        "at", "another", "see", "attempt", "quickly", "now", "okay", "ok", "so", "um", "uh", "hey", "buddy", "well",
        "right", "alright", "just", "the", "an", "what", "is", "are", "works", "work", "does", "do", "and", "then",
        "time", "please", "think", "really", "know", "i've", "ive", "out", "loud", "again", "on", "in", "today",
        "first", "break", "down", "say", "describe", "teacher", "student", "be", "for", "letting", "by", "turn", "mode"
    ]

    /// A topic that is only a pronoun means the lesson just given.
    private static let placeholderTopics: Set<String> = ["it", "that", "this", "them", "these", "those", "everything", "all", ""]

    // MARK: - Helpers

    private static func firstMatch(_ text: String, _ patterns: [String]) -> Range<String.Index>? {
        var earliest: Range<String.Index>?
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression),
               earliest == nil || range.lowerBound < earliest!.lowerBound {
                earliest = range
            }
        }
        return earliest
    }

    private static func matchesAny(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// "what does it mean to teach it back", "how would i explain this in
    /// an interview": a question about explaining, asked of Buddy.
    private static func startsAsQuestionAboutIt(_ words: String) -> Bool {
        words.range(of: #"^(what|why|how|when|where|is|does|do|did|which|who)\b"#, options: .regularExpression) != nil
    }

    /// The words after the request, up to "and you check it" or "to you",
    /// with the request's own words taken off both ends. "let me walk you
    /// through how garbage collection works and you check it" is about
    /// "garbage collection".
    static func topic(after opener: Range<String.Index>, in words: String) -> String {
        var rest = String(words[opener.upperBound...])
        for ending in [#"\b(and|then|so) (you|u|tell me|check|see|let me know|correct)\b.*$"#,
                       #"\b(back )?to (you|u)\b.*$"#,
                       #"\bback\b.*$"#,
                       #"\b(and|to) see (if|whether)\b.*$"#,
                       #"\bin my own words\b.*$"#,
                       #"\b(if|whether) i('m| am)? (right|wrong|correct)\b.*$"#,
                       #"\b(for|with) (you|u)\b.*$"#,
                       #"\bmyself\b.*$"#,
                       #"\bhere goes\b.*$"#,
                       #"\b(right|correct)$"#,
                       #"\bif that's (ok|okay|alright)\b.*$"#,
                       #"\b(so|and) (listen|hear)\b.*$"#] {
            rest = rest.replacingOccurrences(of: ending, with: "", options: .regularExpression)
        }
        // "teach back time, let me explain mitosis": a second request after
        // the first names the topic.
        if let second = firstMatch(rest, studentExplainsPatterns) {
            rest = String(rest[second.upperBound...])
        }
        // "how a hash map works", "how modes work in music theory": the
        // idea is the thing that works.
        let startsWithHow = rest.trimmingCharacters(in: .whitespaces).hasPrefix("how ")
        var topicWords = rest.split(separator: " ").map(String.init)
        if startsWithHow { topicWords.removeAll { $0 == "work" || $0 == "works" } }
        while let first = topicWords.first, requestWords.contains(first) { topicWords.removeFirst() }
        while let last = topicWords.last, requestWords.contains(last) { topicWords.removeLast() }
        return topicWords.joined(separator: " ")
    }
}

/// What the student said while teach-back listens, read for the end of the
/// explanation. Pure, so it is graded with the intent.
enum TeachBackHearing {
    /// What the explanation ends on when the student says they are done:
    /// the transcript without the closing words, or nil while they go on.
    ///
    /// "done" and "that's it" end it only as a sentence of their own:
    /// "and then the handshake is done" is part of the explanation, and so
    /// is "that's it for the ring, now the keys". A recognizer's punctuation
    /// marks the sentence; a run with none ends on silence instead.
    static func explanationIfFinished(_ transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var sentences = trimmed.components(separatedBy: CharacterSet(charactersIn: ".?!"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        while let last = sentences.last, last.isEmpty { sentences.removeLast() }
        guard let lastSentence = sentences.last else { return nil }
        let lastWords = coreWords(of: lastSentence)
        let earlierText = sentences.dropLast().joined(separator: ". ")

        if closingSentences.contains(lastWords.joined(separator: " ")) {
            return earlierText.isEmpty ? "" : earlierText + "."
        }
        // "... to the next server, and i'm done": a closing that names the
        // student ends the sentence it is in.
        let joined = lastWords.joined(separator: " ")
        for closing in closingsAnywhereAtTheEnd where joined.hasSuffix(" " + closing) || joined == closing {
            let lastSentenceWithoutClosing = removingTrailingWords(count: closing.split(separator: " ").count,
                                                                   from: lastSentence)
            let kept = [earlierText, lastSentenceWithoutClosing].filter { !$0.isEmpty }.joined(separator: ". ")
            return kept.isEmpty ? "" : kept + "."
        }
        return nil
    }

    /// Whole sentences that end the explanation.
    private static let closingSentences: Set<String> = [
        "done", "i'm done", "im done", "i am done", "all done", "finished", "i'm finished", "im finished",
        "i am finished", "that's it", "thats it", "that is it", "that's all", "thats all", "that is all",
        "that's everything", "thats everything", "the end", "that's my explanation", "thats my explanation",
        "that's all i've got", "thats all ive got", "that's all i have", "thats all i have", "i think that's it",
        "i think thats it", "i think i'm done", "i think im done", "that's it i'm done", "thats it im done",
        "that's all i'm done", "thats all im done", "done explaining", "i'm done explaining", "im done explaining"
    ]

    /// Closings that end the explanation even at the end of a longer
    /// sentence, because they can only be about the explaining.
    private static let closingsAnywhereAtTheEnd = [
        "and i'm done", "and im done", "and i am done", "i'm done explaining", "im done explaining",
        "and that's my explanation", "and thats my explanation", "that's it i'm done", "thats it im done",
        "and i'm finished", "and im finished"
    ]

    private static let leadingFillers: Set<String> = ["okay", "ok", "so", "and", "yeah", "yes", "right", "alright",
                                                      "um", "uh", "well", "buddy", "hey"]
    private static let trailingFillers: Set<String> = ["buddy", "thanks", "thank", "you", "now", "then", "so",
                                                       "yeah", "okay", "ok"]

    private static func coreWords(of sentence: String) -> [String] {
        var words = BoardIntent.normalized(sentence).split(separator: " ").map(String.init)
        while let first = words.first, leadingFillers.contains(first), words.count > 1 { words.removeFirst() }
        while let last = words.last, trailingFillers.contains(last), words.count > 1 { words.removeLast() }
        return words
    }

    private static func removingTrailingWords(count: Int, from sentence: String) -> String {
        var words = sentence.split(separator: " ").map(String.init)
        // Trailing fillers the closing was matched without.
        while let last = words.last, trailingFillers.contains(BoardIntent.normalized(last)), words.count > 1 {
            words.removeLast()
        }
        words.removeLast(min(count, words.count))
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
    }
}
