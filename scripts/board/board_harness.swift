// Runs real teaching-board sessions against the model, with no app: a
// scripted five-turn conversation per topic, each answer applied to the
// board by the app's own Swift (TeachingBoard, BoardProgramTranslator,
// ProgramStream) and drawn by the app's own engine (DrawingEngine/, in an
// off-screen WKWebView), then saved as a PNG per turn.
//
// Nothing here captures or draws on the screen: the web view lives in a
// window placed far outside every display, and the "screen" behind the
// board in the pictures is a plain placeholder.
//
// Build and run from the repository root:
//
//   swiftc -O -parse-as-library -o /tmp/board_harness scripts/board/board_harness.swift \
//       leanring-buddy/BoardState.swift leanring-buddy/BoardLayout.swift leanring-buddy/TeachingBoard.swift \
//       leanring-buddy/BoardProgramTranslator.swift leanring-buddy/BoardProgramPrompt.swift leanring-buddy/ProgramStream.swift
//   /tmp/board_harness <out_dir> [sonnet|opus|argon|offline] [topic ...]
//
// "argon" calls Gemini 4 Argon on Vertex the way GeminiVisionProvider does:
// a gcloud access token and the project the app keeps in its defaults
// (vertexProjectIdentifier). The token is never printed.
//
// "offline" draws two hand-written turns with no model call, to check the
// drawing itself for free.
//
// The Anthropic key is read from the Keychain by the script itself and is
// never printed or written anywhere.
//
// Written per turn into <out_dir>/<brain>/<topic>/: turnN.png, turnN.program.js
// (what the model wrote), turnN.note.txt (the turn note it was sent),
// turnN.board.json (the board after the turn), and summary.json with token
// counts and cost for every turn.

import AppKit
import Foundation
import WebKit

struct Topic {
    let name: String
    let questions: [String]
}

let topics: [Topic] = [
    Topic(name: "consistent-hashing", questions: [
        "teach me consistent hashing from scratch",
        "what happens when a server leaves the ring",
        "show that again with three servers",
        "why do people add virtual nodes",
        "so with virtual nodes where would the key user42 go"
    ]),
    Topic(name: "binary-search", questions: [
        "i know nothing about binary search, teach me from the start",
        "what happens if the number we want isn't in the list",
        "show that again with a list of eight numbers",
        "why is it log n",
        "what's the bug people usually make with the middle index"
    ]),
    Topic(name: "tcp-handshake", questions: [
        "explain the tcp three way handshake from scratch on the whiteboard",
        "why does it need three steps and not two",
        "what are the sequence numbers actually for",
        "what happens if the last ack gets lost",
        "and how does closing the connection work"
    ])
]

/// The two Claude answer profiles the app uses (ClaudeAnswerProfile). A
/// board turn is routed as a teach question: under the Claude setting that
/// is Sonnet without thinking (the routing table puts Opus within the
/// judges' noise and Sonnet is cheaper); Opus is run for comparison.
struct Brain {
    let name: String
    var isArgon = false
    let model: String
    let thinking: [String: Any]
    let effort: String
    let thinkingHeadroom: Int
    let inputPrice: Double, cachedPrice: Double, outputPrice: Double
}

let brains: [String: Brain] = [
    "sonnet": Brain(name: "sonnet", model: "claude-sonnet-5-5", thinking: ["type": "between_tools"], effort: "high",
                    thinkingHeadroom: 0, inputPrice: 2, cachedPrice: 0.2, outputPrice: 10),
    "opus": Brain(name: "opus", model: "claude-opus-5-5", thinking: ["type": "adaptive"], effort: "low",
                  thinkingHeadroom: 1500, inputPrice: 4, cachedPrice: 0.2, outputPrice: 20),
    // Introductory price until the end of November 2026 (SpendingMeter.swift).
    "argon": Brain(name: "argon", isArgon: true, model: "gemini-4-argon", thinking: [:], effort: "LOW",
                   thinkingHeadroom: 0, inputPrice: 2, cachedPrice: 0.1, outputPrice: 10)
]

struct TurnUsage: Codable {
    var turn: Int
    var question: String
    var outputTokens: Int
    var freshInputTokens: Int
    var cachedInputTokens: Int
    var cacheWriteTokens: Int
    var noteCharacters: Int
    var elementsAfter: Int
    var connectorsAfter: Int
    var problems: [String]
    var engineErrors: [String]
    var seconds: Double
    var dollars: Double
    var png: String
}

