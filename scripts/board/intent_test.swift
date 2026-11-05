// Grades BoardIntent.swift: which phrasings open the teaching board, which
// stay normal answers, and which close the board once it is open.
//
// Compiled together with the app's own file, so the test grades exactly
// what the app runs:
//
//   swiftc -O -parse-as-library -o /tmp/board_intent scripts/board/intent_test.swift leanring-buddy/BoardIntent.swift
//   /tmp/board_intent scripts/board/intent_phrasings.json scripts/board/blind_phrasings.json \
//       scripts/question_sorting/phrasings.json scripts/question_sorting/spoken_test.json
//
// blind_phrasings.json was written by a separate model given only the
// feature's description, never the rules, so it is the fairest of the sets.
// The question sorter's two test sets are real study questions from before
// the board existed: every one that opens the board is listed for reading.
//
// Precision is the share of board openings that were wanted; recall is the
// share of wanted openings that happened. A wrong opening takes the screen
// away from a student asking about it, so precision is the number to hold.

import Foundation

@main
struct BoardIntentTest {
    static func main() {
        let phrasingsPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scripts/board/intent_phrasings.json"
        guard let data = FileManager.default.contents(atPath: phrasingsPath),
              let phrasings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("could not read \(phrasingsPath)")
            exit(1)
        }

        var total = (truePositives: 0, falsePositives: 0, falseNegatives: 0)
        for setName in ["development", "held_out"] {
            guard let set = phrasings[setName] as? [String: [String]] else { continue }
            let result = grade(setName: setName, shouldOpen: set["opens"] ?? [], shouldStayNormal: set["stays_normal"] ?? [])
            total.truePositives += result.truePositives
            total.falsePositives += result.falsePositives
            total.falseNegatives += result.falseNegatives
        }
        let overallPrecision = Double(total.truePositives) / Double(max(1, total.truePositives + total.falsePositives))
        let overallRecall = Double(total.truePositives) / Double(max(1, total.truePositives + total.falseNegatives))
        print(String(format: "\n== both sets: precision %.3f, recall %.3f", overallPrecision, overallRecall))

        for extraPath in CommandLine.arguments.dropFirst(2) {
            guard let extraData = FileManager.default.contents(atPath: extraPath),
                  let extra = try? JSONSerialization.jsonObject(with: extraData) as? [String: Any] else { continue }
            if let opens = extra["opens"] as? [String], let staysNormal = extra["stays_normal"] as? [String] {
                _ = grade(setName: "blind (\(extraPath))", shouldOpen: opens, shouldStayNormal: staysNormal)
                continue
            }
            var questions: [String] = []
            if let test = extra["test"] as? [[Any]] { questions = test.compactMap { $0.first as? String } }
            if let items = extra["items"] as? [[String: Any]] { questions = items.compactMap { $0["question"] as? String } }
            let opened = questions.filter(BoardIntent.opensBoard)
            print("\n== real study questions (\(extraPath)): \(opened.count) of \(questions.count) open the board")
            for question in opened { print("  opens  \"\(question)\"  (\(BoardIntent.decide(question)))") }
        }

        if let closing = phrasings["closing"] as? [String: [String]] {
            print("\n== closing, while the board is open")
            var correct = 0, count = 0
            for phrase in closing["closes"] ?? [] {
                count += 1
                if BoardIntent.closesBoard(phrase) { correct += 1 } else { print("  did not close  \"\(phrase)\"") }
            }
            for phrase in closing["keeps_open"] ?? [] {
                count += 1
                if !BoardIntent.closesBoard(phrase) { correct += 1 } else { print("  wrongly closed  \"\(phrase)\"") }
            }
            print("  \(correct) of \(count) right")
        }
    }

    static func grade(setName: String, shouldOpen: [String], shouldStayNormal: [String]) -> (truePositives: Int, falsePositives: Int, falseNegatives: Int) {
        var truePositives = 0, falsePositives = 0, falseNegatives = 0
        print("\n== \(setName)")
        for phrase in shouldOpen {
            let decision = BoardIntent.decide(phrase)
            if decision.opensBoard { truePositives += 1 } else { falseNegatives += 1; print("  missed   \"\(phrase)\"  (\(decision))") }
        }
        for phrase in shouldStayNormal {
            let decision = BoardIntent.decide(phrase)
            if decision.opensBoard { falsePositives += 1; print("  wrongly opened  \"\(phrase)\"  (\(decision))") }
        }
        let precision = truePositives + falsePositives == 0 ? 1 : Double(truePositives) / Double(truePositives + falsePositives)
        let recall = Double(truePositives) / Double(max(1, shouldOpen.count))
        print(String(format: "  %d should open, %d near misses: precision %.3f (%d of %d openings wanted), recall %.3f (%d of %d)",
                     shouldOpen.count, shouldStayNormal.count, precision, truePositives, truePositives + falsePositives,
                     recall, truePositives, shouldOpen.count))
        return (truePositives, falsePositives, falseNegatives)
    }
}
