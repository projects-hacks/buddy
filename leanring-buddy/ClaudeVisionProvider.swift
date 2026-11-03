//
//  ClaudeVisionProvider.swift
//  leanring-buddy
//
//  Hosted brain on Claude, first-party API.
//
//  Why a second hosted brain. Raced on the same screenshot, index, system
//  prompt and length budgets (scripts/brain_race.py), Argon at its lowest
//  thinking level took about twelve seconds to its first word, because it
//  always thinks before answering and streams in a few large chunks near the
//  end. Claude Sonnet 5.5 with thinking off started in about two seconds and
//  streams word by word, so the first sentence can be spoken while the rest
//  is still being written. For a voice that answers while the student waits,
//  that is the number that matters most.
//
//  Raw HTTP rather than an SDK: there is no official Swift SDK, and the
//  request is one POST with a server-sent event stream back, which the Gemini
//  provider already parses the same way.
//

import AppKit
import Foundation

/// Streaming vision chat against the Claude Messages API.
final class ClaudeVisionProvider: TutorBrain {
    private static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!

    /// The API version this request shape is written against.
    private static let apiVersion = "2026-10-21"

    var model: String
    var maximumResponseTokens: Int = 380

    /// The `thinking` object sent with every request.
    ///
    /// `between_tools` is Sonnet 5.5's way of turning extended thinking off.
    /// Off, because the answer is spoken while the student waits and the race
    /// showed Sonnet answering correctly without it. Other models reject
    /// `between_tools`, so a different model needs a different value here.
    var thinkingConfiguration: [String: Any] = ["type": "between_tools"]

    /// Effort level. `between_tools` accepts `high` or below.
    var effort: String = "high"

    /// Extra room on top of the spoken budget for a model that thinks.
    ///
    /// Thinking counts toward `max_tokens`, so without this a thinking model
    /// spends the budget reasoning and the spoken answer is cut short. Zero
    /// when thinking is off.
    var thinkingTokenHeadroom: Int = 0

    /// Longest edge a screenshot is reduced to before upload. Same as the
    /// Gemini path, for the same reasons: it is billed and uploaded, and the
    /// text the answer depends on comes from the on-device index anyway.
    var maximumImageDimension: CGFloat = 1024

    private let session: URLSession

    /// Sets model, thinking and effort for the next question in one step, so
    /// a profile can never be half applied.
    func apply(_ profile: ClaudeAnswerProfile) {
        model = profile.model
        thinkingConfiguration = profile.thinkingConfiguration
        effort = profile.effort
        thinkingTokenHeadroom = profile.thinkingTokenHeadroom
    }

