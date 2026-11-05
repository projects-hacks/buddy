//
//  SetupWindow.swift
//  leanring-buddy
//
//  First-run setup, for anyone who downloads Buddy, in four steps: Welcome
//  (their name), Keys (their own API keys), Permissions (the three macOS
//  permissions) and Try it (a real hold of Control + Option, heard on the
//  Mac and never sent to a model). Opened again from Settings to change
//  keys, from the notch's alert row for a missing permission, and on its
//  own when a key stops working mid-use, on the step that fixes it.
//
//  A real window rather than the notch, because typing needs a window that
//  can take the keyboard, and the notch is built never to take focus from
//  the app being studied.
//
//  Keys are tested before they are saved (APIKeyChecker), so a wrong key is
//  caught while the person is still looking at it, with a sentence saying
//  what is wrong, a Try again, and a Save anyway for when only the network
//  is the problem. Nothing is sent anywhere but the service the key is for.
//

import AppKit
import AVFoundation
import Combine
import Speech
import SwiftUI

enum SetupStep: Int, CaseIterable {
    case welcome, keys, permissions, done
}

@MainActor
final class SetupModel: ObservableObject {
    enum KeyState: Equatable {
        case empty
        /// Saved earlier; the last four characters, so it can be recognised.
        case saved(lastFour: String)
        case checking
        case result(KeyCheckResult)
    }

    @Published var step: SetupStep = .welcome
    @Published var name = ""
    @Published var entered: [APIKeyStore.Service: String] = [:]
    @Published var states: [APIKeyStore.Service: KeyState] = [:]
    @Published var editing: Set<APIKeyStore.Service> = []

    static let services: [APIKeyStore.Service] = [.anthropic, .gemini, .deepgram]

    func reload(from companionManager: CompanionManager) {
        name = companionManager.studentName.isEmpty
            ? (NSFullUserName().split(separator: " ").first.map(String.init) ?? "")
            : companionManager.studentName
        for service in Self.services {
            if let key = APIKeyStore.key(for: service) {
                states[service] = .saved(lastFour: String(key.suffix(4)))
            } else if case .result = states[service] {
                // Keep a failed check on screen until it is retried.
            } else {
                states[service] = .empty
            }
        }
    }
}

@MainActor
final class SetupWindowController {
    private var window: NSWindow?
    private let model = SetupModel()
    private unowned let companionManager: CompanionManager
    /// The last step's real check of the shortcut and the microphone.
    let shortcutTrial = SetupShortcutTrial()

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func show(startingAt step: SetupStep) {
        // The drawing lives in a window above every app, setup included; an
        // old lesson's cards would sit on top of the key fields.
        companionManager.clearAnnotations()
        // The open notch sits above every window too, and setup is usually
        // opened from it: left open, it would cover the window it opened.
        companionManager.closeNotchForSetup()
        model.reload(from: companionManager)
        model.step = step
        if let problem = companionManager.keyProblem {
            model.states[problem.service] = .result(.rejected(problem.message))
            model.editing.insert(problem.service)
        }
        let window = self.window ?? makeWindow()
        self.window = window
        // A menu bar app is never the active app on its own; it has to ask,
        // or the window opens behind everything and cannot take typing.
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// While the Try it step is on screen, Control + Option belongs to its
    /// check, and no question is asked.
    var isTryingTheShortcut: Bool { isVisible && model.step == .done }

    func close() {
        window?.orderOut(nil)
        shortcutTrial.reset()
        // A pasted key that was never saved does not outlive the window.
        model.entered = [:]
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Above other apps' windows while open: macOS no longer lets an app
        // put itself in front of the one being used, and a first-run window
        // that opens behind the browser is a setup nobody sees.
        window.level = .floating
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Set up Buddy"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(white: 0.07, alpha: 1)
        window.contentView = NSHostingView(rootView: SetupView(
            model: model,
            companionManager: companionManager,
            shortcutTrial: shortcutTrial,
            onFinish: { [weak self] in
                self?.companionManager.finishSetup()
                self?.close()
            }
        ))
        return window
    }
}

// MARK: - The view

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var shortcutTrial: SetupShortcutTrial
    let onFinish: () -> Void
    @State private var opensAtLogin = true

