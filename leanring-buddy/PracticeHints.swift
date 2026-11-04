//
//  PracticeHints.swift
//  leanring-buddy
//
//  On a practice problem (LeetCode, HackerRank and the like), help comes in
//  steps instead of as the solution: a nudge, then the approach, then a walk
//  through by hand, then the code. The student decides how far to go, one
//  tap or one sentence at a time, and can ask for the code outright whenever
//  they want it.
//
//  Why. In a field experiment with about a thousand students, those who
//  practised with plain GPT-4 did 17% worse on the exam once it was taken
//  away, while a version that held back answers did not hurt them (Bastani
//  et al., PNAS 2025): the plain one became a crutch. Hint ladders are how
//  tutoring systems have long handled this, with one known failure, students
//  clicking straight through to the last hint without reading the others
//  (Aleven and Koedinger's "help abuse"). So the code is offered as a button
//  only once the approach has been given; before that it is one sentence
//  away, never hidden, and never refused.
//
//  This is not a quiz and nothing is graded. It changes only how much of
//  the answer is given at once.
//

import Foundation

/// A practice problem the student is working on.
struct PracticeProblem: Equatable {
    /// "LeetCode", "HackerRank".
    let site: String
    /// Stable per problem, from the window title: "two sum - leetcode".
    let key: String
}

enum PracticeHints {
    /// Sites and apps whose windows hold practice problems.
    private static let sites: [(match: String, name: String)] = [
        ("leetcode", "LeetCode"), ("hackerrank", "HackerRank"), ("neetcode", "NeetCode"),
        ("codeforces", "Codeforces"), ("codesignal", "CodeSignal"), ("geeksforgeeks", "GeeksforGeeks"),
        ("interviewbit", "InterviewBit"), ("codewars", "Codewars"), ("atcoder", "AtCoder"),
        ("algoexpert", "AlgoExpert"), ("codility", "Codility"), ("topcoder", "Topcoder"),
        ("exercism", "Exercism"), ("advent of code", "Advent of Code"), ("kattis", "Kattis"),
        ("codechef", "CodeChef"), ("hackerearth", "HackerEarth"), ("cses", "CSES")
    ]

    /// The problem in front of the student, if they are practising.
    static func detect(frontAppName: String?, windowTitle: String?, screenListing: String) -> PracticeProblem? {
        let title = (windowTitle ?? "").lowercased()
        let app = (frontAppName ?? "").lowercased()
        for site in sites where title.contains(site.match) || app.contains(site.match) {
            return PracticeProblem(site: site.name, key: problemKey(title: title, fallback: app))
        }
        // A problem page anywhere else: an example, constraints, and a way
        // to run or submit.
        let screen = screenListing.lowercased()
        if screen.contains("example 1"), screen.contains("constraints"),
           screen.contains("submit") || screen.contains("run code") || screen.contains("run tests") {
            return PracticeProblem(site: "a practice problem", key: problemKey(title: title, fallback: app))
        }
        return nil
    }

