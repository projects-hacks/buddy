// Grades TeachBackIntent.swift: which phrasings start teach it back, which
// stay normal questions, which ask for another go while it is open, and
// which closing words end the student's explanation.
//
// Compiled with the app's own files, so it grades what the app runs:
//
//   swiftc -O -parse-as-library -o /tmp/teach_back_intent scripts/teach_back/intent_test.swift \
//       leanring-buddy/TeachBackIntent.swift leanring-buddy/BoardIntent.swift
//   /tmp/teach_back_intent scripts/teach_back/intent_phrasings.json scripts/teach_back/blind_phrasings.json \
//       scripts/teach_back/listening_phrases.json scripts/board/intent_phrasings.json \
//       scripts/question_sorting/phrasings.json scripts/question_sorting/spoken_test.json
//
// "teach it back" with no topic is about the lesson just given, so every
// phrasing is graded as if a lesson had just ended ("the last lesson").
// Precision is the share of openings that were wanted. A wrong opening
// opens the microphone for minutes on a student who asked a question, so
// it is the number to hold.

import Foundation

@main
struct TeachBackIntentTest {
    static let fallbackTopic = "the last lesson"

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        for path in arguments {
            guard let data = FileManager.default.contents(atPath: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("could not read \(path)")
                continue
            }
            if path.contains("teach_back/intent_phrasings") {
                for setName in ["development", "held_out"] {
                    guard let set = object[setName] as? [String: [String]] else { continue }
                    grade(setName: "\(setName) (\(path))", shouldOpen: set["opens"] ?? [], shouldStayNormal: set["stays_normal"] ?? [])
                }
                if let retry = object["retry"] as? [String: [String]] { gradeRetry(retry) }
                if let interface = object["from_the_interface"] as? [String: Any],
                   let starts = interface["starts"] as? [[String]] { gradeInterface(starts) }
            } else if let opens = object["opens"] as? [String], let staysNormal = object["stays_normal"] as? [String] {
                grade(setName: "blind (\(path))", shouldOpen: opens, shouldStayNormal: staysNormal)
            } else if let ends = object["ends"] as? [[String]], let keeps = object["keeps_listening"] as? [String] {
                gradeListening(ends: ends, keepsListening: keeps)
            } else if path.contains("board/intent_phrasings") {
                // The board's own phrasings: none should start teach-back,
                // and no teach-back opening should also open the board.
                var questions: [String] = []
                for setName in ["development", "held_out"] {
                    guard let set = object[setName] as? [String: [String]] else { continue }
                    questions += (set["opens"] ?? []) + (set["stays_normal"] ?? [])
                }
                let opened = questions.filter { TeachBackIntent.opensTeachBack($0, fallbackTopic: fallbackTopic) }
                print("\n== the board's \(questions.count) phrasings: \(opened.count) start teach-back")
                for question in opened { print("  starts  \"\(question)\"") }
            } else {
                var questions: [String] = []
                if let test = object["test"] as? [[Any]] { questions = test.compactMap { $0.first as? String } }
                if let items = object["items"] as? [[String: Any]] { questions = items.compactMap { $0["question"] as? String } }
                let opened = questions.filter { TeachBackIntent.opensTeachBack($0, fallbackTopic: fallbackTopic) }
                print("\n== real study questions (\(path)): \(opened.count) of \(questions.count) start teach-back")
                for question in opened {
                    print("  starts  \"\(question)\"  (\(TeachBackIntent.decide(question, fallbackTopic: fallbackTopic)))")
                }
            }
        }
    }

    static func grade(setName: String, shouldOpen: [String], shouldStayNormal: [String]) {
        var truePositives = 0, falsePositives = 0
        print("\n== \(setName)")
        for phrase in shouldOpen {
            let decision = TeachBackIntent.decide(phrase, fallbackTopic: fallbackTopic)
            if decision.opensTeachBack {
                truePositives += 1
                print("  opens    \"\(phrase)\"  -> topic \"\(decision.topic ?? "")\"")
                if BoardIntent.opensBoard(phrase) { print("    ALSO OPENS THE BOARD") }
            } else {
                print("  missed   \"\(phrase)\"  (\(decision))")
            }
        }
        for phrase in shouldStayNormal {
            let decision = TeachBackIntent.decide(phrase, fallbackTopic: fallbackTopic)
            if decision.opensTeachBack {
                falsePositives += 1
                print("  wrongly opened  \"\(phrase)\"  -> topic \"\(decision.topic ?? "")\"")
            }
        }
        let precision = truePositives + falsePositives == 0 ? 1 : Double(truePositives) / Double(truePositives + falsePositives)
        let recall = Double(truePositives) / Double(max(1, shouldOpen.count))
        print(String(format: "  %d should open, %d near misses: precision %.3f (%d of %d openings wanted), recall %.3f (%d of %d)",
                     shouldOpen.count, shouldStayNormal.count, precision, truePositives, truePositives + falsePositives,
                     recall, truePositives, shouldOpen.count))
    }

    static func gradeRetry(_ retry: [String: [String]]) {
        print("\n== another go, while teach-back is open")
        var correct = 0, count = 0
        for phrase in retry["listens_again"] ?? [] {
            count += 1
            if TeachBackIntent.asksToExplainAgain(phrase) { correct += 1 } else { print("  did not listen  \"\(phrase)\"") }
        }
        for phrase in retry["normal_board_question"] ?? [] {
            count += 1
            if !TeachBackIntent.asksToExplainAgain(phrase) { correct += 1 } else { print("  wrongly listened  \"\(phrase)\"") }
        }
        print("  \(correct) of \(count) right")
    }

    /// What the interface's buttons ask must start teach-back on the right
    /// topic, whatever lesson or page title fills it in.
    static func gradeInterface(_ starts: [[String]]) {
        print("\n== from the interface (chip, start tile, Map, Notebook)")
        var correct = 0
        for entry in starts where entry.count == 2 {
            let decision = TeachBackIntent.decide(entry[0], fallbackTopic: nil)
            if decision.topic == entry[1] {
                correct += 1
            } else {
                print("  wrong  \"\(entry[0])\" gave \(decision), wanted topic \"\(entry[1])\"")
            }
            if BoardIntent.opensBoard(entry[0]) { print("    ALSO OPENS THE BOARD") }
        }
        print("  \(correct) of \(starts.count) start teach-back on the right topic")
    }

    /// Each "ends" entry is [what was heard, what the explanation should be].
    static func gradeListening(ends: [[String]], keepsListening: [String]) {
        print("\n== the end of an explanation")
        var correct = 0, count = 0
        for entry in ends where entry.count == 2 {
            count += 1
            let result = TeachBackHearing.explanationIfFinished(entry[0])
            if result == entry[1] { correct += 1 } else { print("  wrong end  \"\(entry[0])\" gave \(result.map { "\"\($0)\"" } ?? "no end"), wanted \"\(entry[1])\"") }
        }
        for phrase in keepsListening {
            count += 1
            if TeachBackHearing.explanationIfFinished(phrase) == nil { correct += 1 } else { print("  ended early  \"\(phrase)\"") }
        }
        print("  \(correct) of \(count) right")
    }
}
