//
//  APIKeyChecker.swift
//  leanring-buddy
//
//  Tests a key the moment it is entered, with the smallest real request each
//  service accepts, and says in plain words what is wrong when it fails.
//
//  A real request rather than a format check, because the failures people
//  actually hit are not typos: a key from the wrong account, an account with
//  no credit, a Gemini key on a project that cannot use the model. Only a
//  request finds those, and each costs a fraction of a cent once.
//
//  The same reading of failures is used when a key that worked stops working
//  mid-use (`problem(in:)`), so the student gets the same sentence and the
//  same fix either way.
//

import Foundation

/// What a key test found, in words the student can act on.
enum KeyCheckResult: Equatable {
    case works
    /// It works, with a caveat worth knowing ("busy right now").
    case worksWithNote(String)
    case rejected(String)
    /// Could not tell: no network, or the service is down. Not the key's fault.
    case couldNotCheck(String)

    var isUsable: Bool {
        switch self {
        case .works, .worksWithNote: return true
        case .rejected, .couldNotCheck: return false
        }
    }

    var message: String {
        switch self {
        case .works: return "Works."
        case .worksWithNote(let note): return note
        case .rejected(let reason): return reason
        case .couldNotCheck(let reason): return reason
        }
    }
}

enum APIKeyChecker {
    /// Where each key is made, for the setup window's "Get a key" link.
    static func signUpLink(for service: APIKeyStore.Service) -> URL {
        switch service {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .deepgram: return URL(string: "https://console.deepgram.com/")!
        }
    }

    static func check(_ key: String, for service: APIKeyStore.Service) async -> KeyCheckResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected("Paste a key first.") }
        if let formatProblem = formatProblem(trimmed, for: service) { return .rejected(formatProblem) }

        var request: URLRequest
        switch service {
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue(trimmed, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": "claude-haiku-5-5", "max_tokens": 1,
                "messages": [["role": "user", "content": "hi"]]
            ])
        case .gemini:
            request = URLRequest(url: URL(string:
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-4-argon:generateContent")!)
            request.httpMethod = "POST"
            request.setValue(trimmed, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "contents": [["role": "user", "parts": [["text": "hi"]]]],
                "generationConfig": ["maxOutputTokens": 8, "thinkingConfig": ["thinkingLevel": "LOW"]]
            ])
        case .deepgram:
            request = URLRequest(url: URL(string: "https://api.deepgram.com/v1/speak?model=aura-2-hera-en&encoding=linear16&sample_rate=24000")!)
            request.httpMethod = "POST"
            request.setValue("Token \(trimmed)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": "ok"])
        }
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200...299).contains(status) { return .works }
            return interpret(status: status, body: String(data: data, encoding: .utf8) ?? "", service: service)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                             .cannotConnectToHost, .timedOut, .dnsLookupFailed].contains(error.code) {
            return .couldNotCheck("Couldn't reach \(service.humanReadableName). Check the internet connection, then try again.")
        } catch {
            return .couldNotCheck("Couldn't test the key: \(error.localizedDescription)")
        }
    }

    /// The commonest slip, caught before spending a request: a key pasted
    /// into the wrong field.
    private static func formatProblem(_ key: String, for service: APIKeyStore.Service) -> String? {
        switch service {
        case .anthropic where key.hasPrefix("AIza"):
            return "That looks like a Google key. It goes in the Gemini field."
        case .gemini where key.hasPrefix("sk-ant-"):
            return "That looks like an Anthropic key. It goes in the Anthropic field."
        case .deepgram where key.hasPrefix("sk-ant-") || key.hasPrefix("AIza"):
            return "That looks like a key for another service. Deepgram keys come from console.deepgram.com."
        default:
            return nil
        }
    }

    /// One reading of an error response, for setup and for use alike.
    static func interpret(status: Int, body: String, service: APIKeyStore.Service) -> KeyCheckResult {
        let lowered = body.lowercased()
        let name = service.humanReadableName
        switch (service, status) {
        case (_, 401):
            return .rejected("\(name) didn't accept this key. Check it was copied whole, or make a new one.")
        case (.anthropic, 400) where lowered.contains("credit"):
            return .rejected("The key is fine, but the Anthropic account has no credit. Add some under Plans & Billing.")
        case (.anthropic, 403):
            return .rejected("This key isn't allowed to use Claude. Its workspace may be restricted.")
        case (.gemini, 400) where lowered.contains("api key not valid") || lowered.contains("api_key_invalid"):
            return .rejected("Google didn't accept this key. Check it was copied whole, or make a new one.")
        case (.gemini, 403):
            return .rejected("This key's Google project can't use Gemini. Enable the Generative Language API, or make the key in AI Studio.")
        case (.gemini, 404):
            return .rejected("This key can't use Gemini 4 Argon yet. Make the key in AI Studio, on a project with billing.")
        case (.gemini, 429) where lowered.contains("quota") || lowered.contains("exhausted"):
            return .rejected("The key works, but its quota is used up. Add billing to its Google project, or wait for the limit to reset.")
        case (.deepgram, 402):
            return .rejected("The key is fine, but the Deepgram account is out of credit.")
        case (.deepgram, 403):
            return .rejected("This Deepgram key can't use text to speech. Make one with the Member role or above.")
        case (_, 429):
            return .worksWithNote("The key works. \(name) is rate limiting it right now, so answers may be slow for a moment.")
        case (_, 529), (_, 500...599):
            return .couldNotCheck("\(name) is having trouble right now. Try again in a minute.")
        default:
            return .rejected("\(name) said: HTTP \(status). \(body.prefix(160))")
        }
    }

    /// Whether an error from a brain is a key problem, and what to tell the
    /// student. Nil for every other failure, which are not theirs to fix.
    static func problem(in error: Error) -> (service: APIKeyStore.Service, message: String)? {
        if let claudeError = error as? ClaudeError {
            switch claudeError {
            case .missingKey:
                return (.anthropic, "There's no Anthropic key yet.")
            case .httpStatus(let status, let body):
                let isKeyProblem = status == 401 || status == 403 || (status == 400 && body.lowercased().contains("credit"))
                if isKeyProblem, case .rejected(let reason) = interpret(status: status, body: body, service: .anthropic) {
                    return (.anthropic, reason)
                }
            default:
                break
            }
        }
        if let geminiError = error as? GeminiError {
            switch geminiError {
            case .missingKey:
                return (.gemini, "There's no Gemini key yet.")
            case .httpStatus(let status, let body):
                let lowered = body.lowercased()
                let isKeyProblem = status == 401 || status == 403 || status == 404
                    || (status == 400 && (lowered.contains("api key not valid") || lowered.contains("api_key_invalid")))
                    || (status == 429 && (lowered.contains("quota") || lowered.contains("exhausted")))
                if isKeyProblem, case .rejected(let reason) = interpret(status: status, body: body, service: .gemini) {
                    return (.gemini, reason)
                }
            default:
                break
            }
        }
        return nil
    }
}
