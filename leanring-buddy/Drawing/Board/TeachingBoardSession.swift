//
//  TeachingBoardSession.swift
//  leanring-buddy
//
//  "Teach me consistent hashing from scratch": the screen dims, a sheet of
//  paper comes up, and the lesson is drawn on it over as many turns as the
//  student keeps asking. This ties the board to the rest of the app.
//
//  Lifecycle:
//  - opens on a question BoardIntent says asks for it, or, for teach it
//    back, on one TeachBackIntent says asks for that (TeachBackSession);
//  - while open, every question (spoken, typed, or a follow-up button) is
//    answered on the board, with the board's contents in the turn note;
//  - closes on Esc, on "done" / "thanks, that's it", or after ten minutes
//    with no question, with a short fade; the whole board lesson is then
//    filed into learning memory as one lesson, and the board is kept in the
//    Notebook as one page.
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

/// One answer played on the board: what it said, and the board calls it made.
struct PlayedBoardAnswer {
    let program: String
    let sentences: [String]
    let operations: [BoardOperation]
    let lessonTitle: String?
}

/// What a teach-back session leaves for learning memory when it ends.
struct TeachBackRecord {
    let topic: String
    let openingQuestion: String
    /// Every go at explaining, in order, as heard.
    let explanations: [String]
    let rightIdeas: [String]
    let missedIdeas: [String]
    /// What Buddy said about it, the gaps included.
    let spokenAnswer: String
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
        /// What the student has learned before that this question touches,
        /// from learning memory, as notes for the turn. Bounded by the same
        /// wait as the normal path's recall.
        var studyNotes: (_ question: String) async -> [String] = { _ in [] }

        // Teach it back hooks (TeachBackSession.swift).
        /// The lesson just given, which "teach it back" is about.
        var lastLessonTitle: () -> String? = { nil }
        /// Words the recognizer should expect: the topic and the ideas
        /// memory holds near it.
        var keytermsForTopic: (_ topic: String) -> [String] = { [$0] }
        /// Before the microphone opens: the talk-over listener and any
        /// voice still playing are stopped.
        var prepareForListening: () -> Void = {}
        /// Asks a question as the student would, through the normal path:
        /// the bar's Fill the gaps and Try again.
        var askAsStudent: (String) -> Void = { _ in }
        /// What the student got right and missed, for learning memory.
        var recordTeachBack: (TeachBackRecord) -> Void = { _ in }

