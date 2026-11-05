//
//  CompanionManager+QuestionKind.swift
//  leanring-buddy
//
//  What kind of question was asked and how much room the answer
//  gets: the sorter's deadline, the keyword fallback and the budgets.
//

import Foundation

extension CompanionManager {
    /// Instruction telling the model its last explanation failed, and how to
    /// change tack.
    ///
    /// A tutor that repeats itself when the student says "I still don't get it"
    /// is not teaching, and a model given no instruction will paraphrase rather
    /// than rethink. Naming a different strategy each time, and quoting back
    /// the attempt that failed, is what forces a genuinely new angle instead of
    /// the same explanation with different words.
    // MARK: - Choosing who answers

    /// How long Haiku may run past the end of the screen capture before the
    /// on-device answer is used without it. Its slowest tenth took about 0.8s
    /// to 1.1s in all, and the capture about 0.7s, so most answers arrive
    /// inside this and a slow one costs at most this much.
    static let classifierGraceSeconds: Double = 0.35
    /// The least time from the question Haiku is given: a typical capture
    /// and read (0.35s to 0.55s in the log) plus the grace above. Without
    /// it, a screen read during the talking left Haiku only the grace, and
    /// most of its answers, right nine times in ten, would be dropped.
    private static let classifierFloorSeconds: Double = 0.75
    static let memoryChooserFloorSeconds: Double = 1.0

    /// How much Haiku's kind is trusted against the on-device probabilities:
    /// its accuracy on the blind spoken set, 90 of 100.
    private static let classifierWeight = 0.9

