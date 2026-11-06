//
//  CompanionManager+Pipeline.swift
//  leanring-buddy
//
//  One question from release to the last sentence: capture, sorting,
//  memory, routing, the attempt loop with its deadlines, the answer
//  and what is kept of it.
//

import AppKit
import Foundation
import ScreenCaptureKit

extension CompanionManager {
    /// The answer task running now, if any.
    var currentResponseTask: Task<Void, Never>? {
        get { questionTicket.responseTask }
        set { questionTicket.responseTask = newValue }
    }

    func cancelCurrentResponseTask() {
        questionTicket.cancelCurrentAnswer()
    }

    /// A cancelled request, however it reports it: Swift's own error, or
    /// URLSession's `URLError(.cancelled)`, which is what its async calls
    /// throw when their task is cancelled. Never a failure to explain.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    // MARK: - Companion Prompt

    /// Builds the system prompt, injecting the screen inventory for this turn.
    ///
    /// Written short and example-heavy on purpose. A 4B model follows a compact
    /// prompt with concrete samples far more reliably than a long discursive
    /// one, and the measured failure mode was format drift (`[t23]` instead of
    /// `[POINT:t23]`), not misunderstanding the task.
    private static func tutorSystemPrompt(screenIndexListing: String) -> String {
        """
        you are a live tutor sitting beside the user, looking at their screen. they just spoke to you. your reply is spoken aloud, so write the way you talk. this is an ongoing conversation and you remember what came before.

        WHAT IS ON SCREEN
        below is an exact machine-read inventory of the screen. each line is an id and the text at that location. the coordinates behind these ids are precise, yours would not be.

        \(screenIndexListing)

        read this listing to know what the screen actually says. trust it over your own reading of the image, especially for code, numbers and identifiers. the image shows you layout, colour and diagrams. the listing shows you text.

        HOW TO MARK UP THE SCREEN
        you draw on the screen while you talk. put a tag inline exactly where you mention the thing, not bunched at the end. the mark appears as you say that word.

        [POINT:id]        point at it
        [CIRCLE:id]       circle it
        [BOX:id]          box a region or diagram node
        [UNDERLINE:id]    underline a line of code or phrase
        [HIGHLIGHT:id]    highlight text you are reading out
        [STRIKE:id]       cross out something wrong
        [ARROW:id->id]    show flow or cause between two things
        [STEP:id:1]       number an ordered sequence
        [LABEL:id:text]   attach a short note, four words max
        [SPOTLIGHT:id,id] dim everything except these
        [CLEAR]           wipe all marks

        rules for marking:
        - use ids from the listing above. never invent an id. never write raw coordinates.
        - marks and the board are separate. [CIRCLE:...], [ARROW:...] and the rest take screen ids from the listing above. board tags take words. never put a board word in a mark, so never [ARROW:storage->compute].
        - the ids are NOT in order and NOT numbered from one. copy each id character by character from the listing. if you are marking the five boxes of a diagram their ids might be t11, t12, t13, t14, t15, never t1 to t5. look it up, do not count.
        - the full tag is required. write [POINT:t23], never [t23] and never t23 on its own.
        - the screen is dense, so mark things. a bare explanation with no marks is a worse answer.
        - [SPOTLIGHT:...] takes at most three ids. it works by hiding everything else, so spotlighting a dozen things hides nothing and helps nobody.
        - open with [CLEAR] when you start explaining something new.
        - at most THREE marks in a reply. each one waits for the words that carry it, so fifteen marks is two minutes of drawing and nothing stands out.

        examples:
        - "the bug is here [CIRCLE:t23], you set high to the length [UNDERLINE:t23] but the last index is one less."
        - "requests come in here [STEP:t11:1] then hit the balancer [STEP:t12:2] then the cache [STEP:t14:3]."
        - "[CLEAR] forget the rest for a second [SPOTLIGHT:t26,t31]. these two lines are the whole loop."
        - "that cache [BOX:t14] absorbs most reads, so the database [ARROW:t14->t15] only sees misses."
        - "this is the wrong complexity [STRIKE:t57], it is actually log n [LABEL:t57:O(log n)]."

        HOW TO DRAW A PICTURE
        for an idea with structure, draw it on your board instead of describing it. a shape beats a sentence for anything with stages, flow, or data changing over steps.

        [BOARD:<title>]          start a fresh board
        [COL:<label>:<content>]  a labelled column, left to right
        [BASE:<label>]           a full width bar under the columns, for the thing that stays put
        [CELLS:3,7,9,12]         a row of values, for walking an algorithm
        [PTR:<index>:<name>]     a marker under one cell, like lo, mid, hi. index starts at 0
        [CAPTION:<text>]         one line under the drawing with the takeaway

        CRITICAL: the tag is the drawing. nothing appears unless you write the tag.
        - never announce that you are drawing. do not write "let me draw", "let's picture this", "imagine a diagram". those words draw nothing and the student stares at an empty board.
        - write the tag mid sentence while you explain. the picture appears by itself.
        - if you mention a stage, a column or a value, the tag for it belongs in that same sentence.

        rules for the board:
        - put the tags inline as you say each part. the picture builds up while you talk.
        - keep every label under five words. this is a sketch, not a document.
        - columns are for stages or moments in time. cells are for data you are stepping through.
        - always write [CELLS:...] before any [PTR:...]. a pointer with no row has nothing to sit under.
        - a [PTR:...] index is a number counting from zero. you may also write first, mid or last.
        - say what it means out loud. the board supports your words, it does not replace them.
        - draw a board when it genuinely helps. for a plain factual question, just answer.

        example, separating storage from compute:
        "think about one day of work [BOARD:same data, changing workers]. in the morning you run a cluster [COL:morning:compute]. at night nobody is querying [COL:night:0 workers]. tomorrow you spin one up again [COL:tomorrow:compute]. the table never moved [BASE:100 GB sales table]. [CAPTION:storage stays, compute comes and goes]"

        example, binary search:
        "say the array is this [BOARD:binary search][CELLS:3,7,9,12,15,21,30]. you start with lo at zero and hi at the end [PTR:0:lo][PTR:6:hi]. mid lands here [PTR:3:mid], twelve is too small, so lo jumps past it [PTR:4:lo]. [CAPTION:half the range gone each step]"

        NEVER READ THE SCREEN BACK
        they are looking at the screen. they can read. telling them what it says wastes the only thing they came for.
        - never quote the question, their answer, or any text on screen.
        - never say "you're looking at", "the screen says", "your answer says", "this asks".
        - never summarise what is in front of them before getting to the point.

        NO WARM UP
        your first sentence must contain the actual answer. no runway.
        banned openings: "i hear you", "let's walk through", "let me show you", "let's break this down", "first, look at", "good question", "so basically", "step by step".
        start with the thing they are missing. that is the whole reply.

        HOW TO TALK
        - your words are spoken aloud. write for the ear. short sentences. never use markdown, blockquotes, bullets, headings, asterisks or dashes as punctuation. say "big o of n log n", not "O(n log n)".
        - all lowercase, warm, direct. no emojis.
        - THREE SENTENCES. that is the whole answer. they are waiting in silence while you write, so every extra sentence is a longer wait and more to hold in their head.
        - one idea per reply. the single thing they are missing, said plainly. not the background, not the history, not the counterexample.
        - if they ask you to go deeper, then take the room and teach it properly.
        - never say "simply" or "just". nothing here is simple to someone learning it.
        - do not read code out line by line. say what it does and where it breaks.

        HOW TO TEACH
        - answer from what is actually on their screen, not from the textbook version of the question. if the listing shows their code says one thing, address that, not the canonical example you remember.
        - when something is wrong, say what breaks and under which input. a concrete failing case teaches more than a label.
        - if they are missing the idea underneath the question, say that too. the misunderstanding is usually one level below what they asked.
        - when you are not sure, say so plainly and say what would settle it.
        - end by opening a door: a related idea worth chasing, a harder case their approach would not survive. do not end on a yes or no question.

        if the question has nothing to do with the screen, answer it directly and mark nothing.
        if several screens are sent, the one labelled primary focus holds the cursor. prefer it.
        """
    }

