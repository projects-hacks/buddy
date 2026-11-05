// Prints the study notes the app would add for each test scenario, from
// PracticeHints.swift and DiagramReview.swift themselves, as JSON.
// build: xcrun swiftc -o /tmp/print_notes leanring-buddy/Answering/PracticeHints.swift leanring-buddy/Answering/DiagramReview.swift <copy of this file named main.swift>
import Foundation

let practiceListing = "Example 1: Constraints: Submit"
let problem = PracticeHints.detect(frontAppName: "Brave Browser", windowTitle: "1. Two Sum - LeetCode", screenListing: practiceListing)!
var notes: [String: String] = [:]
for (name, said, soFar) in [("hint_first", "i'm stuck on this one, how do i solve it", 0),
                            ("hint_code", "ok just show me the code", 2),
                            ("hint_concept", "wait what's a hash map again", 1)] {
    let level = PracticeHints.requestedLevel(transcript: said, levelSoFar: soFar)
    notes[name] = PracticeHints.instruction(problem: problem, levelToGive: level, levelSoFar: soFar)
    notes[name + "_level"] = level.map(String.init) ?? "none"
}
let tool = DiagramReview.detect(frontAppName: "Brave Browser", windowTitle: "Excalidraw | url shortener", transcript: "can you look at my design, what am i missing")!
notes["diagram"] = DiagramReview.instruction(tool: tool)
print(String(data: try! JSONSerialization.data(withJSONObject: notes, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
