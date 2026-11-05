//
//  QuestionTicket.swift
//  leanring-buddy
//
//  Which question is being answered, and which try at its answer is live.
//  An answer that was replaced checks its ticket after every wait, so it
//  never writes history, memory, how-tos, guide steps or notebook pages for
//  a question nobody is asking now, and words still arriving from a brain
//  given up on at its deadline are dropped.
//

import Foundation

@MainActor
final class QuestionTicket {
    /// The currently running answer task, if any. Cancelled when the student
    /// speaks again so a new answer can begin immediately.
    var responseTask: Task<Void, Never>?

    /// Bumped whenever the answer is cancelled or replaced.
    private var questionNumber = 0
    /// Bumped for every try at an answer, across questions.
    private var attemptNumber = 0

    func cancelCurrentAnswer() {
        questionNumber += 1
        responseTask?.cancel()
    }

    /// A check that holds while the question asked now is still the one being
    /// answered, and the task calling it has not been cancelled.
    func checkForThisQuestion() -> () -> Bool {
        let issuedNumber = questionNumber
        return { [self] in issuedNumber == self.questionNumber && !Task.isCancelled }
    }

    /// Starts another try at the answer and returns its number.
    func beginAttempt() -> Int {
        attemptNumber += 1
        return attemptNumber
    }

    func isCurrentAttempt(_ attempt: Int) -> Bool {
        attemptNumber == attempt
    }
}
