//
//  TeachingBoardSession.swift
//  leanring-buddy
//
//  "Teach me consistent hashing from scratch": the screen dims, a sheet of
//  paper comes up, and the lesson is drawn on it over as many turns as the
//  student keeps asking. This ties the board to the rest of the app.
//
//  Lifecycle:
//  - opens on a question BoardIntent says asks for it;
//  - while open, every question (spoken, typed, or a follow-up button) is
//    answered on the board, with the board's contents in the turn note;
//  - closes on Esc, on "done" / "thanks, that's it", or after ten minutes
//    with no question, with a short fade; the whole board lesson is then
//    filed into learning memory as one lesson.
//
//  The answer is spoken and drawn by the same LessonProgramPlayer as every
//  answer, so the voice and the pen keep the same pace; the only difference
//  is that each piece of the program has its board calls translated into
//  strokes first (BoardProgramTranslator). The normal flow is untouched
//  while the board is closed: the hook in CompanionManager returns false and
//  the question goes on exactly as before.
//

import AppKit
import Foundation

/// Whether the brain has written anything yet this turn, so a brain that
/// fails before its first word can hand over to the next one.
@MainActor
final class BoardTurnProgress {
    var hasReceivedText = false
    /// Decided from the first characters, as for any answer.
    var answerIsProgram: Bool?
}

@MainActor
final class TeachingBoardSession {
    /// What the session needs from CompanionManager, which owns the brains,
    /// the voice state and memory.
    struct Hooks {
        /// Streams one board answer from the brain routed as for a teach
        /// question and returns its full text.
        var answer: (_ systemPrompt: String,
                     _ history: [(userPlaceholder: String, assistantResponse: String)],
                     _ turnNote: String,
                     _ maximumTokens: Int,
                     _ progress: BoardTurnProgress,
                     _ onTextChunk: @escaping @MainActor @Sendable (String) -> Void) async throws -> String
        var setVoiceState: (CompanionVoiceState) -> Void = { _ in }
        /// Takes down whatever the last answer marked on the screen, before
        /// the board covers it, so nothing of it shows through or above.
        var clearScreenBeforeOpening: () -> Void = {}
        /// Files the finished board lesson into learning memory.
        var fileLesson: (_ question: String, _ lessonTitle: String?, _ spokenAnswer: String) -> Void = { _, _, _ in }
        /// Puts the board lesson into the normal conversation, so a question
        /// after the board closes can refer back to it.
        var rememberExchange: (_ question: String, _ answer: String) -> Void = { _, _ in }
        /// A question that needed no answer (a "done"): nothing is waiting.
        var questionNeedsNoAnswer: () -> Void = {}
        var reportFailure: (Error) async -> Void = { _ in }
        var turnFinished: () -> Void = {}
    }

    var hooks: Hooks

    private let overlay: DrawingOverlay
    private let player: LessonProgramPlayer
    private let bar: TutorControlBarModel

    private(set) var isOpen = false
    private var board: TeachingBoard?
    private var surface: BoardSurface?
    private var screenForBoard: NSScreen?
    private var turnNumber = 0
    private var currentTurnIdentifier = 0
    private var turnTask: Task<Void, Never>?
    private var idleCloseTask: Task<Void, Never>?
    private var openingQuestion = ""
    private var lessonTitle: String?
    private var everySentenceSaid: [String] = []
    /// The board's own conversation: earlier board turns only.
    private var boardHistory: [(question: String, program: String, sentences: [String])] = []

    /// Ten minutes: long enough to read the board and think, short enough
    /// that a board left up while the student went away does not greet them.
    static let idleSecondsBeforeClosing: TimeInterval = 600

    init(overlay: DrawingOverlay, player: LessonProgramPlayer, bar: TutorControlBarModel, hooks: Hooks) {
        self.overlay = overlay
        self.player = player
        self.bar = bar
        self.hooks = hooks
    }

