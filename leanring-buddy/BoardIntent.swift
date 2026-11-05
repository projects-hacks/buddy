//
//  BoardIntent.swift
//  leanring-buddy
//
//  Whether what the student said opens the teaching board, and, while it is
//  open, whether it closes it.
//
//  A check of its own rather than a sixth question kind. The sorter's five
//  kinds decide how long to talk and which brain answers, and were
//  calibrated on their own example sets; a new kind would move every
//  boundary between them. Opening the board is a different decision, taken
//  before the sorter: it takes the screen away, so it has to be precise. A
//  teach question about what is on screen ("explain this from scratch",
//  "walk me through this function") must stay a normal answer with cards,
//  because the board shows no screenshot and could not teach what it cannot
//  see. So the board opens only for a named topic, asked for from zero or
//  on a whiteboard, with nothing pointing at the screen.
//
//  Graded by scripts/board/intent_test.swift on 64 development phrasings,
//  30 held out, and 30 for closing.
//

import Foundation

enum BoardIntent {
    /// Why a phrase did or did not open the board, for the log and the test.
    enum Decision: Equatable {
        case opens(reason: String)
        case staysNormal(reason: String)

        var opensBoard: Bool { if case .opens = self { return true }; return false }
    }

    static func opensBoard(_ transcript: String) -> Bool {
        decide(transcript).opensBoard
    }

