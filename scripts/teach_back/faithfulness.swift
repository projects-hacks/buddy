// Measures teach it back's faithfulness: does the board draw what the
// student said and only that, wrong claims as stated, and do the gaps found
// match the gaps put in on purpose?
//
// For each fixture in fixtures.json (a spoken explanation with deliberate
// errors and omissions) this runs the app's two calls against the real
// model, with the app's own prompts (TeachBackPrompt), the app's board
// (TeachingBoard, BoardProgramTranslator, ProgramStream) and the app's own
// drawing page (DrawingEngine/, in a web view placed outside every display,
// as scripts/board/board_harness.swift does), and saves each board as a PNG.
// Two fixtures also get a second go at one part (fixtures.json "retries"),
// drawn and checked again.
//
// Build and run from the repository root:
//
//   swiftc -O -parse-as-library -o /tmp/teach_back_faithfulness scripts/teach_back/faithfulness.swift \
//       leanring-buddy/BoardState.swift leanring-buddy/BoardLayout.swift leanring-buddy/TeachingBoard.swift \
//       leanring-buddy/BoardProgramTranslator.swift leanring-buddy/ProgramStream.swift leanring-buddy/TeachBackPrompt.swift
//   /tmp/teach_back_faithfulness build/teach-back-runs [fixture ...]
//   /tmp/teach_back_faithfulness build/teach-back-runs replay     # earlier answers, no calls
//
// The Anthropic key is read from the Keychain by the script and is never
// printed or written anywhere. Nothing captures or draws on the screen.
//
// What is counted, per fixture, from the board's state after each call:
// - invented: purple elements whose words are nowhere in what was said, or
//   that name a part listed as unsaid. Must be 0.
// - relations: stated relations drawn as a purple arrow between the two
//   parts it joins (either direction).
// - wrong claims kept: a wrong claim whose words are in the purple drawing
//   with none of the correction's words beside them in purple.
// - gaps: expected gaps whose words are in a red mark or the sentence that
//   came with it, and how many marks were made in all.

import AppKit
import Foundation
import WebKit

struct Fixture: Decodable {
    struct Relation: Decodable { let ends: [[String]] }
    struct WrongClaim: Decodable {
        let claim: String
        let as_stated: [String]
        let corrected: [String]
    }
    struct Gap: Decodable {
        let gap: String
        let words: [String]
    }
    let name: String
    let topic: String
    let explanation: String
    let said_parts: [[String]]
    let stated_relations: [Relation]
    let unconnected_parts: [[String]]
    let wrong_claims: [WrongClaim]
    let unsaid: [String]
    let expected_gaps: [Gap]
}

struct FixtureFile: Decodable {
    struct Retry: Decodable {
        let fixture: String
        let explanation: String
    }
    let fixtures: [Fixture]
    let retries: [Retry]
}

struct CallUsage: Codable {
    var output = 0, freshInput = 0, cachedInput = 0, cacheWrites = 0
    var seconds = 0.0
    var dollars: Double {
        (Double(freshInput) * 2 + Double(cachedInput) * 0.2 + Double(cacheWrites) * 4 + Double(output) * 10) / 1_000_000
    }
}

struct FixtureResult: Codable {
    var name: String
    var round: String
    var studentElements: [String] = []
    var studentArrows: [String] = []
    var studentLabelsNotWhole: [String] = []
    var invented: [String] = []
    var saidPartsDrawn = 0
    var saidPartsTotal = 0
    var relationsDrawn = 0
    var relationsTotal = 0
    var unconnectedKeptAlone = 0
    var unconnectedTotal = 0
    var wrongClaimsKept = 0
    var wrongClaimsTotal = 0
    var wrongClaimsCorrectedInPurple: [String] = []
    var gapsFound = 0
    var gapsExpected = 0
    var gapsMissed: [String] = []
    var marksMade = 0
    var markTexts: [String] = []
    var sentences: [String] = []
    var rightIdeas: [String] = []
    var missedIdeas: [String] = []
    var studentElementsTouchedByCheck = 0
    var problems: [String] = []
    var engineErrors: [String] = []
    var drawingPNG = ""
    var checkPNG = ""
    var drawing = CallUsage()
    var check = CallUsage()
}