    /// The board state, for a later feature to read (teach it back).
    var currentBoardState: BoardState? { board?.state }

    // MARK: - Entry from CompanionManager

    /// Takes the question if the board should answer it. Returns false, and
    /// does nothing, when the board is closed and the question does not ask
    /// for it, so the normal flow goes on unchanged.
    func takeQuestion(_ transcript: String) -> Bool {
        if isOpen {
            if BoardIntent.closesBoard(transcript) {
                TutorDebugLog.write("🧑‍🏫 board: \"\(transcript)\" closes it")
                close(reason: "the student said they were done")
                hooks.questionNeedsNoAnswer()
                return true
            }
            runTurn(question: transcript)
            return true
        }
        let decision = BoardIntent.decide(transcript)
        guard decision.opensBoard else { return false }
        TutorDebugLog.write("🧑‍🏫 board opens: \(decision)")
        open(firstQuestion: transcript)
        runTurn(question: transcript)
        return true
    }

    /// Fades the board away and files its lesson. Safe to call when closed.
    func close(reason: String) {
        guard isOpen else { return }
        TutorDebugLog.write("🧑‍🏫 board closes: \(reason), \(turnNumber) turns, \(board?.state.elements.count ?? 0) elements")
        isOpen = false
        currentTurnIdentifier += 1
        turnTask?.cancel()
        turnTask = nil
        idleCloseTask?.cancel()
        idleCloseTask = nil
        player.stop()
        player.transformPieceBeforeRunning = nil
        overlay.callBoard("close", argumentsJSON: "0.6")
        bar.caption = ""
        bar.followUps = []
        hooks.setVoiceState(.idle)
        InterfaceSounds.shared.play(.wipe)

        if !everySentenceSaid.isEmpty {
            let spokenLesson = everySentenceSaid.joined(separator: " ")
            hooks.fileLesson(openingQuestion, lessonTitle ?? board?.state.title, spokenLesson)
            hooks.rememberExchange(openingQuestion, "(Taught on the board, now closed.) " + spokenLesson)
        }
        board = nil
        surface = nil
        screenForBoard = nil
        boardHistory = []
        everySentenceSaid = []
        lessonTitle = nil
        turnNumber = 0
    }

    // MARK: - Opening

    private func open(firstQuestion: String) {
        // The screen the student is looking at: the one with the pointer.
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        hooks.clearScreenBeforeOpening()
        let surface = BoardSurface(canvasWidth: screen.frame.width, canvasHeight: screen.frame.height)
        self.surface = surface
        self.screenForBoard = screen
        self.board = TeachingBoard(layout: surface.layout)
        self.openingQuestion = firstQuestion
        self.isOpen = true
        self.turnNumber = 0
    }

    // MARK: - One turn