    var body: some View {
        VStack(spacing: 0) {
            stepDots
                .padding(.top, 30)
            Group {
                switch model.step {
                case .welcome: welcome
                case .keys: keys
                case .permissions: permissions
                case .done: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            .padding(.top, 26)
            .transition(.opacity)
            .id(model.step)
        }
        .frame(width: 580, height: 640)
        .background(Color(white: 0.07))
        .animation(.smooth(duration: 0.25), value: model.step)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Set up Buddy, step \(model.step.rawValue + 1) of \(SetupStep.allCases.count)")
    }

    /// The one progress indicator: a dot per step, the current one long.
    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step == model.step ? Color.white : Color.white.opacity(step.rawValue < model.step.rawValue ? 0.5 : 0.22))
                    .frame(width: step == model.step ? 22 : 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .shadow(color: Color(red: 0.35, green: 0.55, blue: 1.0).opacity(0.45), radius: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hi, this is Buddy.")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                    Text("Ask about anything on your screen. Buddy explains it out loud and draws on it while it talks.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SetupWelcomeScene()
                .frame(height: 150)
                .padding(.top, 24)
                .accessibilityHidden(true)

            HStack(alignment: .top, spacing: 14) {
                SetupFact(symbol: "keyboard", text: "Hold Control + Option to ask, or type.")
                SetupFact(symbol: "rectangle.and.pencil.and.ellipsis", text: "Teaches new topics on a board.")
                SetupFact(symbol: "point.3.connected.trianglepath.dotted", text: "Remembers what you learn, on this Mac.")
            }
            .padding(.top, 20)

            VStack(alignment: .leading, spacing: 9) {
                Text("What should Buddy call you?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                SetupNameField(name: $model.name, onSubmit: continueFromWelcome)
            }
            .padding(.top, 24)

            Spacer(minLength: 16)
            SetupFooter {
                Text("About 2 minutes: your name, a key, three permissions.")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textTertiary)
            } trailing: {
                SetupPrimaryButton(title: "Continue", isEnabled: !model.name.trimmingCharacters(in: .whitespaces).isEmpty,
                                   action: continueFromWelcome)
            }
        }
    }

    private func continueFromWelcome() {
        guard !model.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        companionManager.setStudentName(model.name)
        model.step = .keys
    }

    // MARK: Keys

    private var hasSomethingToThinkWith: Bool {
        companionManager.canUseClaude || companionManager.canUseArgon || companionManager.brainKind == .local
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your keys")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text("Buddy runs on your own accounts, so you only pay for what you use: about one to six cents a question. Keys stay in this Mac's Keychain and go only to the service they belong to.")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 10) {
                    KeyCard(service: .anthropic, title: "Anthropic", badge: "Recommended",
                            detail: "Claude Sonnet and Opus answer, and Claude Haiku sorts questions and keeps your learning memory.",
                            model: model, companionManager: companionManager)
                    GeminiCard(model: model, companionManager: companionManager)
                    KeyCard(service: .deepgram, title: "Deepgram", badge: "Optional",
                            detail: "A natural voice, and sharper hearing for technical words. Without it, macOS's own voice and recognizer are used.",
                            model: model, companionManager: companionManager)
                }
            }