@main
struct TeachBackFaithfulness {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await run()
            } catch {
                print("failed: \(error)")
                exit(1)
            }
            exit(0)
        }
        application.run()
    }

    @MainActor
    static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            print("usage: teach_back_faithfulness <out_dir> [replay | fixture ...]")
            exit(2)
        }
        let outputDirectory = URL(fileURLWithPath: arguments[1])
        let isReplay = arguments.count > 2 && arguments[2] == "replay"
        let chosenNames = isReplay ? [] : Array(arguments.dropFirst(2))
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtureData = try Data(contentsOf: repository.appendingPathComponent("scripts/teach_back/fixtures.json"))
        let fixtureFile = try JSONDecoder().decode(FixtureFile.self, from: fixtureData)
        let fixtures = chosenNames.isEmpty ? fixtureFile.fixtures : fixtureFile.fixtures.filter { chosenNames.contains($0.name) }
        let apiKey = isReplay ? "" : try readAnthropicKey()
        TutorBoardLog.write = { _ in }
        let renderer = try await BoardRenderer(repository: repository)

        var results: [FixtureResult] = []
        for fixture in fixtures {
            let directory = outputDirectory.appendingPathComponent(fixture.name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let surface = BoardSurface(canvasWidth: renderer.canvasWidth, canvasHeight: renderer.canvasHeight)
            let board = TeachingBoard(layout: surface.layout)
            try await renderer.openBoard(surface: surface)
            board.beginTurn()
            _ = board.apply(.setTitle(TeachBackPrompt.boardTitle(topic: fixture.topic)))
            // The calm listening state, before anything is drawn, with the
            // meter at a speaking level.
            try await renderer.setTeachBack(phase: "listening", title: TeachBackPrompt.boardTitle(topic: fixture.topic))
            try await renderer.setLevel(0.7)
            try await renderer.snapshot(to: directory.appendingPathComponent("listening.png"))
            try await renderer.setTeachBack(phase: "drawing")

            var explanations = [fixture.explanation]
            var result = try await drawAndCheck(fixture: fixture, explanation: fixture.explanation, earlierExplanation: nil,
                                                explanations: explanations, round: "first", board: board, renderer: renderer,
                                                directory: directory, filePrefix: "", apiKey: apiKey, isReplay: isReplay)
            results.append(result)
            printResult(result)

            if let retry = fixtureFile.retries.first(where: { $0.fixture == fixture.name }) {
                explanations.append(retry.explanation)
                try await renderer.setTeachBack(phase: "drawing")
                result = try await drawAndCheck(fixture: fixture, explanation: retry.explanation,
                                                earlierExplanation: fixture.explanation, explanations: explanations,
                                                round: "again", board: board, renderer: renderer, directory: directory,
                                                filePrefix: "again-", apiKey: apiKey, isReplay: isReplay)
                results.append(result)
                printResult(result)
            }

            // The Notebook's copy of the board, by the app's own snapshot
            // script, drawn back to a picture from the SVG alone.
            let snapshotScript = try String(contentsOf: repository.appendingPathComponent("leanring-buddy/notebook-snapshot.js"), encoding: .utf8)
            if let boardSVG = try await renderer.notebookBoardSVG(snapshotScript: snapshotScript) {
                try boardSVG.write(to: directory.appendingPathComponent("notebook-board.svg"), atomically: true, encoding: .utf8)
                try await renderer.picture(ofSVG: boardSVG, to: directory.appendingPathComponent("notebook-board.png"))
                print("    notebook page board: \(boardSVG.utf8.count / 1024) KB of SVG")
            } else {
                print("    notebook page board: none")
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: outputDirectory.appendingPathComponent(isReplay ? "summary-replay.json" : "summary.json"))
        let first = results.filter { $0.round == "first" }
        let dollars = results.reduce(0) { $0 + $1.drawing.dollars + $1.check.dollars }
        print("\n== \(first.count) fixtures, first explanations")
        print("invented elements: \(first.reduce(0) { $0 + $1.invented.count })")
        print("said parts drawn: \(first.reduce(0) { $0 + $1.saidPartsDrawn }) of \(first.reduce(0) { $0 + $1.saidPartsTotal })")
        print("stated relations drawn: \(first.reduce(0) { $0 + $1.relationsDrawn }) of \(first.reduce(0) { $0 + $1.relationsTotal })")
        print("unconnected parts kept alone: \(first.reduce(0) { $0 + $1.unconnectedKeptAlone }) of \(first.reduce(0) { $0 + $1.unconnectedTotal })")
        print("wrong claims drawn as stated: \(first.reduce(0) { $0 + $1.wrongClaimsKept }) of \(first.reduce(0) { $0 + $1.wrongClaimsTotal })")
        print("gaps found: \(first.reduce(0) { $0 + $1.gapsFound }) of \(first.reduce(0) { $0 + $1.gapsExpected }), marks made \(first.reduce(0) { $0 + $1.marksMade })")
        print("student elements changed by the check: \(results.reduce(0) { $0 + $1.studentElementsTouchedByCheck })")
        print("student arrow labels shortened or left off on the paper: \(results.reduce(0) { $0 + $1.studentLabelsNotWhole.count }) of \(results.reduce(0) { $0 + $1.studentArrows.count })")
        print(String(format: "cost of this run: $%.3f", dollars))
    }

    @MainActor
    static func drawAndCheck(fixture: Fixture, explanation: String, earlierExplanation: String?, explanations: [String],
                             round: String, board: TeachingBoard, renderer: BoardRenderer, directory: URL,
                             filePrefix: String, apiKey: String, isReplay: Bool) async throws -> FixtureResult {
        var result = FixtureResult(name: fixture.name, round: round)

        // The drawing call, in the student's ink. A second go first rubs
        // out the last check's marks, so the new check starts from their
        // drawing alone.
        board.beginTurn()
        board.inkForNewMarks = nil
        let rubbedOutMarks = earlierExplanation == nil ? [] : board.removeGapMarks()
        board.inkForNewMarks = .student
        try await renderer.beginTurn()
        let drawingNote = TeachBackPrompt.drawingNote(topic: fixture.topic, explanation: explanation,
                                                      boardListing: board.state.compactListing(),
                                                      earlierExplanation: earlierExplanation)
        let drawingProgram: String
        if isReplay {
            drawingProgram = try String(contentsOf: directory.appendingPathComponent("\(filePrefix)drawing.program.js"), encoding: .utf8)
        } else {
            let reply = try await askClaude(apiKey: apiKey, system: TeachBackPrompt.drawingSystem, note: drawingNote,
                                            maximumTokens: TeachBackPrompt.drawingMaximumTokens)
            // As the app does: only the first block runs.
            drawingProgram = TeachBackPrompt.firstProgramBlock(of: reply.text)
            if drawingProgram.count + 3 < reply.text.trimmingCharacters(in: .whitespacesAndNewlines).count {
                result.problems.append("drawing: text after the first block was dropped")
            }
            result.drawing = reply.usage
        }
        // As the app plays it: one beat, so parts land beside what they link to.
        let drawingRun = try await runProgram(TeachBackPrompt.drawingAsOneBeat(drawingProgram), on: board, renderer: renderer,
                                              commandsWithFirstSentence: rubbedOutMarks)
        result.problems += drawingRun.problems
        result.engineErrors += drawingRun.engineErrors
        try await renderer.setTeachBack(phase: "checking")
        let drawingPNG = directory.appendingPathComponent("\(filePrefix)drawing.png")
        try await renderer.snapshot(to: drawingPNG)
        result.drawingPNG = drawingPNG.path
        let studentStateAfterDrawing = board.state.elements.filter { $0.ink == .student }

        // The check, in the gap's ink.
        board.beginTurn()
        board.inkForNewMarks = .gap
        try await renderer.beginTurn()
        let gapNote = TeachBackPrompt.gapNote(topic: fixture.topic, explanations: explanations,
                                              boardListing: board.state.compactListing())
        let checkProgram: String
        if isReplay {
            checkProgram = try String(contentsOf: directory.appendingPathComponent("\(filePrefix)check.program.js"), encoding: .utf8)
        } else {
            let reply = try await askClaude(apiKey: apiKey, system: TeachBackPrompt.gapSystem, note: gapNote,
                                            maximumTokens: TeachBackPrompt.gapMaximumTokens)
            checkProgram = TeachBackPrompt.firstProgramBlock(of: reply.text)
            if checkProgram.count + 3 < reply.text.trimmingCharacters(in: .whitespacesAndNewlines).count {
                result.problems.append("check: text after the first block was dropped")
            }
            result.check = reply.usage
        }
        let checkRun = try await runProgram(checkProgram, on: board, renderer: renderer)
        board.inkForNewMarks = nil
        result.problems += checkRun.problems
        result.engineErrors += checkRun.engineErrors
        try await renderer.setTeachBack(phase: "result")
        let checkPNG = directory.appendingPathComponent("\(filePrefix)check.png")
        try await renderer.snapshot(to: checkPNG)
        result.checkPNG = checkPNG.path

        try drawingProgram.write(to: directory.appendingPathComponent("\(filePrefix)drawing.program.js"), atomically: true, encoding: .utf8)
        try checkProgram.write(to: directory.appendingPathComponent("\(filePrefix)check.program.js"), atomically: true, encoding: .utf8)
        try drawingNote.write(to: directory.appendingPathComponent("\(filePrefix)drawing.note.txt"), atomically: true, encoding: .utf8)
        try gapNote.write(to: directory.appendingPathComponent("\(filePrefix)check.note.txt"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(board.state).write(to: directory.appendingPathComponent("\(filePrefix)board.json"))

        score(&result, fixture: fixture, explanations: explanations, state: board.state,
              studentStateAfterDrawing: studentStateAfterDrawing, checkProgram: checkProgram, checkOperations: checkRun.operations)
        return result
    }

    struct ProgramRun {
        var problems: [String] = []
        var engineErrors: [String] = []
        var operations: [BoardOperation] = []
    }

    /// Exactly what LessonProgramPlayer does: cut into pieces as the stream
    /// would, translate each piece's board calls, run it.
    @MainActor
    /// `commandsWithFirstSentence` are strokes decided before the answer
    /// (the old gap marks rubbed out), drawn with its first sentence as
    /// TeachBackSession does.
    static func runProgram(_ program: String, on board: TeachingBoard, renderer: BoardRenderer,
                           commandsWithFirstSentence: [BoardDrawCommand] = []) async throws -> ProgramRun {
        var run = ProgramRun()
        var stream = ProgramStream()
        var waitingStatement = BoardRenderer.applyStatement(commandsWithFirstSentence)
        for piece in stream.finish(fullText: program).newPieces {
            let translation = BoardProgramTranslator.translate(piece, on: board)
            run.problems += translation.problems
            run.operations += translation.operations
            var code = translation.code
            if !waitingStatement.isEmpty, let withStrokes = TeachBackPrompt.inserting(waitingStatement, afterFirstSentenceOf: code) {
                code = withStrokes
                waitingStatement = ""
            }
            run.engineErrors += try await renderer.run(piece: code)
        }
        if !waitingStatement.isEmpty { run.engineErrors += try await renderer.run(piece: waitingStatement) }
        return run
    }

    // MARK: - Scoring

    static func score(_ result: inout FixtureResult, fixture: Fixture, explanations: [String], state: BoardState,
                      studentStateAfterDrawing: [BoardElement], checkProgram: String, checkOperations: [BoardOperation]) {
        let said = explanations.joined(separator: " ").lowercased()
        let saidWords = words(said)
        let studentElements = state.elements.filter { $0.ink == .student }
        let studentConnectors = state.connectors.filter { $0.ink == .student }
        func textOf(_ element: BoardElement) -> String {
            ([element.text] + element.listItems).joined(separator: " ").lowercased()
        }
        let studentTexts = studentElements.map(textOf) + studentConnectors.map { $0.label.lowercased() }
        result.studentElements = studentElements.map { "\($0.identifier): \(textOf($0))" }
        // Words in the state but not on the paper: an arrow label the layout
        // had to shorten or leave off.
        result.studentLabelsNotWhole = studentConnectors.filter { connector in
            guard !connector.label.isEmpty else { return false }
            let shown = (connector.drawnLabelLines ?? []).map(\.text).joined(separator: " ")
            return connector.labelFrame == nil || shown.contains("\u{2026}")
        }.map { "\($0.identifier) \"\($0.label)\" shown as \"\(($0.drawnLabelLines ?? []).map(\.text).joined(separator: " "))\"" }
        result.studentArrows = studentConnectors.map { "\($0.identifier) \"\($0.label)\"" }

        // Invented: an element whose content words are nowhere in what was
        // said, or that names a part that was not said.
        for element in studentElements {
            let text = textOf(element)
            let contentWords = words(text).filter { !stopWords.contains($0) && $0.count > 1 }
            let grounded = contentWords.filter { word in saidWords.contains { sameWord($0, word) } }
            let namesUnsaid = fixture.unsaid.first { matches(text, $0) && !matches(said, $0) }
            if !contentWords.isEmpty && grounded.isEmpty {
                result.invented.append("\(element.identifier) \"\(text)\" (no word of it was said)")
            } else if let namesUnsaid {
                result.invented.append("\(element.identifier) \"\(text)\" (names \"\(namesUnsaid)\", which was not said)")
            }
        }
        for connector in studentConnectors {
            let text = connector.label.lowercased()
            if let namesUnsaid = fixture.unsaid.first(where: { matches(text, $0) && !matches(said, $0) }) {
                result.invented.append("arrow \(connector.identifier) \"\(text)\" (names \"\(namesUnsaid)\", which was not said)")
            }
        }

        result.saidPartsTotal = fixture.said_parts.count
        result.saidPartsDrawn = fixture.said_parts.filter { keywords in
            studentTexts.contains { text in keywords.contains { matches(text, $0) } }
        }.count

        func elementMatches(_ identifier: String, _ keywords: [String]) -> Bool {
            guard let element = state.element(identifier) else { return false }
            return keywords.contains { matches(textOf(element), $0) }
        }
        result.relationsTotal = fixture.stated_relations.count
        result.relationsDrawn = fixture.stated_relations.filter { relation in
            guard relation.ends.count == 2 else { return false }
            return studentConnectors.contains { connector in
                let label = connector.label.lowercased()
                let fromMatches = { (keywords: [String]) in elementMatches(connector.fromIdentifier, keywords) }
                let toMatches = { (keywords: [String]) in elementMatches(connector.toIdentifier, keywords) || relation.ends[1].contains { matches(label, $0) } }
                let forward = fromMatches(relation.ends[0]) && toMatches(relation.ends[1])
                let backward = elementMatches(connector.toIdentifier, relation.ends[0]) && (elementMatches(connector.fromIdentifier, relation.ends[1]))
                return forward || backward
            }
        }.count

        result.unconnectedTotal = fixture.unconnected_parts.count
        result.unconnectedKeptAlone = fixture.unconnected_parts.filter { keywords in
            let matching = studentElements.filter { element in keywords.contains { matches(textOf(element), $0) } }
            return !matching.isEmpty && matching.allSatisfy { element in
                !studentConnectors.contains { $0.fromIdentifier == element.identifier || $0.toIdentifier == element.identifier }
            }
        }.count

        result.wrongClaimsTotal = fixture.wrong_claims.count
        for claim in fixture.wrong_claims {
            let stated = studentTexts.contains { text in claim.as_stated.contains { matches(text, $0) } }
            let correctedWordsNotSaid = claim.corrected.filter { !matches(said, $0) }
            let correctedInPurple = studentTexts.first { text in correctedWordsNotSaid.contains { matches(text, $0) } }
            if stated && correctedInPurple == nil {
                result.wrongClaimsKept += 1
            } else if let correctedInPurple {
                result.wrongClaimsCorrectedInPurple.append("\(claim.claim): \"\(correctedInPurple)\"")
            } else {
                result.wrongClaimsCorrectedInPurple.append("\(claim.claim): not drawn")
            }
        }

        // Each gap mark, with the sentence said in its beat.
        let gapElements = state.elements.filter { $0.ink == .gap }
        let gapConnectors = state.connectors.filter { $0.ink == .gap }
        var markTexts = gapElements.map(textOf) + gapConnectors.map { $0.label.lowercased() }
        let sentences = ProgramStream.closedSayArguments(in: ProgramStream.code(in: checkProgram))
        result.sentences = sentences
        markTexts += sentences.dropFirst().map { $0.lowercased() }
        result.markTexts = gapElements.map { "\($0.identifier): \(textOf($0))" } + gapConnectors.map { "\($0.identifier) \"\($0.label)\"" }
        // A missing part and the missing link that attaches it are one gap.
        let missingParts = gapElements.filter { $0.correctsIdentifier == nil }.count
        let corrections = gapElements.filter { $0.correctsIdentifier != nil }.count
        let linksToNothingMissing = gapConnectors.filter { connector in
            state.element(connector.fromIdentifier)?.ink != .gap && state.element(connector.toIdentifier)?.ink != .gap
        }.count
        result.marksMade = missingParts + corrections + linksToNothingMissing
        result.gapsExpected = fixture.expected_gaps.count
        for gap in fixture.expected_gaps {
            if markTexts.contains(where: { text in gap.words.contains { matches(text, $0) } }) {
                result.gapsFound += 1
            } else {
                result.gapsMissed.append(gap.gap)
            }
        }
        for operation in checkOperations {
            if case .verdict(let right, let missed) = operation {
                result.rightIdeas = right
                result.missedIdeas = missed
            }
        }
        let studentAfterCheck = state.elements.filter { $0.ink == .student }
        result.studentElementsTouchedByCheck = studentStateAfterDrawing.filter { before in
            studentAfterCheck.first { $0.identifier == before.identifier }.map { $0.text != before.text || $0.listItems != before.listItems } ?? true
        }.count
    }

    static let stopWords: Set<String> = ["the", "a", "an", "of", "to", "in", "on", "it", "is", "and", "or", "you", "your", "its",
                                         "that", "this", "for", "with", "by", "as", "at", "be", "are", "they", "them", "then",
                                         "so", "if", "from", "up", "into", "one", "each", "every", "all", "like", "gets", "get"]

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    static func sameWord(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        let shorter = min(first.count, second.count)
        guard shorter >= 3 else { return false }
        return first.prefix(max(3, min(5, shorter))) == second.prefix(max(3, min(5, shorter)))
    }

    /// A keyword matches the start of a word, or a phrase anywhere.
    static func matches(_ text: String, _ keyword: String) -> Bool {
        let lowered = text.lowercased()
        let key = keyword.lowercased()
        if key.contains(" ") || key.contains("-") || key.contains("(") || key.contains("/") || key.contains("+") || key.contains(".") {
            return lowered.contains(key)
        }
        return words(lowered).contains { $0.hasPrefix(key) }
    }

    static func printResult(_ result: FixtureResult) {
        print(String(format: "%@ (%@): invented %d, parts %d/%d, relations %d/%d, alone %d/%d, wrong kept %d/%d, gaps %d/%d with %d marks, %d problems, %d engine errors, $%.4f",
                     result.name, result.round, result.invented.count, result.saidPartsDrawn, result.saidPartsTotal,
                     result.relationsDrawn, result.relationsTotal, result.unconnectedKeptAlone, result.unconnectedTotal,
                     result.wrongClaimsKept, result.wrongClaimsTotal, result.gapsFound, result.gapsExpected, result.marksMade,
                     result.problems.count, result.engineErrors.count, result.drawing.dollars + result.check.dollars))
        for invented in result.invented { print("    invented: \(invented)") }
        for label in result.studentLabelsNotWhole { print("    student words cut: \(label)") }
        for corrected in result.wrongClaimsCorrectedInPurple { print("    wrong claim not as stated: \(corrected)") }
        for missed in result.gapsMissed { print("    gap missed: \(missed)") }
        for problem in result.problems { print("    board: \(problem)") }
        for engineError in result.engineErrors { print("    engine: \(engineError)") }
    }

    // MARK: - The API

    struct Reply {
        var text: String
        var usage: CallUsage
    }

    static func readAnthropicKey() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", "api-key", "-s", "com.maverickrajeev.clicky-local.anthropic", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let key = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw NSError(domain: "teachback", code: 1, userInfo: [NSLocalizedDescriptionKey: "no Anthropic key in the Keychain"]) }
        return key
    }

    /// The request ClaudeVisionProvider makes for a board turn under the
    /// Claude setting: Sonnet, no screenshot, the system prompt cached for
    /// an hour, as scripts/board/board_harness.swift sends it.
    static func askClaude(apiKey: String, system: String, note: String, maximumTokens: Int) async throws -> Reply {
        let body: [String: Any] = [
            "model": "claude-sonnet-5-5",
            "max_tokens": maximumTokens,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral", "ttl": "1h"]]],
            "messages": [["role": "user", "content": [["type": "text", "text": note]]]],
            "thinking": ["type": "between_tools"],
            "output_config": ["effort": "high"]
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "teachback", code: status, userInfo: [NSLocalizedDescriptionKey:
                "HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(400) ?? "")"])
        }
        let text = (object["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined()
        let usage = object["usage"] as? [String: Any] ?? [:]
        var callUsage = CallUsage()
        callUsage.output = usage["output_tokens"] as? Int ?? 0
        callUsage.freshInput = usage["input_tokens"] as? Int ?? 0
        callUsage.cachedInput = usage["cache_read_input_tokens"] as? Int ?? 0
        callUsage.cacheWrites = usage["cache_creation_input_tokens"] as? Int ?? 0
        callUsage.seconds = Date().timeIntervalSince(started)
        return Reply(text: text, usage: callUsage)
    }
}

/// The app's drawing page, loaded the way DrawingOverlay loads it, in a web
/// view inside a window far outside every display (the board harness's
/// approach, scripts/board/board_harness.swift).
@MainActor
final class BoardRenderer: NSObject, WKNavigationDelegate {
    let canvasWidth: Double = 1512
    let canvasHeight: Double = 982
    private let window: NSWindow
    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Never>?

    init(repository: URL) async throws {
        let frame = NSRect(x: -30_000, y: -30_000, width: canvasWidth, height: canvasHeight)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight), configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
        window.orderFrontRegardless()

        let engineDirectory = repository.appendingPathComponent("leanring-buddy/DrawingEngine")
        func read(_ name: String) throws -> String { try String(contentsOf: engineDirectory.appendingPathComponent(name), encoding: .utf8) }
        let scripts = try ["draw-vendor-rough.js", "draw-vendor-freehand.js", "draw-engine.js", "draw-board.js"]
            .map { "<script>\n\(try read($0))\n</script>" }.joined(separator: "\n")
        let page = try read("draw-page.html").replacingOccurrences(of: "<!--SCRIPTS-->", with: scripts)
        await withCheckedContinuation { continuation in
            loadContinuation = continuation
            webView.loadHTMLString(page, baseURL: nil)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.loadContinuation?.resume()
            self.loadContinuation = nil
        }
    }

    private func evaluate(_ script: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: [:], contentWorld: .page)
    }

    private func setUpCanvas() async throws {
        _ = try await evaluate("""
        BuddyEngine.clearAll();
        BuddyEngine.setup({canvasWidth: \(canvasWidth), canvasHeight: \(canvasHeight), targets: {}, targetLabels: {}, screenInk: '#3380FF', unitsPerPoint: 1});
        """)
    }

    func openBoard(surface: BoardSurface) async throws {
        try await setUpCanvas()
        _ = try await evaluate("BuddyBoard.open(\(surface.openArgumentsJSON));")
    }

    func setTeachBack(phase: String, title: String? = nil) async throws {
        let titlePart = title.map { ", title: \(BoardProgramTranslator.javaScriptStringLiteral($0))" } ?? ""
        let subtitle = BoardProgramTranslator.javaScriptStringLiteral(TeachBackPrompt.invitation)
        _ = try await evaluate("BuddyBoard.setTeachBack({subtitle: \(subtitle), phase: '\(phase)'\(titlePart)});")
    }

    func setLevel(_ level: Double) async throws {
        _ = try await evaluate("BuddyBoard.setLevel(\(level));")
    }

    /// What NotebookRecorder.keepBoard gets: the snapshot script's board.
    func notebookBoardSVG(snapshotScript: String) async throws -> String? {
        _ = try await evaluate("BuddyEngine.finishAll();")
        let json = try await webView.evaluateJavaScript(snapshotScript) as? String ?? ""
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let board = object["board"] as? [String: Any] else { return nil }
        return board["svg"] as? String
    }

    /// An SVG drawn as an image, as the Notebook window shows a card.
    func picture(ofSVG svgText: String, to url: URL) async throws {
        let value = try await webView.callAsyncJavaScript("""
        const image = new Image();
        image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svgText);
        await image.decode();
        const canvas = document.createElement('canvas');
        canvas.width = image.naturalWidth;
        canvas.height = image.naturalHeight;
        canvas.getContext('2d').drawImage(image, 0, 0);
        return canvas.toDataURL('image/png');
        """, arguments: ["svgText": svgText], contentWorld: .page) as? String ?? ""
        guard let commaIndex = value.firstIndex(of: ","),
              let pngData = Data(base64Encoded: String(value[value.index(after: commaIndex)...])) else { return }
        try pngData.write(to: url)
    }

    func beginTurn() async throws {
        try await setUpCanvas()
        _ = try await evaluate("BuddyBoard.beginTurn();")
    }

    static func applyStatement(_ commands: [BoardDrawCommand]) -> String {
        guard !commands.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = (try? encoder.encode(commands)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "\nBuddyBoard.apply(\(json));\n"
    }

    func run(piece: String) async throws -> [String] {
        let value = try await webView.callAsyncJavaScript("return JSON.stringify(BuddyEngine.run(code));",
                                                          arguments: ["code": piece], contentWorld: .page)
        guard let text = value as? String, let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object["newErrors"] as? [String] ?? []
    }

    /// Every stroke finished, then a picture, painted by the page itself
    /// since a window outside every display is never composited.
    func snapshot(to url: URL) async throws {
        _ = try await evaluate("BuddyEngine.finishAll();")
        try await Task.sleep(nanoseconds: 300_000_000)
        let dataURL = try await evaluate("""
        for (const animation of document.getAnimations()) {
          try { animation.finish(); } catch (_) {}
          try { animation.commitStyles(); animation.cancel(); continue; } catch (_) {}
          const target = animation.effect && animation.effect.target;
          const keyframes = animation.effect ? animation.effect.getKeyframes() : [];
          const last = keyframes[keyframes.length - 1];
          if (!target || !last) continue;
          for (const [property, value] of Object.entries(last)) {
            if (!['offset', 'computedOffset', 'easing', 'composite'].includes(property)) target.style[property] = value;
          }
          animation.cancel();
        }
        for (const path of document.querySelectorAll('#board path')) {
          if (path.style.strokeDasharray) {
            path.style.strokeDasharray = '';
            path.style.strokeDashoffset = '';
          }
        }
        const svg = document.getElementById('board').cloneNode(true);
        svg.setAttribute('width', \(canvasWidth));
        svg.setAttribute('height', \(canvasHeight));
        const markup = new XMLSerializer().serializeToString(svg);
        const image = new Image();
        image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(markup);
        await image.decode();
        const canvas = document.createElement('canvas');
        canvas.width = \(canvasWidth) * 2;
        canvas.height = \(canvasHeight) * 2;
        const context = canvas.getContext('2d');
        context.scale(2, 2);
        context.drawImage(image, 0, 0, \(canvasWidth), \(canvasHeight));
        return canvas.toDataURL('image/png');
        """) as? String ?? ""
        guard let commaIndex = dataURL.firstIndex(of: ","),
              let pngData = Data(base64Encoded: String(dataURL[dataURL.index(after: commaIndex)...])) else {
            throw NSError(domain: "teachback", code: 3, userInfo: [NSLocalizedDescriptionKey: "the page painted no picture"])
        }
        try pngData.write(to: url)
    }
}