    static func decide(_ transcript: String) -> Decision {
        let words = normalized(transcript)

        let asksFromZero = matchesAny(words, fromZeroPatterns)
        let saysTheyKnowNothing = matchesAny(words, knowsNothingPatterns)
        let asksForWhiteboard = matchesAny(words, whiteboardPatterns)
        guard asksFromZero || saysTheyKnowNothing || asksForWhiteboard else {
            return .staysNormal(reason: "no from-scratch or whiteboard request")
        }
        // "i'm new to all of this" is about everything, not about the screen.
        // Nor is "forget what's on my screen".
        let wordsWithoutAllOfThis = words
            .replacingOccurrences(of: #"\b(all|any) (of )?this\b"#, with: "everything", options: .regularExpression)
            .replacingOccurrences(of: #"\bforget (about )?(what's |what is )?(on )?(my|the) screen\b"#, with: "", options: .regularExpression)
        if matchesAny(wordsWithoutAllOfThis, pointsAtScreenPatterns) {
            return .staysNormal(reason: "about something on the screen")
        }
        // "starting from the first concept on the whiteboard" is a place in
        // the lesson; without a whiteboard, "from the first if" is on screen.
        if !asksForWhiteboard && matchesAny(words, positionPatterns) {
            return .staysNormal(reason: "a place in what is on screen, not a starting point in an idea")
        }
        if matchesAny(words, buildingPatterns) && !matchesAny(words, teachingVerbPatterns) {
            return .staysNormal(reason: "making something from scratch, not learning it")
        }
        let topicWords = topic(of: words)
        guard !topicWords.isEmpty else {
            return .staysNormal(reason: "no topic named")
        }
        let trigger = asksForWhiteboard ? "whiteboard" : (saysTheyKnowNothing ? "knows nothing" : "from scratch")
        return .opens(reason: "\(trigger): \(topicWords.joined(separator: " "))")
    }

    /// "done", "thanks, that's it", "close the board": the whole utterance is
    /// a goodbye. Anything more ("thanks, what about when a node leaves") is
    /// a follow-up, and "thanks" or "got it" alone are not enough, since
    /// people say them between questions.
    static func closesBoard(_ transcript: String) -> Bool {
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return false }
        var words = normalized(transcript).split(separator: " ").map(String.init)
        let leadingFillers: Set<String> = ["ok", "okay", "great", "perfect", "cool", "alright", "awesome", "nice",
                                           "thanks", "thank", "you", "buddy", "so", "yeah", "yes", "got", "it", "right",
                                           "brilliant", "lovely", "and", "well", "oh"]
        let trailingFillers: Set<String> = ["thanks", "thank", "you", "buddy", "for", "now", "today", "here", "then",
                                            "please", "so", "much", "a", "lot"]
        var core = words
        while let first = core.first, leadingFillers.contains(first), !closingCores.contains(core.joined(separator: " ")) {
            core.removeFirst()
        }
        while let last = core.last, trailingFillers.contains(last), !closingCores.contains(core.joined(separator: " ")) {
            core.removeLast()
        }
        words = core
        return closingCores.contains(words.joined(separator: " "))
    }

    // MARK: - Patterns

    private static let closingCores: Set<String> = [
        "done", "im done", "we're done", "were done", "all done", "i'm done", "i am done", "we are done",
        "that's it", "thats it", "that is it", "that's all", "thats all", "that is all",
        "that's enough", "thats enough", "that is enough", "enough",
        "close the board", "close the whiteboard", "close board", "close it", "put the board away",
        "end the lesson", "stop the lesson", "end the board", "finish the lesson",
        "finished", "im finished", "i'm finished", "we're finished", "were finished",
        "that's everything", "thats everything", "no more", "nothing else", "that's all i needed", "thats all i needed",
        "i'm done here", "im done here", "we're done here", "were done here"
    ]

    private static let fromZeroPatterns = [
        #"\bfrom scratch\b"#,
        #"\bfrom (the )?(very )?(start|beginning|basics|ground up|bottom up|first principles)\b"#,
        #"\bfrom (zero|nothing|square one)\b"#,
        #"\bstart(ing)? (from|with|at) (zero|nothing|scratch|square one|the (very )?(beginning|basics|start))\b"#,
        #"\b(begin|start) at the (very )?beginning\b"#,
        #"\bas if i('ve| have)? never (seen|heard|used|learned|studied|touched)\b"#,
        #"\b(like|as if) i('m| am) (a )?(complete|total|absolute) (beginner|newbie|novice)\b"#,
        #"\bthe (very )?basics\b"#,
        #"\bground up\b"#,
        #"\b(begin|start) at the (very )?(start|beginning)\b"#,
        #"\bnothing assumed\b"#,
        #"\bstarting with (absolutely )?nothing\b"#,
        #"\b(square one|day one|ground floor|blank slate|clean slate|first week|starting cold|bottom up)\b"#,
        #"\bfirst time\b.*\b(heard|seen|hearing|seeing|learning)\b|\b(heard|seen|hearing|seeing|learning)\b.*\bfirst time\b"#,
        #"\b(intro|introductory|beginner'?s?) (lesson|class|tutorial)\b"#
    ]

    private static let knowsNothingPatterns = [
        #"\bi (literally |really |honestly )?(know|knew) (absolutely |literally )?nothing about\b"#,
        #"\bi (don't|dont|do not) know (anything|a thing) about\b"#,
        #"\bassum(e|ing) (that )?i know nothing\b"#,
        #"\bi('ve| have)? never (heard of|learned|studied|seen|touched|used|done)\b"#,
        #"\bnever (heard of|learned|studied)\b"#,
        #"\b(complete|total|absolute) (beginner|newbie|novice)\b"#,
        #"\bi have no background\b"#,
        #"\b(pretend|assume|imagine|like|as if) i('ve| have)? never (coded|programmed|written|studied|seen|heard|learned|used)\b"#,
        #"\b(assume|like|as if) i('m| am) (brand |completely |totally )?new\b"#,
        #"\b(brand|completely|totally|absolutely) new to\b"#,
        #"\b(absolutely|completely|totally) clueless about\b"#,
        #"\bassum(e|ing) i know (absolutely |literally )?nothing\b"#
    ]

    private static let whiteboardPatterns = [
        #"^(?!.*\b(app|apps|tool|tools|icon|extension|miro|zoom|excalidraw|figjam|freeform|software|install|share)\b).*\b(on|use|using|with|at|onto) (a|the|your) (white ?board|board)\b"#,
        #"\bwhite ?board (it|this out|it out|time)\b"#,
        #"\b(empty|blank|fresh|clean) (white ?board|board|page|canvas)\b"#,
        #"\b(clear|dim|blank) the screen and (teach|explain|show)\b"#,
        // A whiteboard named anywhere, as long as it is a lesson that is
        // asked for and not a whiteboard app being asked about.
        #"^(?!.*\b(app|apps|tool|tools|icon|extension|miro|zoom|excalidraw|figjam|freeform|software|install|share)\b).*\b(white ?board|blank board)\b.*\b(teach|explain|walk|show|lesson|walkthrough|draw|go over|take me through)\b"#,
        #"^(?!.*\b(app|apps|tool|tools|icon|extension|miro|zoom|excalidraw|figjam|freeform|software|install|share)\b).*\b(teach|explain|walk|show|lesson|walkthrough|draw|go over|take me through)\b.*\b(white ?board|blank board)\b"#
    ]

    /// Strong signs the subject is on the screen. "it" and "that" are not
    /// among them: "explain how garbage collection works, i know nothing
    /// about it" names its topic, and without one the topic check refuses.
    private static let pointsAtScreenPatterns = [
        #"\b(this|these|those|here)\b"#,
        #"\bon (my|the) screen\b"#,
        #"\bline \d+\b"#,
        #"\bthat (code|function|line|diagram|error|file|page|part|bit|word|paragraph|sentence|equation|method|class|variable)\b"#
    ]

    private static let positionPatterns = [
        #"\bfrom (line|row|step|page|slide|minute|chapter|section|paragraph|where)\b"#,
        #"\bfrom (the )?(top|bottom)\b"#,
        #"\b(start|beginning) of (the|my|our) \w+"#,
        #"\bfrom the (first|second|third|next|last) \w+"#
    ]

    private static let buildingPatterns = [
        #"\b(build|make|create|write|code|implement|rewrite|redo|recreate|install|reinstall|configure|deploy|set up|setup|restart)\b"#,
        #"\bstart (a|an|my|the|our) (new )?\w+"#
    ]

    private static let teachingVerbPatterns = [
        #"\b(teach|explain|learn|understand|show me how|walk me through|go over|take me through|introduce)\b"#
    ]

    /// Words that are not a topic: the request itself, fillers and the
    /// screen's own nouns. Whatever is left is what they want to learn.
    private static let wordsThatAreNotATopic: Set<String> = [
        "teach", "me", "explain", "learn", "show", "walk", "through", "go", "over", "take", "tell", "about",
        "understand", "introduce", "cover", "start", "starting", "begin", "from", "scratch", "the", "very",
        "beginning", "basics", "basic", "ground", "up", "bottom", "first", "principles", "zero", "nothing",
        "square", "one", "with", "at", "a", "an", "to", "of", "on", "in", "and", "or", "it", "that", "is", "are",
        "how", "what", "why", "does", "do", "works", "work", "please", "can", "could", "would", "you", "i",
        "i'm", "im", "i've", "ive", "know", "knew", "don't", "dont", "not", "anything", "thing", "never",
        "heard", "learned", "studied", "seen", "used", "touched", "done", "complete", "total", "totally",
        "absolute", "beginner", "newbie", "novice", "new", "assume", "want", "let's", "lets", "us", "we",
        "whiteboard", "white", "board", "use", "using", "draw", "for", "buddy", "hey", "okay", "ok", "so",
        "really", "literally", "honestly", "have", "no", "background", "idea", "where", "my", "your", "all",
        "before", "as", "if", "like", "be", "been", "just", "now", "again", "out", "there", "this", "these",
        "code", "line", "screen", "page", "file", "function", "error", "here", "everything"
    ]

    // MARK: - Helpers

    static func normalized(_ transcript: String) -> String {
        var text = transcript.lowercased()
        text = text.replacingOccurrences(of: "\u{2019}", with: "'")
        text = text.replacingOccurrences(of: #"[^a-z0-9' ]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func matchesAny(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func topic(of words: String) -> [String] {
        words.split(separator: " ").map(String.init).filter { word in
            !wordsThatAreNotATopic.contains(word) && word.count > 1
        }
    }
}
