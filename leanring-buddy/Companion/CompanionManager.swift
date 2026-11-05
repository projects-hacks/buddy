//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//
//  This file holds the stored state, start and stop. What the manager does
//  is in the CompanionManager+*.swift files beside it, one responsibility
//  each, because an extension cannot hold stored properties.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published var voiceState: CompanionVoiceState = .idle
    @Published var lastTranscript: String?
    @Published var currentAudioPowerLevel: CGFloat = 0
    @Published var hasAccessibilityPermission = false
    @Published var hasScreenRecordingPermission = false
    @Published var hasMicrophonePermission = false
    @Published var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    /// Which brain answers. Persisted so the choice survives a restart.
    ///
    /// Defaults to Auto, which picks among Sonnet, Opus and Argon per
    /// question (ModelRouter). Local stays out of the default: it reasons
    /// well about what is on screen and invents technical facts that are not,
    /// naming three different wrong inventors for quicksort across three runs.
    @Published var brainKind: TutorBrainKind = TutorBrainKind(
        rawValue: UserDefaults.standard.string(forKey: "tutorBrainKind") ?? ""
    ) ?? .auto

    lazy var localBrain = OllamaVisionProvider(model: selectedModel)

    var hostedBrain = CompanionManager.makeHostedBrain()

    /// What the student is called, asked once in setup.
    @Published var studentName: String = UserDefaults.standard.string(forKey: "studentName") ?? ""

    /// A key that stopped working mid-use, shown in the notch until fixed.
    @Published var keyProblem: (service: APIKeyStore.Service, message: String)?

    /// The first-run setup, also opened from Settings and when a key fails.
    lazy var setupWindow = SetupWindowController(companionManager: self)

    // MARK: - Map of what you know (KnowledgeMapWindow.swift)

    lazy var knowledgeMapWindow: KnowledgeMapWindowController = {
        let controller = KnowledgeMapWindowController(
            learningMemory: learningMemory,
            askQuestion: { [weak self] question in self?.askTypedQuestion(question) },
            relationPassReply: { [claudeBrain = self.claudeBrain] message in
                guard APIKeyStore.hasKey(for: .anthropic) else { return nil }
                return await claudeBrain.conceptRelationPassReply(message: message)
            }
        )
        controller.onTeachBack = { [weak self] concept in self?.putTeachBackInChatBox(ideaName: concept.name) }
        // Notebook hook: a lesson in the Map's inspector opens its page.
        controller.onOpenLesson = { lessonTitle in
            NotebookWindowController.shared.show(pageTitled: lessonTitle)
        }
        return controller
    }()

    lazy var claudeBrain = ClaudeVisionProvider(model: "claude-sonnet-5-5")

    /// Sorts each question by meaning into the kind that decides who answers.
    let questionSorter = QuestionSorter()
    /// What the student has learned with Buddy across sessions.
    let learningMemory = LearningMemory()
    /// Keeps a downloaded Buddy current from GitHub releases.
    let appUpdater = AppUpdater()
    var updaterStateCancellable: AnyCancellable?
    /// How far up the hint ladder they are on each practice problem.
    let practiceHintLadder = PracticeHintLadder()

    /// Picks Sonnet, Opus or Argon per question under Auto, and Sonnet or
    /// Opus under Claude.
    let modelRouter = ModelRouter()

    /// The brain Auto picked for the answer in progress.
    var autoAnsweringBrain: RoutedBrain = .argon

    lazy var speechClient = LocalSpeechSynthesisClient()

    /// Neural voice, used when its helper process comes up.
    ///
    /// The machine has no premium or enhanced system voice installed, so every
    /// AVSpeechSynthesizer option is the compact tier and sounds plainly
    /// synthetic. This is the difference between a voice you can listen to for
    /// an hour of study and one you cannot.
    /// Hosted voice. Preferred when a key is present: measured 0.16s to first
    /// byte against Kokoro's 0.77s render, and it is a far better voice than
    /// any compact system one.
    lazy var deepgramClient = DeepgramSpeechClient()

    /// Which voice is in use this session, decided once at startup.
    enum VoiceEngine { case deepgram, kokoro, system }
    var voiceEngine: VoiceEngine = .system
    /// The prose path's Deepgram voice, benched for five minutes after a
    /// failure and then tried again, instead of the system voice for good.
    var deepgramProseVoiceBenchedUntil = Date.distantPast
    private var deepgramKeyRefusedObserver: NSObjectProtocol?

    lazy var kokoroClient = KokoroSpeechClient(
        helperScriptPath: Self.kokoroHelperScriptPath
    )

    /// Whether the neural voice is available this session. False falls back to
    /// the system voice, which is worse but always works.
    var isUsingNeuralVoice = false

    /// Draws the board on a fast model while the slow one explains.
    /// Only the older prose path uses it, and only on Vertex; with no
    /// project it simply draws nothing.
    lazy var diagramComposer = DiagramComposer(
        projectIdentifier: Self.hostedProjectIdentifier ?? ""
    )

    /// The in-flight drawing pass, cancelled when a new question arrives.
    var diagramTask: Task<Void, Never>?

    /// Inventory of what is addressable on screen for the current turn.
    ///
    /// Rebuilt per question rather than cached, because the screen has usually
    /// changed between one question and the next.
    /// Replaced by the index read while the student talked, when that one
    /// is still current at release (EarlyScreenCapture).
    var screenIndex = ScreenIndex()

    /// Marks currently drawn on screen.
    @Published var activeAnnotations: [TeacherAnnotation] = []

    /// Regions kept lit while the rest of the screen dims. Empty means no spotlight.
    @Published var spotlightRectsInGlobalPoints: [CGRect] = []

    /// How much of the answer has been spoken, 0 to 1.
    ///
    /// The board is drawn up to this point. Screen marks already fire from
    /// per-word callbacks, but the diagram arrives as one shape from the
    /// second pass, so without this it would appear complete in an instant
    /// while the explanation is still in its first sentence.
    @Published var boardRevealFraction: Double = 0

    /// Characters spoken so far across every segment of this answer.
    var charactersSpokenInAnswer = 0

    /// Length of the whole answer, known once the stream completes.
    var totalCharactersInAnswer = 0

    /// The scratch board the tutor draws on while explaining. Built up as it
    /// speaks, so the picture assembles in the order it is described.
    @Published var whiteboard = TutorWhiteboard()

    /// Whether the local model server was reachable at last check, so the
    /// panel can say "start Ollama" instead of failing mid-question.
    @Published var isLocalModelReachable = true {
        didSet { if !isLocalModelReachable { brainKindKnownReachable = nil } }
    }
    /// The brain a probe last found answering, so the periodic probe stops
    /// once it is known and starts again when the brain changes or fails.
    var brainKindKnownReachable: TutorBrainKind?
    var isProbingBrain = false

    /// What was asked and answered this session, and how often running the
    /// student has said an answer did not land (ConversationHistory.swift).
    var conversation = ConversationHistory()

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    var currentResponseTask: Task<Void, Never>?
    /// Which question is being answered. Bumped whenever the answer is
    /// cancelled or replaced, and checked by the answer after every wait, so
    /// an answer that was replaced never writes history, memory, how-tos,
    /// guide steps or notebook pages for a question nobody is asking now.
    var currentQuestionTicket = 0

    var shortcutTransitionCancellable: AnyCancellable?
    var typeQuestionCancellable: AnyCancellable?
    var voiceStateCancellable: AnyCancellable?
    var audioPowerCancellable: AnyCancellable?
    var accessibilityCheckTimer: Timer?
    var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode, cancelled if the user
    /// speaks again before the delay elapses.
    var transientHideTask: Task<Void, Never>?

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published var isOverlayVisible: Bool = false

    /// Local model used for voice responses. Persisted to UserDefaults.
    ///
    /// Defaults to the 4B after measuring all three candidates on this class of
    /// machine. It is the only one that generates faster than speech plays back,
    /// which is what keeps the voice loop from stalling mid-sentence, and the
    /// only one that stays resident on 16 GB without forcing the system to swap.
    /// See docs/model-choice.md for the numbers.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedLocalModel") ?? "qwen3.5:4b"

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func start() {
        refreshAllPermissions()
        TutorDebugLog.write("🔑 at launch, accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindMarkLifetime()
        observeSystemEvents()
        deepgramKeyRefusedObserver = NotificationCenter.default.addObserver(
            forName: .deepgramKeyRefused, object: nil, queue: .main
        ) { [weak self] notification in
            guard let error = notification.object as? Error else { return }
            MainActor.assumeIsolated { self?.reportDeepgramKeyProblem(error) }
        }
        InterfaceSounds.shared.prepare()
        configureLearningMemory()
        connectNotebook(recorder: notebookRecorder) // Notebook hook
        #if DEBUG
        qaHooks.start()
        #endif
        controlBar.model.onFixKeys = { [weak self] in self?.setupWindow.show(startingAt: .keys) }
        controlBar.model.onAllowPermission = { [weak self] in self?.setupWindow.show(startingAt: .permissions) }
        controlBar.model.onReplayLastAnswer = { [weak self] in _ = self?.replayLastAnswer(startedBy: "Replay in the notch") }
        controlBar.model.onOpenKnowledgeMap = { [weak self] ideaName in self?.openKnowledgeMap(focusingIdeaNamed: ideaName) }
        // Notebook hook: the tab row's Notebook, the card's Open in Notebook
        // and the start tile for the last study day.
        controlBar.model.onOpenNotebook = { dayIdentifier in
            NotebookWindowController.shared.show(dayIdentifier: dayIdentifier)
        }
        connectNotebookWindowButtons()
        controlBar.model.onRefreshHomeSuggestions = { [weak self] in self?.refreshNotchHomeSuggestions() }
        controlBar.model.onExplainError = { [weak self] in self?.errorOffer.studentChoseExplain() }
        controlBar.model.onDismissError = { [weak self] in self?.errorOffer.studentChoseNotNow() }
        // Lecture mode hook: the notch shows whenever the front app's sound
        // is being kept.
        LectureMode.shared.onKeepingSoundChanged = { [weak self] isKeeping in
            self?.controlBar.model.isKeepingLectureSound = isKeeping
        }
        bindUpdater()
        errorOffer.start() // Hook for ErrorOffer.swift.
        if needsSetup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.setupWindow.show(startingAt: .welcome)
            }
        }
        Task {
            await questionSorter.prepare()
            // After the sorter, whose sentence model memory shares.
            await learningMemory.load()
            await learningMemory.embedMissingVectorsInBackground()
        }
        // Load the weights now rather than on the first question. A cold load
        // costs around ten seconds, which would otherwise land entirely inside
        // the user's first interaction and read as the app being broken.
        Task {
            let (isReachable, installedModels) = await tutorBrain.probeServer()
            isLocalModelReachable = isReachable
            TutorDebugLog.write("🧠 brain: \(brainKind.displayName), \(isReachable ? "ready" : "UNREACHABLE")")

            guard isReachable else {
                print("⚠️ Ollama unreachable. Start it with: brew services start ollama")
                return
            }

            // Fall back to any installed vision model rather than failing
            // outright, since a missing pull is a likelier setup mistake than
            // a missing server.
            if !installedModels.contains(where: { $0.hasPrefix(selectedModel) }) {
                print("⚠️ Model \(selectedModel) not installed. Available: \(installedModels.joined(separator: ", "))")
                if let firstAvailable = installedModels.first {
                    selectedModel = firstAvailable
                    localBrain.model = firstAvailable
                    print("🦙 Falling back to \(firstAvailable)")
                }
            }

            await tutorBrain.preloadModel()
            print("🦙 Local tutor ready: \(selectedModel)")
        }

        // Brought up alongside the model, because its first generation would
        // otherwise pay the model load inside the user's first answer.
        Task {
            // Ordered by quality. Deepgram first because it is both the best
            // voice and the fastest to first audio; Kokoro next because it
            // needs no network; the system voice last because every installed
            // one here is the compact tier and sounds it.
            if deepgramClient.isConfigured {
                voiceEngine = .deepgram
                TutorDebugLog.write("🔊 voice: Deepgram \(deepgramClient.voiceName)")
            } else if await kokoroClient.start() {
                voiceEngine = .kokoro
                isUsingNeuralVoice = true
            } else {
                voiceEngine = .system
                TutorDebugLog.write("🔈 no neural voice available, using the system voice")
            }
        }

        // If all permissions are still granted, show the cursor overlay
        // immediately. If permissions were revoked (e.g. signing change),
        // don't show the cursor, the panel will show the permissions UI instead.
        if allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    func stop() {
        systemEventsObserver?.stopObserving()
        kokoroClient.shutDown()
        deepgramClient.shutDown()
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        cancelCurrentResponseTask()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        typeQuestionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published var isRequestingScreenContent = false

    var pendingTalkStart: Task<Void, Never>?
    /// The screen read while the keys are held, for the question they end in.
    let earlyScreenCapture = EarlyScreenCapture()
    /// Where the pointer rested while the keys were held, and the rests of
    /// the press just ended, until its question claims them.
    let pointerRestWatcher = PointerRestWatcher()
    var pointerRestsOfLastPress: [PointerRest] = []
    /// Listens while an answer plays, for the student talking over it.
    lazy var talkOverListener: TalkOverListener = {
        let listener = TalkOverListener()
        listener.recentlySpokenSentences = { [weak self] in self?.lessonPlayer.recentlySpokenSentences ?? [] }
        listener.onRequest = { [weak self] request in self?.handleTalkOver(request) }
        listener.onListeningChanged = { [weak self] isListening in
            guard let model = self?.controlBar.model else { return }
            model.isListeningWhileExplaining = isListening
            if !isListening {
                model.talkOverPause = nil
                model.talkOverHeardWords = ""
            }
        }
        listener.onWordsHeardWhileCuttingIn = { [weak self] words in
            self?.controlBar.model.talkOverHeardWords = words
        }
        return listener
    }()
    /// Paused by "hold on", as against paused while a question is heard.
    var isHeldByTalkOver = false
    var talkOverHoldTimeout: Task<Void, Never>?
    /// The question the current answer is for, for an answer cut off.
    var questionBeingAnswered: String?
    /// The last question, until its answer starts to be heard. A question
    /// asked before then continues it rather than replacing it.
    var questionAwaitingAnswer: (text: String, askedAt: Date)?

    // MARK: - Tutor Response Pipeline

    /// How much of the streamed response has already been handed to speech.
    var streamedCharactersAlreadyQueued = 0

    /// Complete sentences waiting to be spoken, in order.
    var pendingSpeechSegments: [ParsedTeacherResponse] = []

    /// Consumer draining `pendingSpeechSegments`, nil when nothing is speaking.
    var speechConsumerTask: Task<Void, Never>?
    /// Which consumer the handle above belongs to. A cancelled consumer can
    /// still be unwinding when the next one starts, and when it ends it must
    /// clear only its own handle, never the new consumer's.
    var currentSpeechConsumerIdentifier: UUID?

    /// The display the current answer is marking up.
    var displayFrameForCurrentAnswer: CGRect = .zero

    /// Clears the board and marks once the answer has had time to be read.
    var markDismissalTask: Task<Void, Never>?

    /// The strip at the bottom while the tutor talks or has drawn: the
    /// sentence being said, the follow-ups it offered, Stop and Clear.
    lazy var controlBar = TutorControlBarController(
        onAsk: { [weak self] question in self?.askFollowUp(question) },
        onAskTyped: { [weak self] question in self?.askTypedQuestion(question) },
        onStop: { [weak self] in self?.stopAnswering() },
        onClear: { [weak self] in
            if self?.clearAnnotations() == true { InterfaceSounds.shared.play(.wipe) }
        },
        settingsView: { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(CompanionPanelView(companionManager: self, isEmbedded: true))
        }
    )
    /// The latest Dock-click opening; a newer click restarts its clock.
    var briefOpenTask: Task<Void, Never>?
    var controlBarDrawingCancellable: AnyCancellable?
    var notchActivityCancellable: AnyCancellable?
    var notchHeardWordsCancellable: AnyCancellable?

    /// When the keys were let go and when this answer began, for the stage
    /// timings in the log: the only latency the student feels is from the
    /// first to the first spoken word.
    var shortcutReleasedAt: Date?
    var answerStartedAt = Date()

    /// Where drawing programs are drawn, who speaks them, and what ties the two.
    lazy var drawingOverlay = DrawingOverlay()
    // Notebook hook: keeps each finished lesson as a notebook page.
    lazy var notebookRecorder = NotebookRecorder(drawingOverlay: drawingOverlay)
    lazy var narrationVoice: NarrationVoice = {
        let voice = NarrationVoice(fallbackVoice: speechClient)
        voice.onDeepgramKeyProblem = { [weak self] error in self?.reportDeepgramKeyProblem(error) }
        voice.onDeepgramWorked = { [weak self] in self?.clearDeepgramKeyProblemIfReported() }
        return voice
    }()
    /// Keeps an answer's marks on the things they mark as windows move and
    /// pages scroll (MarkFollower.swift).
    lazy var markFollower: MarkFollower = {
        let follower = MarkFollower()
        follower.placeAnchors = { [weak self] placements, animate in
            self?.lessonPlayer.placeAnchors(placements, animate: animate)
        }
        return follower
    }()

    lazy var lessonPlayer: LessonProgramPlayer = {
        let player = LessonProgramPlayer(overlay: drawingOverlay, voice: narrationVoice, bar: controlBar.model)
        player.onAnchorsChanged = { [weak self] anchorIds in self?.markFollower.anchorsNow(anchorIds) }
        player.onFirstSentenceReady = { [weak self] in
            self?.logStage("first sentence ready for the voice")
        }
        player.onFirstSentenceHeard = { [weak self] in
            self?.logStage("first sentence heard")
            self?.questionAwaitingAnswer = nil
            // Only while an answer plays, and never while the keys are held.
            if self?.buddyDictationManager.isDictationInProgress == false { self?.talkOverListener.start() }
            self?.controlBar.model.canReplayLastAnswer = true
        }
        return player
    }()

    // MARK: Teaching board hook (TeachingBoardSession.swift)

    /// "Teach me X from scratch": the lesson on a full-screen board, over
    /// several turns. Shares the overlay, voice and player with every answer.
    lazy var teachingBoard: TeachingBoardSession = {
        var hooks = TeachingBoardSession.Hooks(answer: { [weak self] systemPrompt, history, turnNote, maximumTokens, progress, onTextChunk in
            guard let self else { throw CancellationError() }
            return try await self.answerTeachingBoardTurn(
                systemPrompt: systemPrompt, history: history, turnNote: turnNote,
                maximumTokens: maximumTokens, progress: progress, onTextChunk: onTextChunk)
        })
        hooks.setVoiceState = { [weak self] state in self?.voiceState = state }
        hooks.clearScreenBeforeOpening = { [weak self] in self?.clearAnnotations() }
        hooks.fileLesson = { [weak self] question, lessonTitle, spokenAnswer in
            self?.fileLessonInMemory(question: question, lessonTitle: lessonTitle, spokenAnswer: spokenAnswer, questionKind: .teach)
        }
        hooks.rememberExchange = { [weak self] question, answer in self?.conversation.remember(question: question, answer: answer) }
        hooks.questionNeedsNoAnswer = { [weak self] in self?.questionAwaitingAnswer = nil }
        hooks.reportFailure = { [weak self] error in await self?.speakLocalErrorFallback(for: error) }
        // The same recall as a normal question, inside the same one-second
        // wait, so the board builds on what the student already knows.
        hooks.studyNotes = { [weak self] question in
            guard let self, self.learningMemory.isEnabled else { return [] }
            let startedAt = Date()
            let recallTask = self.learningMemory.startRecall(
                question: question, windowTitle: nil, questionVector: self.questionSorter.sentenceVector(for: question))
            let recollections = await self.settleRecollections(
                recallTask: recallTask, question: question, screenContext: "",
                deadline: startedAt.addingTimeInterval(Self.memoryChooserFloorSeconds))
            self.controlBar.model.buildsOn = recollections.map(\.concept.name)
            return [LearningMemory.promptNote(for: recollections)]
        }
        hooks.turnFinished = { [weak self] in
            self?.questionAwaitingAnswer = nil
            self?.scheduleTransientHideIfNeeded()
        }
        // Teach it back hooks (TeachBackSession.swift).
        hooks.lastLessonTitle = { [weak self] in self?.controlBar.model.transcript.last(where: { $0.lessonTitle != nil })?.lessonTitle }
        hooks.keytermsForTopic = { [weak self] topic in
            guard let self else { return [topic] }
            // The topic, the ideas memory holds near it, then recent ones.
            let related = self.learningMemory.isEnabled
                ? self.learningMemory.namesOnlyRecall(question: topic, screenContext: "").map(\.concept.name) : []
            var terms = [topic] + related + self.learningMemory.recentlyExplainedConceptNames(limit: 15)
            var seen = Set<String>()
            terms = terms.filter { seen.insert($0.lowercased()).inserted }
            return Array(terms.prefix(30))
        }
        hooks.prepareForListening = { [weak self] in
            self?.talkOverListener.stop()
            self?.cancelSpeechAndClearQueue()
        }
        hooks.askAsStudent = { [weak self] question in self?.askFollowUp(question) }
        hooks.recordTeachBack = { [weak self] record in
            guard let self, self.learningMemory.isEnabled else { return }
            let lesson = LessonToRemember(
                question: record.openingQuestion, lessonTitle: TeachBackPrompt.boardTitle(topic: record.topic),
                spokenAnswer: record.spokenAnswer, questionKind: "teach-back",
                answeredBy: self.lastAnsweringBrainName, date: Date())
            Task { [learningMemory] in
                await learningMemory.recordTeachBack(lesson, topic: record.topic,
                                                     rightIdeas: record.rightIdeas, missedIdeas: record.missedIdeas)
            }
        }
        // Notebook hook: the board kept as one page when it is left.
        hooks.keepBoardInNotebook = { [weak self] question, title, paragraphs in
            self?.notebookRecorder.keepBoard(question: question, lessonTitle: title, paragraphs: paragraphs)
        }
        return TeachingBoardSession(overlay: drawingOverlay, player: lessonPlayer, bar: controlBar.model, hooks: hooks)
    }()

    /// Whether this answer is a drawing program or plain prose. Decided from
    /// its first characters: a model that ignores the format still gets
    /// spoken, through the older tag pipeline.
    enum AnswerFormat { case undecided, program, prose }
    var currentAnswerFormat: AnswerFormat = .undecided
    var escapeKeyMonitor: Any?
    var scrollWheelMonitor: Any?
    var applicationSwitchObserver: NSObjectProtocol?

    // MARK: - Sleep, wake and displays (SystemEventsObserver.swift)

    var systemEventsObserver: SystemEventsObserver?

    /// When the answer's stream last delivered text, for noticing a stream
    /// that stopped partway: nil until its first words.
    var lastStreamedTextAt: Date?

    /// Who answered the last question, for the push-back log line.
    var lastAnsweringBrainName = "nobody"

    var currentPracticeProblem: PracticeProblem?

    // Guide mode (GuideMode.swift): a task in an app, one step at a time.
    var currentGuideStep: GuideStep?
    var guideStepsGiven = 0
    /// The screen the current step was given against, for the watcher.
    var guideBaseline: (imageData: Data, displayFrame: CGRect)?
    /// The app the guide started in, kept for the whole task.
    var guidedApplication: NSRunningApplication?
    /// Where the screen changed when the last step looked done.
    var guideChangedRegion: CGRect?
    lazy var guideWatcher: GuideWatcher = {
        let watcher = GuideWatcher()
        watcher.onStepLooksDone = { [weak self] changedRegion in self?.continueGuide(changedRegion: changedRegion) }
        return watcher
    }()

    // How-tos (HowToMemory.swift): finished guides, replayed with no model.
    lazy var howToMemory: HowToMemory = {
        let memory = HowToMemory()
        memory.writeCues = { [weak self] howTo in await self?.claudeBrain.howToCues(howTo) }
        return memory
    }()

    // Hook for ErrorOffer.swift ("explain this error?"): offers to explain an
    // error that just appeared, with no model call until the student accepts.
    // Accepting sends an ordinary question, so the normal pipeline answers.
    lazy var errorOffer: ErrorOfferController = {
        let offer = ErrorOfferController()
        offer.isBuddyBusy = { [weak self] in
            guard let self else { return true }
            return self.voiceState != .idle || self.controlBar.model.activity != .ready
                || self.buddyDictationManager.isDictationInProgress || self.isAnyVoicePlaying
                || self.currentGuideStep != nil || self.guideWatcher.isWatching || self.currentReplay != nil
        }
        offer.isDictationInProgress = { [weak self] in self?.buddyDictationManager.isDictationInProgress ?? false }
        offer.notchShapeSize = { [weak self] in self?.controlBar.model.laidOutShapeSize ?? .zero }
        offer.isNotchOpen = { [weak self] in self?.controlBar.model.isExpanded ?? false }
        offer.onOfferChanged = { [weak self] notchOffer in self?.controlBar.model.errorOffer = notchOffer }
        offer.onExplainRequested = { [weak self] question in self?.askTypedQuestion(question) }
        return offer
    }()

    /// A saved how-to being replayed: which step comes next, and the
    /// question that started it.
    var currentReplay: (howTo: HowTo, nextStepIndex: Int, question: String)?

    /// Which try at the current answer is live. A brain given up on at its
    /// deadline may still deliver words while it unwinds; they are dropped.
    var currentAnswerAttempt = 0

    #if DEBUG
    private lazy var qaHooks = QAHooks(companionManager: self)
    #endif
}