    private static func problemKey(title: String, fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(120))
    }

    /// The rung the student is asking for, from what they said and what they
    /// have had so far. Nil when what they said is not a request for help
    /// with the problem ("what is a heap"), which is answered normally.
    static func requestedLevel(transcript: String, levelSoFar: Int) -> Int? {
        let said = transcript.lowercased()
        func saysAny(_ phrases: [String]) -> Bool { phrases.contains { said.contains($0) } }

        if saysAny(["show me the code", "give me the code", "write the code", "show the code", "the full code",
                    "show me the solution", "give me the solution", "the full solution", "just the solution",
                    "just the code", "just the answer", "solve it for me", "solve this for me", "what's the answer",
                    "what is the answer", "show me the answer", "give me the answer", "code for this"]) {
            return 4
        }
        if saysAny(["walk me through", "walk through", "dry run", "trace it", "trace through", "by hand",
                    "pseudo code", "pseudocode", "step by step on the example"]) {
            return max(3, min(4, levelSoFar + 1))
        }
        if saysAny(["next hint", "another hint", "one more hint", "more hint", "a hint", "hint", "nudge", "clue",
                    "i'm stuck", "im stuck", "i am stuck", "stuck on", "where do i start", "how do i start",
                    "how do i solve", "how should i solve", "how to solve", "how would i solve", "how do i approach",
                    "how should i approach", "what am i missing", "no idea how", "don't know how to", "dont know how to"]) {
            return min(4, levelSoFar + 1)
        }
        if saysAny(["approach", "what algorithm", "which algorithm", "what data structure", "which data structure",
                    "what pattern", "what technique", "what's the trick", "what is the trick", "the intuition"]) {
            return max(2, min(4, levelSoFar + 1))
        }
        return nil
    }

    /// What the tutor is told on a practice problem.
    static func instruction(problem: PracticeProblem, levelToGive: Int?, levelSoFar: Int) -> String {
        var lines = ["THEY ARE PRACTISING a problem on \(problem.site). help in steps, so they still get to solve it themselves."]
        if levelSoFar > 0 {
            lines.append("so far on this problem they have had: \(describeLevel(levelSoFar)).")
        }
        guard let levelToGive else {
            lines.append("what they asked is not a request to solve the problem: answer it normally, and do not solve the problem for them in passing or write its solution code.")
            return lines.joined(separator: "\n")
        }
        lines.append("give exactly this step now, no further: \(rung(levelToGive))")
        if levelToGive < 4 {
            lines.append("if their own code is on screen and wrong, mark the line and show the input it fails on, but do not write the corrected code.")
        }
        lines.append("write hintLevel(\(levelToGive)); as the last line of the program.")
        lines.append(buttons(after: levelToGive))
        lines.append("this is not a test: never ask them to answer you, never grade what they wrote.")
        return lines.joined(separator: "\n")
    }

    private static func rung(_ level: Int) -> String {
        switch level {
        case 1:
            return "A NUDGE. one or two beats. point at the part of the problem or their code that holds the key, and say the observation that leads to the idea, without naming the algorithm or data structure. no card."
        case 2:
            return "THE APPROACH. three to five beats. name the idea and why it fits this problem, the data structure it needs, and its time and space cost. a small card if it helps. no code and no pseudocode."
        case 3:
            return "A WALK THROUGH BY HAND. five to eight beats. run the approach on the problem's first example on a card, one step per sentence, with the real values. no code."
        default:
            return "THE SOLUTION. as many beats as it needs. walk through the code a few lines per sentence, and offer it with button(\"copy the code\", {copy: \"...the full code in the language on their screen...\"})."
        }
    }

    private static func describeLevel(_ level: Int) -> String {
        switch level {
        case 1: return "a nudge"
        case 2: return "a nudge and the approach"
        case 3: return "the approach and a walk through by hand"
        default: return "the full solution"
        }
    }

    /// The code is a button only once the approach has been given; before
    /// that, asking is enough, and the buttons offer the next rung.
    private static func buttons(after level: Int) -> String {
        switch level {
        case 1:
            return "offer exactly: button(\"another hint\", {ask: \"give me another hint\"}); button(\"show the approach\", {ask: \"show me the approach\"});"
        case 2:
            return "offer exactly: button(\"walk me through it\", {ask: \"walk me through it on the example\"}); button(\"show the code\", {ask: \"show me the code\"});"
        case 3:
            return "offer exactly: button(\"show the code\", {ask: \"show me the code\"});"
        default:
            return "after the copy button, one button for the natural next step: the complexity, an edge case, or a follow-up variant."
        }
    }

    /// The rung the program says it gave, from its hintLevel(n) line.
    static func levelGiven(inProgram program: String) -> Int? {
        guard let range = program.range(of: #"hintLevel\(\s*([1-4])\s*\)"#, options: .regularExpression) else { return nil }
        return program[range].compactMap(\.wholeNumberValue).first
    }
}

/// How far up the ladder the student is on each problem, kept on disk so a
/// relaunch mid-problem does not start them over.
@MainActor
final class PracticeHintLadder {
    private struct Entry: Codable {
        var level: Int
        var updatedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClickyLocal/Memory/practice.json")

    /// A problem left this long is a fresh attempt when they come back.
    private static let freshAttemptAfter: TimeInterval = 48 * 60 * 60
    private static let maximumProblems = 300

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: file),
           let saved = try? decoder.decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    func level(for problem: PracticeProblem, now: Date = Date()) -> Int {
        guard let entry = entries[problem.key], now.timeIntervalSince(entry.updatedAt) < Self.freshAttemptAfter else { return 0 }
        return entry.level
    }

    func record(level: Int, for problem: PracticeProblem, now: Date = Date()) {
        entries[problem.key] = Entry(level: level, updatedAt: now)
        if entries.count > Self.maximumProblems {
            let oldest = entries.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(entries.count - Self.maximumProblems)
            oldest.forEach { entries.removeValue(forKey: $0.key) }
        }
        let snapshot = entries
        let file = self.file
        DispatchQueue.global(qos: .utility).async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoder.encode(snapshot).write(to: file, options: .atomic)
        }
    }
}
