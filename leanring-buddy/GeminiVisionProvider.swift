//
//  GeminiVisionProvider.swift
//  leanring-buddy
//
//  Hosted brain, for the questions the local model cannot answer.
//
//  What this buys: technical knowledge. The local 4B reasons well about what
//  is on screen and invents facts that are not, which for a study tool is the
//  failure that matters. What it costs: roughly a cent per question, a network
//  round trip, and the screenshot leaving the machine, which the local path
//  never does. Both paths stay available because that trade is the user's to
//  make per session.
//

import AppKit
import Foundation

/// Streaming vision chat against Google's Gemini API.
final class GeminiVisionProvider: TutorBrain {
    /// Which door to Gemini this provider uses.
    ///
    /// The same models sit behind both, but the billing does not. AI Studio
    /// authenticates with a plain API key and bills its own account. Vertex AI
    /// authenticates with a Google Cloud access token and bills the project,
    /// which is what Google Cloud trial credits are attached to. A trial
    /// credit cannot pay for an AI Studio call no matter how the key is set up.
    enum Endpoint {
        /// Plain API key from the Keychain.
        case aiStudio
        /// Google Cloud project, billed against that project's credits.
        case vertex(projectIdentifier: String, location: String)
    }

    var endpoint: Endpoint

    private static let aiStudioBase = "https://generativelanguage.googleapis.com/v1beta/models"

    /// Cached Vertex access token and the moment it stops being usable.
    ///
    /// Minting shells out to gcloud, which takes a noticeable fraction of a
    /// second, and the tokens last an hour. Re-minting per question would add
    /// that to every answer for nothing.
    private var cachedAccessToken: String?
    private var cachedTokenExpiry: Date = .distantPast

    var model: String
    var maximumResponseTokens: Int = 380

    /// How much the model is allowed to think before answering, on Vertex.
    ///
    /// "LOW", "MEDIUM" (the model's default) or "HIGH". Low by default because
    /// the student is waiting to be spoken to, and on this model thinking is
    /// the parameter that trades latency for depth. Raise it for a question
    /// where being right matters more than being quick.
    var thinkingLevel: String = "LOW"

    /// Longest edge a screenshot is reduced to before upload.
    ///
    /// Smaller than the local path's limit because here it also costs money and
    /// upload time, and the text still comes from the on-device index.
    var maximumImageDimension: CGFloat = 1024

    private let session: URLSession

    init(model: String = "gemini-4-argon", endpoint: Endpoint = .aiStudio) {
        self.model = model
        self.endpoint = endpoint

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Readiness

    func probeServer() async -> (isReachable: Bool, installedModels: [String]) {
        guard let apiKey = APIKeyStore.key(for: .gemini) else {
            TutorDebugLog.write("⚠️ no Gemini key in the keychain")
            return (false, [])
        }

        // Lists models, which both proves the key works and confirms the
        // configured model exists before a question depends on it.
        guard var components = URLComponents(string: Self.aiStudioBase) else {
            return (false, [])
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { return (false, []) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                TutorDebugLog.write("⚠️ Gemini rejected the key: HTTP \(status)")
                return (false, [])
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                return (true, [])
            }
            let names = models.compactMap { entry -> String? in
                guard let name = entry["name"] as? String else { return nil }
                return name.replacingOccurrences(of: "models/", with: "")
            }
            return (true, names)
        } catch {
            TutorDebugLog.write("⚠️ Gemini unreachable: \(error.localizedDescription)")
            return (false, [])
        }
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
        guard let http = response as? HTTPURLResponse else { throw GeminiError.malformedResponse }
        guard (200...299).contains(http.statusCode) else {
            var errorLines: [String] = []
            for try await line in byteStream.lines { errorLines.append(line) }
            throw GeminiError.httpStatus(http.statusCode, errorLines.joined(separator: " ").prefix(300).description)
        }

        var accumulatedText = ""

        // With alt=sse the stream is Server-Sent Events, one JSON payload per
        // `data:` line, which matches the upstream Anthropic parser rather than
        // Ollama's bare newline-delimited objects.
        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payloadText = String(line.dropFirst(6))
            guard payloadText != "[DONE]",
                  let payloadData = payloadText.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                continue
            }

            guard let candidates = payload["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                continue
            }

            for part in parts {
                guard let chunk = part["text"] as? String, !chunk.isEmpty else { continue }
                accumulatedText += chunk
                let snapshot = accumulatedText
                await onTextChunk(snapshot)
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
            throw GeminiError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw GeminiError.malformedResponse
        }

        let text = parts.compactMap { part in part["text"] as? String }.joined()
        return (text: text, duration: Date().timeIntervalSince(startTime))
    }

    // MARK: - Request construction

    /// Mints a Google Cloud access token through gcloud, cached until it nears expiry.
    ///
    /// Shelling out to gcloud rather than implementing the service-account JWT
    /// flow: the user is already signed in on this machine, gcloud already
    /// refreshes the credential, and reimplementing that would mean handling a
    /// private key the app has no reason to hold.
    private func vertexAccessToken() throws -> String {
        if let cachedAccessToken, Date() < cachedTokenExpiry {
            return cachedAccessToken
        }

        let gcloudPaths = ["/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud",
                           "\(NSHomeDirectory())/google-cloud-sdk/bin/gcloud"]
        guard let gcloudPath = gcloudPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw GeminiError.gcloudUnavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gcloudPath)
        process.arguments = ["auth", "application-default", "print-access-token"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw GeminiError.gcloudUnavailable
        }
        process.waitUntilExit()