@main
struct BoardHarness {
    static func main() {
        // A line at a time, so a long run can be followed and a cut-off run keeps what it printed.
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
            print("usage: board_harness <out_dir> [sonnet|opus] [topic ...]")
            exit(2)
        }
        let outputDirectory = URL(fileURLWithPath: arguments[1])
        let isOffline = arguments.count > 2 && arguments[2] == "offline"
        // "replay <run_dir>" redraws the programs a model already wrote in an
        // earlier run, so a layout change is seen on real answers for free.
        let replayDirectory = arguments.count > 3 && arguments[2] == "replay" ? URL(fileURLWithPath: arguments[3]) : nil
        let makesNoCalls = isOffline || replayDirectory != nil
        let brain = makesNoCalls ? Brain(name: isOffline ? "offline" : "replay", model: "none", thinking: [:], effort: "",
                                         thinkingHeadroom: 0, inputPrice: 0, cachedPrice: 0, outputPrice: 0)
            : (brains[arguments.count > 2 ? arguments[2] : "sonnet"] ?? brains["sonnet"]!)
        let chosenTopics = isOffline ? [Topic(name: "offline-check", questions: offlinePrograms.map(\.question))]
            : (replayDirectory == nil && arguments.count > 3 ? topics.filter { arguments[3...].contains($0.name) } : topics)
        let apiKey = makesNoCalls ? "" : try readAnthropicKey()
        let vertexProject = brain.isArgon ? try readVertexProject() : ""
        var vertexToken = brain.isArgon ? try mintVertexToken() : ""

        TutorBoardLog.write = { line in print("    " + line) }
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let renderer = try await BoardRenderer(repository: repository)