    private func runTurn(question: String) {
        guard let board, let surface, let screenForBoard else { return }
        turnTask?.cancel()
        idleCloseTask?.cancel()
        currentTurnIdentifier += 1
        let turnIdentifier = currentTurnIdentifier
        turnNumber += 1
        let thisTurnNumber = turnNumber

        turnTask = Task { [weak self] in
            guard let self else { return }
            self.hooks.setVoiceState(.processing)
            self.bar.waitingStage = "thinking"

            // The same player as every answer, on a canvas the size of the
            // screen in points. Its begin() clears screen marks and cards,
            // never the board, which is its own layer.
            self.player.begin(on: screenForBoard, canvasSize: CGSize(width: surface.canvasWidth, height: surface.canvasHeight),
                              targets: [:], targetLabels: [:], screenInkHex: "#3380FF")
            if thisTurnNumber == 1 { self.overlay.callBoard("open", argumentsJSON: surface.openArgumentsJSON) }
            self.overlay.callBoard("beginTurn", argumentsJSON: "")
            board.beginTurn()
            self.player.transformPieceBeforeRunning = { [weak self] piece in
                self?.translate(piece) ?? piece
            }

            let turnNote = BoardProgramPrompt.turnNote(
                transcript: question, boardListing: board.state.compactListing(), turnNumber: thisTurnNumber,
                studentName: UserDefaults.standard.string(forKey: "studentName"))
            TutorDebugLog.write("🧑‍🏫 board turn \(thisTurnNumber): note is \(turnNote.count) characters")

            let progress = BoardTurnProgress()
            do {
                let fullText = try await self.hooks.answer(
                    BoardProgramPrompt.system, self.historyForModel(), turnNote,
                    BoardProgramPrompt.maximumTokens(turnNumber: thisTurnNumber), progress
                ) { [weak self] accumulatedText in
                    guard let self, self.currentTurnIdentifier == turnIdentifier else { return }
                    progress.hasReceivedText = true
                    if progress.answerIsProgram == nil, let isProgram = ProgramStream.looksLikeProgram(accumulatedText) {
                        progress.answerIsProgram = isProgram
                        if isProgram { self.hooks.setVoiceState(.responding) }
                    }
                    if progress.answerIsProgram == true { self.player.feed(accumulatedText: accumulatedText) }
                }
                guard !Task.isCancelled, self.currentTurnIdentifier == turnIdentifier else { return }
                TutorDebugLog.write("RAW BOARD RESPONSE:\n\(fullText)\n--- end ---")

                // An answer that came back as prose is still spoken, a
                // sentence per beat, with nothing drawn.
                let program = (progress.answerIsProgram ?? ProgramStream.looksLikeProgram(fullText) ?? false)
                    ? fullText : Self.programSpeaking(prose: fullText)
                if progress.answerIsProgram != true {
                    self.hooks.setVoiceState(.responding)
                    self.player.feed(accumulatedText: program)
                }
                await self.player.finish(fullText: program)

                let sentences = ProgramStream.closedSayArguments(in: ProgramStream.code(in: program))
                self.everySentenceSaid += sentences
                self.boardHistory.append((question: question, program: program, sentences: sentences))
                if let title = self.player.lessonTitle {
                    self.lessonTitle = title
                    self.bar.recordLessonTitle(title)
                }
                await self.player.waitUntilSpoken()
            } catch is CancellationError {
                return
            } catch {
                guard self.currentTurnIdentifier == turnIdentifier else { return }
                TutorDebugLog.write("⚠️ board turn failed: \(error.localizedDescription)")
                await self.hooks.reportFailure(error)
            }
            guard self.currentTurnIdentifier == turnIdentifier else { return }
            self.bar.caption = ""
            self.hooks.setVoiceState(.idle)
            self.hooks.turnFinished()
            self.scheduleIdleClose()
        }
    }

    private func translate(_ piece: String) -> String {
        guard let board else { return piece }
        let translation = BoardProgramTranslator.translate(piece, on: board)
        for problem in translation.problems { TutorDebugLog.write("⚠️ board: \(problem)") }
        return translation.code
    }

    private func historyForModel() -> [(userPlaceholder: String, assistantResponse: String)] {
        boardHistory.enumerated().map { index, turn in
            let answer = BoardProgramPrompt.keepsWholeProgram(turnIndex: index, turnCount: boardHistory.count)
                ? turn.program
                : BoardProgramPrompt.shortenedTurnPrefix + turn.sentences.joined(separator: " ")
            return (userPlaceholder: turn.question, assistantResponse: answer)
        }
    }

    private func scheduleIdleClose() {
        idleCloseTask?.cancel()
        idleCloseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleSecondsBeforeClosing * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.close(reason: "ten minutes with no question")
        }
    }

    /// Prose turned into say() lines, one per sentence.
    static func programSpeaking(prose: String) -> String {
        let sentences = prose
            .replacingOccurrences(of: "```", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return sentences.enumerated().map { index, sentence in
            "step(\(index + 1));\nsay(\(BoardProgramTranslator.javaScriptStringLiteral(sentence + ".")));"
        }.joined(separator: "\n")
    }
}
