//
//  CompanionManager+Brains.swift
//  leanring-buddy
//
//  The brains as the views and the rest of the manager reach them, from
//  BrainLineup, plus what a key change touches beyond the brains: the
//  notch's alert row, setup, and the student's name.
//

import Combine
import Foundation

extension CompanionManager {
    typealias ArgonSource = BrainLineup.ArgonSource

    var brainKind: TutorBrainKind { brains.brainKind }
    var argonSource: ArgonSource { brains.argonSource }
    var vertexProjectIdentifier: String { brains.vertexProjectIdentifier }
    var canUseClaude: Bool { brains.canUseClaude }
    var canUseArgon: Bool { brains.canUseArgon }
    var usesVertexForArgon: Bool { brains.usesVertexForArgon }
    var hasHostedAPIKey: Bool { brains.hasHostedAPIKey }
    var keyProblem: (service: APIKeyStore.Service, message: String)? { brains.keyProblem }
    var tutorBrain: TutorBrain { brains.tutorBrain }
    var localBrain: OllamaVisionProvider { brains.localBrain }
    var hostedBrain: GeminiVisionProvider { brains.hostedBrain }
    var claudeBrain: ClaudeVisionProvider { brains.claudeBrain }
    var modelRouter: ModelRouter { brains.modelRouter }
    var selectedModel: String {
        get { brains.selectedModel }
        set { brains.selectedModel = newValue }
    }
    var isLocalModelReachable: Bool {
        get { brains.isLocalModelReachable }
        set { brains.isLocalModelReachable = newValue }
    }
    var lastAnsweringBrainName: String { brains.lastAnsweringBrainName }

    /// Connects the lineup once, before anything can change it: the views
    /// observe the manager, so every change in the lineup is passed on as a
    /// change of the manager's.
    func connectBrainLineup() {
        brainLineupCancellable = brains.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        brains.onKeyProblemMessageChanged = { [weak self] message in
            self?.controlBar.model.keyProblemMessage = message
        }
        brains.onKeyFailedTheAnswer = { [weak self] in
            self?.setupWindow.show(startingAt: .keys)
        }
    }

    func setArgonSource(_ source: ArgonSource, projectIdentifier: String? = nil) {
        brains.saveArgonSource(source, projectIdentifier: projectIdentifier)
        keysDidChange()
    }

    func checkGoogleCloud(projectIdentifier: String) async -> KeyCheckResult {
        await brains.checkGoogleCloud(projectIdentifier: projectIdentifier)
    }

    func setStudentName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        studentName = trimmed
        UserDefaults.standard.set(trimmed, forKey: "studentName")
    }

    /// Called after setup saves or removes a key, so the next question uses it.
    func keysDidChange() {
        brains.rebuildHostedBrain()
        brains.clearKeyProblem()
        brains.probeAfterKeysChanged()
    }

    var needsSetup: Bool {
        let hasFinishedSetup = UserDefaults.standard.bool(forKey: "hasFinishedSetup")
        let hasSomethingToThinkWith = canUseClaude || canUseArgon || brainKind == .local
        return !hasFinishedSetup || !hasSomethingToThinkWith
    }

    func finishSetup() {
        UserDefaults.standard.set(true, forKey: "hasFinishedSetup")
        keysDidChange()
    }

    func keyProblem(in error: Error) -> (service: APIKeyStore.Service, message: String)? {
        brains.keyProblem(in: error)
    }

    func reportKeyProblem(_ problem: (service: APIKeyStore.Service, message: String), answerFailed: Bool) {
        brains.reportKeyProblem(problem, answerFailed: answerFailed)
    }

    func clearKeyProblem() { brains.clearKeyProblem() }
    func reportDeepgramKeyProblem(_ error: Error) { brains.reportDeepgramKeyProblem(error) }
    func clearDeepgramKeyProblemIfReported() { brains.clearDeepgramKeyProblemIfReported() }

    func setBrainKind(_ kind: TutorBrainKind) { brains.setBrainKind(kind) }

    /// Saves a hosted API key and switches to it if it works.
    func saveHostedAPIKey(_ key: String) {
        guard APIKeyStore.save(key: key, for: .gemini) else { return }
        setBrainKind(.hosted)
    }

    func setSelectedModel(_ model: String) { brains.setSelectedModel(model) }

    /// The brains to try, best first, for the current Brain setting. Empty
    /// when the setting names a single brain, which the notch then does not name.
    func routeQuestion(probabilities: [QuestionKind: Double]) -> [RoutedBrain] {
        if brains.namesASingleBrain { controlBar.model.answeredBy = "" }
        return brains.routeQuestion(probabilities: probabilities)
    }

    /// Points the answer at one brain and sets it up for this question.
    func activate(_ brain: RoutedBrain) {
        brains.activate(brain)
        controlBar.model.answeredBy = brain.displayName
    }

    func configureLearningMemory() {
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
}