        var allTurns: [String: [TurnUsage]] = [:]
        for topic in chosenTopics {
            let topicDirectory = outputDirectory.appendingPathComponent(brain.name).appendingPathComponent(topic.name)
            try FileManager.default.createDirectory(at: topicDirectory, withIntermediateDirectories: true)
            let surface = BoardSurface(canvasWidth: renderer.canvasWidth, canvasHeight: renderer.canvasHeight)
            let board = TeachingBoard(layout: surface.layout)
            var history: [(question: String, program: String, sentences: [String])] = []
            var turns: [TurnUsage] = []
            var partTitles: [String] = []
            try await renderer.openBoard(surface: surface)

            for (index, question) in topic.questions.enumerated() {
                let turnNumber = index + 1
                board.beginTurn()
                let note = BoardProgramPrompt.turnNote(transcript: question, boardListing: board.state.compactListing(),
                                                       turnNumber: turnNumber, studentName: nil)
                let historyForModel = history.enumerated().map { historyIndex, turn -> (String, String) in
                    let keepsWhole = BoardProgramPrompt.keepsWholeProgram(turnIndex: historyIndex, turnCount: history.count)
                    return (turn.question, keepsWhole ? turn.program
                            : BoardProgramPrompt.shortenedTurnPrefix + turn.sentences.joined(separator: " "))
                }
                let started = Date()
                let reply: Reply
                do {
                    reply = isOffline
                        ? Reply(text: offlinePrograms[index].program, output: 0, freshInput: 0, cachedInput: 0, cacheWrites: 0)
                        : replayDirectory != nil
                        ? Reply(text: try String(contentsOf: replayDirectory!.appendingPathComponent(topic.name)
                                                    .appendingPathComponent("turn\(turnNumber).program.js"), encoding: .utf8),
                                output: 0, freshInput: 0, cachedInput: 0, cacheWrites: 0)
                        : brain.isArgon
                        ? try await askArgon(token: vertexToken, project: vertexProject, system: BoardProgramPrompt.system,
                                             history: historyForModel, note: note,
                                             maximumTokens: BoardProgramPrompt.maximumTokens(turnNumber: turnNumber))
                        : try await askClaude(apiKey: apiKey, brain: brain, system: BoardProgramPrompt.system,
                                              history: historyForModel, note: note,
                                              maximumTokens: BoardProgramPrompt.maximumTokens(turnNumber: turnNumber))
                } catch {
                    // A failed call ends this topic, not the run: the turns so
                    // far are kept and the next topic is tried.
                    print(String(format: "%@ %@ turn %d FAILED after %.1fs: %@", brain.name, topic.name, turnNumber,
                                 Date().timeIntervalSince(started), String(error.localizedDescription.prefix(160))))
                    break
                }
                if brain.isArgon, turnNumber % 3 == 0 { vertexToken = try mintVertexToken() }
                let seconds = Date().timeIntervalSince(started)

                // Exactly what LessonProgramPlayer does: cut into pieces as
                // the stream would, translate each piece's board calls, run it.
                var stream = ProgramStream()
                let pieces = stream.finish(fullText: reply.text).newPieces
                var problems: [String] = []
                var translatedProgram = ""
                try await renderer.beginTurn(surface: surface)
                partTitles.append(question.split(separator: " ").prefix(6).joined(separator: " "))
                try await renderer.setParts(partTitles)
                var engineErrors: [String] = []
                for piece in pieces {
                    let translation = BoardProgramTranslator.translate(piece, on: board)
                    problems += translation.problems
                    translatedProgram += translation.code
                    engineErrors += try await renderer.run(piece: translation.code)
                }
                if let title = Self.lessonTitle(in: reply.text) {
                    partTitles[partTitles.count - 1] = title
                    try await renderer.setParts(partTitles)
                }
                let pngURL = topicDirectory.appendingPathComponent("turn\(turnNumber).png")
                try await renderer.snapshot(to: pngURL)

                let sentences = ProgramStream.closedSayArguments(in: ProgramStream.code(in: reply.text))
                history.append((question, reply.text, sentences))
                try reply.text.write(to: topicDirectory.appendingPathComponent("turn\(turnNumber).program.js"), atomically: true, encoding: .utf8)
                try translatedProgram.write(to: topicDirectory.appendingPathComponent("turn\(turnNumber).translated.js"), atomically: true, encoding: .utf8)
                try note.write(to: topicDirectory.appendingPathComponent("turn\(turnNumber).note.txt"), atomically: true, encoding: .utf8)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(board.state).write(to: topicDirectory.appendingPathComponent("turn\(turnNumber).board.json"))

                let dollars = (Double(reply.freshInput) * brain.inputPrice + Double(reply.cachedInput) * brain.cachedPrice
                               + Double(reply.cacheWrites) * brain.inputPrice * 2 + Double(reply.output) * brain.outputPrice) / 1_000_000
                let usage = TurnUsage(turn: turnNumber, question: question, outputTokens: reply.output,
                                      freshInputTokens: reply.freshInput, cachedInputTokens: reply.cachedInput,
                                      cacheWriteTokens: reply.cacheWrites, noteCharacters: note.count,
                                      elementsAfter: board.state.elements.count, connectorsAfter: board.state.connectors.count,
                                      problems: problems, engineErrors: engineErrors, seconds: seconds, dollars: dollars,
                                      png: pngURL.path)
                turns.append(usage)
                print(String(format: "%@ %@ turn %d: %d out, %d fresh in, %d cached, %d written, %d elements, %d problems, %d engine errors, %.1fs, $%.4f",
                             brain.name, topic.name, turnNumber, reply.output, reply.freshInput, reply.cachedInput, reply.cacheWrites,
                             board.state.elements.count, problems.count, engineErrors.count, seconds, dollars))
                for problem in problems { print("    board: \(problem)") }
                for engineError in engineErrors { print("    engine: \(engineError)") }
            }
            allTurns[topic.name] = turns
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(turns).write(to: topicDirectory.appendingPathComponent("summary.json"))
        }

        let everyTurn = allTurns.values.flatMap { $0 }
        let totalDollars = everyTurn.reduce(0) { $0 + $1.dollars }
        let meanOutput = Double(everyTurn.reduce(0) { $0 + $1.outputTokens }) / Double(max(1, everyTurn.count))
        print(String(format: "\n%@: %d turns, mean %.0f output tokens a turn, $%.3f in all", brain.name, everyTurn.count, meanOutput, totalDollars))

