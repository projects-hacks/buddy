//
//  DiagramComposer.swift
//  leanring-buddy
//
//  Draws the board in a second, parallel pass on a fast model.
//
//  Why two passes. Measured on the same question and prompt: Argon explains
//  well (162 words, a usable answer) and reaches first byte in 3 seconds, but
//  offering it a layout decision pushed that to 49 seconds, because it is a
//  thinking model and a layout choice is something it will think about.
//  Flash makes the same layout decision in 3.5 seconds and explains terribly,
//  5 to 18 words of nothing.
//
//  Neither does both, so neither is asked to. Argon explains while Flash
//  draws, concurrently, and the board arrives while the first sentence is
//  still being spoken. The drawing pass costs no perceived latency because
//  nothing waits on it: if it is slow, or fails, the answer is unaffected and
//  the student simply gets no picture.
//

import Foundation

/// Asks a fast model for one diagram to accompany an explanation.
@MainActor
final class DiagramComposer {
    /// Fast model, chosen by measurement rather than by tier.
    ///
    /// 3.8-flash measured slower than 3.5-flash on exactly this task and no
    /// better at it, so the newer model is not the right one here.
    private let provider: GeminiVisionProvider

    init(projectIdentifier: String) {
        self.provider = GeminiVisionProvider(
            model: "gemini-3.5-flash",
            endpoint: .vertex(projectIdentifier: projectIdentifier, location: "global")
        )
        // A diagram tag is short. The ceiling exists to stop it writing prose
        // it was not asked for, which is this model's failure mode.
        provider.maximumResponseTokens = 120
    }

    private static let systemPrompt = """
    you turn an explanation into one diagram. you do not explain anything yourself and you never write prose.

    reply with exactly one [DIAGRAM:...] tag and nothing else, or the single word none.

    [DIAGRAM:pipeline:client,balancer,app server,cache,database]
      a request moving through stages, left to right. two to six steps.

    [DIAGRAM:fanout:load balancer|worker,worker,worker|object storage]
      one thing feeding several, optionally over something shared underneath.
      the part after the last bar is optional. up to four branches.

    [DIAGRAM:layers:api,business logic,storage]
      stacked tiers, top to bottom. two to five.

    [DIAGRAM:tree:root|left,right|a,b,c,d]
      a tree by levels, one group per level. for algorithms over structure.

    rules:
    - pick the shape that matches what the explanation is actually about. a
      request path is a pipeline. one thing serving many is a fanout. a stack of
      responsibilities is layers. a search over structure is a tree.
    - labels are two or three words, lowercase, taken from the explanation.
    - if the explanation has no structure worth drawing, reply none. a wrong
      diagram is worse than no diagram, because the student will try to read it.
    """

    /// Returns a diagram for an explanation, or nil if none fits.
    ///
    /// Takes no screenshot: the explanation already says what the idea is, and
    /// an image would add a thousand prompt tokens to a call whose only job is
    /// choosing between four shapes.
    func diagram(
        forExplanation explanation: String,
        screenIndexListing: String
    ) async -> DiagramShape? {
        let trimmedExplanation = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedExplanation.count > 40 else { return nil }

        let userPrompt = """
        the tutor just said this to the student:

        \(trimmedExplanation)

        give the one diagram that would help, or none.
        """

        do {
            let (response, duration) = try await provider.analyzeImage(
                images: [],
                systemPrompt: Self.systemPrompt,
                conversationHistory: [],
                userPrompt: userPrompt
            )

            let parsed = TeacherResponseParser.parse(rawResponse: response)
            for directive in parsed.directives {
                if case .drawDiagram(let shape) = directive.action {
                    TutorDebugLog.write("📐 diagram composed in \(String(format: "%.1f", duration))s")
                    return shape
                }
            }

            TutorDebugLog.write("📐 no diagram fitted (\(String(format: "%.1f", duration))s)")
            return nil
        } catch {
            // Nothing waits on this, so a failure costs the student nothing.
            TutorDebugLog.write("⚠️ diagram pass failed: \(error.localizedDescription)")
            return nil
        }
    }
}