    func logStage(_ stage: String) {
        let sinceStart = Date().timeIntervalSince(answerStartedAt)
        var line = "⏱ \(stage): \(String(format: "%.2f", sinceStart))s"
        if let released = shortcutReleasedAt, Date().timeIntervalSince(released) < 60 {
            line += " (\(String(format: "%.2f", Date().timeIntervalSince(released)))s after release)"
        }
        TutorDebugLog.write(line)
    }

    /// A board turn goes to the brain a teach question would, with no
    /// screenshot: the board is the whole context. A brain that fails before
    /// its first word hands over to the next, as in the normal flow.
    func answerTeachingBoardTurn(
        systemPrompt: String, history: [(userPlaceholder: String, assistantResponse: String)], turnNote: String,
        maximumTokens: Int, progress: BoardTurnProgress, onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        var routing = routeQuestion(probabilities: [.teach: 1.0])
        // Under Auto a teach question goes to Argon, but a board turn goes to
        // Sonnet first whenever there is an Anthropic key: on the board's
        // long system prompt Argon took 6.9 to 59.1 seconds a turn (median 12.6)
        // and answered 429 mid-session (scripts/board/README.md), and a board turn is a
        // student waiting at the board in silence. Argon stays the fallback.
        if brainKind == .auto, canUseClaude {
            routing.removeAll { $0 == .sonnet }
            routing.insert(.sonnet, at: 0)
        }
        var attempt = 0
        while true {
            if attempt < routing.count { activate(routing[attempt]) }
            claudeBrain.maximumResponseTokens = maximumTokens
            hostedBrain.maximumResponseTokens = maximumTokens
            localBrain.maximumResponseTokens = maximumTokens
            do {
                let (text, duration) = try await tutorBrain.analyzeImageStreaming(
                    images: [], systemPrompt: systemPrompt, conversationHistory: history,
                    userPrompt: turnNote, onTextChunk: onTextChunk)
                TutorDebugLog.write("🧑‍🏫 board turn answered in \(String(format: "%.1f", duration))s by \(lastAnsweringBrainName)")
                if attempt < routing.count { modelRouter.answered(by: routing[attempt]) }
                return text
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), !progress.hasReceivedText,
                      attempt + 1 < routing.count else { throw error }
                modelRouter.bench(routing[attempt], because: "it failed on a board turn before speaking")
                attempt += 1
            }
        }
    }

    /// Captures the screen, indexes it, asks the local model, and narrates the
    /// answer while drawing on screen.
    ///
    /// Speech starts on the first complete sentence rather than waiting for the
    /// whole answer. That matters more than raw speed: the model generates
    /// roughly two and a half times faster than speech plays back, so once the
    /// first sentence is out the voice never catches up to the generator, and
    /// the only latency the user perceives is time-to-first-sentence.
    /// `guideStep` is set when guide mode looks again after the student did
    /// a step: nobody spoke, so nothing goes in the transcript as theirs.
    /// `howToTakeover` is set when a saved how-to stopped matching the screen
    /// at that step and the model carries on from there.
    /// `earlyScreen` is the screen read while the keys were held, checked at
    /// release; it comes only with a spoken question, and nil (or a nil
    /// result) means the screen is captured now, as before.
    func sendTranscriptToTutorWithScreenshot(transcript spokenTranscript: String, guideStep: GuideStep? = nil,
                                                     howToTakeover: (howTo: HowTo, stepsDone: Int)? = nil,
                                                     earlyScreen: Task<PreparedScreen?, Never>? = nil,
                                                     studentPointing: StudentPointingClues? = nil,
                                                     interruptedAnswerNote: String? = nil) {
        let isGuideContinuation = guideStep != nil
        // Hook for ErrorOffer.swift: the offered error, when this question accepts it.
        let errorAskedAbout = errorOffer.errorAskedAbout(question: spokenTranscript)
        var transcript = isGuideContinuation ? spokenTranscript : Self.questionWithoutGreeting(spokenTranscript)
        // "Say that again" is not a question: the last answer is played
        // again as it was, with no model, and is not counted or filed.
        if !isGuideContinuation, howToTakeover == nil, TalkOverHearing.isReplayRequest(transcript),
           replayLastAnswer(startedBy: "asked") {
            earlyScreen?.cancel()
            return
        }
        cancelCurrentResponseTask()
        // Notebook hook: the answer just cancelled leaves no page.
        notebookRecorder.newQuestionStarted()
        cancelSpeechAndClearQueue()

        if isGuideContinuation {
            guide.watcher.stop()
            TutorDebugLog.write("🧭 guide: \(transcript)")
        } else if howToTakeover != nil {
            TutorDebugLog.write("📒 replay handed to the model: \(transcript)")
        } else {
            stopGuide(reason: "a new question")
            TutorDebugLog.write("🎙️ asked: \(transcript)")
            controlBar.model.recordStudent(transcript)
            controlBar.model.heardWords = transcript
            // For the lesson card's eyebrow, and cleared for this answer's
            // own lecture label.
            controlBar.model.lectureSourceLabel = nil
            if let front = NSWorkspace.shared.frontmostApplication,
               front.bundleIdentifier != Bundle.main.bundleIdentifier {
                controlBar.model.lastLessonApplicationName = front.localizedName
            }
            // Letting go of the keys mid-thought and pressing them again sends
            // the rest as a new question, which cancels the first before a word
            // of it is answered. Both halves go to the model as one question;
            // the chat already shows the first, so it shows only the new words.
            if let unanswered = questionAwaitingAnswer,
               Date().timeIntervalSince(unanswered.askedAt) < Self.joinUnansweredQuestionWithinSeconds {
                transcript = unanswered.text + " " + transcript
                TutorDebugLog.write("🎙️ joined with the unanswered question before it: \(transcript)")
            }
            questionAwaitingAnswer = (transcript, Date())
        }
        answerStartedAt = Date()
        questionBeingAnswered = transcript
        if howToTakeover == nil { SpendingMeter.shared.countQuestion(isGuideStep: isGuideContinuation) }
        logStage("question in")

        // MARK: Teaching board hook (TeachingBoardSession.swift)
        // A question asking to be taught from scratch opens the board, and
        // while it is open every question is answered there. Otherwise this
        // returns false and nothing below changes.
        if !isGuideContinuation, howToTakeover == nil, teachingBoard.takeQuestion(transcript) {
            return
        }

        // Asked before? A saved how-to for this app is replayed with no
        // model at all. Decided before the sorter and memory calls start, so
        // a replay costs only its voice.
        if !isGuideContinuation, howToTakeover == nil, learningMemory.isEnabled,
           let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier,
           let howTo = howToMemory.match(question: transcript, appBundleIdentifier: front.bundleIdentifier,
                                         vectorFor: { [questionSorter] text in questionSorter.sentenceVector(for: text) }) {
            // A replay reads the screen at each step itself.
            earlyScreen?.cancel()
            currentResponseTask = Task { [weak self] in
                guard let self else { return }
                let replayed = await self.replayHowToStep(howTo, stepIndex: 0, question: transcript,
                                                          startedBy: transcript, application: front)
                guard !replayed, !Task.isCancelled else { return }
                TutorDebugLog.write("📒 replay: the first step's control is not on screen")
                self.howToMemory.noteReplayFailed(howTo)
                self.howToMemory.startRecording(question: transcript, application: front, replacing: howTo.id)
                self.sendTranscriptToTutorWithScreenshot(transcript: transcript, howToTakeover: (howTo, 0))
            }
            return
        }
        let hasPreviousAnswer = !conversation.exchanges.isEmpty
        // A guide step is always short: one or two sentences and a pointer.
        let localProbabilities = isGuideContinuation
            ? [QuestionKind.quick: 1.0]
            : questionSorter.probabilities(of: transcript, hasPreviousAnswer: hasPreviousAnswer)
        let localConfidence = localProbabilities?.values.max() ?? 0

        // Haiku is asked only when the on-device sorter is unsure, and asked
        // now, so it works while the screen is captured and read.
        // Memory starts now too, so its Haiku call also runs during capture.
        let (earlyFrontAppName, earlyWindowTitle) = TutorProgramPrompt.frontmostAppAndWindow()
        let recallTask = learningMemory.startRecall(
            question: transcript, windowTitle: earlyWindowTitle,
            questionVector: questionSorter.sentenceVector(for: transcript))
        _ = earlyFrontAppName
        // Lecture mode hook: what the video in front just said, gathered
        // while the screen is captured. Not for guide steps or replays.
        let lectureGatheringTask = isGuideContinuation || howToTakeover != nil
            ? nil : LectureMode.shared.beginGathering(question: transcript)

        let previousExchangeForSorting = conversation.exchanges.last.map { exchange in
            (question: exchange.userTranscript, spokenAnswer: Self.spokenSentences(inProgram: exchange.assistantResponse))
        }
        let videoWasPlaying = LectureMode.shared.frontAppPlayedSound(withinSeconds: 600)
        let classifierTask: Task<QuestionKind?, Never>? =
            localConfidence < QuestionSorter.confidentEnough && APIKeyStore.hasKey(for: .anthropic)
            ? Task { [claudeBrain] in
                await claudeBrain.classifyQuestion(transcript, previousExchange: previousExchangeForSorting,
                                                   videoWasPlaying: videoWasPlaying)
            }
            : nil

        let isThisQuestionStillAsked = questionTicket.checkForThisQuestion()
        currentResponseTask = Task {
            @MainActor func isStillTheCurrentQuestion() -> Bool {
                isThisQuestionStillAsked()
            }
            // The side calls end with their answer, so a question cut short
            // does not go on spending on a classifier, recall or a lecture.
            defer {
                classifierTask?.cancel()
                recallTask.cancel()
                lectureGatheringTask?.cancel()
            }
            voiceState = .processing
            controlBar.model.waitingStage = "reading your screen"
            clearAnnotations()
            marks.resetRevealForNewAnswer()

            do {
                let screenCaptures: [CompanionScreenCapture]
                let primaryCapture: CompanionScreenCapture
                var screenWasReadWhileTheyTalked = false
                if let preparedScreen = await earlyScreen?.value, isStillTheCurrentQuestion() {
                    screenWasReadWhileTheyTalked = true
                    screenCaptures = preparedScreen.screenCaptures
                    primaryCapture = preparedScreen.primaryCapture
                    screenIndex = preparedScreen.screenIndex
                    logStage("screen read while they talked, still current")
                } else {
                    guard isStillTheCurrentQuestion() else { return }
                    // Notebook hook: the full capture is for the page's crop.
                    screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(
                        alsoCapturingFullResolution: !isGuideContinuation && NotebookRecorder.keepsLessons)
                    guard isStillTheCurrentQuestion(), !screenCaptures.isEmpty else { return }
                    logStage("screen captured")

                    // Index only the screen holding the cursor. Indexing every
                    // display would multiply the prompt for context the user is
                    // almost certainly not looking at.
                    primaryCapture = screenCaptures.first(where: { capture in capture.isCursorScreen })
                        ?? screenCaptures[0]

                    await screenIndex.rebuild(
                        fromScreenshot: primaryCapture.imageData,
                        displayIndex: 0,
                        displayBoundsInPoints: CGSize(
                            width: primaryCapture.displayWidthInPoints,
                            height: primaryCapture.displayHeightInPoints
                        )
                    )
                    guard isStillTheCurrentQuestion() else { return }
                }
                marks.displayFrameForCurrentAnswer = primaryCapture.displayFrame
                logStage("screen captured and read")
                controlBar.model.waitingStage = "thinking"
                let screenReadAt = Date()

                let (questionKind, kindProbabilities) = await settleQuestionKind(
                    transcript: transcript,
                    hasPreviousAnswer: hasPreviousAnswer,
                    localProbabilities: localProbabilities,
                    classifierTask: classifierTask
                )
                guard isStillTheCurrentQuestion() else { return }
                logStage("question kind settled")

                // Counted before the answer is built, so the instruction
                // reflects how many times this idea has already failed to land.
                if questionKind == .reexplain {
                    learningMemory.studentGotLost()
                    conversation.consecutiveReexplanationCount += 1
                    TutorDebugLog.write("🔁 student still lost after \(lastAnsweringBrainName), attempt \(conversation.consecutiveReexplanationCount + 1): switching tactic")
                } else {
                    conversation.consecutiveReexplanationCount = 0
                }

                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                let historyForModel = conversation.exchanges.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                proseSpeech.resetStreamPosition()

                // The ceiling is lifted only when the user asks for depth.
                // Keeping the default tight is what stops the tutor
                // monologuing, but a request to go deeper is exactly when a
                // long answer is the right answer.
                // 200 kept truncating mid-explanation once the board tags
                // started appearing: the structure costs tokens that the spoken
                // answer then does not have. Cut off halfway is worse than
                // slightly long, and the filler rules keep the prose tight.
                let budget = Self.answerBudget(for: questionKind)
                // Set on both, because under Auto which one answers is decided
                // per question and may change on a fallback.
                claudeBrain.maximumResponseTokens = TutorProgramPrompt.maximumTokens(for: questionKind)
                hostedBrain.maximumResponseTokens = TutorProgramPrompt.maximumTokens(for: questionKind)
                localBrain.maximumResponseTokens = TutorProgramPrompt.maximumTokens(for: questionKind)

                let routing = routeQuestion(probabilities: kindProbabilities)

                // The screenshot is the canvas the program draws on, so it is
                // sent at the size it was captured. Reducing it would put every
                // coordinate the model reads off it on a different scale.
                claudeBrain.maximumImageDimension = 1280
                hostedBrain.maximumImageDimension = 1280
                let canvasSize = CGSize(
                    width: primaryCapture.screenshotWidthInPixels,
                    height: primaryCapture.screenshotHeightInPixels
                )
                let (screenListing, screenBoxes) = screenIndex.listingWithBoxes(
                    canvasSize: canvasSize,
                    displaySizeInPoints: CGSize(
                        width: primaryCapture.displayWidthInPoints,
                        height: primaryCapture.displayHeightInPoints
                    )
                )
                let (frontAppName, frontWindowTitle) = TutorProgramPrompt.frontmostAppAndWindow()

                // What the student has learned before that this is about.
                // Small talk is about nothing learned, and a "builds on" note
                // would only tempt the reply into a lesson.
                if questionKind == .chat { recallTask.cancel() }
                let recollections = questionKind == .chat ? [] : await settleRecollections(
                    recallTask: recallTask, question: transcript,
                    screenContext: (frontWindowTitle ?? "") + "\n" + screenListing,
                    // At least a second from the question: the chooser's reply
                    // takes about 0.75 s, and a fast capture alone left it a
                    // coin flip in live testing. Recalling an earlier lesson
                    // is worth a fraction of a second more.
                    deadline: max(screenReadAt.addingTimeInterval(Self.classifierGraceSeconds),
                                  answerStartedAt.addingTimeInterval(Self.memoryChooserFloorSeconds)))
                guard isStillTheCurrentQuestion() else { return }
                logStage("memory settled")
                controlBar.model.buildsOn = recollections.map(\.concept.name)
                var studyNotes = [LearningMemory.promptNote(for: recollections)]
                if let howToTakeover, howToTakeover.stepsDone > 0 {
                    studyNotes.append(HowToMemory.takeoverNote(howToTakeover.howTo, stepsDone: howToTakeover.stepsDone))
                }
                if let interruptedAnswerNote { studyNotes.append(interruptedAnswerNote) }
                if let guideStep {
                    studyNotes.append(GuideMode.continuationNote(
                        after: guideStep, stepNumber: guide.stepsGiven,
                        changedRegion: guide.changedRegion, canvasSize: canvasSize))
                }
                // Hook for ErrorOffer.swift: the error's lines and the ids to ring.
                if let errorAskedAbout {
                    studyNotes.append(ErrorOfferController.turnNote(
                        for: errorAskedAbout, listedLabels: screenIndex.lastListedLabels,
                        canvasSize: canvasSize, displayFrame: primaryCapture.displayFrame))
                }
                let captureForGuide = (imageData: primaryCapture.imageData, displayFrame: primaryCapture.displayFrame)
                let applicationInFront = NSWorkspace.shared.frontmostApplication

                // A practice problem gets hints in steps; a drawing of their
                // own gets a peer's review. A practice problem wins when both
                // seem to apply, unless they said it is their drawing.
                var lengthInstruction = TutorProgramPrompt.lengthInstruction(for: questionKind)
                currentPracticeProblem = nil
                let diagramTool = DiagramReview.detect(
                    frontAppName: frontAppName, windowTitle: frontWindowTitle, transcript: transcript)
                if questionKind != .chat, let problem = PracticeHints.detect(
                    frontAppName: frontAppName, windowTitle: frontWindowTitle, screenListing: screenListing),
                   diagramTool == nil || !transcript.lowercased().contains("my ") {
                    let levelSoFar = practiceHintLadder.level(for: problem)
                    let levelToGive = PracticeHints.requestedLevel(transcript: transcript, levelSoFar: levelSoFar)
                    studyNotes.append(PracticeHints.instruction(problem: problem, levelToGive: levelToGive, levelSoFar: levelSoFar))
                    if let levelToGive {
                        lengthInstruction = "follow the step under THEY ARE PRACTISING, not a usual length."
                        if levelToGive == 4 {
                            claudeBrain.maximumResponseTokens = max(claudeBrain.maximumResponseTokens, 2_600)
                            hostedBrain.maximumResponseTokens = max(hostedBrain.maximumResponseTokens, 2_600)
                        }
                    }
                    currentPracticeProblem = problem
                    TutorDebugLog.write("🧩 practice: \(problem.site), hints so far \(levelSoFar), giving \(levelToGive.map(String.init) ?? "none (not a solve request)")")
                } else if questionKind != .chat, let diagramTool {
                    studyNotes.append(DiagramReview.instruction(tool: diagramTool))
                    TutorDebugLog.write("✏️ reviewing their drawing in \(diagramTool)")
                }

                // Lecture mode hook: a note only when a lecture's words were found.
                // Small talk gets it too: "did you catch that?" is answered
                // in a sentence, from words already on the Mac.
                if let lectureGatheringTask,
                   let lectureNote = await LectureMode.shared.note(
                    for: lectureGatheringTask, question: transcript, screenListing: screenListing,
                    waitingUntil: answerStartedAt.addingTimeInterval(LectureMode.longestWaitAfterQuestionSeconds)) {
                    studyNotes.append(lectureNote)
                    if LectureMode.shared.frontAppPlayedSound(withinSeconds: 3) {
                        studyNotes.append(LectureNote.videoIsPlayingNote)
                    }
                    // Lecture mode hook: the notch says where this answer's words came from.
                    controlBar.model.lectureSourceLabel = LectureMode.shared.lastNoteSourceLabel
                }
                guard isStillTheCurrentQuestion() else { return }

                // The pointer's rests are places on the screen as it was while
                // they talked. Read again because it moved, the screen no
                // longer matches them, so only a selection is kept.
                var pointingLine: String?
                if let studentPointing, !studentPointing.isEmpty {
                    pointingLine = StudentPointingNote.line(
                        for: studentPointing, screenIndex: screenIndex,
                        displayFrame: primaryCapture.displayFrame, canvasSize: canvasSize,
                        includePointer: screenWasReadWhileTheyTalked)
                    TutorDebugLog.write("👉 \(pointingLine.map { $0.hasPrefix("SELECTED") ? "selected text, \(studentPointing.selection?.text.count ?? 0) characters" : $0 } ?? "pointer rested on nothing listed")")
                }

                let turnPrompt = TutorProgramPrompt.turnContext(
                    transcript: transcript,
                    canvasSize: canvasSize,
                    screenListing: screenListing,
                    lengthInstruction: lengthInstruction,
                    reexplanationInstruction: conversation.reexplanationInstruction(),
                    frontAppName: frontAppName,
                    frontWindowTitle: frontWindowTitle,
                    studyNotes: studyNotes,
                    pointingLine: pointingLine
                )

                let screenForDrawing = NSScreen.screens.first { screen in
                    screen.frame == primaryCapture.displayFrame
                } ?? NSScreen.main
                if let screenForDrawing {
                    lessonPlayer.begin(
                        on: screenForDrawing,
                        canvasSize: canvasSize,
                        targets: screenBoxes,
                        targetLabels: screenIndex.lastListedLabels,
                        screenInkHex: "#3380FF",
                        // Kept with the answer, so a replay can tell whether
                        // the screen under its marks has changed since.
                        screenThumbnail: GuideWatcher.thumbnail(fromImageData: primaryCapture.imageData)
                    )
                    followMarks(displayFrame: primaryCapture.displayFrame, canvasSize: canvasSize,
                                targets: screenBoxes, labels: screenIndex.lastListedLabels)
                }
                currentAnswerFormat = .undecided

                // Only the cursor's screen: that one screenshot is the canvas.
                let imagesForModel = [(data: primaryCapture.imageData, label: "")]

                logStage("request sent")
                // Tries the router's choices in order. A brain that fails before
                // saying anything is benched and the next one answers; once
                // words have been spoken, a failure is reported as before,
                // because starting again would repeat what was already heard.
                var attempt = 0
                var answer: (text: String, duration: TimeInterval)?
                var hasRetriedBusyBrain = false
                while answer == nil {
                    if attempt < routing.count { activate(routing[attempt]) }
                    let brainForAttempt = tutorBrain
                    let thisAttempt = questionTicket.beginAttempt()
                    // Only a fallback is worth a deadline: with nobody to hand
                    // over to, a slow answer still beats none.
                    let deadline: TimeInterval? = attempt + 1 < routing.count
                        ? modelRouter.firstWordsDeadline(for: routing[attempt], probabilities: kindProbabilities)
                        : nil
                    do {
                        answer = try await withStallDetection {
                            try await self.withFirstWordsDeadline(deadline) {
                                try await brainForAttempt.analyzeImageStreaming(
                                    images: imagesForModel,
                                    systemPrompt: TutorProgramPrompt.system,
                                    conversationHistory: historyForModel,
                                    userPrompt: turnPrompt,
                                    onTextChunk: { [weak self] accumulatedText in
                                        guard let self, self.questionTicket.isCurrentAttempt(thisAttempt) else { return }
                                        self.lastStreamedTextAt = Date()
                                        self.routeStreamedText(accumulatedText)
                                    }
                                )
                            }
                        }
                    } catch {
                        // Busy, with nobody to hand over to and nothing said
                        // yet: asked once more after a short, random pause.
                        if !hasRetriedBusyBrain, attempt + 1 >= routing.count, currentAnswerFormat == .undecided,
                           isStillTheCurrentQuestion(), Self.isBusyRefusal(error) {
                            hasRetriedBusyBrain = true
                            TutorDebugLog.write("↻ the brain is busy (\(error.localizedDescription.prefix(80))), asking once more")
                            try await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.5...1.5) * 1_000_000_000))
                            continue
                        }
                        guard isStillTheCurrentQuestion(),
                              error is FirstWordsDeadlineMissed || !Self.isCancellation(error),
                              currentAnswerFormat == .undecided,
                              attempt + 1 < routing.count else { throw error }
                        let failedBrain = routing[attempt]
                        var nextAttempt = attempt + 1
                        if error is FirstWordsDeadlineMissed {
                            TutorDebugLog.write("↪️ \(failedBrain.rawValue) said nothing in \(Int(deadline ?? 0))s, \(routing[nextAttempt].rawValue) answers instead")
                            // Silent past the patience window is a failure too:
                            // a brain that slow now is slow for the next
                            // question as well, which then waits the same
                            // seconds again before anyone speaks.
                            modelRouter.bench(failedBrain, because: "it said nothing in \(Int(deadline ?? 0))s")
                        } else {
                            let problem = keyProblem(in: error)
                            if let problem { reportKeyProblem(problem, answerFailed: false) }
                            modelRouter.bench(failedBrain, because: "it failed before speaking")
                            // Sonnet and Opus share the Anthropic key: when the
                            // key is the problem, the other one fails the same way,
                            // so it is skipped rather than tried.
                            if problem?.service == .anthropic {
                                while nextAttempt < routing.count, routing[nextAttempt] != .argon {
                                    modelRouter.bench(routing[nextAttempt], because: "it shares the failing Anthropic key")
                                    nextAttempt += 1
                                }
                                guard nextAttempt < routing.count else { throw error }
                            }
                            TutorDebugLog.write("↪️ \(failedBrain.rawValue) failed before speaking (\(error.localizedDescription.prefix(120))), \(routing[nextAttempt].rawValue) answers instead")
                        }
                        attempt = nextAttempt
                        controlBar.model.waitingStage = "asking \(routing[attempt].displayName) instead"
                    }
                }
                guard let (fullResponseText, duration) = answer else { return }
                if attempt < routing.count { modelRouter.answered(by: routing[attempt]) }

                // An answer from the provider whose key was reported means the
                // key works again: the banner goes, unprompted.
                if let problem = keyProblem, attempt < routing.count {
                    let answeredWith: APIKeyStore.Service = routing[attempt] == .argon ? .gemini : .anthropic
                    if answeredWith == problem.service {
                        clearKeyProblem()
                    }
                }

                guard isStillTheCurrentQuestion() else { return }

                // The raw response, verbatim. When no marks appear this is the
                // only way to tell the two causes apart: the model emitting no
                // tags at all, versus tags that failed to resolve to a target.
                TutorDebugLog.write("RAW MODEL RESPONSE:\n\(fullResponseText)\n--- end ---")

                if currentAnswerFormat == .undecided {
                    routeStreamedText(fullResponseText)
                    if currentAnswerFormat == .undecided { currentAnswerFormat = .prose }
                }

                if currentAnswerFormat == .program {
                    await lessonPlayer.finish(fullText: fullResponseText)
                    guard isStillTheCurrentQuestion() else { return }
                    if let lessonTitle = lessonPlayer.lessonTitle {
                        TutorDebugLog.write("📘 lesson: \(lessonTitle)")
                        controlBar.model.recordLessonTitle(lessonTitle)
                    }
                    controlBar.model.lastAnswerOffersGoDeeper = questionKind == .teach || questionKind == .normal
                    if let problem = currentPracticeProblem,
                       let levelGiven = PracticeHints.levelGiven(inProgram: fullResponseText) {
                        practiceHintLadder.record(level: levelGiven, for: problem)
                    }
                    let nextGuideStep = GuideMode.step(inProgram: fullResponseText)
                    // Kept as a how-to once the task is finished. Memory's
                    // switch covers these too.
                    if learningMemory.isEnabled {
                        let labels = screenIndex.lastListedLabels
                        if !isGuideContinuation, let nextGuideStep {
                            if howToTakeover == nil {
                                howToMemory.startRecording(
                                    question: transcript,
                                    application: applicationInFront?.bundleIdentifier == Bundle.main.bundleIdentifier
                                        ? nil : applicationInFront)
                            }
                            howToMemory.recordStep(program: fullResponseText, labels: labels, waitingFor: nextGuideStep)
                        } else if isGuideContinuation, let nextGuideStep {
                            howToMemory.recordStep(program: fullResponseText, labels: labels, waitingFor: nextGuideStep)
                        } else if isGuideContinuation, !HowToMemory.sayArguments(in: fullResponseText).isEmpty {
                            howToMemory.finishRecording(program: fullResponseText, labels: labels,
                                                        lessonTitle: lessonPlayer.lessonTitle)
                        } else {
                            howToMemory.abandonRecording()
                        }
                    }
                    if let nextGuideStep, guide.hasRoomForAnotherStep {
                        guide.takeStep(nextGuideStep, baseline: captureForGuide, applicationInFront: applicationInFront)
                    } else if isGuideContinuation || nextGuideStep != nil {
                        stopGuide(reason: nextGuideStep == nil ? "task finished" : "too many steps")
                    }
                    // "Click Export" is not something learned. Memory is for
                    // ideas, so guide steps are not filed.
                    // Nor is "thanks": small talk gets no notebook page and no idea.
                    if nextGuideStep == nil && !isGuideContinuation && questionKind != .chat {
                        // Notebook hook: held now, while the board holds the
                        // whole drawing; written only if the answer finishes.
                        notebookRecorder.holdDrawnLesson(
                            question: transcript, lessonTitle: lessonPlayer.lessonTitle, program: fullResponseText,
                            screenshotJPEGData: primaryCapture.imageData,
                            fullResolutionScreenshotTask: primaryCapture.fullResolutionScreenshotTask,
                            canvasSize: canvasSize, answeredBy: lastAnsweringBrainName)
                        fileLessonInMemory(question: transcript, lessonTitle: lessonPlayer.lessonTitle,
                                           spokenAnswer: Self.spokenSentences(inProgram: fullResponseText),
                                           questionKind: questionKind)
                    }
                    // The whole program, not only what was said: the next
                    // answer has to know what it drew to build on it or to
                    // explain it differently.
                    conversation.remember(question: transcript, answer: fullResponseText)
                    print("🧠 Answered in \(String(format: "%.1f", duration))s as a drawing program")
                } else {

                // Flush whatever trailed the final sentence terminator, which
                // the streaming path deliberately held back.
                proseSpeech.enqueueRemainder(ofStreamedText: fullResponseText)
                if currentGuideStep != nil {
                    stopGuide(reason: "the answer came back as plain prose")
                }

                let spokenOnlyText = TeacherResponseParser.parse(rawResponse: fullResponseText).spokenText
                marks.noteSpokenLength(ofWholeAnswer: spokenOnlyText.count)

                // Drawn on a fast model in parallel, because the model that
                // explains well will not draw cheaply: offering Argon a layout
                // decision took first byte from 3 seconds to 49, while Flash
                // makes the same choice in 3.5. Flash sees only this finished
                // explanation, never the screen, so it contributes no
                // reasoning and cannot contradict what was already said.
                //
                // Nothing awaits this. A slow or failed drawing pass costs the
                // student nothing; they simply get no picture.
                if budget.allowsBoard, !marks.whiteboard.hasContent {
                    diagramTask?.cancel()
                    let explanationForDrawing = spokenOnlyText
                    let indexForDrawing = screenIndex.renderForPrompt(maximumTargets: 40)
                    diagramTask = Task { [weak self] in
                        guard let self else { return }
                        guard let shape = await self.diagramComposer.diagram(
                            forExplanation: explanationForDrawing,
                            screenIndexListing: indexForDrawing
                        ) else { return }
                        guard isStillTheCurrentQuestion() else { return }
                        self.apply(
                            directive: TeacherDirective(
                                action: .drawDiagram(shape: shape),
                                characterOffsetInSpokenText: 0
                            )
                        )
                    }
                }
                conversation.remember(question: transcript, answer: spokenOnlyText)
                // Notebook hook: an answer without a drawing is a page of words.
                if !isGuideContinuation && questionKind != .chat {
                    notebookRecorder.holdTextLesson(question: transcript, spokenAnswer: spokenOnlyText,
                                                    answeredBy: lastAnsweringBrainName)
                }
                if questionKind != .chat {
                    fileLessonInMemory(question: transcript, lessonTitle: nil, spokenAnswer: spokenOnlyText,
                                       questionKind: questionKind)
                }

                print("🧠 Answered in \(String(format: "%.1f", duration))s, history \(conversation.exchanges.count) exchanges")
                }

            } catch let error where Self.isCancellation(error) || !isStillTheCurrentQuestion() {
                // User spoke again; the previous answer was abandoned on purpose.
                TutorDebugLog.write("🛑 answer cancelled (\(error.localizedDescription))")
            } catch {
                print("⚠️ Tutor response error: \(error.localizedDescription)")
                TutorDebugLog.write("⚠️ answer failed: \(error.localizedDescription)")
                await speakLocalErrorFallback(for: error, answerHadStarted: currentAnswerFormat != .undecided)
            }

            if isStillTheCurrentQuestion() {
                // Hold .responding while speech drains, so the overlay does not
                // drop back to idle while the tutor is still talking.
                while proseSpeech.isSpeaking || isAnyVoicePlaying {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if Task.isCancelled { break }
                }
                voiceState = .idle
                questionAwaitingAnswer = nil
                if currentAnswerFormat == .program {
                    // A drawing stays until the next question, Clear, Esc, or
                    // the content under it changing: it is the part worth
                    // looking at once the talking stops.
                    await lessonPlayer.waitUntilSpoken()
                    talkOverListener.stop()
                    controlBar.model.caption = ""
                    if guide.currentStep != nil, guide.baseline != nil, isStillTheCurrentQuestion() {
                        guide.watchCurrentStep()
                    }
                } else {
                    marks.scheduleDismissal()
                }
                scheduleTransientHideIfNeeded()
                // Notebook hook: finished and not cancelled, so it is kept.
                if isStillTheCurrentQuestion() { notebookRecorder.keepHeldLesson() }
            }
        }
    }

    /// Sends streamed text to the program player or the prose pipeline,
    /// deciding which on the first few characters.
    private func routeStreamedText(_ accumulatedText: String) {
        if currentAnswerFormat == .undecided, let isProgram = ProgramStream.looksLikeProgram(accumulatedText) {
            currentAnswerFormat = isProgram ? .program : .prose
            TutorDebugLog.write(isProgram ? "🖌️ answer is a drawing program" : "📝 answer is prose")
            logStage("first words from the model")
            if isProgram { voiceState = .responding }
        }
        switch currentAnswerFormat {
        case .program:
            lessonPlayer.feed(accumulatedText: accumulatedText)
        case .prose:
            proseSpeech.enqueueCompletedSentences(fromStreamedText: accumulatedText)
        case .undecided:
            break
        }
    }

    /// The question without a "hey Buddy" in front of it.
    ///
    /// Holding the keys is what starts listening, so the name is never
    /// needed, but people address an assistant by name out of habit, and the
    /// sorter and the model both do better on the question alone. The old
    /// name is stripped too, since the habit outlives the rename.
    static func questionWithoutGreeting(_ transcript: String) -> String {
        let pattern = #"^\s*(?:(?:hey|hi|hello|okay|ok|yo)[\s,]+)?(?:buddy|hey\s*clicky|clicky)\b[\s,.!?:;-]*"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return transcript
        }
        let range = NSRange(transcript.startIndex..., in: transcript)
        let stripped = expression.stringByReplacingMatches(in: transcript, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? transcript : stripped
    }

    /// A follow-up the tutor offered, asked as if the student had said it.
    func askFollowUp(_ question: String) {
        TutorDebugLog.write("👆 follow-up tapped: \(question)")
        // A tapped follow-up is a whole question of its own.
        questionAwaitingAnswer = nil
        shortcutReleasedAt = nil
        sendTranscriptToTutorWithScreenshot(transcript: question)
    }

    /// Plays the last answer again: the same audio and the same drawing, no
    /// model and no speech request. When the screen has changed since, the
    /// marks pinned to its content are left out and the cards are kept. Not
    /// a lesson: nothing is filed, counted or added to the conversation.
    /// False when there is no answer to replay.
    func replayLastAnswer(startedBy trigger: String) -> Bool {
        guard let recording = lessonPlayer.recordingOfLastAnswer() else {
            TutorDebugLog.write("🔁 replay (\(trigger)): no answer to play again yet")
            return false
        }
        TutorDebugLog.write("🔁 replaying the last answer (\(trigger)): \(recording.sentences.count) sentences, no model")
        stopGuide(reason: "replaying the last answer")
        questionAwaitingAnswer = nil
        cancelCurrentResponseTask()
        cancelSpeechAndClearQueue()
        transientHideTask?.cancel()
        transientHideTask = nil
        if !isOverlayVisible {
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
        currentResponseTask = Task { [weak self] in
            guard let self else { return }
            self.voiceState = .responding
            let screenOfTheAnswer = NSScreen.screens.first { screen in screen.frame == recording.displayFrame }
            var includeScreenMarks = false
            if screenOfTheAnswer != nil, let thumbnailThen = recording.screenThumbnail,
               let thumbnailNow = await GuideWatcher.captureThumbnail(of: recording.displayFrame) {
                let (changedCells, _) = GuideWatcher.changes(thumbnailThen, thumbnailNow)
                includeScreenMarks = changedCells < EarlyScreenCapture.changedCellsMeaningTheScreenMoved
                TutorDebugLog.write("🔁 replay: \(changedCells) cells changed since, \(includeScreenMarks ? "marks kept" : "marks left out")")
            }
            guard !Task.isCancelled, let screenForReplay = screenOfTheAnswer ?? NSScreen.main else {
                self.voiceState = .idle
                return
            }
            self.currentAnswerFormat = .program
            // Followed from before the program runs, so it hears of every anchor.
            if includeScreenMarks {
                self.markFollower.begin(displayFrame: recording.displayFrame, canvasSize: recording.canvasSize,
                                        targets: recording.targets, labels: recording.targetLabels, accessibilityItemIds: [])
            } else {
                self.markFollower.stop()
            }
            await self.lessonPlayer.replay(recording, on: screenForReplay, includeScreenMarks: includeScreenMarks)
            while self.proseSpeech.isSpeaking || self.isAnyVoicePlaying {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { break }
            }
            guard !Task.isCancelled else { return }
            self.voiceState = .idle
            await self.lessonPlayer.waitUntilSpoken()
            self.talkOverListener.stop()
            self.controlBar.model.caption = ""
            self.scheduleTransientHideIfNeeded()
        }
        return true
    }

    private struct FirstWordsDeadlineMissed: Error {}

    /// Runs an answer, giving up if no words have arrived by the deadline.
    /// Once words have arrived the answer runs to the end however long it takes.
    private func withFirstWordsDeadline<Answer: Sendable>(
        _ deadline: TimeInterval?,
        _ work: @escaping @MainActor () async throws -> Answer
    ) async throws -> Answer {
        guard let deadline else { return try await work() }
        return try await withThrowingTaskGroup(of: Answer?.self) { group in
            group.addTask { @MainActor in try await work() }
            group.addTask { @MainActor [weak self] in
                try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                if self?.currentAnswerFormat == .undecided { throw FirstWordsDeadlineMissed() }
                // Words are flowing: wait to be cancelled when the answer ends.
                while !Task.isCancelled { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
                return nil
            }
            defer { group.cancelAll() }
            while let finished = try await group.next() {
                if let answer = finished { return answer }
            }
            throw CancellationError()
        }
    }
    private static let longestSilenceInAStreamSeconds: TimeInterval = 20

    struct AnswerStreamStalled: LocalizedError {
        var errorDescription: String? { "the answer stopped arriving partway" }
    }

    /// Runs one attempt at an answer, and ends it once its stream has gone
    /// quiet for `longestSilenceInAStreamSeconds` after its first words: a
    /// connection lost mid-answer otherwise leaves the student with half an
    /// answer and a long silence. Before the first words the request's own
    /// idle timeout is what notices.
    private func withStallDetection<Answer: Sendable>(
        _ work: @escaping @MainActor () async throws -> Answer
    ) async throws -> Answer {
        lastStreamedTextAt = nil
        return try await withThrowingTaskGroup(of: Answer?.self) { group in
            group.addTask { @MainActor in try await work() }
            group.addTask { @MainActor [weak self] in
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if let lastStreamedTextAt = self?.lastStreamedTextAt,
                       Date().timeIntervalSince(lastStreamedTextAt) > Self.longestSilenceInAStreamSeconds {
                        throw AnswerStreamStalled()
                    }
                }
                return nil
            }
            defer { group.cancelAll() }
            while let finished = try await group.next() {
                if let answer = finished { return answer }
            }
            throw CancellationError()
        }
    }

    /// A network that went away, as opposed to a brain that refused.
    static func isLostConnection(_ error: Error) -> Bool {
        if error is AnswerStreamStalled { return true }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// The brain is busy rather than broken: Anthropic's 429 and 529 (or an
    /// overloaded error mid-stream) and Gemini's 429 or 503. Worth one more
    /// try when nobody else can answer.
    static func isBusyRefusal(_ error: Error) -> Bool {
        if let claudeError = error as? ClaudeError {
            switch claudeError {
            case .httpStatus(let code, _): return code == 429 || code == 529
            case .streamError(let message): return message.lowercased().contains("overloaded")
            default: return false
            }
        }
        if let geminiError = error as? GeminiError, case .httpStatus(let code, _) = geminiError {
            return code == 429 || code == 503
        }
        return false
    }

    /// Hands the finished lesson to memory, after it has been said: filing it
    /// costs a Haiku call the student never waits for.
    func fileLessonInMemory(question: String, lessonTitle: String?, spokenAnswer: String, questionKind: QuestionKind) {
        let lesson = LessonToRemember(
            question: question, lessonTitle: lessonTitle, spokenAnswer: spokenAnswer,
            questionKind: questionKind.tableName, answeredBy: lastAnsweringBrainName, date: Date())
        Task { [learningMemory] in await learningMemory.remember(lesson) }
    }

    /// Every say("...") in a drawing program, in order: the whole answer as
    /// heard, even while the voice is still partway through it.
    static func spokenSentences(inProgram program: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"say\(\s*"((?:[^"\\]|\\.)*)"\s*\)"#) else { return "" }
        let range = NSRange(program.startIndex..., in: program)
        return expression.matches(in: program, range: range).compactMap { match in
            Range(match.range(at: 1), in: program).map { String(program[$0]) }
        }.joined(separator: " ")
    }

    /// Waits for memory's choice until the same moment the question
    /// classifier was given up on, then falls back to names alone.
    func settleRecollections(
        recallTask: Task<[ConceptRecollection]?, Never>,
        question: String,
        screenContext: String,
        deadline: Date
    ) async -> [ConceptRecollection] {
        let remaining = max(0, deadline.timeIntervalSinceNow)
        let chosen: [ConceptRecollection]?? = await withTaskGroup(of: [ConceptRecollection]??.self) { group in
            group.addTask {
                await withTaskCancellationHandler { await recallTask.value } onCancel: { recallTask.cancel() }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                return .some(nil)
            }
            let first = await group.next() ?? .some(nil)
            group.cancelAll()
            return first
        }
        if let chosen, let recollections = chosen { return recollections }
        if remaining <= 0 || chosen == .some(nil) {
            TutorDebugLog.write("⌛ memory chooser late or unavailable, recalling by name")
        }
        return learningMemory.namesOnlyRecall(question: question, screenContext: screenContext)
    }

    /// Explains a failure out loud instead of leaving the user with silence.
    ///
    /// The common cause is the local server not running, which has a specific
    /// and actionable fix, so it gets its own message.
    func speakLocalErrorFallback(for error: Error, answerHadStarted: Bool = false) async {
        guard !Task.isCancelled, !Self.isCancellation(error) else { return }
        // Cut off partway: what was already said finishes, then one sentence
        // says why it stopped, instead of a probe and a guess at the cause.
        if answerHadStarted, Self.isLostConnection(error) {
            while proseSpeech.isSpeaking || isAnyVoicePlaying {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
            }
            InterfaceSounds.shared.play(.error)
            await speakFailure("i lost the connection partway through that answer, so ask me again in a moment.")
            return
        }
        InterfaceSounds.shared.play(.error)
        // Skipped in setup: say so plainly and reopen the permission steps,
        // rather than a generic failure the student cannot act on.
        if !hasScreenRecordingPermission || error.localizedDescription.contains("declined TCC") {
            TutorDebugLog.write("🔑 no Screen Recording permission, opening setup on it")
            setupWindow.show(startingAt: .permissions)
            await speakFailure("i can't see your screen yet. allow screen recording for buddy, then ask again. i've opened the steps.")
            return
        }
        if let problem = keyProblem(in: error) {
            reportKeyProblem(problem, answerFailed: true)
            await speakFailure("your \(problem.service.humanReadableName.lowercased()) key isn't working. i've opened setup so you can fix it.")
            return
        }
        let (isReachable, _) = await tutorBrain.probeServer()
        isLocalModelReachable = isReachable

        // Said per brain, because the fix differs completely: telling a cloud
        // user to start Ollama sends them after a server they are not using.
        let spokenExplanation: String
        switch (brainKind, isReachable) {
        case (.hosted, false) where usesVertexForArgon:
            spokenExplanation = "i can't reach the cloud model. your google cloud sign in has probably expired. run gcloud auth application default login in a terminal."
        case (.hosted, false):
            spokenExplanation = "i can't reach gemini. check your internet, or the gemini key in setup."
        case (.claude, false):
            spokenExplanation = "i can't reach claude. check your internet, or the anthropic key in setup."
        case (.auto, false):
            spokenExplanation = "i can't reach any of the models right now. check your internet, or your keys in setup."
        case (.local, false):
            spokenExplanation = "i can't reach the local model. start it by running brew services start ollama in a terminal."
        default:
            spokenExplanation = "something went wrong answering that. the details are in the clicky log."
        }

        await speakFailure(spokenExplanation)
    }

    private func speakFailure(_ explanation: String) async {
        voiceState = .responding
        try? await speechClient.speakText(explanation)
    }
}
