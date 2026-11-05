//
//  BrainLineup.swift
//  leanring-buddy
//
//  Who can answer and who does: the Brain setting, the three brains (Argon,
//  Claude, the local model), how Argon is reached, whether the brain in use
//  answers, routing a question to a brain under Auto, and the key that
//  stopped working mid-use. CompanionManager owns one and forwards it to the
//  views, which read it through the manager.
//

import Combine
import Foundation

@MainActor
final class BrainLineup: ObservableObject {
    /// Which brain answers. Persisted so the choice survives a restart.
    ///
    /// Defaults to Auto, which picks among Sonnet, Opus and Argon per
    /// question (ModelRouter). Local stays out of the default: it reasons
    /// well about what is on screen and invents technical facts that are not,
    /// naming three different wrong inventors for quicksort across three runs.
    @Published private(set) var brainKind: TutorBrainKind = TutorBrainKind(
        rawValue: UserDefaults.standard.string(forKey: "tutorBrainKind") ?? ""
    ) ?? .auto

    /// Local model used for voice responses. Persisted to UserDefaults.
    ///
    /// Defaults to the 4B after measuring all three candidates on this class of
    /// machine. It is the only one that generates faster than speech plays back,
    /// which is what keeps the voice loop from stalling mid-sentence, and the
    /// only one that stays resident on 16 GB without forcing the system to swap.
    /// See docs/model-choice.md for the numbers.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedLocalModel") ?? "qwen3.5:4b"

    /// Whether the local model server was reachable at last check, so the
    /// panel can say "start Ollama" instead of failing mid-question.
    @Published var isLocalModelReachable = true {
        didSet { if !isLocalModelReachable { brainKindKnownReachable = nil } }
    }
    /// The brain a probe last found answering, so the periodic probe stops
    /// once it is known and starts again when the brain changes or fails.
    private var brainKindKnownReachable: TutorBrainKind?
    private var isProbingBrain = false

    /// A key that stopped working mid-use, shown in the notch until fixed.
    @Published private(set) var keyProblem: (service: APIKeyStore.Service, message: String)?
    /// The notch's alert row for a key problem, or nil to clear it.
    var onKeyProblemMessageChanged: (String?) -> Void = { _ in }
    /// A key failed and nothing else could answer: setup opens on the keys.
    var onKeyFailedTheAnswer: () -> Void = {}

    lazy var localBrain = OllamaVisionProvider(model: selectedModel)
    private(set) var hostedBrain = BrainLineup.makeHostedBrain()
    lazy var claudeBrain = ClaudeVisionProvider(model: "claude-sonnet-5-5")

    /// Picks Sonnet, Opus or Argon per question under Auto, and Sonnet or
    /// Opus under Claude.
    let modelRouter = ModelRouter()

    /// The brain Auto picked for the answer in progress.
    var autoAnsweringBrain: RoutedBrain = .argon

    /// Who answered the last question, for the push-back log line.
    var lastAnsweringBrainName = "nobody"

    // MARK: - How Argon is reached

