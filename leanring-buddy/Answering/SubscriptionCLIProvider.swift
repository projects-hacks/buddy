//
//  SubscriptionCLIProvider.swift
//  leanring-buddy
//
//  A brain that answers through a subscription the student already pays
//  for: Claude (Pro or Max), ChatGPT (through Codex) or GitHub Copilot.
//
//  It runs that vendor's own command-line tool, installed and signed in on
//  this Mac, and reads its streamed JSON. Buddy never sees or stores the
//  subscription's credentials. Lifting a CLI's sign-in tokens and calling the
//  API with them directly would be faster, but every one of these vendors
//  forbids it, and that can get the student's account banned.
//
//  The cost of doing it this way is the process start. Measured on an M4:
//  Claude's first word after about 1.5 s of a 5 s run (with no settings,
//  MCP servers or skills loaded; with the student's own hooks and plugins it
//  took 13 s), and Copilot took about 16 s, most of it picking a model. So
//  this is a brain the student chooses, never one Auto routes to.
//

import Foundation

/// A vendor CLI that can answer with the student's subscription.
enum SubscriptionCLI: String, CaseIterable, Identifiable {
    case claude, codex, copilot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .copilot: return "GitHub Copilot"
        }
    }

    /// Which subscription pays, for the setup card.
    var subscriptionName: String {
        switch self {
        case .claude: return "Claude Pro or Max"
        case .codex: return "ChatGPT Plus or Pro"
        case .copilot: return "GitHub Copilot"
        }
    }

    var binaryName: String { rawValue }

    var installCommand: String {
        switch self {
        case .claude: return "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: return "npm install -g @openai/codex"
        case .copilot: return "npm install -g @github/copilot"
        }
    }

    var signInCommand: String {
        switch self {
        case .claude: return "claude auth login"
        case .codex: return "codex login"
        case .copilot: return "copilot login"
        }
    }

    /// Where these CLIs install. An app opened from Finder inherits a bare
    /// PATH rather than the one the shell sets, so the usual places are added.
    /// shortcut: misses node installed only through nvm or asdf; add their
    /// shim folders if students report "not installed" with it installed.
    static var searchDirectories: [String] {
        let home = NSHomeDirectory()
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let usual = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                     "\(home)/.npm-global/bin", "\(home)/.bun/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        return (usual + inherited).filter { seen.insert($0).inserted }
    }

    /// The installed binary, or nil.
    var executableURL: URL? {
        Self.searchDirectories
            .map { URL(fileURLWithPath: $0).appendingPathComponent(binaryName) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var isInstalled: Bool { executableURL != nil }

    // MARK: - The command

    /// Arguments for one answer. `prompt` already holds the earlier
    /// conversation; the system prompt goes in it too for the CLIs with no
    /// flag for one.
    func arguments(systemPrompt: String, prompt: String, imagePaths: [String]) -> [String] {
        switch self {
        case .claude:
            // No settings, MCP servers, skills or tools: the student's own
            // Claude Code setup added eight seconds of hooks to every answer
            // in testing, and an answer needs none of it. Not --bare, which
            // also skips the keychain and with it the subscription sign-in.
            // Images go in as content blocks on stdin, so no files.
            return ["-p", "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands",
                    "--tools", "", "--no-session-persistence", "--model", "sonnet", "--effort", "low",
                    "--input-format", "stream-json", "--output-format", "stream-json",
                    "--verbose", "--include-partial-messages", "--system-prompt", systemPrompt]
        case .codex:
            // The prompt comes on stdin ("-"), so a long one is never an argument.
            return ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only"]
                + imagePaths.flatMap { ["-i", $0] } + ["-"]
        case .copilot:
            // No tools: with them it opened the screenshot with `view`, then
            // ran Python on it, three model turns for one answer.
            return ["-p", Self.combined(systemPrompt: systemPrompt, prompt: prompt),
                    "--output-format", "json", "--stream", "on",
                    "--no-custom-instructions", "--disable-builtin-mcps", "--available-tools="]
                + imagePaths.flatMap { ["--attachment", $0] }
        }
    }

    /// What is written to the CLI's stdin, or nil for nothing.
    func standardInput(systemPrompt: String, prompt: String, jpegImages: [Data]) -> Data? {
        switch self {
        case .claude:
            var content: [[String: Any]] = jpegImages.map { jpeg in
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                             "data": jpeg.base64EncodedString()]]
            }
            content.append(["type": "text", "text": prompt])
            let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
            guard var line = try? JSONSerialization.data(withJSONObject: message) else { return nil }
            line.append(0x0A)
            return line
        case .codex:
            return Self.combined(systemPrompt: systemPrompt, prompt: prompt).data(using: .utf8)
        case .copilot:
            return nil
        }
    }

    private static func combined(systemPrompt: String, prompt: String) -> String {
        "\(systemPrompt)\n\n---\n\n\(prompt)"
    }

    // MARK: - Reading the stream

    enum Event: Equatable {
        /// More of the answer.
        case text(String)
        /// The CLI reported an error in its stream.
        case failure(String)
    }

    /// One line of the CLI's JSON output, read as more answer text, a failure,
    /// or nil for the many lines that are neither (hooks, status, usage).
    func event(inLine line: String) -> Event? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch self {
        case .claude:
            if type == "stream_event",
               let event = object["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String, !text.isEmpty {
                return .text(text)
            }
            if type == "result", object["is_error"] as? Bool == true {
                return .failure(object["result"] as? String ?? "unknown error")
            }
        case .codex:
            // Codex sends each message whole, not word by word.
            if type == "item.completed", let item = object["item"] as? [String: Any],
               item["type"] as? String == "agent_message", let text = item["text"] as? String, !text.isEmpty {
                return .text(text)
            }
            if type == "error" { return .failure(object["message"] as? String ?? "unknown error") }
            if type == "turn.failed" {
                return .failure((object["error"] as? [String: Any])?["message"] as? String ?? "unknown error")
            }
        case .copilot:
            let payload = object["data"] as? [String: Any]
            if type == "assistant.message_delta", let text = payload?["deltaContent"] as? String, !text.isEmpty {
                return .text(text)
            }
            if type == "session.error" { return .failure(payload?["message"] as? String ?? "unknown error") }
        }
        return nil
    }

    /// Whether a failure means the CLI is installed but not signed in.
    static func meansSignedOut(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return ["not logged in", "log in", "login", "sign in", "signed in", "authenticat", "unauthorized"]
            .contains { lowered.contains($0) }
    }
}

