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

    /// Local inference server. No proxy and no API keys, because nothing
    /// leaves the machine: screen contents during a study session are about
    /// as private as data gets.
    /// Which brain answers this session. Persisted so the choice survives a
    /// restart, defaulting to local because it is free, private and offline.
    /// Defaults to the hosted brain. The local model reasons well about what
    /// is on screen and invents technical facts that are not, which is the
    /// failure that matters for studying: it named three different wrong
    /// inventors for quicksort across three runs, where Argon answered
    /// correctly first time. Local remains one switch away for working
    /// offline or avoiding the per-question cost.
    @Published private(set) var brainKind: TutorBrainKind = TutorBrainKind(
        rawValue: UserDefaults.standard.string(forKey: "tutorBrainKind") ?? ""
    ) ?? .hosted

    private lazy var localBrain = OllamaVisionProvider(model: selectedModel)
    /// Google Cloud project the hosted brain bills against.
    ///
    /// Overridable through defaults so the project can change without a
    /// rebuild. Vertex rather than AI Studio because only Vertex draws on this
    /// project's credits.
    private static var hostedProjectIdentifier: String {
        UserDefaults.standard.string(forKey: "vertexProjectIdentifier") ?? "medi-agent-490106"
    }

    private lazy var hostedBrain = GeminiVisionProvider(
        model: "gemini-4-argon",
        endpoint: .vertex(projectIdentifier: Self.hostedProjectIdentifier, location: "global")
    )

    /// The brain in use. Both conform to the same protocol, so nothing
    /// downstream of here knows or cares which one answered.
    private var tutorBrain: TutorBrain {
        switch brainKind {
        case .local: return localBrain
        case .hosted: return hostedBrain
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

    /// Inventory of what is addressable on screen for the current turn.
    ///
    /// Rebuilt per question rather than cached, because the screen has usually
    /// changed between one question and the next.
    private let screenIndex = ScreenIndex()

    /// Marks currently drawn on screen.
    @Published private(set) var activeAnnotations: [TeacherAnnotation] = []

    /// Regions kept lit while the rest of the screen dims. Empty means no spotlight.
    @Published private(set) var spotlightRectsInGlobalPoints: [CGRect] = []

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
    /// Scheduled hide for transient cursor mode — cancelled if the user
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
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
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
        TutorDebugLog.write("🔑 at launch — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Load the weights now rather than on the first question. A cold load
        // costs around ten seconds, which would otherwise land entirely inside
        // the user's first interaction and read as the app being broken.
        Task {
            let (isReachable, installedModels) = await tutorBrain.probeServer()
            isLocalModelReachable = isReachable
            TutorDebugLog.write("🧠 brain: \(brainKind.displayName) — \(isReachable ? "ready" : "UNREACHABLE")")

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
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
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
        // Screen content permission is persisted — once the user has approved the
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
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
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
    /// user grants them in System Settings. Screen Recording is the exception —
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
                // Don't override .responding — the AI response pipeline
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
                    // saying anything, no response task runs — schedule the
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
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToTutorWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
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
        - two to five marks in a reply is right. twenty is noise.

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
        - two to four sentences by default. if they ask you to go deeper, drop the limit and teach it properly.
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

    /// Captures the screen, indexes it, asks the local model, and narrates the
    /// answer while drawing on screen.
    ///
    /// Speech starts on the first complete sentence rather than waiting for the
    /// whole answer. That matters more than raw speed: the model generates
    /// roughly two and a half times faster than speech plays back, so once the
    /// first sentence is out the voice never catches up to the generator, and
    /// the only latency the user perceives is time-to-first-sentence.
    private func sendTranscriptToTutorWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        cancelSpeechAndClearQueue()

        // Counted before the answer is built, so the instruction reflects how
        // many times this idea has already failed to land.
        if Self.isAskingAgain(transcript) && !conversationHistory.isEmpty {
            consecutiveReexplanationCount += 1
            TutorDebugLog.write("🔁 student still lost, attempt \(consecutiveReexplanationCount + 1): switching tactic")
        } else {
            consecutiveReexplanationCount = 0
        }

        currentResponseTask = Task {
            voiceState = .processing
            clearAnnotations()

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
                tutorBrain.maximumResponseTokens = Self.isRequestForDepth(transcript) ? 700 : 380

                // A second attempt at the same idea needs room to actually
                // work the example through, not the terse default.
                if consecutiveReexplanationCount > 0 {
                    tutorBrain.maximumResponseTokens = max(tutorBrain.maximumResponseTokens, 450)
                }


                let (fullResponseText, duration) = try await tutorBrain.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.tutorSystemPrompt(
                        screenIndexListing: screenIndex.renderForPrompt()
                    ) + reexplanationInstruction(),
                    conversationHistory: historyForModel,
                    userPrompt: transcript,
                    onTextChunk: { [weak self] accumulatedText in
                        self?.enqueueCompletedSentences(fromStreamedText: accumulatedText)
                    }
                )

                guard !Task.isCancelled else { return }

                // The raw response, verbatim. When no marks appear this is the
                // only way to tell the two causes apart: the model emitting no
                // tags at all, versus tags that failed to resolve to a target.
                TutorDebugLog.write("RAW MODEL RESPONSE:\n\(fullResponseText)\n--- end ---")

                // Flush whatever trailed the final sentence terminator, which
                // the streaming path deliberately held back.
                enqueueRemainder(ofStreamedText: fullResponseText)

                let spokenOnlyText = TeacherResponseParser.parse(rawResponse: fullResponseText).spokenText
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenOnlyText
                ))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Answered in \(String(format: "%.1f", duration))s, history \(conversationHistory.count) exchanges")

            } catch is CancellationError {
                // User spoke again; the previous answer was abandoned on purpose.
            } catch {
                print("⚠️ Tutor response error: \(error.localizedDescription)")
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
                scheduleTransientHideIfNeeded()
            }
        }
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

    /// Whether the user is asking for a longer, fuller explanation.
    ///
    /// Deliberately a keyword check rather than a model call: it runs on every
    /// question, and spending a second of inference to decide how long the next
    /// answer may be would cost more than it saves.
    private static func isRequestForDepth(_ transcript: String) -> Bool {
        let lowercasedTranscript = transcript.lowercased()
        let depthPhrases = [
            "explain more", "go deeper", "deeper", "elaborate", "in detail",
            "more detail", "walk me through", "step by step", "why does",
            "teach me", "full explanation", "properly", "from scratch"
        ]
        return depthPhrases.contains { phrase in lowercasedTranscript.contains(phrase) }
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

        func drawMarksReached(upToCharacterOffset offset: Int) {
            while let next = undispatchedDirectives.first,
                  next.characterOffsetInSpokenText <= offset {
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
        drawMarksReached(upToCharacterOffset: Int.max)
    }

    /// Whether either speech engine is currently producing audio.
    private var isAnyVoicePlaying: Bool {
        speechClient.isPlaying || kokoroClient.isPlaying || deepgramClient.isPlaying
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
        TutorDebugLog.write("🖊️ \(identifier) -> rect (\(Int(rect.minX)),\(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height)) on display \(Int(displayFrame.width))x\(Int(displayFrame.height)) at \(Int(displayFrame.origin.x)),\(Int(displayFrame.origin.y)) — total now \(activeAnnotations.count), overlayVisible=\(isOverlayVisible)")
    }

    /// Wipes every mark and takes down the board.
    func clearAnnotations() {
        let hasNothingToClear = activeAnnotations.isEmpty
            && spotlightRectsInGlobalPoints.isEmpty
            && !whiteboard.hasContent
        guard !hasNothingToClear else { return }

        withAnimation(.easeOut(duration: 0.25)) {
            activeAnnotations.removeAll()
            spotlightRectsInGlobalPoints.removeAll()
            whiteboard = TutorWhiteboard()
        }
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
        let (isReachable, _) = await tutorBrain.probeServer()
        isLocalModelReachable = isReachable

        let spokenExplanation: String
        if !isReachable {
            spokenExplanation = "i can't reach the local model. start it by running brew services start ollama in a terminal."
        } else {
            spokenExplanation = "something went wrong answering that. check the console for details."
        }

        voiceState = .responding
        try? await speechClient.speakText(spokenExplanation)
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

        // Start playback immediately — the video plays while invisible,
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
