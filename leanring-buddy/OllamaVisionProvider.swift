//
//  OllamaVisionProvider.swift
//  leanring-buddy
//
//  Local vision+chat backend backed by an Ollama server on this machine.
//  Mirrors the `ClaudeAPI` method surface so call sites can swap between a
//  local model and a hosted one without restructuring the pipeline.
//

import AppKit
import Foundation

/// Streaming vision chat against a local Ollama server.
///
/// Deliberately matches `ClaudeAPI.analyzeImageStreaming` argument-for-argument.
/// `CompanionManager` holds one of these behind `TeacherBrain`, so switching
/// between local and hosted inference is a provider swap, not a rewrite.
///
/// **Why newline-delimited JSON instead of SSE**: Ollama streams `/api/chat` as
/// one JSON object per line, not as `data:`-prefixed Server-Sent Events. The
/// Anthropic client's SSE parser does not apply here.
final class OllamaVisionProvider: TutorBrain {
    /// Ollama's default loopback address. No proxy or API key is involved
    /// because inference never leaves the machine.
    static let defaultBaseURL = "http://127.0.0.1:11434"

    private let chatURL: URL
    private let baseURL: URL
    private let session: URLSession

    var model: String

    /// Context window handed to the model, in tokens.
    ///
    /// **Why not the model's full 256K**: the KV cache is allocated against this
    /// number, and on a 16 GB machine a large window will evict the weights and
    /// push inference into swap. A screenshot costs roughly 1-2K tokens, so this
    /// leaves ample room for the image, the screen index and a few turns of history.
    var contextWindowTokens: Int

    /// Hard ceiling on how much the model may say in one answer.
    ///
    /// The system prompt asks for two to four sentences and the model ignored
    /// it, producing 25 seconds of continuous speech for a single question.
    /// A tutor that monologues is worse than one that says less: the student
    /// cannot interrupt, and the next question is faster than the rest of the
    /// answer. Instructions alone did not hold this, so it is enforced.
    var maximumResponseTokens: Int

    /// Whether to let a thinking-capable model emit a reasoning pass first.
    ///
    /// Off for conversational turns because the latency is felt in a voice loop.
    /// Worth turning on for a deliberate "explain this properly" request, where
    /// correctness on a DSA or system-design question beats time-to-first-word.
    var allowExtendedThinking: Bool

    /// Longest edge, in pixels, that a screenshot is reduced to before sending.
    ///
    /// Image tokens dominate prefill, and prefill is the delay before the first
    /// spoken word. A full capture cost over a thousand tokens. The picture no
    /// longer has to carry the text, because `ScreenIndex` supplies that
    /// exactly, so it only has to convey layout, colour and diagrams, which
    /// survives a smaller image. Below roughly 900 the model starts losing
    /// track of where things sit relative to each other.
    var maximumImageDimension: CGFloat = 1024