/// Answers with the student's subscription, through its own CLI.
final class SubscriptionCLIProvider: TutorBrain {
    var cli: SubscriptionCLI
    /// Not settable per CLI: each picks its own model from the subscription.
    var model: String
    /// The CLIs have no output limit flag; the prompt's own length budgets
    /// hold answers short.
    var maximumResponseTokens: Int = 380
    var maximumImageDimension: CGFloat = 1024

    /// A CLI that never exits, waiting on a prompt nobody can see, would
    /// otherwise hold this question and every later one.
    static let longestAnswerSeconds: UInt64 = 180

    init(cli: SubscriptionCLI) {
        self.cli = cli
        self.model = cli.rawValue
    }

    /// Installed counts as reachable. Being signed in is proved by the
    /// first answer (or setup's Check), whose error then says how to sign in.
    func probeServer() async -> (isReachable: Bool, installedModels: [String]) {
        guard cli.isInstalled else {
            TutorDebugLog.write("⚠️ \(cli.displayName) CLI not found in \(SubscriptionCLI.searchDirectories.joined(separator: ":"))")
            return (false, [])
        }
        return (true, [cli.rawValue])
    }

    func preloadModel() async {}

    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        try await analyzeImageStreaming(images: images, systemPrompt: systemPrompt,
                                        conversationHistory: conversationHistory,
                                        userPrompt: userPrompt, onTextChunk: { _ in })
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let cli = self.cli
        guard let executableURL = cli.executableURL else { throw SubscriptionCLIError.notInstalled(cli) }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let jpegImages = images.map { ClaudeVisionProvider.reduced(imageData: $0.data, toLongestEdge: maximumImageDimension) }
        var imagePaths: [String] = []
        for (index, jpeg) in jpegImages.enumerated() {
            let url = workingDirectory.appendingPathComponent("screen-\(index + 1).jpg")
            try jpeg.write(to: url)
            imagePaths.append(url.path)
        }
        let prompt = Self.prompt(images: images, conversationHistory: conversationHistory, userPrompt: userPrompt)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = cli.arguments(systemPrompt: systemPrompt, prompt: prompt, imagePaths: imagePaths)
        // An empty folder: no project instructions or files get picked up.
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        // Copilot and Codex are node scripts, found through `env node`.
        environment["PATH"] = SubscriptionCLI.searchDirectories.joined(separator: ":")
        process.environment = environment
        let inputPipe = Pipe(), outputPipe = Pipe(), errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do { try process.run() } catch { throw SubscriptionCLIError.notInstalled(cli) }
        TutorDebugLog.write("🎫 \(cli.displayName) CLI started, \(images.count) image(s)")