        let tokenData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let token = String(data: tokenData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0, !token.isEmpty else {
            throw GeminiError.notSignedIn
        }

        cachedAccessToken = token
        // Tokens last about an hour; refreshed early so one cannot expire
        // between being checked and being used.
        cachedTokenExpiry = Date().addingTimeInterval(50 * 60)
        return token
    }

    private func makeRequest(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        streaming: Bool
    ) throws -> URLRequest {
        let method = streaming ? "streamGenerateContent" : "generateContent"

        var components: URLComponents
        var authorizationHeader: String?

        switch endpoint {
        case .aiStudio:
            guard let apiKey = APIKeyStore.key(for: .gemini) else {
                throw GeminiError.missingKey
            }
            guard let built = URLComponents(string: "\(Self.aiStudioBase)/\(model):\(method)") else {
                throw GeminiError.malformedResponse
            }
            components = built
            components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        case .vertex(let projectIdentifier, let location):
            let host = location == "global"
                ? "https://aiplatform.googleapis.com"
                : "https://\(location)-aiplatform.googleapis.com"
            let path = "/v1/projects/\(projectIdentifier)/locations/\(location)"
                + "/publishers/google/models/\(model):\(method)"
            guard let built = URLComponents(string: host + path) else {
                throw GeminiError.malformedResponse
            }
            components = built
            components.queryItems = []
            authorizationHeader = "Bearer \(try vertexAccessToken())"
        }

        if streaming {
            components.queryItems?.append(URLQueryItem(name: "alt", value: "sse"))
        }
        guard let url = components.url else { throw GeminiError.malformedResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 120

        // Gemini alternates user and model turns, and rejects two in a row, so
        // history is emitted strictly in pairs.
        var contents: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            contents.append(["role": "user", "parts": [["text": userPlaceholder]]])
            contents.append(["role": "model", "parts": [["text": assistantResponse]]])
        }

        var currentParts: [[String: Any]] = []
        for labeledImage in images {
            let reducedData = Self.reduced(
                imageData: labeledImage.data,
                toLongestEdge: maximumImageDimension
            )
            // camelCase, as the Vertex schema specifies. AI Studio accepts
            // either, so one spelling serves both endpoints.
            currentParts.append([
                "inlineData": [
                    "mimeType": "image/jpeg",
                    "data": reducedData.base64EncodedString()
                ]
            ])
            if !labeledImage.label.isEmpty {
                currentParts.append(["text": labeledImage.label])
            }
        }
        currentParts.append(["text": userPrompt])
        contents.append(["role": "user", "parts": currentParts])

        // Built per endpoint because Gemini 4 Argon rejects or ignores several
        // parameters the older API took. Its docs state that temperature, topP
        // and topK are ignored, and that frequencyPenalty, presencePenalty and
        // candidateCount return HTTP 400. Sending ignored parameters is merely
        // untidy; sending rejected ones fails the request.
        var generationConfig: [String: Any] = ["maxOutputTokens": maximumResponseTokens]

        switch endpoint {
        case .vertex:
            // Reasoning depth is the one real control on this model. LOW is
            // chosen deliberately: the answer is spoken aloud while the student
            // waits, and depth bought with latency is a bad trade here. MEDIUM
            // is the model's default.
            generationConfig["thinkingConfig"] = ["thinkingLevel": thinkingLevel]
        case .aiStudio:
            // AI Studio still honours sampling parameters.
            generationConfig["temperature"] = 0.4
            generationConfig["topP"] = 0.9
        }

        let body: [String: Any] = [
            "contents": contents,
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "generationConfig": generationConfig
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        let payloadMB = Double(bodyData.count) / 1_048_576.0
        TutorDebugLog.write("☁️ Gemini \(model): \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        return request
    }

    /// Scales a screenshot down, as the local provider does and for the extra
    /// reason that here every pixel is billed and uploaded.
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

// MARK: - Errors

enum GeminiError: LocalizedError {
    case missingKey
    case httpStatus(Int, String)
    case malformedResponse
    /// gcloud is not installed where expected, so no Vertex token can be minted.
    case gcloudUnavailable
    /// gcloud is present but its credential is expired or revoked. This is the
    /// failure that cost an afternoon: it surfaces as HTTP 401
    /// CREDENTIALS_MISSING rather than saying the credential expired.
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No Gemini API key saved. Add one in the Clicky panel."
        case .httpStatus(let code, let body):
            return "Gemini HTTP \(code): \(body)"
        case .malformedResponse:
            return "Gemini returned a response in an unexpected shape."
        case .gcloudUnavailable:
            return "gcloud was not found. Install the Google Cloud CLI to use the cloud brain."
        case .notSignedIn:
            return "Google Cloud credentials have expired. Run: gcloud auth application-default login"
        }
    }
}