    init(
        baseURL: String = OllamaVisionProvider.defaultBaseURL,
        model: String,
        // 16K was overkill: the prompt, the index and one screenshot come in
        // well under half of this, and the KV cache is allocated against it,
        // which is memory a 16 GB machine does not have spare.
        contextWindowTokens: Int = 8_192,
        maximumResponseTokens: Int = 200,
        allowExtendedThinking: Bool = false
    ) {
        self.baseURL = URL(string: baseURL)!
        self.chatURL = URL(string: baseURL)!.appendingPathComponent("api/chat")
        self.model = model
        self.contextWindowTokens = contextWindowTokens
        self.maximumResponseTokens = maximumResponseTokens
        self.allowExtendedThinking = allowExtendedThinking

        // Generous timeouts: a cold model load pulls several GB off disk into
        // unified memory before the first token appears.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Health

    /// Whether the local Ollama server is reachable, and which models it has.
    ///
    /// Called before the first interaction so the UI can say "start Ollama"
    /// instead of surfacing a connection refused error mid-sentence.
    func probeServer() async -> (isReachable: Bool, installedModels: [String]) {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                return (false, [])
            }
            let installedModelNames = models.compactMap { modelEntry in
                modelEntry["name"] as? String
            }
            return (true, installedModelNames)
        } catch {
            return (false, [])
        }
    }

    /// Asks Ollama to load the model into memory without generating anything.
    ///
    /// The first real question otherwise pays the multi-second weight-load cost
    /// while the user is already waiting on a spoken answer.
    func preloadModel() async {
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [] as [[String: Any]],
            "stream": false,
            "keep_alive": "30m"
        ])
        _ = try? await session.data(for: request)
    }

    // MARK: - Streaming chat

    /// Sends labeled screenshots plus a prompt to the local model, streaming text back.
    ///
    /// `onTextChunk` receives the full accumulated answer each time more arrives,
    /// matching `ClaudeAPI`'s contract so the overlay's progressive rendering is unchanged.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let request = try makeChatRequest(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            stream: true
        )

        let (byteStream, response) = try await session.bytes(for: request)
        try validate(response: response, byteStream: byteStream)

        var accumulatedText = ""

        // One JSON object per line. A line that fails to parse is skipped rather
        // than fatal, so a partial flush cannot abort an otherwise good answer.
        for try await line in byteStream.lines {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if let errorMessage = payload["error"] as? String {
                throw OllamaError.serverReported(errorMessage)
            }

            // `thinking` carries the reasoning pass on thinking-capable models.
            // It is intentionally dropped: it must never be spoken aloud or
            // parsed for pointing tags.
            if let message = payload["message"] as? [String: Any],
               let chunk = message["content"] as? String,
               !chunk.isEmpty {
                accumulatedText += chunk
                let snapshot = accumulatedText
                await onTextChunk(snapshot)
            }

            if payload["done"] as? Bool == true { break }
        }

        return (text: accumulatedText, duration: Date().timeIntervalSince(startTime))
    }

    /// Non-streaming variant for internal calls whose text is never rendered
    /// progressively, such as classification or a screen-index lookup.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let request = try makeChatRequest(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            stream: false
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw OllamaError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw OllamaError.malformedResponse
        }

        return (text: text, duration: Date().timeIntervalSince(startTime))
    }

    // MARK: - Request construction

    private func makeChatRequest(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        stream: Bool
    ) throws -> URLRequest {
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Ollama attaches images to a message via an `images` array of bare
        // base64 strings, with no data: prefix and no per-image media type.
        // Image labels are folded into the text so a multi-monitor capture can
        // still be described as "screen 1", "screen 2" in the answer.
        var promptText = userPrompt
        if images.count > 1 {
            let imageLabelLines = images.enumerated()
                .map { (imageIndex, labeledImage) in
                    "Image \(imageIndex + 1): \(labeledImage.label)"
                }
                .joined(separator: "\n")
            promptText = "\(imageLabelLines)\n\n\(userPrompt)"
        } else if let onlyLabel = images.first?.label, !onlyLabel.isEmpty {
            promptText = "\(onlyLabel)\n\n\(userPrompt)"
        }

        var userMessage: [String: Any] = ["role": "user", "content": promptText]
        if !images.isEmpty {
            userMessage["images"] = images.map { labeledImage in
                Self.reduced(
                    imageData: labeledImage.data,
                    toLongestEdge: maximumImageDimension
                ).base64EncodedString()
            }
        }
        messages.append(userMessage)

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream,
            // Holding the weights resident between questions is the difference
            // between a conversational reply and a cold load on every turn.
            "keep_alive": "30m",
            "options": [
                "num_ctx": contextWindowTokens,
                "num_predict": maximumResponseTokens,
                // Low but non-zero: explanations should stay grounded in what is
                // actually on screen, without reading as flat and repetitive.
                "temperature": 0.4,
                "top_p": 0.9
            ]
        ]

        // Only sent when disabled, so non-thinking models are not handed a
        // parameter they would reject.
        if !allowExtendedThinking {
            body["think"] = false
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🦙 Ollama \(model): \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), ctx \(contextWindowTokens)")

        return request
    }

    /// Scales a screenshot down so its longest edge is at most `longestEdge`.
    ///
    /// Returns the original bytes untouched when it is already small enough or
    /// cannot be decoded, because sending a slightly large image is recoverable
    /// and sending none is not.
    private static func reduced(imageData: Data, toLongestEdge longestEdge: CGFloat) -> Data {
        guard let sourceImage = NSImage(data: imageData),
              let sourceCGImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return imageData
        }

        let sourceWidth = CGFloat(sourceCGImage.width)
        let sourceHeight = CGFloat(sourceCGImage.height)
        let currentLongestEdge = max(sourceWidth, sourceHeight)
        guard currentLongestEdge > longestEdge else { return imageData }

        let scale = longestEdge / currentLongestEdge
        let targetWidth = Int(sourceWidth * scale)
        let targetHeight = Int(sourceHeight * scale)

        // Built at exact pixel dimensions rather than through NSImage, which
        // on a Retina display would silently produce a bitmap at twice the
        // requested size and undo the reduction entirely.
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

        guard let reducedData = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.8]
        ) else {
            return imageData
        }

        return reducedData
    }

    private func validate(response: URLResponse, byteStream: URLSession.AsyncBytes) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.malformedResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw OllamaError.httpStatus(http.statusCode, "see Ollama server log")
        }
    }
}

// MARK: - Errors

enum OllamaError: LocalizedError {
    case serverReported(String)
    case httpStatus(Int, String)
    case malformedResponse
    case serverUnreachable

    var errorDescription: String? {
        switch self {
        case .serverReported(let message):
            return "Ollama error: \(message)"
        case .httpStatus(let code, let body):
            return "Ollama HTTP \(code): \(body)"
        case .malformedResponse:
            return "Ollama returned a response in an unexpected shape."
        case .serverUnreachable:
            return "Ollama is not running. Start it with `brew services start ollama`."
        }
    }
}