        guard !makesNoCalls else { return }
        // The turn note's size for a board of twenty elements, counted by
        // the API's own tokenizer.
        let sizeProbe = twentyElementBoard()
        let probeNote = BoardProgramPrompt.turnNote(transcript: "what happens when a server leaves the ring",
                                                    boardListing: sizeProbe.state.compactListing(), turnNumber: 4, studentName: nil)
        let countingModel = brain.isArgon ? "claude-sonnet-5-5" : brain.model
        let probeTokens = try await countTokens(apiKey: apiKey, model: countingModel, text: probeNote)
        let systemTokens = try await countTokens(apiKey: apiKey, model: countingModel, text: BoardProgramPrompt.system)
        try probeNote.write(to: outputDirectory.appendingPathComponent("twenty_element_note.txt"), atomically: true, encoding: .utf8)
        print("turn note for a \(sizeProbe.state.elements.count)-element board with \(sizeProbe.state.connectors.count) arrows: \(probeNote.count) characters, \(probeTokens) tokens")
        print("board system prompt: \(BoardProgramPrompt.system.count) characters, \(systemTokens) tokens")
    }

    static let offlinePrograms: [(question: String, program: String)] = [
        ("teach me consistent hashing from scratch", """
        ```js
        step(1);
        say("consistent hashing decides which server keeps each key, so adding a server moves few keys.");
        board.title("consistent hashing");
        step(2);
        say("picture a ring of numbers from zero to ninety nine.");
        board.group("ring", "the hash ring, 0 to 99");
        say("each server is hashed to a spot on it.");
        board.circle("a", "A at 10", {in: "ring"});
        board.circle("b", "B at 45", {in: "ring"});
        board.circle("c", "C at 80", {in: "ring"});
        step(3);
        say("a key is hashed the same way, then walks clockwise to the next server.");
        board.box("key", "user42 hashes to 30");
        board.link("key", "b", "walks clockwise");
        step(4);
        say("so each server owns the stretch of ring just before it.");
        board.table("owns", "who owns what", [["range", "server"], ["81 to 10", "A"], ["11 to 45", "B"], ["46 to 80", "C"]], {near: "ring", side: "below"});
        board.note("tip", "only one neighbour's keys move");
        board.highlight("b");
        button("a server leaves", {ask: "what happens when a server leaves the ring"});
        lessonTitle("consistent hashing basics");
        ```
        """),
        ("what happens when a server leaves the ring", """
        ```js
        step(1);
        say("when b leaves, only its keys move, to the next server clockwise.");
        board.highlight("b");
        board.update("b", "B left");
        step(2);
        say("user42 now walks past where b was and lands on c.");
        board.unlink("key", "b");
        board.link("key", "c", "now lands on C");
        step(3);
        say("the table changes in one row only.");
        board.update("owns", [["range", "server"], ["81 to 10", "A"], ["11 to 80", "C"]]);
        board.list("leave", "a server leaves", ["its keys go to the next server", "every other key stays put"]);
        ```
        """)
    ]

    /// A board with twenty elements, built through the same API the model
    /// uses, to measure the turn note at that size.
    static func twentyElementBoard() -> TeachingBoard {
        let surface = BoardSurface(canvasWidth: 1512, canvasHeight: 982)
        let board = TeachingBoard(layout: surface.layout)
        board.beginTurn()
        var program = "board.title(\"consistent hashing\");\nboard.group(\"ring\", \"the hash ring, 0 to 99\");\n"
        for (index, name) in ["A", "B", "C", "D"].enumerated() {
            program += "board.circle(\"s\(index)\", \"server \(name) at \(10 + index * 25)\", {in: \"ring\"});\n"
        }
        for index in 0..<6 {
            program += "board.box(\"k\(index)\", \"key\(index) hashes to \(index * 17)\");\n"
            program += "board.link(\"k\(index)\", \"s\(index % 4)\", \"goes to\");\n"
        }
        program += "board.table(\"where\", \"where keys live\", [[\"key\", \"server\"], [\"key0\", \"A\"], [\"key1\", \"A\"], [\"key2\", \"B\"]]);\n"
        program += "board.list(\"steps\", \"a server leaves\", [\"its keys move on\", \"to the next server\", \"nothing else moves\"]);\n"
        program += "board.note(\"tip\", \"only one neighbour's keys move\");\n"
        program += "board.label(\"why\", \"clockwise is the rule\");\n"
        program += "board.box(\"client\", \"client\");\nboard.box(\"hash\", \"hash function\");\nboard.link(\"client\", \"hash\", \"key\");\n"
        program += "board.circle(\"v1\", \"A copy 2\", {in: \"ring\"});\nboard.label(\"load\", \"load evens out\");\nboard.circle(\"v2\", \"B copy 2\", {in: \"ring\"});\n"
        _ = BoardProgramTranslator.translate(program, on: board)
        return board
    }

    // MARK: - The API

    struct Reply {
        var text: String
        var output: Int
        var freshInput: Int
        var cachedInput: Int
        var cacheWrites: Int
    }

    static func lessonTitle(in program: String) -> String? {
        guard let match = program.range(of: #"lessonTitle\(\s*"([^"]*)""#, options: .regularExpression) else { return nil }
        let call = String(program[match])
        guard let open = call.firstIndex(of: "\"") else { return nil }
        return String(call[call.index(after: open)...].dropLast())
    }

    static func readVertexProject() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "com.maverickrajeev.clicky-local", "vertexProjectIdentifier"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let project = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !project.isEmpty else { throw NSError(domain: "board", code: 4, userInfo: [NSLocalizedDescriptionKey: "no Vertex project in the app's defaults"]) }
        return project
    }

    /// As GeminiVisionProvider mints it: gcloud's application default credential.
    static func mintVertexToken() throws -> String {
        let candidates = ["/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud", "\(NSHomeDirectory())/google-cloud-sdk/bin/gcloud"]
        guard let gcloud = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "board", code: 5, userInfo: [NSLocalizedDescriptionKey: "gcloud not found"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gcloud)
        process.arguments = ["auth", "application-default", "print-access-token"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let token = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !token.isEmpty else {
            throw NSError(domain: "board", code: 6, userInfo: [NSLocalizedDescriptionKey: "gcloud gave no access token"])
        }
        return token
    }

    /// The request GeminiVisionProvider makes on Vertex, without a
    /// screenshot: history in user and model pairs, the system instruction,
    /// thinking LOW, the app's token room.
    static func askArgon(token: String, project: String, system: String, history: [(String, String)], note: String,
                         maximumTokens: Int) async throws -> Reply {
        var contents: [[String: Any]] = []
        for exchange in history {
            contents.append(["role": "user", "parts": [["text": exchange.0]]])
            contents.append(["role": "model", "parts": [["text": exchange.1]]])
        }
        contents.append(["role": "user", "parts": [["text": note]]])
        let body: [String: Any] = [
            "contents": contents,
            "systemInstruction": ["parts": [["text": system]]],
            "generationConfig": ["maxOutputTokens": maximumTokens, "thinkingConfig": ["thinkingLevel": "LOW"]]
        ]
        var request = URLRequest(url: URL(string: "https://aiplatform.googleapis.com/v1/projects/\(project)/locations/global/publishers/google/models/gemini-4-argon:generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Vertex answers a burst with 429 now and then: waited out, as a
        // student's next question would be.
        var data = Data()
        var status = 0
        for attempt in 0..<2 {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            data = responseData
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 429 else { break }
            print("    Vertex said 429, waiting \(20 * (attempt + 1))s")
            try await Task.sleep(nanoseconds: UInt64(20 * (attempt + 1)) * 1_000_000_000)
        }
        guard status == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "board", code: status, userInfo: [NSLocalizedDescriptionKey:
                "HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(400) ?? "")"])
        }
        let candidate = (object["candidates"] as? [[String: Any]])?.first
        let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        let usage = object["usageMetadata"] as? [String: Any] ?? [:]
        let prompt = usage["promptTokenCount"] as? Int ?? 0
        let cached = usage["cachedContentTokenCount"] as? Int ?? 0
        let output = (usage["candidatesTokenCount"] as? Int ?? 0) + (usage["thoughtsTokenCount"] as? Int ?? 0)
        return Reply(text: text, output: output, freshInput: max(0, prompt - cached), cachedInput: cached, cacheWrites: 0)
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
        guard !key.isEmpty else { throw NSError(domain: "board", code: 1, userInfo: [NSLocalizedDescriptionKey: "no Anthropic key in the Keychain"]) }
        return key
    }

    /// The request ClaudeVisionProvider makes, without a screenshot: the
    /// system prompt cached for an hour, a cache point after the last
    /// earlier answer, thinking and effort as in the app's profile.
    static func askClaude(apiKey: String, brain: Brain, system: String, history: [(String, String)], note: String,
                          maximumTokens: Int) async throws -> Reply {
        var messages: [[String: Any]] = []
        for (index, exchange) in history.enumerated() {
            messages.append(["role": "user", "content": exchange.0])
            var block: [String: Any] = ["type": "text", "text": exchange.1]
            if index == history.count - 1 { block["cache_control"] = ["type": "ephemeral", "ttl": "1h"] }
            messages.append(["role": "assistant", "content": [block]])
        }
        messages.append(["role": "user", "content": [["type": "text", "text": note]]])
        let body: [String: Any] = [
            "model": brain.model,
            "max_tokens": maximumTokens + brain.thinkingHeadroom,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral", "ttl": "1h"]]],
            "messages": messages,
            "thinking": brain.thinking,
            "output_config": ["effort": brain.effort]
        ]
        let object = try await post(apiKey: apiKey, path: "/v1/messages", body: body)
        let text = (object["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined()
        let usage = object["usage"] as? [String: Any] ?? [:]
        return Reply(text: text, output: usage["output_tokens"] as? Int ?? 0, freshInput: usage["input_tokens"] as? Int ?? 0,
                     cachedInput: usage["cache_read_input_tokens"] as? Int ?? 0,
                     cacheWrites: usage["cache_creation_input_tokens"] as? Int ?? 0)
    }

    static func countTokens(apiKey: String, model: String, text: String) async throws -> Int {
        let object = try await post(apiKey: apiKey, path: "/v1/messages/count_tokens",
                                    body: ["model": model, "messages": [["role": "user", "content": text]]])
        return object["input_tokens"] as? Int ?? -1
    }

    static func post(apiKey: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "board", code: status, userInfo: [NSLocalizedDescriptionKey:
                "HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(400) ?? "")"])
        }
        return object
    }
}

