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
import ScreenCaptureKit

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
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let keyData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let key = String(data: keyData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    /// About ten frames a second of one area of the main display, as JPEGs
    /// numbered in order, with the time of each in frames.txt.
    private static func recordFrames(seconds: Double, rect: CGRect, folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else { return }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.width = Int(rect.width * 2)
        configuration.height = Int(rect.height * 2)
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let started = Date()
        var index = 0
        var times = ""
        while Date().timeIntervalSince(started) < seconds {
            let frameStarted = Date()
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
               let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                try? data.write(to: folder.appendingPathComponent(String(format: "frame-%04d.jpg", index)))
                times += String(format: "%04d %.3f\n", index, frameStarted.timeIntervalSince(started))
                index += 1
            }
            let spent = Date().timeIntervalSince(frameStarted)
            if spent < 0.1 { try? await Task.sleep(nanoseconds: UInt64((0.1 - spent) * 1_000_000_000)) }
        }
        try? times.write(to: folder.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        TutorDebugLog.write("🧪 qa: recorded \(index) frames")
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
        case "holdTalk":
            companionManager.qaHoldTalkKeys(down: true)
        case "releaseTalk":
            companionManager.qaHoldTalkKeys(down: false)
        case "recordFrames":
            // Frames of the screen, Buddy's own windows included, for a demo
            // recording: value is "seconds,x,y,width,height" in points from
            // the top left, text is the folder.
            let numbers = (info["value"] ?? "").split(separator: ",").compactMap { Double($0) }
            guard numbers.count == 5, let folder = info["text"] else { return }
            Task { await Self.recordFrames(seconds: numbers[0],
                                           rect: CGRect(x: numbers[1], y: numbers[2], width: numbers[3], height: numbers[4]),
                                           folder: URL(fileURLWithPath: folder)) }
        case "notchTab":
            companionManager.qaSetNotchTab(info["value"] ?? "lesson")
        case "openChat":
            companionManager.qaOpenChat()
        case "chatDraft":
            companionManager.qaSetChatDraft(info["text"] ?? "")
        case "chatReturn":
            companionManager.qaPressChatReturn(withShift: info["value"] == "shift")
        case "closeChat":
            companionManager.qaCloseChat()
        case "sendChat":
            companionManager.qaSendChat()
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
