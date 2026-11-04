//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel, dark, rounded, minimal, and special.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    /// Shown inside the notch's settings tab rather than as its own panel:
    /// no header, no window background, the notch's width.
    var isEmbedded = false
    /// Just the permission steps, for the setup window, which has its own
    /// heading and buttons around them.
    var showsOnlyPermissions = false

    var body: some View {
        if showsOnlyPermissions {
            settingsSection
        } else {
            fullPanel
        }
    }

    private var fullPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isEmbedded {
                panelHeader
                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.horizontal, 16)
            }

            howToUseSection
                .padding(.top, 14)
                .padding(.horizontal, 16)

            if companionManager.allPermissionsGranted {
                Spacer().frame(height: 14)
                modelPickerRow
                    .padding(.horizontal, 16)

                Spacer().frame(height: 6)
                interfaceSoundsToggleRow
                    .padding(.horizontal, 16)

                learningMemoryRow
                    .padding(.horizontal, 16)

                keysAndNameRow
                    .padding(.horizontal, 16)

                openAtLoginRow
                    .padding(.horizontal, 16)

                Spacer().frame(height: 10)
                lessonsSection
                    .padding(.horizontal, 16)
            } else {
                Spacer().frame(height: 16)
                settingsSection
                    .padding(.horizontal, 16)
            }

            Spacer().frame(height: 12)
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: isEmbedded ? nil : 320)
        .frame(maxWidth: isEmbedded ? .infinity : nil)
        .background(isEmbedded ? AnyView(Color.clear) : AnyView(panelBackground))
    }

    // MARK: - How to use

    @ViewBuilder
    private var howToUseSection: some View {
        if companionManager.allPermissionsGranted {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hold Control + Option and ask about anything on your screen.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    hintRow(symbol: "rectangle.topthird.inset.filled", text: "Hover the notch to read the conversation.")
                    hintRow(symbol: "escape", text: "Esc clears the drawing.")
                    hintRow(symbol: "arrow.uturn.backward", text: "Say \"I didn't get it\" for a new angle.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("Let Buddy hear and see")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Nothing is captured until you hold Control + Option, and nothing is kept but your own transcript.")
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hintRow(symbol: String, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    // MARK: - Lessons

    private var lessonsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Today")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button(action: { companionManager.openTranscriptsFolder() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .medium))
                        Text("Transcripts")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            let titles = companionManager.recentLessonTitles
            if titles.isEmpty {
                Text("Lessons you work through show up here.")
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textTertiary)
            } else {
                ForEach(titles, id: \.self) { title in
                    HStack(spacing: 7) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.accentText)
                        Text(title)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Buddy")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions

    /// The permissions still to grant, in the order macOS makes sensible:
    /// the microphone first (one click), Screen Recording last (it asks for a
    /// reopen). Screen Content appears only once Screen Recording is on,
    /// because macOS offers it only then.
    private var permissionSteps: [PermissionStep] {
        var steps: [PermissionStep] = [
            PermissionStep(
                symbol: "mic.fill", title: "Microphone", reason: "Hears your question while you hold Control + Option.",
                isGranted: companionManager.hasMicrophonePermission,
                allow: {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }),
            PermissionStep(
                symbol: "keyboard.fill", title: "Accessibility", reason: "Notices Control + Option from any app.",
                isGranted: companionManager.hasAccessibilityPermission,
                allow: { WindowPositionManager.requestAccessibilityPermission() },
                helpTitle: "Buddy not in the list?",
                help: {
                    // Locally signed apps are sometimes missing from the list
                    // until dragged in; Finder shows the app to drag.
                    WindowPositionManager.revealAppInFinder()
                    WindowPositionManager.openAccessibilitySettings()
                }),
            PermissionStep(
                symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
                reason: "Sees what you are asking about, only while you hold the keys.",
                isGranted: companionManager.hasScreenRecordingPermission,
                allow: { WindowPositionManager.requestScreenRecordingPermission() },
                note: "macOS asks you to reopen Buddy after this one.")
        ]
        if companionManager.hasScreenRecordingPermission {
            steps.append(PermissionStep(
                symbol: "eye.fill", title: "Screen Content", reason: "Lets Buddy read the text on screen to point at it exactly.",
                isGranted: companionManager.hasScreenContentPermission,
                allow: { companionManager.requestScreenContentPermission() }))
        }
        return steps
    }

    private var settingsSection: some View {
        let steps = permissionSteps
        let grantedCount = steps.filter(\.isGranted).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // How far through: a thin bar fills as each one is allowed.
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(DS.Colors.success)
                            .frame(width: proxy.size.width * CGFloat(grantedCount) / CGFloat(max(1, steps.count)))
                    }
                }
                .frame(height: 4)
                Text("\(grantedCount) of \(steps.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
                    .monospacedDigit()
            }
            .padding(.bottom, 4)
            .animation(.smooth(duration: 0.3), value: grantedCount)

            ForEach(Array(steps.enumerated()), id: \.element.title) { position, step in
                PermissionStepRow(
                    step: step,
                    // Only the first one still to grant is highlighted, so
                    // there is always exactly one obvious next click.
                    isNext: !step.isGranted && steps.prefix(position).allSatisfy(\.isGranted)
                )
            }
        }
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Sounds Toggle

    @AppStorage(InterfaceSounds.enabledDefaultsKey) private var interfaceSoundsEnabled = true

    private var interfaceSoundsToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: interfaceSoundsEnabled ? "speaker.wave.2" : "speaker.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Sounds")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: $interfaceSoundsEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
                .pointerCursor()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Open at login

    @State private var opensAtLogin = LoginItem.isChosen

    private var openAtLoginRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)
                Text("Open at login")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { opensAtLogin }, set: { chosen in
                opensAtLogin = chosen
                LoginItem.setChosen(chosen)
            }))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
            .pointerCursor()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Keys and Name

    private var keysAndNameRow: some View {
        Button(action: { companionManager.setupWindow.show(startingAt: .keys) }) {
            HStack(spacing: 8) {
                Image(systemName: "key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)
                Text("Name and API keys")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Learning Memory

    @AppStorage(LearningMemory.enabledDefaultsKey) private var learningMemoryEnabled = true
    /// Forgetting is permanent, so it takes a second click within a few seconds.
    @State private var isConfirmingForget = false

    private var learningMemoryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)

                    Text("Learning memory")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: $learningMemoryEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(DS.Colors.accent)
                    .scaleEffect(0.8)
                    .pointerCursor()
            }

            HStack(spacing: 8) {
                Text(learningMemoryCaption)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                if companionManager.learningMemory.conceptCount > 0 {
                    Button(action: forgetButtonTapped) {
                        Text(isConfirmingForget ? "Click again to forget all" : "Forget all")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(isConfirmingForget ? .red : DS.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.leading, 24)
        }
        .padding(.vertical, 4)
    }

    private var learningMemoryCaption: String {
        let count = companionManager.learningMemory.conceptCount
        guard learningMemoryEnabled else { return "Off. Each answer starts fresh." }
        if count == 0 { return "Remembers what you learn, on this Mac only." }
        return count == 1 ? "1 idea remembered, on this Mac only." : "\(count) ideas remembered, on this Mac only."
    }

    private func forgetButtonTapped() {
        if isConfirmingForget {
            companionManager.forgetLearningMemory()
            isConfirmingForget = false
        } else {
            isConfirmingForget = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { isConfirmingForget = false }
        }
    }

    // MARK: - Show Clicky Cursor Toggle

    private var showClickyCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show Clicky")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isClickyCursorEnabled },
                set: { companionManager.setClickyCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Brain Picker

    private var modelPickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            modelPickerControls

            // The one failure worth explaining in the UI: everything else
            // still works, the app simply has nothing to think with, and the
            // fix differs per brain, so the message names the right one.
            if !companionManager.isLocalModelReachable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text(unreachableBrainFix)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var unreachableBrainFix: String {
        switch companionManager.brainKind {
        case .hosted: return "Google Cloud sign-in expired. Run: gcloud auth application-default login"
        case .claude: return "No Anthropic key in the Keychain."
        case .auto: return "No Anthropic key in the Keychain, so Auto can only use Argon."
        case .local: return "Ollama is not running. Run: brew services start ollama"
        }
    }

    private var modelPickerControls: some View {
        HStack {
            Text("Brain")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            // Local is left out: its models are not installed by default, and
            // a button that can only fail is worse than no button.
            HStack(spacing: 0) {
                brainOptionButton(kind: .auto)
                brainOptionButton(kind: .claude)
                brainOptionButton(kind: .hosted)
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func brainOptionButton(kind: TutorBrainKind) -> some View {
        let isSelected = companionManager.brainKind == kind
        return Button(action: {
            companionManager.setBrainKind(kind)
        }) {
            Text(kind.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Buddy")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Spacer()
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}


/// One permission to grant: what it is for, and how to grant it.
private struct PermissionStep {
    let symbol: String
    let title: String
    let reason: String
    let isGranted: Bool
    let allow: () -> Void
    var helpTitle: String? = nil
    var help: (() -> Void)? = nil
    var note: String? = nil
}

private struct PermissionStepRow: View {
    let step: PermissionStep
    let isNext: Bool
    @State private var isHoveringAllow = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(step.isGranted ? DS.Colors.success.opacity(0.16) : (isNext ? DS.Colors.accent.opacity(0.2) : Color.white.opacity(0.06)))
                Image(systemName: step.isGranted ? "checkmark" : step.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(step.isGranted ? DS.Colors.success : (isNext ? DS.Colors.accentText : DS.Colors.textTertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(step.isGranted ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                Text(step.isGranted ? "Allowed" : step.reason)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if !step.isGranted, isNext, let note = step.note {
                    Text(note)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.warning)
                }
                if !step.isGranted, let helpTitle = step.helpTitle, let help = step.help {
                    Button(action: help) {
                        Text(helpTitle + " Show it in Finder")
                            .font(.system(size: 10.5, weight: .medium))
                            .underline()
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            Spacer(minLength: 8)

            if !step.isGranted {
                Button(action: step.allow) {
                    Text("Allow")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isNext ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(isNext
                                ? DS.Colors.accent.opacity(isHoveringAllow ? 1 : 0.88)
                                : Color.white.opacity(isHoveringAllow ? 0.16 : 0.08))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .onHover { isHoveringAllow = $0 }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isNext ? Color.white.opacity(0.06) : Color.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isNext ? DS.Colors.accent.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .animation(.smooth(duration: 0.25), value: step.isGranted)
        .animation(.smooth(duration: 0.25), value: isNext)
    }
}