        // Notebook hook (NotebookRecorder.keepBoard).
        /// Keeps the board as it stands as a Notebook page. Called before the
        /// board fades, so the snapshot still has it.
        var keepBoardInNotebook: (_ question: String, _ title: String?, _ paragraphs: [String]) -> Void = { _, _, _ in }
    }

    var hooks: Hooks

    let overlay: DrawingOverlay
    private let player: LessonProgramPlayer
    let bar: TutorControlBarModel

    private(set) var isOpen = false
    private var board: TeachingBoard?
    private var surface: BoardSurface?
    private var screenForBoard: NSScreen?
    /// Whether BuddyBoard.open has been called for this session.
    private var boardIsOnScreen = false
    private var turnNumber = 0
    private var currentTurnIdentifier = 0
    private var turnTask: Task<Void, Never>?
    private var idleCloseTask: Task<Void, Never>?
    private var openingQuestion = ""
    private var lessonTitle: String?
    private var everySentenceSaid: [String] = []
    /// One name per turn, the parts of the lesson so far: the turn's lesson
    /// title once it is known, the question until then.
    private var partTitles: [String] = []
    /// The board's own conversation: earlier board turns only.
    private var boardHistory: [(question: String, program: String, sentences: [String])] = []
    /// The board calls of the answer being played, for teach-back's verdict.
    private var operationsThisAnswer: [BoardOperation] = []
    /// Strokes decided before the answer, drawn with its first sentence.
    private var commandsWaitingForFirstPiece: [BoardDrawCommand] = []
    /// Teach it back, while the board is open for it.
    private(set) var teachBack: TeachBackSession?
    var isTeachBackListening: Bool { teachBack?.isListening == true }
    /// The talk keys were pressed to end a teach-back explanation, so their
    /// release is not a question either.
    private(set) var talkKeysEndedTeachBack = false

    /// Ten minutes: long enough to read the board and think, short enough
    /// that a board left up while the student went away does not greet them.
    static let idleSecondsBeforeClosing: TimeInterval = 600

    init(overlay: DrawingOverlay, player: LessonProgramPlayer, bar: TutorControlBarModel, hooks: Hooks) {
        self.overlay = overlay
        self.player = player
        self.bar = bar
        self.hooks = hooks
        TutorBoardLog.write = { line in TutorDebugLog.write(line) }
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
            if let teachBack {
                if teachBack.isListening {
                    // A typed question while the microphone is open: the
                    // explanation is still being given, so it waits.
                    TutorDebugLog.write("🎓 teach-back: a question arrived while listening; it is not answered")
                    hooks.questionNeedsNoAnswer()
                    return true
                }
                if TeachBackIntent.asksToExplainAgain(transcript) {
                    TutorDebugLog.write("🎓 teach-back: \"\(transcript)\" is another go")
                    hooks.questionNeedsNoAnswer()
                    teachBack.listenAgain()
                    return true
                }
            } else if let topic = TeachBackIntent.decide(transcript, fallbackTopic: lessonTitle ?? board?.state.title).topic {
                // From a lesson on the board to explaining it back.
                close(reason: "teach it back starts")
                openTeachBack(topic: topic, question: transcript)
                return true
            }
            runTurn(question: transcript)
            return true
        }
        let teachBackDecision = TeachBackIntent.decide(transcript, fallbackTopic: hooks.lastLessonTitle())
        if let topic = teachBackDecision.topic {
            TutorDebugLog.write("🎓 teach-back opens: \(teachBackDecision)")
            openTeachBack(topic: topic, question: transcript)
            return true
        }
        let decision = BoardIntent.decide(transcript)
        guard decision.opensBoard else { return false }
        TutorDebugLog.write("🧑‍🏫 board opens: \(decision)")
        open(firstQuestion: transcript)
        runTurn(question: transcript)
        return true
    }

    /// Esc, as the design has it: while Buddy is speaking it stops the
    /// sentence and leaves the board up; when it is quiet it leaves. While
    /// teach-back listens it cancels what was being said.
    func escapeWasPressed() {
        guard isOpen else { return }
        if let teachBack, teachBack.isListening {
            teachBack.cancelListening()
            return
        }
        if player.isSpeaking || turnTask != nil {
            TutorDebugLog.write("🧑‍🏫 board: Esc stops the turn, the board stays")
            stopCurrentTurn()
            teachBack?.answerWasStopped()
            scheduleIdleClose()
            return
        }
        close(reason: "Esc")
    }

    /// Teach it back: the talk keys pressed while the student explains end
    /// the explanation, as Return does, and start no question. Returns true
    /// when it took them.
    func talkKeysPressed() -> Bool {
        guard let teachBack, teachBack.isListening else { return false }
        talkKeysEndedTeachBack = true
        teachBack.finishListening()
        return true
    }

    /// The release that goes with `talkKeysPressed`. Returns true when the
    /// press had been taken, so the release starts nothing either.
    func talkKeysReleased() -> Bool {
        guard talkKeysEndedTeachBack else { return false }
        talkKeysEndedTeachBack = false
        return true
    }

    /// Fades the board away, keeps it in the Notebook and files its lesson.
    /// `keepsNothing` is for an explanation cancelled before anything was
    /// drawn: nothing is saved anywhere. Safe to call when closed.
    func close(reason: String, keepsNothing: Bool = false) {
        guard isOpen else { return }
        TutorDebugLog.write("🧑‍🏫 board closes: \(reason), \(turnNumber) turns, \(board?.state.elements.count ?? 0) elements")
        isOpen = false
        let endingTeachBack = teachBack
        endingTeachBack?.end()
        teachBack = nil
        bar.isTeachingBack = false
        currentTurnIdentifier += 1
        turnTask?.cancel()
        turnTask = nil
        idleCloseTask?.cancel()
        idleCloseTask = nil
        player.stop()
        player.transformPieceBeforeRunning = nil

        // Notebook hook: the board as it stands, before it fades.
        let boardHasContent = !(board?.state.isEmpty ?? true)
        if !keepsNothing, boardHasContent {
            if let endingTeachBack {
                hooks.keepBoardInNotebook(openingQuestion, TeachBackPrompt.boardTitle(topic: endingTeachBack.topic),
                                          endingTeachBack.notebookParagraphs)
            } else if !everySentenceSaid.isEmpty {
                hooks.keepBoardInNotebook(openingQuestion, lessonTitle ?? board?.state.title, everySentenceSaid)
            }
        }

        overlay.callBoard("close", argumentsJSON: "0.6")
        overlay.boardTakesTheMouse = false
        overlay.onLeaveBoardRequested = nil
        overlay.onTeachBackAction = nil
        overlay.releaseKeyboard()
        bar.isBoardOpen = false
        bar.caption = ""
        bar.followUps = []
        hooks.setVoiceState(.idle)
        InterfaceSounds.shared.play(.wipe)

        if let endingTeachBack {
            if !keepsNothing, let record = endingTeachBack.record(openingQuestion: openingQuestion) {
                hooks.recordTeachBack(record)
                hooks.rememberExchange(openingQuestion, "(Taught back on the board, now closed.) " + record.spokenAnswer)
            }
        } else if !everySentenceSaid.isEmpty {
            let spokenLesson = everySentenceSaid.joined(separator: " ")
            hooks.fileLesson(openingQuestion, lessonTitle ?? board?.state.title, spokenLesson)
            hooks.rememberExchange(openingQuestion, "(Taught on the board, now closed.) " + spokenLesson)
        }
        board = nil
        surface = nil
        screenForBoard = nil
        boardIsOnScreen = false
        boardHistory = []
        everySentenceSaid = []
        lessonTitle = nil
        partTitles = []
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
        self.boardIsOnScreen = false
        // While the board is up it is the only surface: clicks land on it,
        // never on an app the student cannot see, and the notch says so.
        overlay.boardTakesTheMouse = true
        overlay.onLeaveBoardRequested = { [weak self] in self?.close(reason: "Leave board") }
        bar.isBoardOpen = true
    }

    /// Teach it back: the board opens titled with the topic, in its calm
    /// listening state, and the microphone opens.
    private func openTeachBack(topic: String, question: String) {
        open(firstQuestion: question)
        guard isOpen, let board, let surface, let screenForBoard else { return }
        let session = TeachBackSession(topic: topic, host: self)
        teachBack = session
        bar.isTeachingBack = true
        hooks.questionNeedsNoAnswer()
        // The player sizes the drawing page to the screen before the board
        // is put on it, as the first board turn does.
        player.begin(on: screenForBoard, canvasSize: CGSize(width: surface.canvasWidth, height: surface.canvasHeight),
                     targets: [:], targetLabels: [:], screenInkHex: "#3380FF")
        overlay.callBoard("open", argumentsJSON: surface.openArgumentsJSON)
        boardIsOnScreen = true
        board.beginTurn()
        let title = TeachBackPrompt.boardTitle(topic: topic)
        _ = board.apply(.setTitle(title))
        lessonTitle = title
        overlay.onTeachBackAction = { [weak self] action in self?.teachBackBarWasClicked(action) }
        showTeachBackPhase("listening")
        session.startListening()
    }

    private func teachBackBarWasClicked(_ action: String) {
        guard let teachBack else { return }
        switch action {
        case "done": teachBack.finishListening()
        case "cancel": teachBack.cancelListening()
        case "fill": hooks.askAsStudent("fill in the gaps you marked on my drawing")
        case "again": hooks.askAsStudent("let me try that part again")
        default: break
        }
    }

    /// The board's bar and the line under its title, for teach-back's phase:
    /// listening, drawing, checking or result.
    func showTeachBackPhase(_ phase: String) {
        guard let teachBack else { return }
        let payload: [String: Any] = [
            "title": TeachBackPrompt.boardTitle(topic: teachBack.topic),
            "subtitle": TeachBackPrompt.invitation,
            "phase": phase
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        overlay.callBoard("setTeachBack", argumentsJSON: json)
    }

    /// A part's name for the bar and the parts card: the lesson title, or
    /// the question cut to its first words while there is no title yet.
    private static func partName(forQuestion question: String) -> String {
        let words = question.split(separator: " ").prefix(6).joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private func showParts() {
        let payload: [String: Any] = ["parts": partTitles, "current": partTitles.count - 1]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        overlay.callBoard("setParts", argumentsJSON: json)
    }

    // MARK: - One turn

    private func runTurn(question: String) {
        guard let board else { return }
        idleCloseTask?.cancel()
        stopCurrentTurn()
        turnNumber += 1
        let thisTurnNumber = turnNumber
        let turnIdentifier = currentTurnIdentifier

        turnTask = Task { [weak self] in
            guard let self else { return }
            self.hooks.setVoiceState(.processing)
            self.bar.waitingStage = "thinking"
            if self.teachBack == nil {
                self.partTitles.append(Self.partName(forQuestion: question))
            }
            let studyNotes = await self.hooks.studyNotes(question)
            guard !Task.isCancelled, self.currentTurnIdentifier == turnIdentifier else { return }
            let turnNote = BoardProgramPrompt.turnNote(
                transcript: question, boardListing: board.state.compactListing(), turnNumber: thisTurnNumber,
                studentName: UserDefaults.standard.string(forKey: "studentName"), studyNotes: studyNotes)
            TutorDebugLog.write("🧑‍🏫 board turn \(thisTurnNumber): note is \(turnNote.count) characters")

            let played = await self.playBoardAnswer(
                systemPrompt: BoardProgramPrompt.system, history: self.historyForModel(), turnNote: turnNote,
                maximumTokens: BoardProgramPrompt.maximumTokens(turnNumber: thisTurnNumber), ink: nil)
            guard self.currentTurnIdentifier == turnIdentifier else { return }
            if let played {
                self.everySentenceSaid += played.sentences
                self.teachBack?.boardAnswerWasGiven(sentences: played.sentences)
                self.boardHistory.append((question: question, program: played.program, sentences: played.sentences))
                if let title = played.lessonTitle, self.teachBack == nil {
                    self.lessonTitle = title
                    self.bar.recordLessonTitle(title)
                    if !self.partTitles.isEmpty { self.partTitles[self.partTitles.count - 1] = title }
                    self.showParts()
                }
            }
            self.turnFinished()
        }
    }

    /// Ends the turn as every turn ends: quiet, idle, the idle close armed.
    private func turnFinished() {
        overlay.callBoard("setSpeaking", argumentsJSON: "false")
        bar.caption = ""
        hooks.setVoiceState(.idle)
        hooks.turnFinished()
        scheduleIdleClose()
        turnTask = nil
    }

    private func stopCurrentTurn() {
        currentTurnIdentifier += 1
        turnTask?.cancel()
        turnTask = nil
        player.stop()
        overlay.callBoard("setSpeaking", argumentsJSON: "false")
        bar.caption = ""
        hooks.setVoiceState(.idle)
    }

    /// One answer from the brain, spoken and drawn on the board, the same
    /// way for a lesson turn and for teach-back's two calls. `ink` is the
    /// pen for what it adds (nil is Buddy's own); `commandsWithFirstSentence`
    /// are strokes decided before it (teach-back's old gap marks rubbed
    /// out), drawn while its first sentence is said. Returns nil when the answer was
    /// stopped or failed.
    func playBoardAnswer(systemPrompt: String, history: [(userPlaceholder: String, assistantResponse: String)],
                         turnNote: String, maximumTokens: Int, ink: BoardInk?,
                         commandsWithFirstSentence: [BoardDrawCommand] = [],
                         keepsOnlyTheFirstBlock: Bool = false,
                         drawsAsOneBeat: Bool = false) async -> PlayedBoardAnswer? {
        guard let board, let surface, let screenForBoard else { return nil }
        let answerIdentifier = currentTurnIdentifier
        hooks.setVoiceState(.processing)
        bar.waitingStage = "thinking"

        // The same player as every answer, on a canvas the size of the
        // screen in points. Its begin() clears screen marks and cards,
        // never the board, which is its own layer.
        player.begin(on: screenForBoard, canvasSize: CGSize(width: surface.canvasWidth, height: surface.canvasHeight),
                     targets: [:], targetLabels: [:], screenInkHex: "#3380FF")
        if !boardIsOnScreen {
            overlay.callBoard("open", argumentsJSON: surface.openArgumentsJSON)
            boardIsOnScreen = true
        }
        overlay.callBoard("beginTurn", argumentsJSON: "")
        board.beginTurn()
        board.inkForNewMarks = ink
        operationsThisAnswer = []
        commandsWaitingForFirstPiece = commandsWithFirstSentence
        if teachBack == nil { showParts() }
        player.transformPieceBeforeRunning = { [weak self] piece in
            self?.translate(piece) ?? piece
        }

        let progress = BoardTurnProgress()
        // Teach it back runs only its first block: a model that writes a
        // corrected second one would otherwise draw the student's words twice.
        // Its drawing is one beat, so each part lands beside what it links to.
        func usable(_ text: String) -> String {
            let firstBlock = keepsOnlyTheFirstBlock ? TeachBackPrompt.firstProgramBlock(of: text) : text
            return drawsAsOneBeat ? TeachBackPrompt.drawingAsOneBeat(firstBlock) : firstBlock
        }
        do {
            let fullText = usable(try await hooks.answer(systemPrompt, history, turnNote, maximumTokens, progress) { [weak self] accumulatedText in
                guard let self, self.currentTurnIdentifier == answerIdentifier else { return }
                progress.hasReceivedText = true
                let text = usable(accumulatedText)
                if progress.answerIsProgram == nil, let isProgram = ProgramStream.looksLikeProgram(text) {
                    progress.answerIsProgram = isProgram
                    if isProgram {
                        self.hooks.setVoiceState(.responding)
                        self.overlay.callBoard("setSpeaking", argumentsJSON: "true")
                    }
                }
                if progress.answerIsProgram == true { self.player.feed(accumulatedText: text) }
            })
            guard !Task.isCancelled, currentTurnIdentifier == answerIdentifier else { return nil }
            TutorDebugLog.write("RAW BOARD RESPONSE:\n\(fullText)\n--- end ---")

            // An answer that came back as prose is still spoken, a
            // sentence per beat, with nothing drawn.
            let program = (progress.answerIsProgram ?? ProgramStream.looksLikeProgram(fullText) ?? false)
                ? fullText : Self.programSpeaking(prose: fullText)
            if progress.answerIsProgram != true {
                hooks.setVoiceState(.responding)
                player.feed(accumulatedText: program)
            }
            await player.finish(fullText: program)
            // Strokes still waiting (an answer with no runnable piece) are
            // drawn now rather than lost.
            if !commandsWaitingForFirstPiece.isEmpty, let json = Self.json(commandsWaitingForFirstPiece) {
                overlay.callBoard("apply", argumentsJSON: json)
                commandsWaitingForFirstPiece = []
            }
            let sentences = ProgramStream.closedSayArguments(in: ProgramStream.code(in: program))
            let lessonTitle = player.lessonTitle
            await player.waitUntilSpoken()
            board.inkForNewMarks = nil
            guard currentTurnIdentifier == answerIdentifier else { return nil }
            return PlayedBoardAnswer(program: program, sentences: sentences, operations: operationsThisAnswer,
                                     lessonTitle: lessonTitle)
        } catch is CancellationError {
            board.inkForNewMarks = nil
            return nil
        } catch {
            board.inkForNewMarks = nil
            guard currentTurnIdentifier == answerIdentifier else { return nil }
            TutorDebugLog.write("⚠️ board turn failed: \(error.localizedDescription)")
            await hooks.reportFailure(error)
            return nil
        }
    }

    /// Speaks one sentence on the board with no model: teach-back's "I did
    /// not hear anything".
    func speakOnBoard(_ sentence: String) async {
        guard let surface, let screenForBoard else { return }
        player.begin(on: screenForBoard, canvasSize: CGSize(width: surface.canvasWidth, height: surface.canvasHeight),
                     targets: [:], targetLabels: [:], screenInkHex: "#3380FF")
        player.transformPieceBeforeRunning = nil
        let program = Self.programSpeaking(prose: sentence)
        hooks.setVoiceState(.responding)
        player.feed(accumulatedText: program)
        await player.finish(fullText: program)
        await player.waitUntilSpoken()
        bar.caption = ""
        hooks.setVoiceState(.idle)
    }

    /// Teach it back: rubs out the last check's marks, to be drawn with the
    /// next answer's first sentence.
    func removeGapMarks() -> [BoardDrawCommand] {
        guard let board else { return [] }
        board.inkForNewMarks = nil
        return board.removeGapMarks()
    }

    var boardListing: String { board?.state.compactListing() ?? "ON THE BOARD: nothing yet." }

    /// Runs teach-back's work as the board's turn, so Esc and a new
    /// question stop it the way they stop a lesson turn.
    func runTeachBackWork(_ work: @escaping @MainActor () async -> Void) {
        idleCloseTask?.cancel()
        stopCurrentTurn()
        turnNumber += 1
        let turnIdentifier = currentTurnIdentifier
        turnTask = Task { [weak self] in
            await work()
            guard let self, self.currentTurnIdentifier == turnIdentifier else { return }
            self.turnFinished()
        }
    }

    /// The microphone is about to open: whatever was being said stops, and
    /// the board does not close itself while the student talks.
    func prepareForListening() {
        stopCurrentTurn()
        idleCloseTask?.cancel()
        hooks.prepareForListening()
    }

    func listeningEnded() {
        scheduleIdleClose()
    }

    private func translate(_ piece: String) -> String {
        guard let board else { return piece }
        let translation = BoardProgramTranslator.translate(piece, on: board)
        for problem in translation.problems { TutorDebugLog.write("⚠️ board: \(problem)") }
        operationsThisAnswer += translation.operations
        var code = translation.code
        if !commandsWaitingForFirstPiece.isEmpty, let json = Self.json(commandsWaitingForFirstPiece),
           let withStrokes = TeachBackPrompt.inserting("\nBuddyBoard.apply(\(json));", afterFirstSentenceOf: code) {
            code = withStrokes
            commandsWaitingForFirstPiece = []
        }
        return code
    }

    private static func json(_ commands: [BoardDrawCommand]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(commands) else { return nil }
        return String(data: data, encoding: .utf8)
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
        // Never while the student is explaining: a long pause there is theirs.
        guard teachBack?.isListening != true else { return }
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