            SetupFooter {
                SetupBackButton { model.step = .welcome }
            } trailing: {
                if !hasSomethingToThinkWith {
                    Text("Add an Anthropic or a Gemini key to continue.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                SetupPrimaryButton(title: "Continue", isEnabled: hasSomethingToThinkWith) {
                    companionManager.keysDidChange()
                    model.step = companionManager.allPermissionsGranted ? .done : .permissions
                }
            }
        }
    }

    // MARK: Permissions

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Three permissions")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text("Buddy only looks at your screen when you ask.")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.62))

            ScrollView {
                CompanionPanelView(companionManager: companionManager, isEmbedded: true, showsOnlyPermissions: true)
                    .padding(.vertical, 6)
            }

            SetupFooter {
                SetupBackButton { model.step = .keys }
            } trailing: {
                SetupPrimaryButton(title: companionManager.allPermissionsGranted ? "Continue" : "Skip for now", isEnabled: true) {
                    model.step = .done
                }
            }
        }
    }

    // MARK: Try it

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("You're set, \(companionManager.studentName.isEmpty ? "friend" : companionManager.studentName).")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)

            SetupTryCard(trial: shortcutTrial, hasAccessibilityPermission: companionManager.hasAccessibilityPermission)
                .padding(.top, 20)

            Text("Three more ways in")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
                .padding(.top, 24)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
                SetupWayIn(symbol: "keyboard", title: "Control + Option + T to type",
                           detail: "For code, error messages, or a quiet library.")
                SetupWayIn(symbol: "rectangle.and.pencil.and.ellipsis", title: "\u{201C}Teach me \u{2026} from scratch\u{201D}",
                           detail: "Opens a board for a new topic. Esc leaves it.")
                SetupWayIn(symbol: "book.closed", title: "Hover the notch",
                           detail: "Your last lesson, the day's chat, the Notebook, the Map and Settings.")
            }
            .padding(.top, 12)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Buddy when you log in")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Change it any time in Settings.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                Spacer()
                Toggle("", isOn: $opensAtLogin)
                    .toggleStyle(NotchSwitchStyle())
                    .labelsHidden()
                    .allowsHitTesting(false)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
            .contentShape(Rectangle())
            .onTapGesture { opensAtLogin.toggle() }
            .pointerCursor()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Open Buddy when you log in")
            .accessibilityValue(opensAtLogin ? "on" : "off")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { opensAtLogin.toggle() }
            .padding(.top, 18)

            Spacer(minLength: 12)
            SetupFooter {
                SetupBackButton { model.step = .keys }
            } trailing: {
                SetupPrimaryButton(title: "Start using Buddy", isEnabled: true) {
                    LoginItem.setChosen(opensAtLogin)
                    onFinish()
                }
            }
        }
        .onDisappear { shortcutTrial.reset() }
    }
}

// MARK: - Welcome pieces

/// Where Buddy lives, drawn small and not interactive: the notch saying
/// "explaining" over a ringed line of code, and a paper card beside it.
private struct SetupWelcomeScene: View {
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.24, blue: 0.36), Color(red: 0.14, green: 0.15, blue: 0.22)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)

            // The code being studied, one line ringed.
            VStack(alignment: .leading, spacing: 6) {
                Text("for i in range(len(nums)):")
                Text("for j in range(len(nums)):")
                    .padding(.horizontal, 4)
                    .overlay(Capsule().stroke(Color(hex: "#3B82F6"), lineWidth: 2).padding(-3))
                    .padding(.leading, 12)
                Text("if nums[i] + nums[j] == t:")
                    .padding(.leading, 28)
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color(hex: "#9DC2FF"))
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.13)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 36)
            .padding(.top, 62)

            // The paper card, written by hand.
            VStack(alignment: .leading, spacing: 4) {
                Text("i = 0, j = 0")
                    .foregroundStyle(DS.Paper.ink)
                Text("pairs 3 with itself")
                    .foregroundStyle(Color(hex: "#D9363E"))
            }
            .font(.custom("Noteworthy", size: 17))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 168, height: 82, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Paper.board))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .rotationEffect(.degrees(-1.5))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 30)
            .padding(.top, 50)

            // The notch, explaining.
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(DS.Notch.dotSpeaking).frame(width: 7, height: 7)
                    Text("explaining")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Text("This loop starts at zero, so it pairs a number with itself.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14).fill(Color.black))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SetupFact: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Colors.accentText)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The name field, with a focus ring in the accent colour.
private struct SetupNameField: View {
    @Binding var name: String
    let onSubmit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "person")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.45))
            TextField("Your first name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .focused($isFocused)
                .onSubmit(onSubmit)
                .accessibilityLabel("What should Buddy call you?")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isFocused ? DS.Colors.accentText.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(DS.Colors.accent.opacity(isFocused ? 0.25 : 0), lineWidth: 3)
            .padding(-1.5))
        .overlay(IBeamCursorView())
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .onAppear { isFocused = true }
    }
}

// MARK: - Try it

/// Hold Control + Option and say hello: the shortcut and the microphone,
/// checked for real. What is heard is recognised on the Mac (Apple Speech)
/// and shown, and nothing is sent anywhere, to a model or otherwise.
@MainActor
final class SetupShortcutTrial: ObservableObject {
    enum Outcome: Equatable {
        case waiting
        case listening
        case heard
        case nothingHeard
    }

