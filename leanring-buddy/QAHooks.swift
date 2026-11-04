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

    private static func readStandardKey(_ service: APIKeyStore.Service) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", "api-key", "-s",
                             "\(AppIdentity.standardBundleIdentifier).\(service.rawValue)", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let key = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    private func handle(_ info: [String: String]) {
        let command = info["command"] ?? ""
        TutorDebugLog.write("🧪 qa: \(command) \(info["text"] ?? info["value"] ?? "")")
        switch command {
        case "ask":
            companionManager.qaAsk(info["text"] ?? "")
        case "snapshot":
            // Buddy's own windows included, unlike the capture sent to the
            // model: the notch and the drawing are what is being checked.
            let path = info["value"] ?? NSTemporaryDirectory() + "buddy-qa.png"
            Task { @MainActor in
                do {
                    try await CalibrationSnapshot.captureIncludingOverlay()
                    try? FileManager.default.removeItem(atPath: path)
                    try FileManager.default.copyItem(at: CalibrationSnapshot.outputURL, to: URL(fileURLWithPath: path))
                    TutorDebugLog.write("🧪 qa: snapshot saved \(path)")
                } catch {
                    TutorDebugLog.write("🧪 qa: snapshot failed: \(error.localizedDescription)")
                }
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
        case "setupName":
            companionManager.setStudentName(info["value"] ?? "")
            TutorDebugLog.write("🧪 qa: name is now \(companionManager.studentName)")
        case "checkKey":
            // The same check and save the setup window's Test and save runs.
            // The key is read from the standard Buddy's Keychain item by name,
            // so no key ever travels in a notification.
            guard let service = APIKeyStore.Service.allCases.first(where: { $0.humanReadableName == info["value"] }) else { return }
            let source = info["text"] == "invalid" ? "qa-not-a-real-key-0000000000000000"
                : (Self.readStandardKey(service) ?? "")
            Task { @MainActor in
                let result = await APIKeyChecker.check(source, for: service)
                TutorDebugLog.write("🧪 qa: check \(service.humanReadableName): usable=\(result.isUsable) \(result.message)")
                if result.isUsable {
                    let saved = APIKeyStore.save(key: source, for: service)
                    TutorDebugLog.write("🧪 qa: saved=\(saved)")
                    companionManager.keysDidChange()
                }
            }
        case "finishSetup":
            companionManager.finishSetup()
            companionManager.setupWindow.close()
        case "memoryRecentSeconds":
            LearningMemory.stillInConversationSeconds = TimeInterval(info["value"] ?? "") ?? 20 * 60
        case "checkUpdate":
            Task { @MainActor in
                await companionManager.appUpdater.check()
                TutorDebugLog.write("🧪 qa: update state \(companionManager.appUpdater.state), running \(companionManager.appUpdater.currentVersion)")
            }
        case "installUpdate":
            Task { @MainActor in await companionManager.appUpdater.installAvailableUpdate() }
        case "forgetMemory":
            companionManager.forgetLearningMemory()
        default:
            TutorDebugLog.write("🧪 qa: unknown command")
        }
    }
}
#endif