    /// A Google Cloud project to bill Argon against through Vertex, for
    /// anyone set up with gcloud (`defaults write com.maverickrajeev.clicky-local
    /// vertexProjectIdentifier <project>`). Vertex rather than AI Studio when
    /// both exist, because only Vertex draws on a project's credits. Nobody
    /// else's project is ever assumed: without one, Argon uses a Gemini key.
    static var hostedProjectIdentifier: String? {
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

    /// Saves how Argon is reached; the caller then treats it as a key change.
    func saveArgonSource(_ source: ArgonSource, projectIdentifier: String?) {
        UserDefaults.standard.set(source.rawValue, forKey: "argonSource")
        if let projectIdentifier {
            let trimmed = projectIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: "vertexProjectIdentifier")
        }
        objectWillChange.send()
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

    static func makeHostedBrain() -> GeminiVisionProvider {
        if argonSource == .googleCloud, let project = hostedProjectIdentifier {
            return GeminiVisionProvider(model: "gemini-4-argon", endpoint: .vertex(projectIdentifier: project, location: "global"))
        }
        return GeminiVisionProvider(model: "gemini-4-argon", endpoint: .aiStudio)
    }

    /// A key or the Argon source changed: the next question uses the new one.
    func rebuildHostedBrain() {
        hostedBrain = Self.makeHostedBrain()
    }

    // MARK: - Who can answer

    /// Claude can answer: an Anthropic key is saved.
    var canUseClaude: Bool { APIKeyStore.hasKey(for: .anthropic) }
    /// Argon can answer: a Gemini key, or a Vertex project.
    var canUseArgon: Bool {
        argonSource == .googleCloud ? Self.hostedProjectIdentifier != nil : APIKeyStore.hasKey(for: .gemini)
    }
    var usesVertexForArgon: Bool { argonSource == .googleCloud && Self.hostedProjectIdentifier != nil }
    var hasHostedAPIKey: Bool { APIKeyStore.hasKey(for: .gemini) }

    /// The brain in use. All conform to the same protocol, so nothing
    /// downstream of here knows or cares which one answered.
    var tutorBrain: TutorBrain {
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

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedLocalModel")
        localBrain.model = model
        Task { await tutorBrain.preloadModel() }
    }

    // MARK: - Whether the brain answers

    /// After a key change: assumed reachable until the probe says otherwise.
    func probeAfterKeysChanged() {
        isLocalModelReachable = true
        Task {
            let (isReachable, _) = await tutorBrain.probeServer()
            isLocalModelReachable = isReachable
        }
    }

    /// The periodic probe, on the permission poll's slower beat.
    ///
    /// Only until the brain is known to answer: probing a reachable
    /// brain all day costs a request every twelve seconds (a real
    /// model listing for an AI Studio key). A failed answer marks
    /// it unreachable, and waking re-probes, which starts this again.
    /// Never two probes at once, however slow one is.
    func probeIfStillUnknown(shouldProbeModelServer: Bool) async {
        let brainNeedsProbing = !isLocalModelReachable || brainKindKnownReachable != brainKind
        if shouldProbeModelServer, brainNeedsProbing, !isProbingBrain {
            isProbingBrain = true
            defer { isProbingBrain = false }
            let brainKindProbed = brainKind
            let (isReachable, _) = await tutorBrain.probeServer()
            brainKindKnownReachable = isReachable ? brainKindProbed : nil
            if isReachable != isLocalModelReachable {
                isLocalModelReachable = isReachable
                if isReachable {
                    print("🦙 Ollama came back, preloading \(selectedModel)")
                    await tutorBrain.preloadModel()
                }
            }
        }
    }

    /// The brain may have been unreachable while the Mac slept.
    func probeAfterWake() {
        Task { [weak self] in
            guard let self, !self.isProbingBrain else { return }
            self.isProbingBrain = true
            defer { self.isProbingBrain = false }
            let brainKindProbed = self.brainKind
            let (isReachable, _) = await self.tutorBrain.probeServer()
            self.isLocalModelReachable = isReachable
            self.brainKindKnownReachable = isReachable ? brainKindProbed : nil
            TutorDebugLog.write("☀️ after waking, the brain is \(isReachable ? "reachable" : "UNREACHABLE")")
        }
    }

    // MARK: - Routing a question

    /// Whether the Brain setting names one brain, so nothing is routed.
    var namesASingleBrain: Bool { brainKind == .hosted || brainKind == .local }

    /// The brains to try, best first, for the current Brain setting. Empty
    /// when the setting names a single brain.
    func routeQuestion(probabilities: [QuestionKind: Double]) -> [RoutedBrain] {
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
            lastAnsweringBrainName = brainKind.displayName
            return []
        }
        let choice = modelRouter.choose(probabilities: probabilities, allowed: allowed)
        TutorDebugLog.write("🧭 route: \(choice.ranking.map(\.rawValue).joined(separator: " > ")) (\(choice.explanation))")
        return choice.ranking
    }

    /// Points the answer at one brain and sets it up for this question.
    func activate(_ brain: RoutedBrain) {
        autoAnsweringBrain = brain
        switch brain {
        case .sonnet: claudeBrain.apply(.sonnetWithoutThinking)
        case .opus: claudeBrain.apply(.opusThinkingLow)
        case .argon: break
        }
        lastAnsweringBrainName = brain.displayName
        TutorDebugLog.write("🧭 answered by \(brain.displayName)")
    }

    // MARK: - A key that stopped working

    /// The key problem in an error, worded for how Argon is reached: on Google
    /// Cloud there is no Gemini key, so the fix is the project, not a key.
    func keyProblem(in error: Error) -> (service: APIKeyStore.Service, message: String)? {
        guard let problem = APIKeyChecker.problem(in: error) else { return nil }
        if problem.service == .gemini, usesVertexForArgon {
            return (.gemini, "Argon couldn't use the Google Cloud project \(vertexProjectIdentifier). Check that Vertex is enabled on it and gcloud is signed in.")
        }
        return problem
    }

    /// Records a key that failed during use: opens setup on it when the
    /// question could not be answered at all, and otherwise just says so in
    /// the notch, since another brain covered for it.
    func reportKeyProblem(_ problem: (service: APIKeyStore.Service, message: String), answerFailed: Bool) {
        TutorDebugLog.write("🔑 \(problem.service.humanReadableName) key problem: \(problem.message)")
        keyProblem = problem
        let label = problem.service == .gemini && usesVertexForArgon ? "Google Cloud project" : "\(problem.service.humanReadableName) key"
        // The first sentence is the news, shown bold in the alert row; the
        // checker's own sentence after it says what is wrong and the fix.
        onKeyProblemMessageChanged("Your \(label) stopped working. \(problem.message)")
        if answerFailed { onKeyFailedTheAnswer() }
    }

    /// The reported key works again, or was replaced.
    func clearKeyProblem() {
        keyProblem = nil
        onKeyProblemMessageChanged(nil)
    }

    /// Deepgram refused the key, while speaking or while listening: said in
    /// the notch's banner like any other key, without opening setup mid-answer.
    func reportDeepgramKeyProblem(_ error: Error) {
        guard let problem = APIKeyChecker.problem(in: error), problem.service == .deepgram,
              keyProblem?.service != .deepgram else { return }
        reportKeyProblem(problem, answerFailed: false)
    }

    /// A Deepgram request worked, so a banner about its key can go.
    func clearDeepgramKeyProblemIfReported() {
        guard keyProblem?.service == .deepgram else { return }
        clearKeyProblem()
    }
}