    // Set only by the trial itself in the app; left settable inside the
    // module so a render of the step can show each state.
    @Published var areKeysHeld = false
    @Published var heardWords = ""
    @Published var outcome: Outcome = .waiting

    private var audioEngine: AVAudioEngine?
    private var transcriptionSession: (any BuddyStreamingTranscriptionSession)?
    private let speechRecognizer = AppleSpeechTranscriptionProvider()
    private var loudestDecibels: Float = -120
    private var nothingHeardTimer: Task<Void, Never>?
    private var sessionGeneration = 0

    /// A voice at the Mac, well above a quiet room, as the talk-over
    /// listener measures it.
    private static let loudEnoughDecibels: Float = -40

    func keysPressed() {
        guard !areKeysHeld else { return }
        areKeysHeld = true
        heardWords = ""
        loudestDecibels = -120
        outcome = .listening
        sessionGeneration += 1
        let generation = sessionGeneration
        Task { @MainActor in
            await startListening(generation: generation)
        }
        // Nothing in three seconds, while still held: say so, and keep listening.
        nothingHeardTimer?.cancel()
        nothingHeardTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, self.areKeysHeld, !self.hasHeardAnything else { return }
            self.outcome = .nothingHeard
        }
    }

    func keysReleased() {
        guard areKeysHeld else { return }
        areKeysHeld = false
        nothingHeardTimer?.cancel()
        transcriptionSession?.requestFinalTranscript()
        let generation = sessionGeneration
        // The last words land a moment after the keys come up.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, self.sessionGeneration == generation else { return }
            self.stopListening()
            self.outcome = self.hasHeardAnything ? .heard : .nothingHeard
            if self.outcome == .heard {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                    .announcement: "Buddy heard you.",
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ])
            }
        }
    }

    func reset() {
        sessionGeneration += 1
        nothingHeardTimer?.cancel()
        stopListening()
        areKeysHeld = false
        heardWords = ""
        outcome = .waiting
    }

    private var hasHeardAnything: Bool {
        !heardWords.trimmingCharacters(in: .whitespaces).isEmpty || loudestDecibels >= Self.loudEnoughDecibels
    }

    private func startListening(generation: Int) async {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        // Words need speech recognition; without it the check still knows
        // the microphone heard a voice, from how loud it was.
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        guard sessionGeneration == generation, areKeysHeld else { return }
        if SFSpeechRecognizer.authorizationStatus() == .authorized {
            transcriptionSession = try? await speechRecognizer.startStreamingSession(
                keyterms: ["Buddy"],
                onTranscriptUpdate: { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.heardWords = text
                        if self.outcome == .nothingHeard { self.outcome = .listening }
                    }
                },
                onFinalTranscriptReady: { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.sessionGeneration == generation, !text.isEmpty else { return }
                        self.heardWords = text
                    }
                },
                onError: { _ in })
        }
        guard sessionGeneration == generation, areKeysHeld else {
            stopListening()
            return
        }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return }
        let session = transcriptionSession
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            session?.appendAudioBuffer(buffer)
            let decibels = Self.decibels(of: buffer)
            DispatchQueue.main.async {
                guard let self, self.sessionGeneration == generation else { return }
                self.loudestDecibels = max(self.loudestDecibels, decibels)
            }
        }
        engine.prepare()
        do {
            try engine.start()
            audioEngine = engine
        } catch {
            inputNode.removeTap(onBus: 0)
        }
    }

    private func stopListening() {
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        transcriptionSession?.cancel()
        transcriptionSession = nil
    }

    private nonisolated static func decibels(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -120 }
        var sumOfSquares: Float = 0
        for index in 0..<Int(buffer.frameLength) { sumOfSquares += samples[index] * samples[index] }
        let rootMeanSquare = sqrt(sumOfSquares / Float(buffer.frameLength))
        return rootMeanSquare > 0 ? 20 * log10(rootMeanSquare) : -120
    }
}

/// The green card on the last step: large keycaps that light while held,
/// the words heard, and what that means.
private struct SetupTryCard: View {
    @ObservedObject var trial: SetupShortcutTrial
    let hasAccessibilityPermission: Bool