        // Read alongside stdout: a full stderr pipe nobody reads blocks the CLI.
        let errorReader = Task.detached { errorPipe.fileHandleForReading.readDataToEndOfFile() }
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: Self.longestAnswerSeconds * 1_000_000_000)
            if !Task.isCancelled, process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }

        if let input = cli.standardInput(systemPrompt: systemPrompt, prompt: prompt, jpegImages: jpegImages) {
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
        }
        try? inputPipe.fileHandleForWriting.close()

        var accumulatedText = ""
        var reportedFailure: String?
        try await withTaskCancellationHandler {
            for try await line in outputPipe.fileHandleForReading.bytes.lines {
                switch cli.event(inLine: line) {
                case .text(let chunk):
                    accumulatedText += chunk
                    let snapshot = accumulatedText
                    await onTextChunk(snapshot)
                case .failure(let message):
                    reportedFailure = message
                case nil:
                    continue
                }
            }
        } onCancel: {
            process.terminate()
        }
        // stdout has closed, so the process is exiting; this is milliseconds.
        while process.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
        try Task.checkCancellation()

        let errorOutput = String(data: await errorReader.value, encoding: .utf8) ?? ""
        let duration = Date().timeIntervalSince(startTime)
        TutorDebugLog.write("🎫 \(cli.displayName) exited \(process.terminationStatus) after \(String(format: "%.1f", duration))s, \(accumulatedText.count) chars")

        if !accumulatedText.isEmpty { return (accumulatedText, duration) }
        let message = reportedFailure ?? errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        TutorDebugLog.write("⚠️ \(cli.displayName) CLI: \(message.prefix(500))")
        if SubscriptionCLI.meansSignedOut(message) { throw SubscriptionCLIError.notSignedIn(cli) }
        throw SubscriptionCLIError.failed(cli, message.isEmpty ? "it gave no answer" : message)
    }

    /// The conversation as one text prompt: a CLI takes one turn at a time,
    /// so earlier exchanges are written in rather than sent as turns.
    static func prompt(
        images: [(data: Data, label: String)],
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> String {
        var parts: [String] = []
        if !conversationHistory.isEmpty {
            let earlier = conversationHistory
                .map { "Student: \($0.userPlaceholder)\nYou: \($0.assistantResponse)" }
                .joined(separator: "\n\n")
            parts.append("Earlier in this conversation:\n\n\(earlier)")
        }
        for (index, image) in images.enumerated() where !image.label.isEmpty {
            parts.append("Image \(index + 1): \(image.label)")
        }
        parts.append(userPrompt)
        return parts.joined(separator: "\n\n")
    }
}

enum SubscriptionCLIError: LocalizedError {
    case notInstalled(SubscriptionCLI)
    case notSignedIn(SubscriptionCLI)
    case failed(SubscriptionCLI, String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let cli):
            return "\(cli.displayName) isn't installed. Install it with: \(cli.installCommand)"
        case .notSignedIn(let cli):
            return "\(cli.displayName) isn't signed in. Run \(cli.signInCommand) in Terminal."
        case .failed(let cli, let message):
            return "\(cli.displayName) failed: \(message.prefix(300))"
        }
    }

    /// The sentence Buddy says when this stops an answer.
    var spokenExplanation: String {
        switch self {
        case .notInstalled(let cli):
            return "\(cli.displayName.lowercased()) isn't installed on this mac. the install command is in setup."
        case .notSignedIn(let cli):
            return "\(cli.displayName.lowercased()) isn't signed in. run \(cli.signInCommand) in a terminal, then ask again."
        case .failed(let cli, _):
            return "\(cli.displayName.lowercased()) couldn't answer that. the details are in the buddy log."
        }
    }
}