    /// The question's kind, and how likely each kind is, from the on-device
    /// sorter, Haiku when it was asked and is back in time, or keywords when
    /// neither is available.
    func settleQuestionKind(
        transcript: String,
        hasPreviousAnswer: Bool,
        localProbabilities: [QuestionKind: Double]?,
        classifierTask: Task<QuestionKind?, Never>?
    ) async -> (kind: QuestionKind, probabilities: [QuestionKind: Double]) {
        var classifierKind: QuestionKind?
        if let classifierTask {
            enum Outcome { case answered(QuestionKind?), timedOut }
            let outcome = await withTaskGroup(of: Outcome.self) { group -> Outcome in
                // Awaiting another task's value ignores cancellation, so the
                // group would wait for Haiku however late it was. Passing the
                // cancellation on stops the request itself at the deadline.
                group.addTask {
                    .answered(await withTaskCancellationHandler {
                        await classifierTask.value
                    } onCancel: {
                        classifierTask.cancel()
                    })
                }
                // Haiku keeps the time it had when the screen was always read
                // after release, even when it was read during the talking.
                let classifierDeadline = max(Date().addingTimeInterval(Self.classifierGraceSeconds),
                                             answerStartedAt.addingTimeInterval(Self.classifierFloorSeconds))
                let classifierWaitSeconds = max(0, classifierDeadline.timeIntervalSinceNow)
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(classifierWaitSeconds * 1_000_000_000))
                    return .timedOut
                }
                let first = await group.next() ?? .timedOut
                group.cancelAll()
                return first
            }
            switch outcome {
            case .answered(let kind):
                classifierKind = kind
            case .timedOut:
                classifierTask.cancel()
                TutorDebugLog.write("⌛ question classifier late, the on-device sorter decides")
            }
        }

        let fallback = localProbabilities ?? [
            Self.questionKindFromKeywords(transcript, hasPreviousAnswer: hasPreviousAnswer): 1.0
        ]
        var probabilities = fallback
        var source = localProbabilities == nil ? "keywords" : "on device"
        if let classifierKind {
            probabilities = fallback.mapValues { $0 * (1 - Self.classifierWeight) }
            probabilities[classifierKind, default: 0] += Self.classifierWeight
            source = "haiku"
        }
        if !hasPreviousAnswer, let pushBack = probabilities[.reexplain], pushBack > 0 {
            probabilities[.reexplain] = 0
            probabilities[.teach, default: 0] += pushBack
        }

        let kind = probabilities.max { $0.value < $1.value }?.key ?? .normal
        let spread = probabilities
            .filter { $0.value >= 0.05 }
            .sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue) \(String(format: "%.2f", $0.value))" }
            .joined(separator: ", ")
        TutorDebugLog.write("🧭 sorted as \(kind.rawValue) by \(source) (\(spread))")
        return (kind, probabilities)
    }

    /// How much room an answer gets, decided from what was asked.
    ///
    /// A fixed ceiling is the wrong instrument. "what does this line do" wants
    /// one sentence; "walk me through binary search" wants a diagram and the
    /// room to build it. Capping both at the same number either truncates the
    /// second or lets the first ramble, and on Vertex a long answer is silence
    /// rather than slow speech, so the cost of over-answering falls on the
    /// student as waiting.
    ///
    /// The budget is also stated in the prompt rather than only enforced at
    /// the sampler, because a model told to write three sentences writes three
    /// sentences, while a model cut off at 150 tokens stops mid-thought.
    struct AnswerBudget {
        let questionKind: QuestionKind
        let maximumTokens: Int
        /// Shape instruction injected into the prompt.
        let shapeInstruction: String
        /// Whether a diagram is worth the room it costs.
        let allowsBoard: Bool
    }

    /// Sorts by keywords. The fallback for when the meaning-based sorter is
    /// not ready: it got 30 of 50 test phrasings right where meaning got 40.
    private static func questionKindFromKeywords(
        _ transcript: String,
        hasPreviousAnswer: Bool
    ) -> QuestionKind {
        let question = transcript.lowercased()

        func mentions(_ phrases: [String]) -> Bool {
            phrases.contains { phrase in question.contains(phrase) }
        }

        if hasPreviousAnswer && ConversationHistory.isAskingAgain(transcript) {
            return .reexplain
        }

        if mentions(["walk me through", "step by step", "teach me", "explain more",
                     "go deeper", "in detail", "more detail", "from scratch",
                     "full explanation", "properly", "whole thing", "how does it work"]) {
            return .teach
        }

        // Checked before the quick test: "is this better than a hash map"
        // starts like a quick question but is asking for a judgement.
        if mentions(["should i", "should it", "should we", "should this", "better",
                     "trade off", "tradeoff", "trade-off", "versus", " vs ", "compare",
                     "instead of", "why not", "which one", "pros and cons", "worth it",
                     "would it be", "right call", "right choice"]) {
            return .tradeOff
        }

        if mentions(["what is", "what does", "what's", "whats", "is this", "is that",
                     "which line", "where is", "does this", "did i", "can i"])
            && question.split(separator: " ").count <= 12 {
            return .quick
        }

        return .normal
    }

    /// How much room each kind of question gets.
    static func answerBudget(for questionKind: QuestionKind) -> AnswerBudget {
        switch questionKind {
        case .teach:
            // Asked to teach it properly. Worth a diagram and the room to build one.
            return AnswerBudget(
                questionKind: .teach,
                maximumTokens: 520,
                shapeInstruction: """
                LENGTH: they asked to be taught this properly. take the room: up to eight sentences, and draw a board if the idea has structure. still no preamble and no reading the screen back.
                """,
                allowsBoard: true
            )

        case .tradeOff:
            // A judgement between designs. Same length as a normal answer, but
            // it goes to the model that reasons, because the race showed the
            // difference here is insight rather than speed: asked whether
            // find_slot should be a binary search, Sonnet said "use a hash
            // map", while Opus noticed the function only returns exact
            // matches, which is the wrong lookup for the consistent hashing
            // ring it belongs to.
            return AnswerBudget(
                questionKind: .tradeOff,
                maximumTokens: 190,
                shapeInstruction: """
                LENGTH: THREE sentences carrying one idea. they asked for a judgement, so give the verdict first and the deciding reason second. draw a board only if the comparison genuinely has stages.
                """,
                allowsBoard: true
            )

        case .quick:
            // A small specific question. One sentence is the honest answer.
            return AnswerBudget(
                questionKind: .quick,
                maximumTokens: 90,
                shapeInstruction: """
                LENGTH: ONE sentence. they asked something specific and small. answer it and stop. no board.
                """,
                allowsBoard: false
            )

        case .reexplain:
            // A second attempt at the same idea needs room to actually work
            // the example through, not the terse default.
            return AnswerBudget(
                questionKind: .reexplain,
                maximumTokens: 420,
                shapeInstruction: """
                LENGTH: THREE sentences carrying one idea. they are waiting in silence while you write, so every extra sentence is a longer wait. draw a board only if the idea genuinely has stages or data to step through.
                """,
                allowsBoard: true
            )

        case .normal:
            // A real question wanting a real but compact answer.
            return AnswerBudget(
                questionKind: .normal,
                maximumTokens: 190,
                shapeInstruction: """
                LENGTH: THREE sentences carrying one idea. they are waiting in silence while you write, so every extra sentence is a longer wait. draw a board only if the idea genuinely has stages or data to step through.
                """,
                allowsBoard: true
            )
        }
    }
}