/// The app's drawing page, loaded the way DrawingOverlay loads it, in a web
/// view inside a window far outside every display.
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

    /// As LessonProgramPlayer.begin does before every answer, then the board's own turn start.
    func setParts(_ parts: [String]) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["parts": parts, "current": parts.count - 1])
        _ = try await evaluate("BuddyBoard.setParts(\(String(data: data, encoding: .utf8) ?? "{}"));")
    }

    func beginTurn(surface: BoardSurface) async throws {
        try await setUpCanvas()
        _ = try await evaluate("BuddyBoard.beginTurn();")
    }

    func run(piece: String) async throws -> [String] {
        let value = try await webView.callAsyncJavaScript("return JSON.stringify(BuddyEngine.run(code));",
                                                          arguments: ["code": piece], contentWorld: .page)
        guard let text = value as? String, let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object["newErrors"] as? [String] ?? []
    }

    /// Every stroke finished, then a picture over a placeholder screen.
    func snapshot(to url: URL) async throws {
        _ = try await evaluate("BuddyEngine.finishAll();")
        try await Task.sleep(nanoseconds: 300_000_000)
        // A window outside every display is never composited, so the page
        // paints its own picture: every finished animation's end state is
        // written into the elements, the drawing is serialised and painted
        // into a canvas at twice the size.
        let dataURL = try await evaluate("""
        // A page that is never shown has its clock held, so every animation
        // is first jumped to its end, as it would be on screen by now.
        // commitStyles refuses some SVG targets, so the last keyframe is
        // written by hand where it does.
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
        // A pen stroke is revealed by a dash as long as the path; once drawn
        // the dash is the whole line, and dropping it draws the same thing
        // without depending on how the image renderer measures the path.
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
              let pngData = Data(base64Encoded: String(dataURL[dataURL.index(after: commaIndex)...])),
              let image = NSImage(data: pngData) else {
            throw NSError(domain: "board", code: 3, userInfo: [NSLocalizedDescriptionKey: "the page painted no picture"])
        }
        let pixelWidth = Int(canvasWidth) * 2, pixelHeight = Int(canvasHeight) * 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.cgContext.scaleBy(x: 2, y: 2)
        drawPlaceholderScreen(width: canvasWidth, height: canvasHeight)
        image.draw(in: NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A stand-in for whatever the student had open: a light editor window
    /// on a desktop, so the dimming reads as it would on a real screen.
    private func drawPlaceholderScreen(width: Double, height: Double) {
        NSColor(calibratedRed: 0.36, green: 0.45, blue: 0.58, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 120, y: 90, width: width - 240, height: height - 180), xRadius: 12, yRadius: 12).fill()
        NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
        for row in 0..<22 {
            let lineWidth = Double(200 + (row * 137) % 700)
            NSRect(x: 180, y: height - 170 - Double(row) * 30, width: lineWidth, height: 10).fill()
        }
    }
}