    private static let tint = DS.Colors.success

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TRY IT NOW")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Self.tint)
            HStack(spacing: 12) {
                Text("Hold")
                SetupBigKeycap(symbol: "\u{2303}", name: "Control", isHeld: trial.areKeysHeld)
                SetupBigKeycap(symbol: "\u{2325}", name: "Option", isHeld: trial.areKeysHeld)
                Text("and say hello.")
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)

            if !trial.heardWords.isEmpty || trial.areKeysHeld {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(trial.heardWords.isEmpty ? "Listening\u{2026}" : trial.heardWords)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(trial.heardWords.isEmpty ? 0.55 : 0.92))
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
                }
                .transition(.opacity)
            }

            resultLine
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Self.tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Self.tint.opacity(0.4), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: trial.areKeysHeld)
        .animation(.easeOut(duration: 0.2), value: trial.outcome)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var resultLine: some View {
        if !hasAccessibilityPermission {
            SetupTrialProblem(text: "The shortcut isn't reaching Buddy. Allow Accessibility.") {
                WindowPositionManager.openAccessibilitySettings()
            }
        } else {
            switch trial.outcome {
            case .heard:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                    Text("Buddy heard you. The microphone and the shortcut both work.")
                        .font(.system(size: 13.5, weight: .semibold))
                }
                .foregroundStyle(Self.tint)
            case .nothingHeard:
                SetupTrialProblem(text: "Nothing heard. Check the microphone in System Settings.") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .waiting, .listening:
                Text("Nothing you say here is sent anywhere. You can also skip this.")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textTertiary)
            }
        }
    }
}

private struct SetupTrialProblem: View {
    let text: String
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Colors.warning)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Open", action: openSettings)
                .buttonStyle(SetupSmallButtonStyle())
                .pointerCursor()
                .accessibilityLabel("Open System Settings")
        }
    }
}

/// A key, large, lit green while it is held down.
private struct SetupBigKeycap: View {
    let symbol: String
    let name: String
    let isHeld: Bool

    var body: some View {
        Text(symbol)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 40)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isHeld ? DS.Colors.success.opacity(0.25) : Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isHeld ? DS.Colors.success.opacity(0.7) : Color.white.opacity(0.2), lineWidth: 1))
            .offset(y: isHeld ? 1 : 0)
            .accessibilityLabel(name + (isHeld ? ", held" : ""))
    }
}

private struct SetupWayIn: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.Colors.accentText)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Keys

/// One service's key: saved, being typed, being tested, or what went wrong.
private struct KeyCard: View {
    let service: APIKeyStore.Service
    let title: String
    let badge: String
    let detail: String
    @ObservedObject var model: SetupModel
    let companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                SetupBadge(text: badge)
                Spacer()
                SetupLink(title: "Get a key", destination: APIKeyChecker.signUpLink(for: service))
            }
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            KeyFieldAndStatus(service: service, model: model, companionManager: companionManager)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(KeyFieldAndStatus.borderColour(for: model.states[service] ?? .empty), lineWidth: 1))
    }
}

/// The key field, its Test and save, and what came of it. Shared by the
/// plain cards and the Gemini card, which has a choice above it.
private struct KeyFieldAndStatus: View {
    let service: APIKeyStore.Service
    @ObservedObject var model: SetupModel
    let companionManager: CompanionManager

    private var state: SetupModel.KeyState { model.states[service] ?? .empty }
    private var isEditing: Bool {
        if model.editing.contains(service) { return true }
        if case .saved = state { return false }
        return true
    }
    private var entered: Binding<String> {
        Binding(get: { model.entered[service] ?? "" }, set: { model.entered[service] = $0 })
    }

