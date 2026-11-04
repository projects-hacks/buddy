//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
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
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Which brain answers. Persisted so the choice survives a restart.
    ///
    /// Defaults to Auto, which picks among Sonnet, Opus and Argon per
    /// question (ModelRouter). Local stays out of the default: it reasons
    /// well about what is on screen and invents technical facts that are not,
    /// naming three different wrong inventors for quicksort across three runs.
    @Published private(set) var brainKind: TutorBrainKind = TutorBrainKind(
        rawValue: UserDefaults.standard.string(forKey: "tutorBrainKind") ?? ""
    ) ?? .auto

    private lazy var localBrain = OllamaVisionProvider(model: selectedModel)
    /// A Google Cloud project to bill Argon against through Vertex, for
    /// anyone set up with gcloud (`defaults write com.maverickrajeev.clicky-local
    /// vertexProjectIdentifier <project>`). Vertex rather than AI Studio when
    /// both exist, because only Vertex draws on a project's credits. Nobody
    /// else's project is ever assumed: without one, Argon uses a Gemini key.
    private static var hostedProjectIdentifier: String? {
        UserDefaults.standard.string(forKey: "vertexProjectIdentifier").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// How Argon is reached: a Gemini API key from AI Studio, or a Google
    /// Cloud project through gcloud. Chosen in setup; before any choice,
    /// Google Cloud when a project is set, the key otherwise.
    enum ArgonSource: String { case apiKey, googleCloud }

    static var argonSource: ArgonSource {
        if let saved = UserDefaults.standard.string(forKey: "argonSource").flatMap(ArgonSource.init(rawValue:)) {
            return saved
        }
        return hostedProjectIdentifier != nil ? .googleCloud : .apiKey
    }

    var argonSource: ArgonSource { Self.argonSource }
    var vertexProjectIdentifier: String { Self.hostedProjectIdentifier ?? "" }

    func setArgonSource(_ source: ArgonSource, projectIdentifier: String? = nil) {
        UserDefaults.standard.set(source.rawValue, forKey: "argonSource")
        if let projectIdentifier {
            let trimmed = projectIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: "vertexProjectIdentifier")
        }
        objectWillChange.send()
        keysDidChange()
    }

    /// Whether Argon can be reached through a Google Cloud project: gcloud is
    /// installed and signed in, so an access token can be minted for it.
    func checkGoogleCloud(projectIdentifier: String) async -> KeyCheckResult {
        let trimmed = projectIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected("Type the project ID, as shown in the Google Cloud console.") }
        let provider = GeminiVisionProvider(model: "gemini-4-argon", endpoint: .vertex(projectIdentifier: trimmed, location: "global"))
        let token: String
        do {
            token = try await provider.vertexAccessToken()
        } catch {
            return .rejected("gcloud isn't installed or isn't signed in. Install the Google Cloud CLI, then run: gcloud auth application-default login")
        }
        // A token proves the sign-in, not the project: a one-word request
        // proves the project exists, has Vertex on, and can use Argon.
        guard let url = URL(string: "https://aiplatform.googleapis.com/v1/projects/\(trimmed)/locations/global/publishers/google/models/gemini-4-argon:generateContent") else {
            return .rejected("That project ID has characters a Google Cloud project ID can't have.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": [["text": "hi"]]]],
            "generationConfig": ["maxOutputTokens": 8, "thinkingConfig": ["thinkingLevel": "LOW"]]
        ])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? -1 {
            case 200...299:
                return .worksWithNote("Works. Argon will bill \(trimmed) through Vertex.")
            case 403:
                return .rejected("Your Google account can't use Vertex on \(trimmed). Enable the Vertex AI API on the project, or check you have access to it.")
            case 404:
                return .rejected("Google can't find \(trimmed), or Gemini 4 Argon isn't available on it. Check the project ID in the Google Cloud console.")
            case 429:
                return .worksWithNote("Works, but \(trimmed) is at its quota right now, so answers may be slow for a moment.")
            case let status:
                return .rejected("Google Cloud said HTTP \(status) for \(trimmed).")
            }
        } catch {
            return .couldNotCheck("Couldn't reach Google Cloud. Check the internet connection, then try again.")
        }
    }

    private static func makeHostedBrain() -> GeminiVisionProvider {
        if argonSource == .googleCloud, let project = hostedProjectIdentifier {
            return GeminiVisionProvider(model: "gemini-4-argon", endpoint: .vertex(projectIdentifier: project, location: "global"))
        }
        return GeminiVisionProvider(model: "gemini-4-argon", endpoint: .aiStudio)
    }

    private var hostedBrain = CompanionManager.makeHostedBrain()

    /// Claude can answer: an Anthropic key is saved.
    var canUseClaude: Bool { APIKeyStore.hasKey(for: .anthropic) }
    /// Argon can answer: a Gemini key, or a Vertex project.
    var canUseArgon: Bool {
        argonSource == .googleCloud ? Self.hostedProjectIdentifier != nil : APIKeyStore.hasKey(for: .gemini)
    }
    var usesVertexForArgon: Bool { argonSource == .googleCloud && Self.hostedProjectIdentifier != nil }

    /// What the student is called, asked once in setup.
    @Published private(set) var studentName: String = UserDefaults.standard.string(forKey: "studentName") ?? ""

    func setStudentName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        studentName = trimmed
        UserDefaults.standard.set(trimmed, forKey: "studentName")
    }

    /// A key that stopped working mid-use, shown in the notch until fixed.
    @Published var keyProblem: (service: APIKeyStore.Service, message: String)?

    /// Called after setup saves or removes a key, so the next question uses it.
    func keysDidChange() {
        hostedBrain = Self.makeHostedBrain()
        keyProblem = nil
        controlBar.model.keyProblemMessage = nil
        isLocalModelReachable = true
        Task {
            let (isReachable, _) = await tutorBrain.probeServer()
            isLocalModelReachable = isReachable
        }
    }

    /// The first-run setup, also opened from Settings and when a key fails.
    lazy var setupWindow = SetupWindowController(companionManager: self)

    var needsSetup: Bool {
        let hasFinishedSetup = UserDefaults.standard.bool(forKey: "hasFinishedSetup")
        let hasSomethingToThinkWith = canUseClaude || canUseArgon || brainKind == .local
        return !hasFinishedSetup || !hasSomethingToThinkWith
    }

    func finishSetup() {
        UserDefaults.standard.set(true, forKey: "hasFinishedSetup")
        keysDidChange()
    }

    /// Records a key that failed during use: opens setup on it when the
    /// question could not be answered at all, and otherwise just says so in
    /// the notch, since another brain covered for it.
    /// The key problem in an error, worded for how Argon is reached: on Google
    /// Cloud there is no Gemini key, so the fix is the project, not a key.
    private func keyProblem(in error: Error) -> (service: APIKeyStore.Service, message: String)? {
        guard let problem = APIKeyChecker.problem(in: error) else { return nil }
        if problem.service == .gemini, usesVertexForArgon {
            return (.gemini, "Argon couldn't use the Google Cloud project \(vertexProjectIdentifier). Check that Vertex is enabled on it and gcloud is signed in.")
        }
        return problem
    }

    private func reportKeyProblem(_ problem: (service: APIKeyStore.Service, message: String), answerFailed: Bool) {
        TutorDebugLog.write("🔑 \(problem.service.humanReadableName) key problem: \(problem.message)")
        keyProblem = problem
        let label = problem.service == .gemini && usesVertexForArgon ? "Google Cloud" : "\(problem.service.humanReadableName) key"
        controlBar.model.keyProblemMessage = "\(label): \(problem.message)"
        if answerFailed { setupWindow.show(startingAt: .keys) }
    }

    private lazy var claudeBrain = ClaudeVisionProvider(model: "claude-sonnet-5-5")

    /// Sorts each question by meaning into the kind that decides who answers.
    private let questionSorter = QuestionSorter()
    /// What the student has learned with Buddy across sessions.
    let learningMemory = LearningMemory()
    /// Keeps a downloaded Buddy current from GitHub releases.
    let appUpdater = AppUpdater()
    private var updaterStateCancellable: AnyCancellable?
    /// How far up the hint ladder they are on each practice problem.
    private let practiceHintLadder = PracticeHintLadder()

    /// Picks Sonnet, Opus or Argon per question under Auto, and Sonnet or
    /// Opus under Claude.
    private let modelRouter = ModelRouter()

    /// The brain Auto picked for the answer in progress.
    private var autoAnsweringBrain: RoutedBrain = .argon

    /// The brain in use. All conform to the same protocol, so nothing
    /// downstream of here knows or cares which one answered.
    private var tutorBrain: TutorBrain {
        switch brainKind {
        case .local: return localBrain
        case .hosted: return hostedBrain
        case .claude: return claudeBrain
        // At rest, before any question is routed, Auto points at a brain that
        // is set up: probing an unconfigured one fails every few seconds.
        case .auto:
            if autoAnsweringBrain == .argon, canUseArgon || !canUseClaude { return hostedBrain }
            return canUseClaude ? claudeBrain : hostedBrain
        }
    }

    /// Switches brain and gets the new one ready.
    ///
    /// Refuses to switch to the hosted brain without a key rather than failing
    /// on the next question, since the fix is in the panel the user is already
    /// looking at.
    func setBrainKind(_ kind: TutorBrainKind) {
        // No key check for the hosted brain: on Vertex it authenticates with a
        // gcloud access token, not a stored key, so requiring one here would
        // lock out the very path that bills against the project's credits.
        // probeServer reports unreachable if the credential is bad.

        brainKind = kind
        UserDefaults.standard.set(kind.rawValue, forKey: "tutorBrainKind")
        TutorDebugLog.write("🧠 brain switched to \(kind.displayName)")

        Task {
            let (isReachable, _) = await tutorBrain.probeServer()
            isLocalModelReachable = isReachable
            if isReachable { await tutorBrain.preloadModel() }
        }
    }

    /// Saves a hosted API key and switches to it if it works.
    func saveHostedAPIKey(_ key: String) {
        guard APIKeyStore.save(key: key, for: .gemini) else { return }
        setBrainKind(.hosted)
    }

    var hasHostedAPIKey: Bool { APIKeyStore.hasKey(for: .gemini) }

    private lazy var speechClient = LocalSpeechSynthesisClient()

    /// Neural voice, used when its helper process comes up.
    ///
    /// The machine has no premium or enhanced system voice installed, so every
    /// AVSpeechSynthesizer option is the compact tier and sounds plainly
    /// synthetic. This is the difference between a voice you can listen to for
    /// an hour of study and one you cannot.
    /// Hosted voice. Preferred when a key is present: measured 0.16s to first
    /// byte against Kokoro's 0.77s render, and it is a far better voice than
    /// any compact system one.
    private lazy var deepgramClient = DeepgramSpeechClient()

    /// Which voice is in use this session, decided once at startup.
    private enum VoiceEngine { case deepgram, kokoro, system }
    private var voiceEngine: VoiceEngine = .system

    private lazy var kokoroClient = KokoroSpeechClient(
        helperScriptPath: Self.kokoroHelperScriptPath
    )

    /// Whether the neural voice is available this session. False falls back to
    /// the system voice, which is worse but always works.
    private var isUsingNeuralVoice = false

    /// Location of the speech helper.
    ///
    /// Overridable through defaults so the script can be moved without a
    /// rebuild, defaulting to its place in the checkout.
    private static var kokoroHelperScriptPath: String {
        if let overridePath = UserDefaults.standard.string(forKey: "kokoroHelperScriptPath") {
            return overridePath
        }
        return "\(NSHomeDirectory())/Documents/projects/clicky-local/scripts/kokoro_speech_server.py"
    }

    /// Draws the board on a fast model while the slow one explains.
    /// Only the older prose path uses it, and only on Vertex; with no
    /// project it simply draws nothing.
    private lazy var diagramComposer = DiagramComposer(
        projectIdentifier: Self.hostedProjectIdentifier ?? ""
    )

    /// The in-flight drawing pass, cancelled when a new question arrives.
    private var diagramTask: Task<Void, Never>?

    /// Inventory of what is addressable on screen for the current turn.
    ///
    /// Rebuilt per question rather than cached, because the screen has usually
    /// changed between one question and the next.
    private let screenIndex = ScreenIndex()

    /// Marks currently drawn on screen.
    @Published private(set) var activeAnnotations: [TeacherAnnotation] = []

    /// Regions kept lit while the rest of the screen dims. Empty means no spotlight.
    @Published private(set) var spotlightRectsInGlobalPoints: [CGRect] = []

    /// How much of the answer has been spoken, 0 to 1.
    ///
    /// The board is drawn up to this point. Screen marks already fire from
    /// per-word callbacks, but the diagram arrives as one shape from the
    /// second pass, so without this it would appear complete in an instant
    /// while the explanation is still in its first sentence.
    @Published private(set) var boardRevealFraction: Double = 0

    /// Characters spoken so far across every segment of this answer.
    private var charactersSpokenInAnswer = 0

    /// Length of the whole answer, known once the stream completes.
    private var totalCharactersInAnswer = 0

    /// The scratch board the tutor draws on while explaining. Built up as it
    /// speaks, so the picture assembles in the order it is described.
    @Published private(set) var whiteboard = TutorWhiteboard()

    /// Whether the local model server was reachable at last check, so the
    /// panel can say "start Ollama" instead of failing mid-question.
    @Published private(set) var isLocalModelReachable = true

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode, cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// Local model used for voice responses. Persisted to UserDefaults.
    ///
    /// Defaults to the 4B after measuring all three candidates on this class of
    /// machine. It is the only one that generates faster than speech plays back,
    /// which is what keeps the voice loop from stalling mid-sentence, and the
    /// only one that stays resident on 16 GB without forcing the system to swap.
    /// See docs/model-choice.md for the numbers.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedLocalModel") ?? "qwen3.5:4b"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedLocalModel")
        localBrain.model = model
        Task { await tutorBrain.preloadModel() }
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    ///
    /// Always true in this app. Upstream's onboarding was its author's video,
    /// music and an email sign-up for a public release; none of it applies to
    /// a study helper that runs for one person, and the only setup that
    /// matters, the four permissions, is checked separately.
    var hasCompletedOnboarding: Bool {
        get { true }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Lessons from today's conversation, newest first, for the menu panel.
    var recentLessonTitles: [String] {
        controlBar.model.transcript.compactMap(\.lessonTitle).reversed().prefix(4).map { $0 }
    }

    /// Opens the folder holding each day's saved transcript.
    func openTranscriptsFolder() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(AppIdentity.dataName)/Transcripts")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Records that onboarding's email step is done.
    ///
    /// Upstream sent the address to a form service and identified the user in
    /// analytics. Both are removed here: a tutor that reads your screen has no
    /// business transmitting anything, so this only flips the local flag that
    /// stops onboarding asking again.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")
    }

    func start() {
        refreshAllPermissions()
        TutorDebugLog.write("🔑 at launch, accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindMarkLifetime()
        InterfaceSounds.shared.prepare()
        configureLearningMemory()
        #if DEBUG
        qaHooks.start()
        #endif
        controlBar.model.onFixKeys = { [weak self] in self?.setupWindow.show(startingAt: .keys) }
        bindUpdater()
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

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor, the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence, dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches, the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time, isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        kokoroClient.shutDown()
        deepgramClient.shutDown()
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            TutorDebugLog.write("🔑 accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted, once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content, a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result, width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception , 
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        var tickCount = 0
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            tickCount += 1
            let shouldProbeModelServer = tickCount % 8 == 0

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshAllPermissions()

                // Re-probe far less often than permissions. This exists so the
                // "Ollama is not running" warning clears on its own once the
                // user starts it, instead of needing an app restart.
                self.keepSettingsOpenWhileSetupIsNeeded()

                // Test triggers read from files in ~/Library/Logs. Debug builds
                // only: any program on the Mac can write those files, and one
                // of them makes Buddy capture the screen and send it to a model.
                #if DEBUG
                if FileManager.default.fileExists(atPath: CalibrationSnapshot.triggerURL.path) {
                    try? FileManager.default.removeItem(at: CalibrationSnapshot.triggerURL)
                    await self.runCalibration()
                }

                if let tabName = try? String(contentsOf: CalibrationSnapshot.openNotchURL, encoding: .utf8) {
                    try? FileManager.default.removeItem(at: CalibrationSnapshot.openNotchURL)
                    switch tabName.trimmingCharacters(in: .whitespacesAndNewlines) {
                    case "transcript": self.openNotchBriefly(on: .transcript)
                    case "settings": self.openNotchBriefly(on: .settings)
                    default: self.openNotchBriefly(on: .lesson)
                    }
                }

                // A question in this file is asked as if spoken, so the whole
                // pipeline can be checked from a terminal: capture, model,
                // voice, drawing.
                if let question = try? String(contentsOf: CalibrationSnapshot.askURL, encoding: .utf8) {
                    try? FileManager.default.removeItem(at: CalibrationSnapshot.askURL)
                    let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedQuestion.isEmpty {
                        TutorDebugLog.write("🧪 asked from file")
                        self.sendTranscriptToTutorWithScreenshot(transcript: trimmedQuestion)
                    }
                }

                // A picture of the screen with whatever is drawn on it, to
                // check a drawing by looking at it.
                if FileManager.default.fileExists(atPath: CalibrationSnapshot.snapshotTriggerURL.path) {
                    try? FileManager.default.removeItem(at: CalibrationSnapshot.snapshotTriggerURL)
                    do {
                        try await CalibrationSnapshot.captureIncludingOverlay()
                        TutorDebugLog.write("📸 snapshot saved")
                    } catch {
                        TutorDebugLog.write("⚠️ snapshot failed: \(error.localizedDescription)")
                    }
                }

                #endif

                if shouldProbeModelServer {
                    let (isReachable, _) = await self.tutorBrain.probeServer()
                    if isReachable != self.isLocalModelReachable {
                        self.isLocalModelReachable = isReachable
                        if isReachable {
                            print("🦙 Ollama came back, preloading \(self.selectedModel)")
                            await self.tutorBrain.preloadModel()
                        }
                    }
                }
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding, the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs, schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }
            // First, so it lands the instant the keys go down: the student
            // hears that the mic is live without looking for the red dot.
            InterfaceSounds.shared.play(.listen)
            // The student is about to talk for a few seconds. That is free
            // time to open the secure connections the answer will need, so
            // the handshake is not paid after they stop.
            // Claude is warmed under every setting that has a key, because the
            // question classifier uses the same connection whichever brain answers.
            if APIKeyStore.hasKey(for: .anthropic) { claudeBrain.prewarmConnection() }
            narrationVoice.prewarmConnection()

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // Make sure there is an overlay to draw into before answering.
            //
            // Upstream only reinstated it when the cursor had been switched
            // off, because every other path had already created it during
            // onboarding. This fork is useful before anyone sits through
            // onboarding, and until that happens the overlay window does not
            // exist, so marks resolve correctly and then render into nothing:
            // the answer is spoken over a completely unmarked screen.
            if !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            markDismissalTask?.cancel()
            markDismissalTask = nil
            diagramTask?.cancel()
            diagramTask = nil
            cancelSpeechAndClearQueue()
            clearDetectedElementLocation()
            clearAnnotations()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        InterfaceSounds.shared.play(.sent)
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToTutorWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            shortcutReleasedAt = Date()
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
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

    // MARK: - Tutor Response Pipeline

    /// How much of the streamed response has already been handed to speech.
    private var streamedCharactersAlreadyQueued = 0

    /// Complete sentences waiting to be spoken, in order.
    private var pendingSpeechSegments: [ParsedTeacherResponse] = []

    /// Consumer draining `pendingSpeechSegments`, nil when nothing is speaking.
    private var speechConsumerTask: Task<Void, Never>?

    /// The display the current answer is marking up.
    private var displayFrameForCurrentAnswer: CGRect = .zero

    /// Clears the board and marks once the answer has had time to be read.
    private var markDismissalTask: Task<Void, Never>?

    /// The strip at the bottom while the tutor talks or has drawn: the
    /// sentence being said, the follow-ups it offered, Stop and Clear.
    private lazy var controlBar = TutorControlBarController(
        onAsk: { [weak self] question in self?.askFollowUp(question) },
        onStop: { [weak self] in self?.stopAnswering() },
        onClear: { [weak self] in
            if self?.clearAnnotations() == true { InterfaceSounds.shared.play(.wipe) }
        },
        settingsView: { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(CompanionPanelView(companionManager: self, isEmbedded: true))
        }
    )

    /// The notch is the only window the app has, so setup happens there:
    /// while a permission is missing, it stays open on its settings tab.
    func keepSettingsOpenWhileSetupIsNeeded() {
        let model = controlBar.model
        // The setup window walks through permissions; pinning the notch open
        // as well would put it over the window, and after "Skip for now" it
        // would hold the notch open with no way to close it.
        let setupHandlesPermissions = setupWindow.isVisible || UserDefaults.standard.bool(forKey: "hasFinishedSetup")
        if !allPermissionsGranted && !setupHandlesPermissions {
            guard !notchIsPinnedForSetup else { return }
            notchIsPinnedForSetup = true
            model.selectedTab = .settings
            model.isPinnedOpen = true
            model.isExpanded = true
        } else if notchIsPinnedForSetup, allPermissionsGranted || setupHandlesPermissions {
            // Only undoes its own pin: this runs every couple of seconds, and
            // must not close the notch when something else opened it.
            notchIsPinnedForSetup = false
            model.isPinnedOpen = false
            model.isExpanded = false
            model.selectedTab = .lesson
        }
    }
    private var notchIsPinnedForSetup = false
    /// The latest Dock-click opening; a newer click restarts its clock.
    private var briefOpenTask: Task<Void, Never>?

    /// Opens the notch on a tab for a few seconds, then lets the mouse decide.
    /// For the Dock icon, which has no window of its own to show.
    func openNotchBriefly(on tab: NotchTab) {
        let model = controlBar.model
        model.selectedTab = tab
        model.isPinnedOpen = true
        model.isExpanded = true
        briefOpenTask?.cancel()
        briefOpenTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, !self.notchIsPinnedForSetup else { return }
            model.isPinnedOpen = false
            model.isExpanded = false
        }
    }
    private var controlBarDrawingCancellable: AnyCancellable?
    private var notchActivityCancellable: AnyCancellable?
    private var notchHeardWordsCancellable: AnyCancellable?

    /// When the keys were let go and when this answer began, for the stage
    /// timings in the log: the only latency the student feels is from the
    /// first to the first spoken word.
    private var shortcutReleasedAt: Date?
    private var answerStartedAt = Date()

    private func logStage(_ stage: String) {
        let sinceStart = Date().timeIntervalSince(answerStartedAt)
        var line = "⏱ \(stage): \(String(format: "%.2f", sinceStart))s"
        if let released = shortcutReleasedAt, Date().timeIntervalSince(released) < 60 {
            line += " (\(String(format: "%.2f", Date().timeIntervalSince(released)))s after release)"
        }
        TutorDebugLog.write(line)
    }

    /// Where drawing programs are drawn, who speaks them, and what ties the two.
    private lazy var drawingOverlay = DrawingOverlay()
    private lazy var narrationVoice = NarrationVoice(fallbackVoice: speechClient)
    private lazy var lessonPlayer: LessonProgramPlayer = {
        let player = LessonProgramPlayer(overlay: drawingOverlay, voice: narrationVoice, bar: controlBar.model)
        player.onFirstSentenceHeard = { [weak self] in self?.logStage("first sentence heard") }
        return player
    }()

    /// Whether this answer is a drawing program or plain prose. Decided from
    /// its first characters: a model that ignores the format still gets
    /// spoken, through the older tag pipeline.
    private enum AnswerFormat { case undecided, program, prose }
    private var currentAnswerFormat: AnswerFormat = .undecided
    private var escapeKeyMonitor: Any?
    private var scrollWheelMonitor: Any?
    private var applicationSwitchObserver: NSObjectProtocol?

    /// Captures the screen, indexes it, asks the local model, and narrates the
    /// answer while drawing on screen.
    ///
    /// Speech starts on the first complete sentence rather than waiting for the
    /// whole answer. That matters more than raw speed: the model generates
    /// roughly two and a half times faster than speech plays back, so once the
    /// first sentence is out the voice never catches up to the generator, and
    /// the only latency the user perceives is time-to-first-sentence.
    private func sendTranscriptToTutorWithScreenshot(transcript spokenTranscript: String) {
        let transcript = Self.questionWithoutGreeting(spokenTranscript)
        currentResponseTask?.cancel()
        cancelSpeechAndClearQueue()

        TutorDebugLog.write("🎙️ asked: \(transcript)")
        controlBar.model.recordStudent(transcript)
        controlBar.model.heardWords = transcript
        answerStartedAt = Date()
        logStage("question in")
        let hasPreviousAnswer = !conversationHistory.isEmpty
        let localProbabilities = questionSorter.probabilities(of: transcript, hasPreviousAnswer: hasPreviousAnswer)
        let localConfidence = localProbabilities?.values.max() ?? 0

        // Haiku is asked only when the on-device sorter is unsure, and asked
        // now, so it works while the screen is captured and read.
        // Memory starts now too, so its Haiku call also runs during capture.
        let (earlyFrontAppName, earlyWindowTitle) = TutorProgramPrompt.frontmostAppAndWindow()
        let recallTask = learningMemory.startRecall(
            question: transcript, windowTitle: earlyWindowTitle,
            questionVector: questionSorter.sentenceVector(for: transcript))
        _ = earlyFrontAppName

        let classifierTask: Task<QuestionKind?, Never>? =
            localConfidence < QuestionSorter.confidentEnough && APIKeyStore.hasKey(for: .anthropic)
            ? Task { [claudeBrain] in
                await claudeBrain.classifyQuestion(transcript, hasPreviousAnswer: hasPreviousAnswer)
            }
            : nil

        currentResponseTask = Task {
            voiceState = .processing
            controlBar.model.waitingStage = "reading your screen"
            clearAnnotations()
            charactersSpokenInAnswer = 0
            totalCharactersInAnswer = 0
            boardRevealFraction = 0

            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard !Task.isCancelled, !screenCaptures.isEmpty else { return }

                // Index only the screen holding the cursor. Indexing every
                // display would multiply the prompt for context the user is
                // almost certainly not looking at.
                let primaryCapture = screenCaptures.first(where: { capture in capture.isCursorScreen })
                    ?? screenCaptures[0]
                displayFrameForCurrentAnswer = primaryCapture.displayFrame

                await screenIndex.rebuild(
                    fromScreenshot: primaryCapture.imageData,
                    displayIndex: 0,
                    displayBoundsInPoints: CGSize(
                        width: primaryCapture.displayWidthInPoints,
                        height: primaryCapture.displayHeightInPoints
                    )
                )
                guard !Task.isCancelled else { return }
                logStage("screen captured and read")
                controlBar.model.waitingStage = "thinking"
                let screenReadAt = Date()

                let (questionKind, kindProbabilities) = await settleQuestionKind(
                    transcript: transcript,
                    hasPreviousAnswer: hasPreviousAnswer,
                    localProbabilities: localProbabilities,
                    classifierTask: classifierTask
                )
                guard !Task.isCancelled else { return }

                // Counted before the answer is built, so the instruction
                // reflects how many times this idea has already failed to land.
                if questionKind == .reexplain {
                    learningMemory.studentGotLost()
                    consecutiveReexplanationCount += 1
                    TutorDebugLog.write("🔁 student still lost after \(lastAnsweringBrainName), attempt \(consecutiveReexplanationCount + 1): switching tactic")
                } else {
                    consecutiveReexplanationCount = 0
                }

                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                let historyForModel = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                streamedCharactersAlreadyQueued = 0

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
                let recollections = await settleRecollections(
                    recallTask: recallTask, question: transcript,
                    screenContext: (frontWindowTitle ?? "") + "\n" + screenListing,
                    // At least a second from the question: the chooser's reply
                    // takes about 0.75 s, and a fast capture alone left it a
                    // coin flip in live testing. Recalling an earlier lesson
                    // is worth a fraction of a second more.
                    deadline: max(screenReadAt.addingTimeInterval(Self.classifierGraceSeconds),
                                  answerStartedAt.addingTimeInterval(Self.memoryChooserFloorSeconds)))
                guard !Task.isCancelled else { return }
                controlBar.model.buildsOn = recollections.map(\.concept.name)
                var studyNotes = [LearningMemory.promptNote(for: recollections)]

                // A practice problem gets hints in steps; a drawing of their
                // own gets a peer's review. A practice problem wins when both
                // seem to apply, unless they said it is their drawing.
                var lengthInstruction = TutorProgramPrompt.lengthInstruction(for: questionKind)
                currentPracticeProblem = nil
                let diagramTool = DiagramReview.detect(
                    frontAppName: frontAppName, windowTitle: frontWindowTitle, transcript: transcript)
                if let problem = PracticeHints.detect(
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
                } else if let diagramTool {
                    studyNotes.append(DiagramReview.instruction(tool: diagramTool))
                    TutorDebugLog.write("✏️ reviewing their drawing in \(diagramTool)")
                }

                let turnPrompt = TutorProgramPrompt.turnContext(
                    transcript: transcript,
                    canvasSize: canvasSize,
                    screenListing: screenListing,
                    lengthInstruction: lengthInstruction,
                    reexplanationInstruction: reexplanationInstruction(),
                    frontAppName: frontAppName,
                    frontWindowTitle: frontWindowTitle,
                    studyNotes: studyNotes
                )

                let screenForDrawing = NSScreen.screens.first { screen in
                    screen.frame == primaryCapture.displayFrame
                } ?? NSScreen.main
                if let screenForDrawing {
                    lessonPlayer.begin(
                        on: screenForDrawing,
                        canvasSize: canvasSize,
                        targets: screenBoxes,
                        screenInkHex: "#3380FF"
                    )
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
                while answer == nil {
                    if attempt < routing.count { activate(routing[attempt]) }
                    let brainForAttempt = tutorBrain
                    currentAnswerAttempt += 1
                    let thisAttempt = currentAnswerAttempt
                    // Only a fallback is worth a deadline: with nobody to hand
                    // over to, a slow answer still beats none.
                    let deadline: TimeInterval? = attempt + 1 < routing.count
                        ? modelRouter.firstWordsDeadline(for: routing[attempt], probabilities: kindProbabilities)
                        : nil
                    do {
                        answer = try await withFirstWordsDeadline(deadline) {
                            try await brainForAttempt.analyzeImageStreaming(
                                images: imagesForModel,
                                systemPrompt: TutorProgramPrompt.system,
                                conversationHistory: historyForModel,
                                userPrompt: turnPrompt,
                                onTextChunk: { [weak self] accumulatedText in
                                    guard let self, self.currentAnswerAttempt == thisAttempt else { return }
                                    self.routeStreamedText(accumulatedText)
                                }
                            )
                        }
                    } catch {
                        guard !Task.isCancelled,
                              error is FirstWordsDeadlineMissed || !(error is CancellationError),
                              currentAnswerFormat == .undecided,
                              attempt + 1 < routing.count else { throw error }
                        let failedBrain = routing[attempt]
                        var nextAttempt = attempt + 1
                        if error is FirstWordsDeadlineMissed {
                            TutorDebugLog.write("↪️ \(failedBrain.rawValue) said nothing in \(Int(deadline ?? 0))s, \(routing[nextAttempt].rawValue) answers instead")
                        } else {
                            let problem = keyProblem(in: error)
                            if let problem { reportKeyProblem(problem, answerFailed: false) }
                            modelRouter.bench(failedBrain)
                            // Sonnet and Opus share the Anthropic key: when the
                            // key is the problem, the other one fails the same way,
                            // so it is skipped rather than tried.
                            if problem?.service == .anthropic {
                                while nextAttempt < routing.count, routing[nextAttempt] != .argon {
                                    modelRouter.bench(routing[nextAttempt])
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

                // An answer from the provider whose key was reported means the
                // key works again: the banner goes, unprompted.
                if let problem = keyProblem, attempt < routing.count {
                    let answeredWith: APIKeyStore.Service = routing[attempt] == .argon ? .gemini : .anthropic
                    if answeredWith == problem.service {
                        keyProblem = nil
                        controlBar.model.keyProblemMessage = nil
                    }
                }

                guard !Task.isCancelled else { return }

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
                    if let lessonTitle = lessonPlayer.lessonTitle {
                        TutorDebugLog.write("📘 lesson: \(lessonTitle)")
                        controlBar.model.recordLessonTitle(lessonTitle)
                    }
                    if let problem = currentPracticeProblem,
                       let levelGiven = PracticeHints.levelGiven(inProgram: fullResponseText) {
                        practiceHintLadder.record(level: levelGiven, for: problem)
                    }
                    fileLessonInMemory(question: transcript, lessonTitle: lessonPlayer.lessonTitle,
                                       spokenAnswer: Self.spokenSentences(inProgram: fullResponseText),
                                       questionKind: questionKind)
                    // The whole program, not only what was said: the next
                    // answer has to know what it drew to build on it or to
                    // explain it differently.
                    conversationHistory.append((
                        userTranscript: transcript,
                        assistantResponse: fullResponseText
                    ))
                    if conversationHistory.count > 10 {
                        conversationHistory.removeFirst(conversationHistory.count - 10)
                    }
                    print("🧠 Answered in \(String(format: "%.1f", duration))s as a drawing program")
                } else {

                // Flush whatever trailed the final sentence terminator, which
                // the streaming path deliberately held back.
                enqueueRemainder(ofStreamedText: fullResponseText)

                let spokenOnlyText = TeacherResponseParser.parse(rawResponse: fullResponseText).spokenText
                totalCharactersInAnswer = max(totalCharactersInAnswer, spokenOnlyText.count)

                // Drawn on a fast model in parallel, because the model that
                // explains well will not draw cheaply: offering Argon a layout
                // decision took first byte from 3 seconds to 49, while Flash
                // makes the same choice in 3.5. Flash sees only this finished
                // explanation, never the screen, so it contributes no
                // reasoning and cannot contradict what was already said.
                //
                // Nothing awaits this. A slow or failed drawing pass costs the
                // student nothing; they simply get no picture.
                if budget.allowsBoard, !whiteboard.hasContent {
                    diagramTask?.cancel()
                    let explanationForDrawing = spokenOnlyText
                    let indexForDrawing = screenIndex.renderForPrompt(maximumTargets: 40)
                    diagramTask = Task { [weak self] in
                        guard let self else { return }
                        guard let shape = await self.diagramComposer.diagram(
                            forExplanation: explanationForDrawing,
                            screenIndexListing: indexForDrawing
                        ) else { return }
                        guard !Task.isCancelled else { return }
                        self.apply(
                            directive: TeacherDirective(
                                action: .drawDiagram(shape: shape),
                                characterOffsetInSpokenText: 0
                            )
                        )
                    }
                }
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenOnlyText
                ))
                fileLessonInMemory(question: transcript, lessonTitle: nil, spokenAnswer: spokenOnlyText,
                                   questionKind: questionKind)
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Answered in \(String(format: "%.1f", duration))s, history \(conversationHistory.count) exchanges")
                }

            } catch is CancellationError {
                // User spoke again; the previous answer was abandoned on purpose.
            } catch {
                print("⚠️ Tutor response error: \(error.localizedDescription)")
                TutorDebugLog.write("⚠️ answer failed: \(error.localizedDescription)")
                await speakLocalErrorFallback(for: error)
            }

            if !Task.isCancelled {
                // Hold .responding while speech drains, so the overlay does not
                // drop back to idle while the tutor is still talking.
                while speechConsumerTask != nil || isAnyVoicePlaying {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if Task.isCancelled { break }
                }
                voiceState = .idle
                if currentAnswerFormat == .program {
                    // A drawing stays until the next question, Clear, Esc, or
                    // the content under it changing: it is the part worth
                    // looking at once the talking stops.
                    await lessonPlayer.waitUntilSpoken()
                    controlBar.model.caption = ""
                } else {
                    scheduleMarkDismissal()
                }
                scheduleTransientHideIfNeeded()
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
            enqueueCompletedSentences(fromStreamedText: accumulatedText)
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
    private func askFollowUp(_ question: String) {
        TutorDebugLog.write("👆 follow-up tapped: \(question)")
        sendTranscriptToTutorWithScreenshot(transcript: question)
    }

    /// Stop on the bar: stops talking and the answer being written, and
    /// leaves what is drawn.
    private func stopAnswering() {
        currentResponseTask?.cancel()
        cancelSpeechAndClearQueue()
        voiceState = .idle
        controlBar.model.caption = ""
    }

    /// How many times running the student has said they still do not follow.
    ///
    /// Reset by any question that is not a push-back, because the counter
    /// tracks one idea failing to land rather than the length of the session.
    private var consecutiveReexplanationCount = 0

    /// Whether the student is saying the last explanation did not work.
    private static func isAskingAgain(_ transcript: String) -> Bool {
        let lowercasedTranscript = transcript.lowercased()
        let pushBackPhrases = [
            "again", "didn't get", "didnt get", "don't get", "dont get",
            "don't understand", "dont understand", "not clear", "unclear",
            "confused", "confusing", "still", "what do you mean",
            "simpler", "another way", "rephrase", "lost me", "huh"
        ]
        return pushBackPhrases.contains { phrase in lowercasedTranscript.contains(phrase) }
    }

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
    private static let classifierGraceSeconds: Double = 0.35
    private static let memoryChooserFloorSeconds: Double = 1.0

    /// How much Haiku's kind is trusted against the on-device probabilities:
    /// its accuracy on the blind spoken set, 90 of 100.
    private static let classifierWeight = 0.9

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

    /// Who answered the last question, for the push-back log line.
    private var lastAnsweringBrainName = "nobody"

    /// The question's kind, and how likely each kind is, from the on-device
    /// sorter, Haiku when it was asked and is back in time, or keywords when
    /// neither is available.
    private func settleQuestionKind(
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
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(Self.classifierGraceSeconds * 1_000_000_000))
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

    /// The brains to try, best first, for the current Brain setting. Empty
    /// when the setting names a single brain.
    private func routeQuestion(probabilities: [QuestionKind: Double]) -> [RoutedBrain] {
        let allowed: Set<RoutedBrain>
        switch brainKind {
        case .auto:
            // Only brains that are set up: an Anthropic key for Sonnet and
            // Opus, a Gemini key or a Vertex project for Argon.
            var available: Set<RoutedBrain> = []
            if canUseClaude { available.formUnion([.sonnet, .opus]) }
            if canUseArgon { available.insert(.argon) }
            allowed = available.isEmpty ? [.argon] : available
        case .claude:
            allowed = [.sonnet, .opus]
        case .hosted, .local:
            controlBar.model.answeredBy = ""
            lastAnsweringBrainName = brainKind.displayName
            return []
        }
        let choice = modelRouter.choose(probabilities: probabilities, allowed: allowed)
        TutorDebugLog.write("🧭 route: \(choice.ranking.map(\.rawValue).joined(separator: " > ")) (\(choice.explanation))")
        return choice.ranking
    }

    /// Points the answer at one brain and sets it up for this question.
    private func activate(_ brain: RoutedBrain) {
        autoAnsweringBrain = brain
        switch brain {
        case .sonnet: claudeBrain.apply(.sonnetWithoutThinking)
        case .opus: claudeBrain.apply(.opusThinkingLow)
        case .argon: break
        }
        controlBar.model.answeredBy = brain.displayName
        lastAnsweringBrainName = brain.displayName
        TutorDebugLog.write("🧭 answered by \(brain.displayName)")
    }

    private func configureLearningMemory() {
        learningMemory.embed = { [weak self] text in self?.questionSorter.sentenceVector(for: text) }
        learningMemory.embeddingModelIdentifier = { [weak self] in self?.questionSorter.embeddingModelIdentifier }
        learningMemory.extract = { [claudeBrain] lesson, known in
            guard APIKeyStore.hasKey(for: .anthropic) else { return nil }
            return await claudeBrain.extractLessonConcepts(lesson, known: known)
        }
        learningMemory.choose = { [claudeBrain] question, windowTitle, candidates in
            guard APIKeyStore.hasKey(for: .anthropic) else { return nil }
            return await claudeBrain.chooseRememberedConcepts(
                question: question, windowTitle: windowTitle, candidates: candidates)
        }
    }

    private var currentPracticeProblem: PracticeProblem?
    /// Which try at the current answer is live. A brain given up on at its
    /// deadline may still deliver words while it unwinds; they are dropped.
    private var currentAnswerAttempt = 0

    /// Forgets the learning memory and the hint steps together, as Settings
    /// promises.
    func forgetLearningMemory() {
        learningMemory.forgetEverything()
        practiceHintLadder.forgetAll()
    }

    /// An available update shows in the open notch, with its progress, until
    /// installed; a failure keeps the banner with what went wrong.
    private func bindUpdater() {
        let model = controlBar.model
        model.onInstallUpdate = { [weak self] in Task { await self?.appUpdater.installAvailableUpdate() } }
        model.onShowReleaseNotes = { [weak self] in
            if let page = self?.appUpdater.availableRelease?.pageURL { NSWorkspace.shared.open(page) }
        }
        updaterStateCancellable = appUpdater.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let version = self.appUpdater.availableRelease?.version ?? ""
                switch state {
                case .available: model.updateBanner = .init(text: "Buddy \(version) is ready.", isWorking: false, canInstall: true)
                case .downloading: model.updateBanner = .init(text: "Downloading Buddy \(version)...", isWorking: true, canInstall: false)
                case .installing: model.updateBanner = .init(text: "Checking and installing Buddy \(version)...", isWorking: true, canInstall: false)
                case .failed(let message) where self.appUpdater.availableRelease != nil:
                    model.updateBanner = .init(text: message, isWorking: false, canInstall: true)
                default: model.updateBanner = nil
                }
            }
        appUpdater.startAutomaticChecks()
    }

    /// Esc puts away what was opened last: the notch first, then the drawing.
    private func handleEscape() {
        if controlBar.closeFromKeyboard() {
            TutorDebugLog.write("⎋ Esc: closing the notch")
            return
        }
        TutorDebugLog.write("⎋ Esc: clearing the drawing")
        if clearAnnotations() { InterfaceSounds.shared.play(.wipe) }
    }

    #if DEBUG
    private lazy var qaHooks = QAHooks(companionManager: self)

    /// As if spoken: the connections are warmed the way holding the keys
    /// warms them, then the question goes in after a speaking-length pause,
    /// so timings match real use instead of a cold start.
    func qaAsk(_ text: String) {
        if APIKeyStore.hasKey(for: .anthropic) { claudeBrain.prewarmConnection() }
        narrationVoice.prewarmConnection()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            sendTranscriptToTutorWithScreenshot(transcript: text)
        }
    }
    func qaPressEscape() { handleEscape() }
    func qaSetNotchOpen(_ open: Bool) { controlBar.model.isExpanded = open }
    func qaLogState() {
        let model = controlBar.model
        TutorDebugLog.write("🧪 state: activity=\(model.activity) stage=\(model.waitingStage ?? "-") expanded=\(model.isExpanded) "
            + "answeredBy=\(model.answeredBy) buildsOn=\(model.buildsOn) keyProblem=\(model.keyProblemMessage ?? "-") "
            + "followUps=\(model.followUps.map(\.title)) memory=\(learningMemory.conceptCount) brain=\(brainKind.rawValue) "
            + "claude=\(canUseClaude) argon=\(canUseArgon) vertex=\(usesVertexForArgon) setupNeeded=\(needsSetup)")
    }
    #endif

    /// Hands the finished lesson to memory, after it has been said: filing it
    /// costs a Haiku call the student never waits for.
    private func fileLessonInMemory(question: String, lessonTitle: String?, spokenAnswer: String, questionKind: QuestionKind) {
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
    private func settleRecollections(
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

    private func reexplanationInstruction() -> String {
        guard consecutiveReexplanationCount > 0 else { return "" }

        // Ordered from cheapest shift to most drastic, so a student who keeps
        // pushing back gets progressively more concrete rather than more words.
        let strategiesInEscalatingOrder = [
            "take one small concrete example with real numbers and walk it through a step at a time. no definitions.",
            "use an analogy from ordinary life, nothing to do with computers, then tie it back in one sentence.",
            "stop explaining and show it. mark up what is on their screen and talk only about what you marked.",
            "start from what goes wrong without it. describe the failure first, then the fix."
        ]
        let chosenStrategy = strategiesInEscalatingOrder[
            min(consecutiveReexplanationCount - 1, strategiesInEscalatingOrder.count - 1)
        ]

        let failedAttempt = conversationHistory.last?.assistantResponse ?? ""

        return """


        THE STUDENT STILL DOES NOT FOLLOW. this is attempt \(consecutiveReexplanationCount + 1).
        your previous attempt was: "\(failedAttempt.prefix(350))"
        that did not work. do not restate it and do not paraphrase it.
        change the approach completely: \(chosenStrategy)
        """
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

        if hasPreviousAnswer && isAskingAgain(transcript) {
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
    private static func answerBudget(for questionKind: QuestionKind) -> AnswerBudget {
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

    // MARK: - Progressive speech

    /// Pulls any newly completed sentences out of the stream and queues them.
    private func enqueueCompletedSentences(fromStreamedText streamedText: String) {
        guard let chunk = TeacherResponseParser.nextSpeakableChunk(
            fromStreamedText: streamedText,
            alreadySpokenCharacterCount: streamedCharactersAlreadyQueued
        ) else { return }

        streamedCharactersAlreadyQueued += chunk.count
        enqueueParsedSegment(TeacherResponseParser.parse(rawResponse: chunk))
    }

    /// Queues the tail that followed the last sentence terminator.
    private func enqueueRemainder(ofStreamedText fullText: String) {
        guard streamedCharactersAlreadyQueued < fullText.count else { return }

        let startIndex = fullText.index(fullText.startIndex, offsetBy: streamedCharactersAlreadyQueued)
        let remainder = String(fullText[startIndex...])
        streamedCharactersAlreadyQueued = fullText.count

        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        enqueueParsedSegment(TeacherResponseParser.parse(rawResponse: remainder))
    }

    private func enqueueParsedSegment(_ segment: ParsedTeacherResponse) {
        // A segment that was nothing but tags still carries marks worth drawing.
        guard !segment.spokenText.isEmpty || !segment.directives.isEmpty else { return }

        if !segment.directives.isEmpty {
            TutorDebugLog.write("✏️ segment carries \(segment.directives.count) mark(s)")
        }

        pendingSpeechSegments.append(segment)
        startSpeechConsumerIfIdle()
    }

    private func startSpeechConsumerIfIdle() {
        guard speechConsumerTask == nil else { return }

        speechConsumerTask = Task { [weak self] in
            guard let self else { return }

            // Audio for the sentence after the current one, rendered while the
            // current one plays. Without this the speech stopped for a second
            // and a half before every sentence, which is what made it sound
            // halting instead of fluent: rendering only started once the
            // previous sentence had finished.
            var prefetchedClipTask: Task<KokoroSpeechClient.GeneratedClip, Error>?

            while !self.pendingSpeechSegments.isEmpty {
                guard !Task.isCancelled else { break }

                let segment = self.pendingSpeechSegments.removeFirst()
                if !segment.spokenText.isEmpty {
                    self.controlBar.model.recordTutorSentence(segment.spokenText)
                }

                if self.voiceState != .responding {
                    self.voiceState = .responding
                }

                let clipTaskForThisSegment = prefetchedClipTask
                prefetchedClipTask = nil

                // Start the next sentence rendering before speaking this one.
                // Only Kokoro needs this: it renders a whole clip before
                // playing, so without a lookahead every sentence began with a
                // second and a half of silence. Deepgram streams into the
                // engine as bytes arrive and reaches first audio in about a
                // sixth of a second, so there is no gap worth hiding.
                if self.voiceEngine == .kokoro,
                   let nextSegment = self.pendingSpeechSegments.first,
                   !nextSegment.spokenText.isEmpty {
                    prefetchedClipTask = self.kokoroClient.beginGeneratingClip(
                        for: nextSegment.spokenText
                    )
                }

                // A ceiling on how long one sentence may take. Without it a
                // single stalled playback holds the pipeline open and the user
                // gets no answer at all and no error explaining why, which is
                // precisely what an audio format mismatch caused: buffers were
                // silently dropped, the completion handler never fired, and
                // everything waited on a sentence that was never spoken.
                let finishedSpeaking: Void? = try? await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor in
                        await self.speak(segment: segment, prerenderedClip: clipTaskForThisSegment)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 45_000_000_000)
                        throw CancellationError()
                    }
                    try await group.next()
                    group.cancelAll()
                }

                if finishedSpeaking == nil {
                    TutorDebugLog.write("⚠️ sentence never finished speaking, abandoning the rest")
                    self.cancelSpeechAndClearQueue()
                    break
                }
            }

            self.speechConsumerTask = nil
        }
    }

    /// Speaks one segment, drawing its marks as the words carrying them are said.
    ///
    /// Both engines report progress as a character offset into the text, but
    /// they measure it very differently. AVSpeechSynthesizer reports real word
    /// boundaries as it speaks them. Kokoro hands back a finished waveform with
    /// no timing at all, so its offsets are interpolated from elapsed playback.
    /// That is an estimate, and it only has to be close enough to land a mark
    /// in the right clause.
    private func speak(
        segment: ParsedTeacherResponse,
        prerenderedClip: Task<KokoroSpeechClient.GeneratedClip, Error>? = nil
    ) async {
        var undispatchedDirectives = segment.directives
        let charactersBeforeThisSegment = charactersSpokenInAnswer

        // Until the stream finishes the total is unknown, so it is estimated
        // from what has been queued. Otherwise the first segment would divide
        // by nothing and the board would appear complete immediately.
        if totalCharactersInAnswer == 0 {
            totalCharactersInAnswer = max(1, charactersBeforeThisSegment + segment.spokenText.count * 3)
        }

        func drawMarksReached(upToCharacterOffset offset: Int) {
            let spokenOverall = charactersBeforeThisSegment + offset
            charactersSpokenInAnswer = max(charactersSpokenInAnswer, spokenOverall)
            let fraction = Double(charactersSpokenInAnswer) / Double(max(1, totalCharactersInAnswer))
            // Monotonic: a diagram must never un-draw itself mid-sentence.
            if fraction > boardRevealFraction {
                withAnimation(.easeOut(duration: 0.35)) {
                    boardRevealFraction = min(1.0, fraction)
                }
            }

            while let next = undispatchedDirectives.first,
                  Self.offsetWhereMarkedPhraseBegins(
                    tagOffset: next.characterOffsetInSpokenText,
                    spokenText: segment.spokenText
                  ) <= offset {
                undispatchedDirectives.removeFirst()
                apply(directive: next, spokenContext: segment.spokenText)
            }
        }

        // A segment that is nothing but tags still has marks worth drawing.
        guard !segment.spokenText.isEmpty else {
            drawMarksReached(upToCharacterOffset: Int.max)
            return
        }

        switch voiceEngine {
        case .deepgram:
            deepgramClient.onSpokenProgress = { reachedOffset in
                drawMarksReached(upToCharacterOffset: reachedOffset)
            }
            do {
                // No prefetch needed here. Deepgram streams PCM into the audio
                // engine as it arrives, so the gap before a sentence is about
                // a sixth of a second rather than the second and a half that
                // made rendering ahead worth the complexity for Kokoro.
                try await deepgramClient.speakText(segment.spokenText)
            } catch {
                TutorDebugLog.write("⚠️ Deepgram failed: \(error.localizedDescription). system voice from here.")
                voiceEngine = .system
                deepgramClient.onSpokenProgress = nil
                speechClient.onWillSpeakRange = { spokenRange, _ in
                    drawMarksReached(upToCharacterOffset: spokenRange.location + spokenRange.length)
                }
                try? await speechClient.speakText(segment.spokenText)
                speechClient.onWillSpeakRange = nil
            }
            deepgramClient.onSpokenProgress = nil

        case .kokoro:
            kokoroClient.onSpokenProgress = { reachedOffset in
                drawMarksReached(upToCharacterOffset: reachedOffset)
            }
            do {
                // Already rendering, or rendered, from the previous iteration.
                let clipTask = prerenderedClip
                    ?? kokoroClient.beginGeneratingClip(for: segment.spokenText)
                try await kokoroClient.play(clip: try await clipTask.value)
            } catch {
                // Falling back for the rest of the session rather than retrying
                // each sentence: whatever broke the helper will break it again,
                // and a stutter between every sentence is worse than a plainer
                // voice throughout.
                TutorDebugLog.write("⚠️ neural voice failed: \(error.localizedDescription). system voice from here.")
                isUsingNeuralVoice = false
                kokoroClient.onSpokenProgress = nil
                try? await speechClient.speakText(segment.spokenText)
            }
            kokoroClient.onSpokenProgress = nil
            if voiceEngine == .kokoro, !isUsingNeuralVoice { voiceEngine = .system }

        case .system:
            speechClient.onWillSpeakRange = { spokenRange, _ in
                drawMarksReached(upToCharacterOffset: spokenRange.location + spokenRange.length)
            }
            try? await speechClient.speakText(segment.spokenText)
            speechClient.onWillSpeakRange = nil
        }

        // Anything the progress callback never reached, because speech was cut
        // short or the tag sat past the final word.
        drawMarksReached(upToCharacterOffset: segment.spokenText.count)
        charactersSpokenInAnswer = charactersBeforeThisSegment + segment.spokenText.count
    }

    /// Whether either speech engine is currently producing audio.
    private var isAnyVoicePlaying: Bool {
        speechClient.isPlaying || kokoroClient.isPlaying || deepgramClient.isPlaying || narrationVoice.isSpeaking
    }

    private func cancelSpeechAndClearQueue() {
        speechConsumerTask?.cancel()
        speechConsumerTask = nil
        pendingSpeechSegments.removeAll()
        streamedCharactersAlreadyQueued = 0
        speechClient.onWillSpeakRange = nil
        speechClient.stopPlayback()
        kokoroClient.onSpokenProgress = nil
        kokoroClient.stopPlayback()
        deepgramClient.onSpokenProgress = nil
        deepgramClient.stopPlayback()
        lessonPlayer.stop()
        currentAnswerFormat = .undecided
    }

    // MARK: - Drawing on screen

    /// Turns one directive into a mark, resolving its target to an exact rectangle.
    ///
    /// `spokenContext` is the sentence the mark was attached to. It is only
    /// consulted when an id fails to resolve, as the recovery path described
    /// on `ScreenIndex.bestTextMatch(forSpokenPhrase:)`.
    private func apply(directive: TeacherDirective, spokenContext: String = "") {
        let displayFrame = displayFrameForCurrentAnswer

        /// Converts a display-local rectangle into global AppKit points.
        func globalRect(for target: ScreenTarget) -> CGRect {
            CGRect(
                x: target.boundsInDisplayPoints.origin.x + displayFrame.origin.x,
                y: target.boundsInDisplayPoints.origin.y + displayFrame.origin.y,
                width: target.boundsInDisplayPoints.width,
                height: target.boundsInDisplayPoints.height
            )
        }

        func resolve(_ identifier: String) -> CGRect? {
            if let target = screenIndex.target(forIdentifier: identifier) {
                return globalRect(for: target)
            }

            // The id missed. The words around it are usually still honest
            // about what the model meant, so try to recover from those before
            // dropping the mark.
            let leadingPhrase = phraseLeadingUpTo(
                characterOffset: directive.characterOffsetInSpokenText,
                in: spokenContext
            )

            if let recoveredTarget = screenIndex.bestTextMatch(forSpokenPhrase: leadingPhrase) {
                TutorDebugLog.write("↩️ Recovered bad id \(identifier) as \(recoveredTarget.id) via \"\(recoveredTarget.displayedText)\"")
                return globalRect(for: recoveredTarget)
            }

            TutorDebugLog.write("⚠️ unknown target \(identifier), nothing nearby matched")
            return nil
        }

        switch directive.action {
        case .clearAll:
            clearAnnotations()

        // MARK: Board
        //
        // Each of these appends to the board, and appending is the reveal:
        // because directives fire from speech word boundaries, an element
        // lands exactly as it is described rather than the finished picture
        // appearing at once.

        case .beginBoard(let title):
            withAnimation(.easeOut(duration: 0.3)) {
                whiteboard = TutorWhiteboard(title: title)
            }

        case .addBoardColumn(let label, let content):
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                whiteboard.columns.append(
                    TutorWhiteboard.Column(label: label, content: content)
                )
            }

        case .addBoardBase(let label):
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                whiteboard.baseLabel = label
            }

        case .addBoardCells(let values):
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                whiteboard.cells = values
                // Pointers refer to positions in the old row, so they are
                // dropped rather than left pointing somewhere arbitrary.
                whiteboard.pointers = []
            }

        case .addBoardPointer(let position, let name):
            guard let cellIndex = position.resolve(inCellCount: whiteboard.cells.count) else {
                TutorDebugLog.write("⚠️ pointer \(name) could not be placed; row has \(whiteboard.cells.count) cell(s)")
                return
            }
            withAnimation(.easeOut(duration: 0.22)) {
                // One name per position: re-stating `mid` moves it rather than
                // stacking a second label under the same cell. This is what
                // makes a walkthrough animate, since each restatement of `lo`
                // slides the marker along instead of littering the row.
                whiteboard.pointers.removeAll { pointer in pointer.name == name }
                whiteboard.pointers.append(
                    TutorWhiteboard.Pointer(cellIndex: cellIndex, name: name)
                )
            }

        case .addBoardNode(let identifier, let column, let row, let widthInColumns, let label, let tint):
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                // Restating a node moves it rather than stacking a duplicate,
                // which is what lets a diagram be corrected mid-explanation.
                whiteboard.nodes.removeAll { existing in existing.id == identifier }
                whiteboard.nodes.append(
                    TutorWhiteboard.Node(
                        id: identifier,
                        column: column,
                        row: row,
                        widthInColumns: widthInColumns,
                        label: label,
                        tint: TutorWhiteboard.Node.Tint(name: tint)
                    )
                )
            }

        case .addBoardEdge(let fromIdentifier, let toIdentifier, let label):
            // Both ends must exist, or the arrow has nothing to attach to and
            // would be drawn from the origin.
            let knownIdentifiers = Set(whiteboard.nodes.map(\.id))
            guard knownIdentifiers.contains(fromIdentifier),
                  knownIdentifiers.contains(toIdentifier) else {
                TutorDebugLog.write("⚠️ edge \(fromIdentifier)->\(toIdentifier) references a node that was never drawn")
                return
            }
            withAnimation(.easeOut(duration: 0.3)) {
                whiteboard.edges.append(
                    TutorWhiteboard.Edge(
                        fromIdentifier: fromIdentifier,
                        toIdentifier: toIdentifier,
                        label: label
                    )
                )
            }

        case .drawDiagram(let shape):
            let expanded = shape.expand()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                whiteboard.nodes = expanded.nodes
                whiteboard.edges = expanded.edges
            }
            TutorDebugLog.write("📐 drew \(expanded.nodes.count) boxes, \(expanded.edges.count) arrows")

        case .addBoardNote(let text):
            withAnimation(.easeOut(duration: 0.25)) {
                whiteboard.caption = text
            }

        case .point(let identifier):
            guard let rect = resolve(identifier) else { return }
            detectedElementScreenLocation = CGPoint(x: rect.midX, y: rect.midY)
            detectedElementDisplayFrame = displayFrame

        case .pointAtCoordinate(let x, let y, _, _):
            // Coordinates arrive in the screenshot's top-left space; the
            // overlay works in AppKit's bottom-left space.
            let flippedY = displayFrame.height - y
            detectedElementScreenLocation = CGPoint(
                x: x + displayFrame.origin.x,
                y: flippedY + displayFrame.origin.y
            )
            detectedElementDisplayFrame = displayFrame

        case .circle(let identifier):
            appendAnnotation(style: .circle, identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .box(let identifier):
            appendAnnotation(style: .box, identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .underline(let identifier):
            appendAnnotation(style: .underline, identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .highlight(let identifier):
            appendAnnotation(style: .highlight, identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .strikethrough(let identifier):
            appendAnnotation(style: .strikethrough, identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .step(let identifier, let stepNumber):
            appendAnnotation(style: .step(number: stepNumber), identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .callout(let identifier, let text):
            appendAnnotation(style: .callout(text: text), identifier: identifier, resolve: resolve, displayFrame: displayFrame)

        case .arrow(let fromIdentifier, let toIdentifier):
            guard let fromRect = resolve(fromIdentifier),
                  let toRect = resolve(toIdentifier) else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                activeAnnotations.append(
                    TeacherAnnotation(
                        style: .arrow(destinationRectInGlobalPoints: toRect),
                        rectInGlobalPoints: fromRect,
                        displayFrame: displayFrame
                    )
                )
            }

        case .spotlight(let identifiers):
            // Capped in code, not just asked for in the prompt. The model
            // spotlighted sixteen targets on its first real run, which lights
            // most of the screen and hides nothing, defeating the one mark
            // whose whole value is removing distraction.
            let litRects = identifiers.prefix(3).compactMap(resolve)
            guard !litRects.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                spotlightRectsInGlobalPoints = litRects
            }
        }
    }

    /// Returns the words just before a mark, which is where the model names
    /// the thing it is marking.
    ///
    /// Looks backwards rather than around the offset because the natural
    /// phrasing is "the load balancer [POINT:t12]": the noun precedes the tag.
    /// A short lookahead is still included for the occasional inversion.
    private func phraseLeadingUpTo(characterOffset: Int, in text: String) -> String {
        guard !text.isEmpty else { return "" }

        let charactersBefore = 70
        let charactersAfter = 25

        let clampedOffset = max(0, min(characterOffset, text.count))
        let lowerBound = max(0, clampedOffset - charactersBefore)
        let upperBound = min(text.count, clampedOffset + charactersAfter)
        guard lowerBound < upperBound else { return "" }

        let startIndex = text.index(text.startIndex, offsetBy: lowerBound)
        let endIndex = text.index(text.startIndex, offsetBy: upperBound)
        return String(text[startIndex..<endIndex])
    }

    private func appendAnnotation(
        style: TeacherAnnotation.Style,
        identifier: String,
        resolve: (String) -> CGRect?,
        displayFrame: CGRect
    ) {
        guard let rect = resolve(identifier) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            activeAnnotations.append(
                TeacherAnnotation(
                    style: style,
                    rectInGlobalPoints: rect,
                    displayFrame: displayFrame
                )
            )
        }
        TutorDebugLog.write("🖊️ \(identifier) -> rect (\(Int(rect.minX)),\(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height)) on display \(Int(displayFrame.width))x\(Int(displayFrame.height)) at \(Int(displayFrame.origin.x)),\(Int(displayFrame.origin.y)), total now \(activeAnnotations.count), overlayVisible=\(isOverlayVisible)")
    }

    /// Boxes every indexed target and photographs the result.
    ///
    /// Runs the exact capture, indexing and drawing path a real answer uses,
    /// minus the model, so a misplaced box here is misplaced for the same
    /// reason a misplaced mark is in an answer.
    func runCalibration() async {
        TutorDebugLog.write("🎯 calibration: starting")
        do {
            if !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            guard let capture = captures.first(where: { candidate in candidate.isCursorScreen })
                    ?? captures.first else { return }
            displayFrameForCurrentAnswer = capture.displayFrame

            await screenIndex.rebuild(
                fromScreenshot: capture.imageData,
                displayIndex: 0,
                displayBoundsInPoints: CGSize(
                    width: capture.displayWidthInPoints,
                    height: capture.displayHeightInPoints
                )
            )

            clearAnnotations()
            let targets = screenIndex.orderedTargets
                .filter { target in target.locationSource == .recognizedText }
                .prefix(40)
            for target in targets {
                apply(directive: TeacherDirective(action: .box(targetIdentifier: target.id),
                                                  characterOffsetInSpokenText: 0))
            }
            TutorDebugLog.write("🎯 calibration: boxed \(targets.count) targets, waiting for render")

            // The board from a real answer that came out clipped and mostly
            // empty, so its size and placement are in the same picture.
            let sampleBoard = TeacherResponseParser.parse(rawResponse: """
            [BOARD:Separated Storage and Compute][COL:Finance Cluster:Stateless CPUs]\
            [COL:Data Science:Stateless CPUs][BASE:Shared Cloud Storage (S3)]\
            [CAPTION:Workers own zero data, they only cache it]
            """)
            for directive in sampleBoard.directives {
                apply(directive: directive)
            }
            boardRevealFraction = 1

            // Long enough for every box's stroke animation to finish.
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            try await CalibrationSnapshot.captureIncludingOverlay()
            TutorDebugLog.write("🎯 calibration: saved \(CalibrationSnapshot.outputURL.path)")

            // A sample of indexed text and rectangles, so the image can be
            // checked against what the index believed.
            for target in targets.prefix(8) {
                let r = target.boundsInDisplayPoints
                TutorDebugLog.write("🎯   \(target.id) '\(target.displayedText.prefix(30))' bottomLeft (\(Int(r.minX)),\(Int(r.minY))) \(Int(r.width))x\(Int(r.height))")
            }

            try? await Task.sleep(nanoseconds: 800_000_000)
            clearAnnotations()
        } catch {
            TutorDebugLog.write("⚠️ calibration failed: \(error.localizedDescription)")
        }
    }

    /// Takes the board and marks down a while after the answer finishes.
    ///
    /// They previously stayed until the next question, so a board left behind
    /// covered the screen indefinitely. The delay is generous on purpose: the
    /// diagram is the part worth looking at after the talking stops, and
    /// asking again clears it immediately anyway.
    private func scheduleMarkDismissal() {
        markDismissalTask?.cancel()
        markDismissalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.clearAnnotations()
        }
    }

    /// Where the words a mark belongs to start, so the mark appears as they
    /// are spoken rather than after.
    ///
    /// The model writes a tag after the phrase it marks: "the real separation
    /// is between workers and a shared storage layer like s3 [UNDERLINE:t44]".
    /// Fired at the tag, that underline landed ten seconds into the sentence,
    /// after the student had finished hearing about the thing it underlines.
    /// Backed up to the start of the clause, it appears as the phrase begins.
    /// Capped at about four seconds of speech, so a long clause does not mark
    /// its subject before it has been named at all.
    private static func offsetWhereMarkedPhraseBegins(tagOffset: Int, spokenText: String) -> Int {
        let characters = Array(spokenText)
        let clampedTagOffset = min(max(tagOffset, 0), characters.count)
        let longestLeadInCharacters = 60
        let clauseBoundaries: Set<Character> = [".", ",", ";", ":", "!", "?"]

        var phraseStart = clampedTagOffset
        // Step over any boundary sitting right at the tag, so "s3 [TAG]." backs
        // into its own clause rather than stopping at its own full stop.
        while phraseStart > 0, characters[phraseStart - 1] == " " {
            phraseStart -= 1
        }
        while phraseStart > 0,
              clampedTagOffset - phraseStart < longestLeadInCharacters,
              !clauseBoundaries.contains(characters[phraseStart - 1]) {
            phraseStart -= 1
        }
        // The cap can stop mid-word. Finish the word, so the count is in words.
        while phraseStart > 0, characters[phraseStart - 1].isLetter || characters[phraseStart - 1].isNumber {
            phraseStart -= 1
        }
        return phraseStart
    }

    /// Keeps marks attached to what they point at, and gives the student ways
    /// to get rid of them.
    ///
    /// A mark is drawn at a fixed place on the screen, and the content under
    /// it does not stay put: the student scrolls, or switches to another app,
    /// and the underline that was under "data lives once" is now under
    /// something else, or across a different window entirely.
    private func bindMarkLifetime() {
        notchActivityCancellable = $voiceState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .idle: self.controlBar.model.activity = .ready
                case .listening:
                    // A new question: the last one's words must not linger.
                    self.controlBar.model.heardWords = ""
                    self.controlBar.model.activity = .listening
                case .processing: self.controlBar.model.activity = .thinking
                case .responding: self.controlBar.model.activity = .speaking
                }
                InterfaceSounds.shared.isTutorSpeaking = state == .responding
                if state != .processing { self.controlBar.model.waitingStage = nil }
            }

        notchHeardWordsCancellable = buddyDictationManager.$liveTranscriptText
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] liveTranscriptText in
                // Empty when the session resets on release; the final question
                // is put in place by sendTranscriptToTutorWithScreenshot.
                guard let self, !liveTranscriptText.isEmpty else { return }
                self.controlBar.model.heardWords = Self.questionWithoutGreeting(liveTranscriptText)
            }

        controlBarDrawingCancellable = Publishers.CombineLatest3(
            $activeAnnotations, $spotlightRectsInGlobalPoints, $whiteboard
        )
        .map { annotations, spotlightRects, whiteboard in
            !annotations.isEmpty || !spotlightRects.isEmpty || whiteboard.hasContent
        }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] somethingIsDrawn in
            guard let self else { return }
            self.controlBar.model.hasDrawing = somethingIsDrawn || self.lessonPlayer.hasDrawing
        }

        // Esc clears, while there is something to clear. Observed, never
        // swallowed: the app in front still gets its Esc too.
        escapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.handleEscape() }
        }

        scrollWheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let hasPreciseDeltas = event.hasPreciseScrollingDeltas
            let verticalDelta = event.scrollingDeltaY
            Task { @MainActor in
                self?.followScroll(verticalDelta: verticalDelta, hasPreciseDeltas: hasPreciseDeltas)
            }
        }

        // Marks belong to the window they were drawn over. In another app
        // they point at nothing. The board stays: it is about the idea, not
        // about a place on the screen.
        applicationSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // This app coming forward (for a permission prompt) is not the
            // student leaving the content.
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard activatedApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            Task { @MainActor in self?.clearScreenMarks() }
        }
    }

    /// Moves screen marks with the content as it scrolls.
    ///
    /// A trackpad reports scrolling in points, and browsers move the page by
    /// that amount, so the marks can move with it. A mouse wheel reports
    /// lines, whose size in points depends on the app, so rather than guess,
    /// the marks are cleared. Positive deltas move content down the screen,
    /// which is downward in AppKit's bottom-left coordinates.
    private func followScroll(verticalDelta: CGFloat, hasPreciseDeltas: Bool) {
        guard verticalDelta != 0 else { return }
        if lessonPlayer.hasDrawing {
            // The drawing page is top-left origin, so content moving down is
            // a positive offset there.
            if hasPreciseDeltas {
                lessonPlayer.scrollScreenMarks(byPoints: verticalDelta)
            } else {
                lessonPlayer.clearScreenMarks()
            }
        }
        guard !activeAnnotations.isEmpty || !spotlightRectsInGlobalPoints.isEmpty else { return }

        guard hasPreciseDeltas else {
            clearScreenMarks()
            return
        }

        activeAnnotations = activeAnnotations.map { annotation in
            annotation.shiftedVertically(by: -verticalDelta)
        }
        spotlightRectsInGlobalPoints = spotlightRectsInGlobalPoints.map { rect in
            rect.offsetBy(dx: 0, dy: -verticalDelta)
        }
    }

    /// Removes marks drawn over screen content, keeping the board.
    private func clearScreenMarks() {
        lessonPlayer.clearScreenMarks()
        guard !activeAnnotations.isEmpty || !spotlightRectsInGlobalPoints.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            activeAnnotations.removeAll()
            spotlightRectsInGlobalPoints.removeAll()
        }
    }

    /// Wipes every mark and takes down the board.
    /// Whether anything was on screen to clear, so the student's own Clear
    /// and Esc can be heard to work while the clears that come with every
    /// new question stay silent.
    @discardableResult
    func clearAnnotations() -> Bool {
        let lessonHadDrawing = lessonPlayer.hasDrawing
        lessonPlayer.clear()
        let hasNothingToClear = activeAnnotations.isEmpty
            && spotlightRectsInGlobalPoints.isEmpty
            && !whiteboard.hasContent
        guard !hasNothingToClear else { return lessonHadDrawing }

        withAnimation(.easeOut(duration: 0.25)) {
            activeAnnotations.removeAll()
            spotlightRectsInGlobalPoints.removeAll()
            whiteboard = TutorWhiteboard()
        }
        return true
    }

    /// If the cursor is in transient mode, waits for speech and any pointing
    /// animation to finish, then fades the overlay out.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            while isAnyVoicePlaying || speechConsumerTask != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            clearAnnotations()
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Explains a failure out loud instead of leaving the user with silence.
    ///
    /// The common cause is the local server not running, which has a specific
    /// and actionable fix, so it gets its own message.
    private func speakLocalErrorFallback(for error: Error) async {
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

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately, the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static func onboardingDemoSystemPrompt(screenIndexListing: String) -> String {
        """
        you live on the user's screen and you are showing off for a moment. here is an exact inventory of what is on screen, each line an id and the text there:

        \(screenIndexListing)

        pick exactly ONE id that looks interesting and specific. prefer something with real identity, a filename, a heading, a button label, a line of code. avoid generic chrome.

        reply with a playful remark of six words or fewer, then the tag [CIRCLE:id] for the id you picked. nothing else. all lowercase. never quote the text back.

        example: "someone has been busy here [CIRCLE:t14]"
        """
    }

    /// Picks something on screen, remarks on it, and circles it.
    ///
    /// Runs during onboarding to show what the tutor can do before the user
    /// has asked anything. Uses the same index-and-mark path as a real answer,
    /// so if this works the main pipeline is wired correctly too.
    func performOnboardingDemoInteraction() {
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard let cursorScreenCapture = screenCaptures.first(where: { capture in
                    capture.isCursorScreen
                }) ?? screenCaptures.first else {
                    print("🎯 Onboarding demo: no screen captured")
                    return
                }

                displayFrameForCurrentAnswer = cursorScreenCapture.displayFrame

                await screenIndex.rebuild(
                    fromScreenshot: cursorScreenCapture.imageData,
                    displayIndex: 0,
                    displayBoundsInPoints: CGSize(
                        width: cursorScreenCapture.displayWidthInPoints,
                        height: cursorScreenCapture.displayHeightInPoints
                    )
                )

                let (responseText, _) = try await tutorBrain.analyzeImage(
                    images: [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label)],
                    systemPrompt: Self.onboardingDemoSystemPrompt(
                        screenIndexListing: screenIndex.renderForPrompt(maximumTargets: 60)
                    ),
                    conversationHistory: [],
                    userPrompt: "find something interesting on my screen"
                )

                let parsed = TeacherResponseParser.parse(rawResponse: responseText)
                guard !parsed.directives.isEmpty else {
                    print("🎯 Onboarding demo: model picked nothing")
                    return
                }

                detectedElementBubbleText = parsed.spokenText
                for directive in parsed.directives { apply(directive: directive, spokenContext: parsed.spokenText) }
                print("🎯 Onboarding demo: \"\(parsed.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error.localizedDescription)")
            }
        }
    }
}