    init(model: String = "claude-sonnet-5-5") {
        self.model = model

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Readiness

    /// Opens the connection to the API before it is needed, so the first
    /// answer does not pay for the secure handshake. Any response will do;
    /// listing models is free and needs nothing but the key.
    func prewarmConnection() {
        guard let apiKey = APIKeyStore.key(for: .anthropic),
              let url = URL(string: "https://api.anthropic.com/v1/models?limit=1") else { return }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 10
        session.dataTask(with: request).resume()
    }

    /// Reachable means a key is stored. Checking it against the API would cost
    /// a request on every launch; a bad key surfaces on the first question
    /// with the API's own error instead.
    func probeServer() async -> (isReachable: Bool, installedModels: [String]) {
        guard APIKeyStore.hasKey(for: .anthropic) else {
            TutorDebugLog.write("⚠️ no Anthropic API key in the keychain")
            return (false, [])
        }
        return (true, [model])
    }

    /// Nothing to warm: there are no weights to load on this side.
    func preloadModel() async {}

    // MARK: - Streaming

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let request = try makeRequest(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            streaming: true
        )

        let (byteStream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.malformedResponse }
        guard (200...299).contains(http.statusCode) else {
            var errorLines: [String] = []
            for try await line in byteStream.lines { errorLines.append(line) }
            throw ClaudeError.httpStatus(http.statusCode, errorLines.joined(separator: " ").prefix(300).description)
        }

        var accumulatedText = ""
        var inputUsageForCost: (fresh: Int, cached: Int, written: Int) = (0, 0, 0)

        // Each `data:` line carries a typed event. Only text deltas are spoken;
        // thinking blocks, when a model writes them, are skipped by type.
        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            guard let payloadData = String(line.dropFirst(6)).data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let eventType = payload["type"] as? String else {
                continue
            }

            switch eventType {
            case "message_start":
                // How much of the prompt came from cache, for the cost log.
                if let message = payload["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    let fresh = usage["input_tokens"] as? Int ?? 0
                    let cached = usage["cache_read_input_tokens"] as? Int ?? 0
                    let written = usage["cache_creation_input_tokens"] as? Int ?? 0
                    TutorDebugLog.write("💾 \(model): \(cached) cached, \(written) newly cached, \(fresh) fresh input tokens")
                    inputUsageForCost = (fresh, cached, written)
                }

            case "content_block_delta":
                guard let delta = payload["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let chunk = delta["text"] as? String, !chunk.isEmpty else { continue }
                accumulatedText += chunk
                let snapshot = accumulatedText
                await onTextChunk(snapshot)

            case "message_delta":
                // How the answer ended, and how long it was: a program cut off
                // at max_tokens explains a lesson that stops mid-sentence.
                if let delta = payload["delta"] as? [String: Any],
                   let stopReason = delta["stop_reason"] as? String {
                    let outputTokens = (payload["usage"] as? [String: Any])?["output_tokens"] as? Int ?? 0
                    TutorDebugLog.write("🏁 \(model) stopped: \(stopReason), \(outputTokens) output tokens, \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s")
                    let cost = Self.estimatedCostInDollars(
                        model: model, freshInput: inputUsageForCost.fresh,
                        cachedInput: inputUsageForCost.cached, cacheWrites: inputUsageForCost.written,
                        output: outputTokens
                    )
                    TutorDebugLog.write("💰 about $\(String(format: "%.4f", cost)) for this answer")
                    if stopReason == "refusal" {
                        TutorDebugLog.write("⚠️ Claude declined to answer this one")
                    }
                }

            case "error":
                // Errors after the stream has started, an overloaded server
                // most often, come as an event rather than an HTTP status.
                let error = payload["error"] as? [String: Any]
                let message = error?["message"] as? String ?? "unknown"
                throw ClaudeError.streamError(message)

            default:
                continue
            }
        }

        return (text: accumulatedText, duration: Date().timeIntervalSince(startTime))
    }

    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let request = try makeRequest(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            streaming: false
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.prefix(300).description ?? "unknown"
            throw ClaudeError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]] else {
            throw ClaudeError.malformedResponse
        }

        // Read by block type, not position: a thinking model can lead with a
        // thinking block before the text.
        let text = contentBlocks
            .filter { block in block["type"] as? String == "text" }
            .compactMap { block in block["text"] as? String }
            .joined()
        return (text: text, duration: Date().timeIntervalSince(startTime))
    }

    /// List prices per million tokens, for the cost line in the log. Cache
    /// reads are a tenth of input; cache writes a quarter more than input.
    private static func estimatedCostInDollars(
        model: String, freshInput: Int, cachedInput: Int, cacheWrites: Int, output: Int
    ) -> Double {
        let (inputPrice, outputPrice): (Double, Double)
        switch model {
        case let name where name.contains("opus"): (inputPrice, outputPrice) = (4, 20)
        case let name where name.contains("haiku"): (inputPrice, outputPrice) = (0.10, 0.50)
        default: (inputPrice, outputPrice) = (2, 10)
        }
        let cacheReadPrice = model.contains("haiku") ? 0.01 : 0.20
        let millions = 1_000_000.0
        return Double(freshInput) * inputPrice / millions
            + Double(cachedInput) * cacheReadPrice / millions
            + Double(cacheWrites) * inputPrice * 1.25 / millions
            + Double(output) * outputPrice / millions
    }

    // MARK: - Request construction

    private func makeRequest(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        streaming: Bool
    ) throws -> URLRequest {
        guard let apiKey = APIKeyStore.key(for: .anthropic) else {
            throw ClaudeError.missingKey
        }

        var request = URLRequest(url: Self.messagesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        // The conversation so far is identical from one turn to the next
        // apart from the newest exchange, so a cache point after the last
        // earlier answer lets the next turn read all of it from cache. The
        // current turn is not cached: its screenshot and screen text are
        // never sent again, so writing them to cache would cost a quarter
        // more and save nothing.
        var messages: [[String: Any]] = []
        for (historyIndex, exchange) in conversationHistory.enumerated() {
            messages.append(["role": "user", "content": exchange.userPlaceholder])
            var answerBlock: [String: Any] = ["type": "text", "text": exchange.assistantResponse]
            if historyIndex == conversationHistory.count - 1 {
                answerBlock["cache_control"] = ["type": "ephemeral"]
            }
            messages.append(["role": "assistant", "content": [answerBlock]])
        }

        var currentContent: [[String: Any]] = []
        for labeledImage in images {
            let reducedData = Self.reduced(
                imageData: labeledImage.data,
                toLongestEdge: maximumImageDimension
            )
            currentContent.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": reducedData.base64EncodedString()
                ]
            ])
            if !labeledImage.label.isEmpty {
                currentContent.append(["type": "text", "text": labeledImage.label])
            }
        }
        currentContent.append(["type": "text", "text": userPrompt])
        messages.append(["role": "user", "content": currentContent])

        // No temperature or top_p: this API version rejects sampling
        // parameters on every model.
        //
        // The system prompt is the same on every turn, so after the first
        // question it is read from cache at a tenth of the price. Caching
        // changes nothing the model sees; it only skips re-reading an
        // identical prefix.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maximumResponseTokens + thinkingTokenHeadroom,
            "system": [[
                "type": "text",
                "text": systemPrompt,
                "cache_control": ["type": "ephemeral"]
            ]],
            "messages": messages,
            "thinking": thinkingConfiguration,
            "output_config": ["effort": effort],
            "stream": streaming
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        let payloadMB = Double(bodyData.count) / 1_048_576.0
        TutorDebugLog.write("☁️ Claude \(model): \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        return request
    }

    /// Scales a screenshot down and re-encodes it as JPEG, matching the
    /// media type the request declares.
    private static func reduced(imageData: Data, toLongestEdge longestEdge: CGFloat) -> Data {
        guard let sourceImage = NSImage(data: imageData),
              let sourceCGImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return imageData
        }

        let sourceWidth = CGFloat(sourceCGImage.width)
        let sourceHeight = CGFloat(sourceCGImage.height)
        // Already small enough: sent as captured, with no redraw and no
        // second JPEG pass on the path to the first word.
        guard max(sourceWidth, sourceHeight) > longestEdge else { return imageData }
        let scale = longestEdge / max(sourceWidth, sourceHeight)
        let targetWidth = Int(sourceWidth * scale)
        let targetHeight = Int(sourceHeight * scale)

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return imageData
        }
        bitmap.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current = graphicsContext
        graphicsContext?.imageInterpolation = .high
        sourceImage.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: NSRect(origin: .zero, size: sourceImage.size),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) ?? imageData
    }
}