    static func borderColour(for state: SetupModel.KeyState) -> Color {
        switch state {
        case .result(let result) where !result.isUsable: return DS.Colors.warning.opacity(0.55)
        case .saved, .result: return DS.Colors.success.opacity(0.35)
        default: return Color.white.opacity(0.08)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isEditing {
                HStack(spacing: 8) {
                    SecureField("Paste your \(service.humanReadableName) key", text: entered)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
                        .foregroundStyle(.white)
                        .overlay(IBeamCursorView())
                        .onSubmit(testAndSave)
                        .accessibilityLabel("\(service.humanReadableName) key")
                    Button(state == .checking ? "Testing" : "Test and save", action: testAndSave)
                        .buttonStyle(SetupSmallButtonStyle())
                        .disabled(state == .checking || (model.entered[service] ?? "").isEmpty)
                        .pointerCursor(isEnabled: state != .checking && !(model.entered[service] ?? "").isEmpty)
                    if model.editing.contains(service), APIKeyStore.hasKey(for: service) {
                        Button("Cancel") {
                            model.editing.remove(service)
                            model.reload(from: companionManager)
                        }
                        .buttonStyle(SetupSmallButtonStyle())
                        .pointerCursor()
                    }
                }
            }
            statusLine
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .empty:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing with \(service.humanReadableName)...")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.6))
            }
        case .saved(let lastFour):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Colors.success)
                Text("Saved, ending in \(lastFour)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                if !isEditing {
                    Button("Change") { model.editing.insert(service) }
                        .buttonStyle(SetupSmallButtonStyle())
                        .pointerCursor()
                    Button("Remove") {
                        APIKeyStore.deleteKey(for: service)
                        model.states[service] = .empty
                        model.entered[service] = ""
                        companionManager.keysDidChange()
                    }
                    .buttonStyle(SetupSmallButtonStyle())
                    .pointerCursor()
                }
            }
        case .result(let result):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: result.isUsable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.isUsable ? DS.Colors.success : DS.Colors.warning)
                Text(result.isUsable ? "Saved. \(result.message == "Works." ? "" : result.message)" : result.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if case .couldNotCheck = result {
                    Button("Save anyway") { save(model.entered[service] ?? "", note: nil) }
                        .buttonStyle(SetupSmallButtonStyle())
                        .disabled((model.entered[service] ?? "").isEmpty)
                        .pointerCursor(isEnabled: !(model.entered[service] ?? "").isEmpty)
                }
            }
        }
    }

    private func testAndSave() {
        let key = (model.entered[service] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Return pressed again mid-test would pay for a second identical check.
        guard !key.isEmpty, state != .checking else { return }
        model.states[service] = .checking
        Task { @MainActor in
            let result = await APIKeyChecker.check(key, for: service)
            if result.isUsable {
                save(key, note: result)
            } else {
                model.states[service] = .result(result)
            }
        }
    }

    private func save(_ key: String, note: KeyCheckResult?) {
        guard APIKeyStore.save(key: key, for: service) else {
            model.states[service] = .result(.rejected("The Keychain wouldn't store the key. Try again, or restart the Mac if it keeps happening."))
            return
        }
        model.entered[service] = ""
        model.editing.remove(service)
        // A clean pass is shown as saved, with Change and Remove; only a pass
        // with something worth saying keeps its message.
        if let note, case .worksWithNote = note {
            model.states[service] = .result(note)
        } else {
            model.states[service] = .saved(lastFour: String(key.suffix(4)))
        }
        companionManager.keysDidChange()
    }
}

