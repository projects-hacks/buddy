//
//  SetupWindow.swift
//  leanring-buddy
//
//  First-run setup, for anyone who downloads Buddy: their name, their own
//  API keys, the three macOS permissions, and how to ask a first question.
//  Opened again from Settings to change keys, and on its own when a key
//  stops working mid-use, on the step that fixes it.
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
import Combine
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

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func show(startingAt step: SetupStep) {
        // The drawing lives in a window above every app, setup included; an
        // old lesson's cards would sit on top of the key fields.
        companionManager.clearAnnotations()
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

    func close() {
        window?.orderOut(nil)
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
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(white: 0.07, alpha: 1)
        window.contentView = NSHostingView(rootView: SetupView(
            model: model,
            companionManager: companionManager,
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
    let onFinish: () -> Void
    @State private var opensAtLogin = true

    var body: some View {
        VStack(spacing: 0) {
            stepDots
                .padding(.top, 34)
            Group {
                switch model.step {
                case .welcome: welcome
                case .keys: keys
                case .permissions: permissions
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            .padding(.top, 22)
            .transition(.opacity)
            .id(model.step)
        }
        .frame(width: 580, height: 640)
        .background(Color(white: 0.07))
        .animation(.smooth(duration: 0.25), value: model.step)
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step == model.step ? Color.white : Color.white.opacity(step.rawValue < model.step.rawValue ? 0.5 : 0.18))
                    .frame(width: step == model.step ? 22 : 8, height: 8)
            }
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .shadow(color: Color(red: 0.35, green: 0.55, blue: 1.0).opacity(0.45), radius: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hi, this is Buddy.")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("A study helper that sees your screen and explains it out loud.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                FeatureTile(symbol: "waveform", tint: Color(red: 0.45, green: 0.7, blue: 1.0),
                            title: "Explains out loud", detail: "Hold Control + Option, ask, and hear the answer.")
                FeatureTile(symbol: "pencil.tip.crop.circle", tint: Color(red: 0.55, green: 0.85, blue: 0.6),
                            title: "Draws as it talks", detail: "Circles, arrows and sketches on what you're looking at.")
                FeatureTile(symbol: "brain.head.profile", tint: Color(red: 0.78, green: 0.62, blue: 1.0),
                            title: "Remembers what you learn", detail: "New answers build on earlier lessons.")
                FeatureTile(symbol: "lightbulb", tint: Color(red: 1.0, green: 0.78, blue: 0.4),
                            title: "Hints before answers", detail: "On practice problems, you choose how much to see.")
            }
            .padding(.top, 26)

            VStack(alignment: .leading, spacing: 8) {
                Text("What should Buddy call you?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.4))
                    TextField("Your first name", text: $model.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .onSubmit(continueFromWelcome)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
            }
            .padding(.top, 28)

            Spacer(minLength: 16)
            SetupFooter(step: .welcome) {
                EmptyView()
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
                            detail: "A natural voice. Without it, macOS's own voice reads the answers.",
                            model: model, companionManager: companionManager)
                }
            }

            SetupFooter(step: .keys) {
                SetupSecondaryButton(title: "Back") { model.step = .welcome }
            } trailing: {
                if !hasSomethingToThinkWith {
                    Text("Add an Anthropic or a Gemini key to continue.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
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
            Text("The microphone hears your question, Screen Recording lets Buddy see what you are asking about, and Accessibility catches Control + Option from any app. The screen is only captured while you hold the keys.")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                CompanionPanelView(companionManager: companionManager, isEmbedded: true, showsOnlyPermissions: true)
                    .padding(.vertical, 6)
            }

            SetupFooter(step: .permissions) {
                SetupSecondaryButton(title: "Back") { model.step = .keys }
            } trailing: {
                SetupPrimaryButton(title: companionManager.allPermissionsGranted ? "Continue" : "Skip for now", isEnabled: true) {
                    model.step = .done
                }
            }
        }
    }

    // MARK: Done

    private var done: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("You're set, \(companionManager.studentName.isEmpty ? "friend" : companionManager.studentName).")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 14) {
                HowToRow(symbol: "keyboard", title: "Hold Control + Option and ask",
                         detail: "About anything on your screen. Let go when you're done; your words show under the notch as you speak.")
                HowToRow(symbol: "pencil.and.scribble", title: "Watch it explain",
                         detail: "Buddy talks and draws at the same time. Esc clears the drawing.")
                HowToRow(symbol: "rectangle.topthird.inset.filled", title: "Hover the notch",
                         detail: "For the last lesson, the day's transcript, and Settings, where your keys and name can be changed.")
                HowToRow(symbol: "lightbulb", title: "On LeetCode, it hints first",
                         detail: "Say \"show me the code\" whenever you want the full answer.")
            }
            .padding(.top, 6)

            Toggle(isOn: $opensAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Buddy when you log in")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("So it is in the notch whenever you sit down to study. Change it any time in Settings.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .toggleStyle(.switch)
            .pointerCursor()
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
            .padding(.top, 10)

            Spacer()
            SetupFooter(step: .done) {
                SetupSecondaryButton(title: "Back") { model.step = .keys }
            } trailing: {
                SetupPrimaryButton(title: "Start using Buddy", isEnabled: true) {
                    LoginItem.setChosen(opensAtLogin)
                    onFinish()
                }
            }
        }
    }
}

/// One service's key: saved, being typed, being tested, or what went wrong.
private struct KeyCard: View {
    let service: APIKeyStore.Service
    let title: String
    let badge: String
    let detail: String
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(badge.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(badge == "Recommended" ? Color(red: 0.55, green: 0.78, blue: 1.0) : .white.opacity(0.45))
                Spacer()
                Link("Get a key", destination: APIKeyChecker.signUpLink(for: service))
                    .font(.system(size: 11.5, weight: .semibold))
                    .pointerCursor()
            }
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            if isEditing {
                HStack(spacing: 8) {
                    SecureField("Paste your \(service.humanReadableName) key", text: entered)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                        .foregroundStyle(.white)
                        .onSubmit(testAndSave)
                    SetupSmallButton(title: state == .checking ? "Testing" : "Test and save",
                                     isEnabled: state != .checking && !(model.entered[service] ?? "").isEmpty,
                                     action: testAndSave)
                    if model.editing.contains(service), APIKeyStore.hasKey(for: service) {
                        SetupSmallButton(title: "Cancel", isEnabled: true) {
                            model.editing.remove(service)
                            model.reload(from: companionManager)
                        }
                    }
                }
            }

            statusLine
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColour, lineWidth: 1))
    }

    private var borderColour: Color {
        switch state {
        case .result(let result) where !result.isUsable: return Color.orange.opacity(0.55)
        case .saved, .result: return Color.green.opacity(0.35)
        default: return Color.white.opacity(0.08)
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
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Saved, ending in \(lastFour)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                if !isEditing {
                    SetupSmallButton(title: "Change", isEnabled: true) { model.editing.insert(service) }
                    SetupSmallButton(title: "Remove", isEnabled: true) {
                        APIKeyStore.deleteKey(for: service)
                        model.states[service] = .empty
                        model.entered[service] = ""
                        companionManager.keysDidChange()
                    }
                }
            }
        case .result(let result):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: result.isUsable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.isUsable ? .green : .orange)
                Text(result.isUsable ? "Saved. \(result.message == "Works." ? "" : result.message)" : result.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if case .couldNotCheck = result {
                    SetupSmallButton(title: "Save anyway", isEnabled: !(model.entered[service] ?? "").isEmpty) {
                        save(model.entered[service] ?? "", note: nil)
                    }
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
/// that project and can draw on its credits.
private struct GeminiCard: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var companionManager: CompanionManager
    @State private var projectIdentifier = ""
    @State private var cloudCheck: KeyCheckResult?
    @State private var isCheckingCloud = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Gemini comes from")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Picker("", selection: Binding(
                    get: { companionManager.argonSource },
                    set: { companionManager.setArgonSource($0) }
                )) {
                    Text("An API key").tag(CompanionManager.ArgonSource.apiKey)
                    Text("Google Cloud").tag(CompanionManager.ArgonSource.googleCloud)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                .pointerCursor()
                Spacer()
            }

            if companionManager.argonSource == .apiKey {
                KeyCard(service: .gemini, title: "Google Gemini", badge: "Optional",
                        detail: "Adds Gemini 4 Argon, which answers most explanations under Auto. Make the key in Google AI Studio.",
                        model: model, companionManager: companionManager)
            } else {
                googleCloud
            }
        }
        .onAppear {
            projectIdentifier = companionManager.vertexProjectIdentifier
            if let problem = companionManager.keyProblem, problem.service == .gemini, companionManager.argonSource == .googleCloud {
                cloudCheck = .rejected(problem.message)
            }
        }
    }

    private var googleCloud: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Google Cloud project")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("ADVANCED")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Link("Install gcloud", destination: URL(string: "https://cloud.google.com/sdk/docs/install")!)
                    .font(.system(size: 11.5, weight: .semibold))
                    .pointerCursor()
            }
            Text("Argon runs through Vertex on your own project, signed in with gcloud. No key is stored; usage bills the project, and its credits.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("project-id", text: $projectIdentifier)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                    .foregroundStyle(.white)
                    .onSubmit(checkAndSave)
                SetupSmallButton(title: isCheckingCloud ? "Testing" : "Test and save",
                                 isEnabled: !isCheckingCloud && !projectIdentifier.trimmingCharacters(in: .whitespaces).isEmpty,
                                 action: checkAndSave)
            }
            if let cloudCheck {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: cloudCheck.isUsable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(cloudCheck.isUsable ? .green : .orange)
                    Text(cloudCheck.message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } else if companionManager.usesVertexForArgon {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Using \(companionManager.vertexProjectIdentifier)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(
            (cloudCheck.map { !$0.isUsable } ?? false) ? Color.orange.opacity(0.55)
                : (companionManager.usesVertexForArgon ? Color.green.opacity(0.35) : Color.white.opacity(0.08)),
            lineWidth: 1))
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

private struct HowToRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 0.55, green: 0.78, blue: 1.0))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SetupPrimaryButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.black : Color.white.opacity(0.4))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Capsule().fill(isEnabled ? Color.white.opacity(isHovering ? 1 : 0.9) : Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pointerCursor(isEnabled: isEnabled)
        .onHover { isHovering = $0 }
    }
}

private struct SetupSecondaryButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(isHovering ? 0.95 : 0.65))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
    }
}

private struct SetupSmallButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(isEnabled ? 0.9 : 0.35))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(isEnabled ? (isHovering ? 0.2 : 0.12) : 0.05)))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pointerCursor(isEnabled: isEnabled)
        .onHover { isHovering = $0 }
    }
}

/// One thing Buddy does, on the welcome step.
private struct FeatureTile: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.14)))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

/// The bar every step ends with: where you are, back, and the next step.
private struct SetupFooter<Leading: View, Trailing: View>: View {
    let step: SetupStep
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 14) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            HStack(spacing: 10) {
                leading()
                Text("Step \(step.rawValue + 1) of \(SetupStep.allCases.count)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()
                trailing()
            }
        }
        .padding(.bottom, 22)
    }
}
