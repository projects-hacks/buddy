//
//  QAHooks.swift
//  leanring-buddy
//
//  A control channel for scripted end-to-end testing, so a test run can put
//  real questions through the whole pipeline (screen capture, sorting,
//  memory, routing, the model, the voice, the drawing) and look at the
//  result, without a microphone.
//
//  Debug builds only, and off unless `defaults write <bundle id>
//  qaHooksEnabled -bool true`: a release build has none of this code, and a
//  local build ignores every command until it is switched on. Commands
//  arrive as distributed notifications named "<bundle id>.qa" with a
//  "command" entry; each is written to the log with a 🧪, and its result
//  too, so the test reads the log rather than trusting the sender.
//

#if DEBUG
import AppKit
import Foundation

@MainActor
final class QAHooks {
    private unowned let companionManager: CompanionManager

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func start() {
        guard UserDefaults.standard.bool(forKey: "qaHooksEnabled") else { return }
        let name = Notification.Name((Bundle.main.bundleIdentifier ?? "buddy") + ".qa")
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            let info = (note.userInfo as? [String: String]) ?? [:]
            Task { @MainActor in self?.handle(info) }
        }
        TutorDebugLog.write("🧪 qa hooks listening")
    }

    private func handle(_ info: [String: String]) {
        let command = info["command"] ?? ""
        TutorDebugLog.write("🧪 qa: \(command) \(info["text"] ?? info["value"] ?? "")")
        switch command {
        case "ask":
            companionManager.qaAsk(info["text"] ?? "")
        case "snapshot":
            let path = info["value"] ?? NSTemporaryDirectory() + "buddy-qa.jpg"
            Task { @MainActor in
                guard let captures = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(),
                      let capture = captures.first(where: \.isCursorScreen) ?? captures.first else {
                    TutorDebugLog.write("🧪 qa: snapshot failed")
                    return
                }
                try? capture.imageData.write(to: URL(fileURLWithPath: path))
                TutorDebugLog.write("🧪 qa: snapshot saved \(path)")
            }
        case "state":
            companionManager.qaLogState()
        case "fakeKey":
            if let service = APIKeyStore.Service.allCases.first(where: { $0.humanReadableName == info["value"] }) {
                APIKeyStore.qaReplaceInMemory(with: "qa-not-a-real-key-0000000000000000", for: service)
            }
        case "clearFakeKeys":
            APIKeyStore.Service.allCases.forEach { APIKeyStore.qaReplaceInMemory(with: nil, for: $0) }
        case "brain":
            if let kind = TutorBrainKind(rawValue: info["value"] ?? "") { companionManager.setBrainKind(kind) }
        case "notch":
            companionManager.qaSetNotchOpen(info["value"] == "open")
        case "escape":
            companionManager.qaPressEscape()
        case "setup":
            companionManager.setupWindow.show(startingAt: SetupStep(rawValue: Int(info["value"] ?? "0") ?? 0) ?? .welcome)
        case "closeSetup":
            companionManager.setupWindow.close()
        case "memoryRecentSeconds":
            LearningMemory.stillInConversationSeconds = TimeInterval(info["value"] ?? "") ?? 20 * 60
        case "forgetMemory":
            companionManager.forgetLearningMemory()
        default:
            TutorDebugLog.write("🧪 qa: unknown command")
        }
    }
}
#endif