/// Gemini 4 Argon, reached either way: a key from AI Studio, which anyone can
/// make in a minute, or a Google Cloud project through gcloud, which bills
/// that project and can draw on its credits. One card: the choice sits in
/// its header and the field below changes with it.
private struct GeminiCard: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var companionManager: CompanionManager
    @State private var projectIdentifier = ""
    @State private var cloudCheck: KeyCheckResult?
    @State private var isCheckingCloud = false

    private var usesGoogleCloud: Bool { companionManager.argonSource == .googleCloud }

    private var borderColour: Color {
        if usesGoogleCloud {
            if cloudCheck.map({ !$0.isUsable }) ?? false { return DS.Colors.warning.opacity(0.55) }
            return companionManager.usesVertexForArgon ? DS.Colors.success.opacity(0.35) : Color.white.opacity(0.08)
        }
        return KeyFieldAndStatus.borderColour(for: model.states[.gemini] ?? .empty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Google Gemini")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                SetupBadge(text: usesGoogleCloud ? "Advanced" : "Optional")
                Spacer()
                Picker("Gemini comes from", selection: Binding(
                    get: { companionManager.argonSource },
                    set: { companionManager.setArgonSource($0) }
                )) {
                    Text("An API key").tag(CompanionManager.ArgonSource.apiKey)
                    Text("Google Cloud").tag(CompanionManager.ArgonSource.googleCloud)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .pointerCursor()
            }
            if usesGoogleCloud {
                googleCloud
            } else {
                HStack {
                    Text("Adds Gemini 4 Argon, which answers most explanations under Auto. Make the key in Google AI Studio.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    SetupLink(title: "Get a key", destination: APIKeyChecker.signUpLink(for: .gemini))
                }
                KeyFieldAndStatus(service: .gemini, model: model, companionManager: companionManager)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(borderColour, lineWidth: 1))
        .onAppear {
            projectIdentifier = companionManager.vertexProjectIdentifier
            if let problem = companionManager.keyProblem, problem.service == .gemini, companionManager.argonSource == .googleCloud {
                cloudCheck = .rejected(problem.message)
            }
        }
    }

    @ViewBuilder
    private var googleCloud: some View {
        HStack {
            Text("Argon runs through Vertex on your own project, signed in with gcloud. No key is stored; usage bills the project, and its credits.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            SetupLink(title: "Install gcloud", destination: URL(string: "https://cloud.google.com/sdk/docs/install")!)
        }
        HStack(spacing: 8) {
            TextField("project-id", text: $projectIdentifier)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
                .foregroundStyle(.white)
                .overlay(IBeamCursorView())
                .onSubmit(checkAndSave)
                .accessibilityLabel("Google Cloud project")
            Button(isCheckingCloud ? "Testing" : "Test and save", action: checkAndSave)
                .buttonStyle(SetupSmallButtonStyle())
                .disabled(isCheckingCloud || projectIdentifier.trimmingCharacters(in: .whitespaces).isEmpty)
                .pointerCursor(isEnabled: !isCheckingCloud && !projectIdentifier.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let cloudCheck {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: cloudCheck.isUsable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(cloudCheck.isUsable ? DS.Colors.success : DS.Colors.warning)
                Text(cloudCheck.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } else if companionManager.usesVertexForArgon {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Colors.success)
                Text("Using \(companionManager.vertexProjectIdentifier)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func checkAndSave() {
        let project = projectIdentifier
        isCheckingCloud = true
        Task { @MainActor in
            let result = await companionManager.checkGoogleCloud(projectIdentifier: project)
            isCheckingCloud = false
            cloudCheck = result
            if result.isUsable {
                companionManager.setArgonSource(.googleCloud, projectIdentifier: project)
            }
        }
    }
}

/// "Recommended", "Optional", "Advanced": sentence case, readable size.
private struct SetupBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(text == "Recommended" ? DS.Colors.accentText : DS.Colors.textTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(text == "Recommended" ? DS.Colors.accentText.opacity(0.14) : Color.white.opacity(0.06)))
    }
}

private struct SetupLink: View {
    let title: String
    let destination: URL
    @State private var isHovering = false

    var body: some View {
        Link(destination: destination) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(DS.Colors.accentText.opacity(isHovering ? 1 : 0.85))
                .underline(isHovering)
        }
        .pointerCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering }
        }
        .accessibilityLabel("\(title), opens in your browser")
    }
}

// MARK: - Buttons

/// The app's one primary style, the accent capsule, sized for a window
/// footer. Disabled, it dims and keeps the arrow cursor.
private struct SetupPrimaryButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(DSPrimaryButtonStyle(isFullWidth: false))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
    }
}

/// Back: the text style, secondary until hovered.
private struct SetupBackButton: View {
    let action: () -> Void

    var body: some View {
        Button("Back", action: action)
            .buttonStyle(DSTextButtonStyle(fontSize: 13.5))
            .padding(.horizontal, 8)
    }
}

private struct SetupSmallButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        SmallButtonBody(configuration: configuration, isEnabled: isEnabled)
    }

    private struct SmallButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let isEnabled: Bool
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(isEnabled ? 0.9 : 0.35))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(isEnabled ? (isHovering || configuration.isPressed ? 0.2 : 0.12) : 0.05)))
                .onHover { hovering in
                    withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering && isEnabled }
                }
        }
    }
}

/// The bar every step ends with: back or a note, and the next step.
private struct SetupFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 16) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            HStack(spacing: 10) {
                leading()
                Spacer()
                trailing()
            }
        }
        .padding(.bottom, 22)
    }
}
