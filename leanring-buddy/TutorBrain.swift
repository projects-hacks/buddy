//
//  TutorBrain.swift
//  leanring-buddy
//
//  The one thing the pipeline needs from whatever is doing the thinking.
//
//  Two implementations exist for a reason rather than for symmetry. The local
//  model is free, private and works offline, and it is genuinely good at
//  reasoning about what is on screen. It is not good at technical knowledge
//  that is not on screen: asked who wrote quicksort it invented a different
//  wrong person three times running, which for a study tool is the one failure
//  that matters, because a confident wrong answer is worse than no answer.
//
//  So the choice is real and the user should make it per session, not have it
//  made for them at build time.
//

import Foundation

/// Where a tutor answer comes from.
enum TutorBrainKind: String, CaseIterable {
    /// On-device model via Ollama. Free, private, offline, weaker on facts.
    case local
    /// Gemini 4 Argon on Vertex. Bills the Google Cloud project's credits.
    case hosted
    /// Claude on the first-party API. Starts speaking in about two seconds
    /// where Argon took eight to twelve on the same question. Billed to the
    /// Anthropic account, not the Google Cloud credits.
    case claude
    /// Each question goes to Sonnet, Opus or Argon, whichever ModelRouter
    /// measured best for that kind of question.
    case auto

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .local: return "Local"
        case .hosted: return "Gemini"
        case .claude: return "Claude"
        }
    }
}

/// A vision-and-text model that can answer about a screenshot.
///
/// Deliberately the same shape as upstream's Claude client had, so the
/// pipeline, the parser, the board and the speech timing are untouched by
/// which brain is behind it.
protocol TutorBrain: AnyObject {
    /// Model identifier, as that provider names it.
    var model: String { get set }

    /// Ceiling on answer length, enforced by the provider.
    var maximumResponseTokens: Int { get set }

    /// Whether the provider can be reached and is configured.
    /// The second value carries whatever the provider wants to report:
    /// installed models locally, nothing hosted.
    func probeServer() async -> (isReachable: Bool, installedModels: [String])

    /// Gives the provider a chance to get ready before the first question.
    func preloadModel() async

    /// Streams an answer about `images`, calling `onTextChunk` with the full
    /// accumulated text each time more arrives.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)

    /// Non-streaming answer, for internal calls nothing renders progressively.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval)
}