// MARK: - Routing

/// What kind of question was asked, which decides who answers it.
enum QuestionKind: String {
    /// "which line is wrong". One sentence.
    case quick
    /// A real question wanting a compact answer.
    case normal
    /// "walk me through", "teach me". Room and a board.
    case teach
    /// "i still don't get it", after an answer that did not land.
    case reexplain
    /// "should this be a hash map instead". A judgement between designs.
    case tradeOff
}

/// Which Claude model answers, and how hard it thinks.
///
/// Chosen per kind from scripts/brain_race.py, two runs each on the same
/// screen and prompt. The time is to the first spoken sentence.
///
///   quick, normal  Sonnet, thinking off. 2.2 to 2.9s. Correct every time,
///                  and nothing else was faster without being worse.
///   teach          Opus, effort low. 2.6 to 2.8s, the same as Sonnet here,
///                  and it drew a board on every walk-through and kept to the
///                  three-mark rule, where Sonnet put five and six marks up.
///   reexplain      Opus, effort low. 4.5 to 4.9s against Sonnet's 2.0 to
///                  2.5s, bought deliberately: a re-explanation is a worked
///                  example with real numbers, Opus traced every step exactly,
///                  and Sonnet slipped a step in one run. A wrong number in the
///                  explanation meant to finally make it click is the worst
///                  place for one.
///   tradeOff       Opus, effort low. 3.2 to 3.9s. Same verdict as Sonnet but
///                  the sharper reason (see AnswerBudget).
///
/// Opus at medium effort was never better than at low and always slower, so
/// no kind uses it. Haiku was fastest but ignored the spoken-style rules and
/// gave a walk-through in 41 words, so it answers nothing.
struct ClaudeAnswerProfile {
    let model: String
    let thinkingConfiguration: [String: Any]
    let effort: String
    let thinkingTokenHeadroom: Int

    /// For the log, so which model answered each question can be read back.
    var summary: String {
        let thinking = thinkingConfiguration["type"] as? String == "between_tools"
            ? "thinking off"
            : "thinking \(effort)"
        return "\(model), \(thinking)"
    }

    static let sonnetWithoutThinking = ClaudeAnswerProfile(
        model: "claude-sonnet-5-5",
        thinkingConfiguration: ["type": "between_tools"],
        effort: "high",
        thinkingTokenHeadroom: 0
    )

    static let opusThinkingLow = ClaudeAnswerProfile(
        model: "claude-opus-5-5",
        thinkingConfiguration: ["type": "adaptive"],
        effort: "low",
        // Thinking counts toward max_tokens. Without room for it the spoken
        // answer is what gets cut short.
        thinkingTokenHeadroom: 1500
    )

    static func forQuestion(_ questionKind: QuestionKind) -> ClaudeAnswerProfile {
        switch questionKind {
        case .quick, .normal:
            return .sonnetWithoutThinking
        case .teach, .reexplain, .tradeOff:
            return .opusThinkingLow
        }
    }
}

// MARK: - Errors

enum ClaudeError: LocalizedError {
    case missingKey
    case httpStatus(Int, String)
    case streamError(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No Anthropic API key saved in the Keychain."
        case .httpStatus(let code, let body):
            return "Claude HTTP \(code): \(body)"
        case .streamError(let message):
            return "Claude stream error: \(message)"
        case .malformedResponse:
            return "Claude returned a response in an unexpected shape."
        }
    }
}
