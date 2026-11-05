//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  Settings, behind the gear in the open notch: eight controls in four
//  groups, two columns, never a scroll. Talking (Sounds, Open at login),
//  Memory (Remember what I learn, Open Map, Forget everything), Answers
//  (Answers from, Spent today, Name and keys) and Buddy itself (one update
//  row), with How to use Buddy and Quit Buddy under them. Talking over an
//  answer has no switch, like lecture mode and the error offer
//  (TalkOverListener says why that is safe).
//
//  Settings only holds settings: the how-to lives in setup's last step and
//  How to use Buddy, the day's lessons in the Notebook, and a missing
//  permission is an alert on the Lesson tab, not a takeover of this tab.
//  The same file draws the permission rows the setup window shows.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    /// Inside the notch's settings tab, the only place it is shown now. Off,
    /// it draws its own dark background, for the old menu bar panel.
    var isEmbedded = false
    /// Just the permission steps, for the setup window, which has its own
    /// heading and buttons around them.
    var showsOnlyPermissions = false

    var body: some View {
        if showsOnlyPermissions {
            PermissionStepsList(companionManager: companionManager)
        } else {
            NotchSettingsView(companionManager: companionManager)
                .padding(isEmbedded ? 0 : 16)
                .frame(width: isEmbedded ? nil : 600)
                .background(isEmbedded ? Color.clear : DS.Colors.background)
        }
    }
}

struct NotchSettingsView: View {
    @ObservedObject var companionManager: CompanionManager

    /// Each column's width inside the open notch (600 points, less 18 a
    /// side and the 12 between). Fixed, because wrapped captions in two
    /// flexible columns are measured at the wrong width and overflow.
    static let columnWidth: CGFloat = 276

    /// Where How to use Buddy goes: the guide on Buddy's site, written for
    /// students rather than for the repository's readers.
    private var howToUseBuddyURL: URL {
        URL(string: "https://projects-hacks.github.io/buddy/guide/")!
    }

    /// Whether the pointer is over Spent today, which shows its breakdown
    /// card over the other column.
    @State private var isHoveringSpendingRow = false

    /// The card covers the left column and half the gap beside it, which
    /// leaves "Listening while it talks" room on one line beside two
    /// columns of amounts.
    private static let spendingCardWidth: CGFloat = columnWidth + 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsGroup(title: "Talking") {
                        TalkingSettings()
                    }
                    SettingsGroup(title: "Memory") {
                        MemorySettings(companionManager: companionManager)
                    }
                }
                .frame(width: Self.columnWidth, alignment: .top)
                VStack(alignment: .leading, spacing: 12) {
                    SettingsGroup(title: "Answers") {
                        AnswersSettings(companionManager: companionManager,
                                        isHoveringSpendingRow: $isHoveringSpendingRow)
                    }
                    SettingsGroup(title: "Buddy \(companionManager.appUpdater.currentVersion)") {
                        UpdateRow(updater: companionManager.appUpdater)
                    }
                }
                .frame(width: Self.columnWidth, alignment: .top)
            }
            .overlayPreferenceValue(SpendingRowBoundsKey.self) { spendingRowAnchor in
                spendingCardLayer(spendingRowAnchor: spendingRowAnchor)
            }

            HStack {
                NotchQuietTextButton(title: "How to use Buddy", systemImage: "questionmark.circle") {
                    NSWorkspace.shared.open(howToUseBuddyURL)
                }
                .accessibilityLabel("How to use Buddy, opens in your browser")
                Spacer()
                NotchQuietTextButton(title: "Quit Buddy", systemImage: "power") {
                    NSApp.terminate(nil)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
        }
    }

    /// The spending card, drawn over the whole left column, beside Spent
    /// today. An overlay takes no room, so the notch keeps its size and
    /// never scrolls, and the card stays inside the columns, away from the
    /// notch's curved edge. Covering the column from top to bottom leaves no
    /// half-hidden group title or border peeking out around it. The left
    /// column is covered rather than the right because the right one holds
    /// the very amounts the card explains.
    private func spendingCardLayer(spendingRowAnchor: Anchor<CGRect>?) -> some View {
        GeometryReader { proxy in
            if let spendingRowAnchor {
                let rowFrame = proxy[spendingRowAnchor]
                let cardLeadingX = max(0, rowFrame.minX - 12 - Self.columnWidth)
                SpendingBreakdownCard(width: Self.spendingCardWidth, minimumHeight: proxy.size.height)
                    .offset(x: cardLeadingX)
                    .opacity(isHoveringSpendingRow ? 1 : 0)
                    .animation(.easeInOut(duration: DS.Animation.normal), value: isHoveringSpendingRow)
                    .allowsHitTesting(false)
                    // The row's own label reads the whole breakdown.
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Groups and rows

/// A titled group: white 4.5% on black, a hairline border, rows inside.
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.leading, 6)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                content()
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Notch.groupFill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Notch.groupBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// The hairline between rows, inset as far as the rows' content.
private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
            .padding(.horizontal, DS.Notch.settingsRowHorizontalInset)
    }
}

private extension View {
    /// Every row in every group is padded the same way, so each group has
    /// the same room inside its border at the top and the bottom, whichever
    /// kind of row comes first or last. A minimum height alone would leave
    /// a captioned row, which outgrows it, closer to the border than a
    /// one-line row centred in it.
    func settingsRowInsets() -> some View {
        self
            .padding(.vertical, DS.Notch.settingsRowVerticalInset)
            .padding(.horizontal, DS.Notch.settingsRowHorizontalInset)
            .frame(minHeight: DS.Notch.settingsOneLineRowHeight)
    }
}

/// A label with an optional caption under it.
private struct SettingsLabel: View {
    let title: String
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Colors.textPrimary)
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A switch with its label. The whole row toggles, so the target is the
/// row and not only the small switch, and the pointer says so over all of it.
private struct SettingsSwitchRow: View {
    let title: String
    var caption: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            SettingsLabel(title: title, caption: caption)
            Toggle("", isOn: $isOn)
                .toggleStyle(NotchSwitchStyle())
                .labelsHidden()
                .allowsHitTesting(false)
        }
        .settingsRowInsets()
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .pointerCursor()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityHint(caption ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isOn.toggle() }
    }
}

/// A switch drawn here rather than by AppKit: the notch's panel is never the
/// active window (it must not take focus from the app being studied), and
/// AppKit draws every switch in an inactive window grey, on or off. Small
/// size, accent when on.
struct NotchSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(configuration.isOn ? DS.Colors.accent : Color.white.opacity(0.18))
            .frame(width: DS.Notch.switchSize.width, height: DS.Notch.switchSize.height)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
    }
}

// MARK: - Talking

private struct TalkingSettings: View {
    @AppStorage(InterfaceSounds.enabledDefaultsKey) private var interfaceSoundsEnabled = true
    @State private var opensAtLogin = LoginItem.isChosen

    var body: some View {
        SettingsSwitchRow(title: "Sounds", isOn: $interfaceSoundsEnabled)
        SettingsDivider()
        SettingsSwitchRow(title: "Open at login", isOn: Binding(get: { opensAtLogin }, set: { chosen in
            opensAtLogin = chosen
            LoginItem.setChosen(chosen)
        }))
    }
}

// MARK: - Memory

private struct MemorySettings: View {
    @ObservedObject var companionManager: CompanionManager
    @AppStorage(LearningMemory.enabledDefaultsKey) private var learningMemoryEnabled = true

    private var ideaCount: Int { companionManager.learningMemory.conceptCount }
    private var howToCount: Int { companionManager.howToCount }

    /// "142 ideas and 6 how-tos"
    private var whatIsKept: String {
        var parts: [String] = []
        if ideaCount > 0 { parts.append(ideaCount == 1 ? "1 idea" : "\(ideaCount) ideas") }
        if howToCount > 0 { parts.append(howToCount == 1 ? "1 how-to" : "\(howToCount) how-tos") }
        return parts.joined(separator: " and ")
    }

    private var caption: String {
        guard learningMemoryEnabled else { return "Off. Each answer starts fresh." }
        if whatIsKept.isEmpty { return "Nothing yet. What you learn is kept on this Mac." }
        return whatIsKept + ", kept on this Mac."
    }

    var body: some View {
        SettingsSwitchRow(title: "Remember what I learn", caption: caption, isOn: $learningMemoryEnabled)
        SettingsDivider()
        HStack {
            MapLinkButton { companionManager.openKnowledgeMap() }
            Spacer()
            SettingsTextButton(title: "Forget everything\u{2026}", isEnabled: !whatIsKept.isEmpty) {
                confirmForgetting()
            }
            .accessibilityLabel("Forget everything Buddy remembers")
        }
        .settingsRowInsets()
    }

    /// Forgetting is permanent, so it asks first, in the system's own alert
    /// with Cancel as the default.
    private func confirmForgetting() {
        let alert = NSAlert()
        alert.messageText = "Forget \(whatIsKept)?"
        alert.informativeText = "Buddy will stop building on earlier lessons. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        let forgetButton = alert.addButton(withTitle: "Forget")
        forgetButton.hasDestructiveAction = true
        // A menu bar app has to ask to come forward, or the alert opens
        // behind the app being studied.
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            companionManager.forgetLearningMemory()
        }
    }
}

private struct MapLinkButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .semibold))
                Text("Open Map")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(DS.Colors.accentText.opacity(isHovering ? 1 : 0.88))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(NotchMotion.hover) { isHovering = hovering }
        }
        .accessibilityLabel("Open Map of what you know, opens a window")
    }
}

/// Text that acts, secondary until hovered. Disabled, it keeps the arrow
/// and does not change on hover.
private struct SettingsTextButton: View {
    let title: String
    var isEnabled = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled
                                 ? (isHovering ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                                 : DS.Colors.textDisabled)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pointerCursor(isEnabled: isEnabled)
        .onHover { hovering in
            withAnimation(NotchMotion.hover) { isHovering = hovering && isEnabled }
        }
    }
}

// MARK: - Answers

private struct AnswersSettings: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var meter = SpendingMeter.shared
    @Binding var isHoveringSpendingRow: Bool

    /// Local is left out: its models are not installed by default, and a
    /// choice that can only fail is worse than none.
    private static let choices: [TutorBrainKind] = [.auto, .claude, .hosted]

    private func hasKey(for kind: TutorBrainKind) -> Bool {
        switch kind {
        case .auto: return companionManager.canUseClaude || companionManager.canUseArgon
        case .claude: return companionManager.canUseClaude
        case .hosted: return companionManager.canUseArgon
        case .local: return true
        }
    }

    private var caption: String {
        switch companionManager.brainKind {
        case .auto: return "Auto picks the best one for each question."
        case .claude: return "Claude answers every question."
        case .hosted: return "Gemini answers every question."
        case .local: return "The model on this Mac answers."
        }
    }

    /// Picking a brain without a key opens setup on Keys instead, since the
    /// answer would only fail.
    private var brainChoice: Binding<TutorBrainKind> {
        Binding(
            get: { companionManager.brainKind },
            set: { chosen in
                if hasKey(for: chosen) {
                    companionManager.setBrainKind(chosen)
                } else {
                    companionManager.setupWindow.show(startingAt: .keys)
                }
            })
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingsLabel(title: "Answers from", caption: caption)
            Picker("Answers from", selection: brainChoice) {
                ForEach(Self.choices, id: \.self) { kind in
                    Text(hasKey(for: kind) ? kind.displayName : "\(kind.displayName), add a key")
                        .foregroundStyle(hasKey(for: kind) ? DS.Colors.textPrimary : DS.Colors.textDisabled)
                        .tag(kind)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .pointerCursor()
            .accessibilityLabel("Answers from")
        }
        .settingsRowInsets()

        SettingsDivider()

        let today = meter.today
        HStack(spacing: 12) {
            SettingsLabel(title: "Spent today",
                          caption: "This month \(SpendingMeter.formatted(meter.thisMonthDollars))")
            Text(SpendingMeter.formatted(today.dollars))
                .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(DS.Colors.textPrimary)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.3), value: today.dollars)
        }
        .settingsRowInsets()
        .contentShape(Rectangle())
        // Not a tooltip: AppKit's tooltips are unreliable in the notch's
        // never-active panel, so the breakdown is a card the settings view
        // draws where this row says it is. The row does nothing when
        // clicked, so the pointer stays the arrow.
        .anchorPreference(key: SpendingRowBoundsKey.self, value: .bounds) { $0 }
        .onHover { hovering in isHoveringSpendingRow = hovering }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spendingAccessibilityLabel)

        SettingsDivider()

        SettingsChevronRow(title: "Name and keys") {
            companionManager.setupWindow.show(startingAt: .keys)
        }
    }

    private var spendingAccessibilityLabel: String {
        let breakdown = SpendingBreakdown(today: SpendingMeter.Totals(adding: [meter.today]), thisMonth: meter.thisMonth)
        return "Spent today, \(SpendingMeter.formatted(meter.today.dollars)). This month, "
            + "\(SpendingMeter.formatted(meter.thisMonthDollars)). " + breakdown.spokenDescription
    }
}

/// Where Spent today is, for the card that explains it.
private struct SpendingRowBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// What Spent today is made of, today and this month: per service, then per
/// purpose, then the day's questions and where the numbers come from.
/// Drawn by NotchSettingsView over the left column while the pointer is on
/// the row.
struct SpendingBreakdownCard: View {
    let width: CGFloat
    /// The height of the column it covers, so nothing of it shows around
    /// the card; more lines than that make the card taller instead.
    let minimumHeight: CGFloat
    @ObservedObject private var meter = SpendingMeter.shared

    /// Wide enough for "under 1¢" and "$100.00" at this size.
    private static let todayColumnWidth: CGFloat = 52
    /// Wide enough for "$100.00"; its heading, a little wider, reaches over
    /// the gap before it rather than making every row lose that room.
    private static let thisMonthColumnWidth: CGFloat = 60

    var body: some View {
        let breakdown = SpendingBreakdown(today: SpendingMeter.Totals(adding: [meter.today]), thisMonth: meter.thisMonth)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                columnHeading("Today", width: Self.todayColumnWidth)
                columnHeading("This month", width: Self.thisMonthColumnWidth)
                    .padding(.leading, Self.spaceBetweenAmountColumns)
            }
            .padding(.bottom, 4)

            ForEach(breakdown.serviceLines, id: \.name) { line in
                amountRow(line)
            }

            if !breakdown.purposeLines.isEmpty {
                Rectangle()
                    .fill(DS.Notch.groupBorder)
                    .frame(height: 1)
                    .padding(.vertical, 6)
                ForEach(breakdown.purposeLines, id: \.name) { line in
                    amountRow(line)
                }
            }

            // The counts and the note sit at the foot of the card, however
            // few rows there are above them.
            Spacer(minLength: 10)
            Text(breakdown.countsSentence)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DS.Notch.textSecondary)
            Text(SpendingBreakdown.whereTheNumbersComeFrom)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .padding(.horizontal, DS.Notch.settingsRowHorizontalInset)
        .padding(.vertical, 10)
        .frame(width: width, alignment: .leading)
        .frame(minHeight: minimumHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface2))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }

    private static let spaceBetweenAmountColumns: CGFloat = 8

    private func columnHeading(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DS.Colors.textTertiary)
            // On one line even when wider than its column: it then reaches
            // left over the gap, and the amounts under it stay aligned.
            .lineLimit(1)
            .fixedSize()
            .frame(width: width, alignment: .trailing)
    }

    private func amountRow(_ line: SpendingBreakdown.Line) -> some View {
        HStack(spacing: 0) {
            Text(line.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DS.Notch.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            amount(line.today, width: Self.todayColumnWidth)
            amount(line.thisMonth, width: Self.thisMonthColumnWidth)
                .padding(.leading, Self.spaceBetweenAmountColumns)
        }
        .padding(.vertical, 1)
    }

    /// Nothing spent shows dimmer, so the eye goes to what did cost.
    private func amount(_ dollars: Double, width: CGFloat) -> some View {
        Text(SpendingMeter.formatted(dollars))
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(dollars > 0 ? DS.Notch.textPrimary : DS.Colors.textTertiary)
            .frame(width: width, alignment: .trailing)
    }
}

/// A row that opens something: white 5% on hover, the pointer, a chevron.
private struct SettingsChevronRow: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            .settingsRowInsets()
            .background(isHovering ? DS.Notch.rowHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(NotchMotion.hover) { isHovering = hovering }
        }
        .accessibilityLabel("\(title), opens setup")
    }
}

// MARK: - Updates

/// One row: when Buddy last looked and Check now, or the newer Buddy and
/// Update. Checks run once a day on their own; there is no switch for them.
private struct UpdateRow: View {
    @ObservedObject var updater: AppUpdater

    private var title: String {
        switch updater.state {
        case .checking: return "Checking\u{2026}"
        case .available: return "Buddy \(updater.availableRelease?.version ?? "") is ready"
        case .downloading: return "Downloading Buddy \(updater.availableRelease?.version ?? "")\u{2026}"
        case .installing: return "Checking and installing\u{2026}"
        case .failed: return "Couldn't update"
        case .upToDate: return "Up to date"
        case .idle: return updater.lastCheckedAt == nil ? "Not checked yet" : "Up to date"
        }
    }

    private var caption: String? {
        switch updater.state {
        case .failed(let message): return message
        case .available: return "Updating restarts Buddy."
        case .checking, .downloading, .installing: return nil
        case .upToDate, .idle: return Self.checkedText(updater.lastCheckedAt)
        }
    }

    /// "Checked today at 09:12".
    static func checkedText(_ lastCheckedAt: Date?) -> String? {
        guard let lastCheckedAt else { return "Buddy looks once a day." }
        let time = lastCheckedAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if Calendar.current.isDateInToday(lastCheckedAt) { return "Checked today at \(time)" }
        if Calendar.current.isDateInYesterday(lastCheckedAt) { return "Checked yesterday at \(time)" }
        return "Checked \(lastCheckedAt.formatted(.dateTime.day().month(.wide)))"
    }

    private var isBusy: Bool {
        updater.state == .checking || updater.state == .downloading || updater.state == .installing
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingsLabel(title: title, caption: caption)
            if isBusy {
                ProgressView().controlSize(.small)
            } else if updater.state == .available {
                NotchPrimaryButton(systemImage: nil, title: "Update") {
                    Task { await updater.installAvailableUpdate() }
                }
            } else {
                SettingsTextButton(title: "Check now") {
                    Task { await updater.check() }
                }
            }
        }
        .settingsRowInsets()
    }
}

// MARK: - Permissions (shown by the setup window)

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

/// The permissions still to grant, in the order macOS makes sensible: the
/// microphone first (one click), Screen Recording last (it asks for a
/// reopen). Screen Content appears only once Screen Recording is on,
/// because macOS offers it only then.
private struct PermissionStepsList: View {
    @ObservedObject var companionManager: CompanionManager

    private var permissionSteps: [PermissionStep] {
        var steps: [PermissionStep] = [
            PermissionStep(
                symbol: "mic.fill", title: "Microphone", reason: "Hears you while you hold Control + Option, and while Buddy explains so you can cut in.",
                isGranted: companionManager.hasMicrophonePermission,
                allow: {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }),
            PermissionStep(
                symbol: "keyboard.fill", title: "Accessibility", reason: "Notices Buddy's shortcuts from any app, and finds the button to point at.",
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
                reason: "Sees what you are asking about, only when you ask or while it guides you.",
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

    var body: some View {
        let steps = permissionSteps
        let grantedCount = steps.filter(\.isGranted).count
        VStack(alignment: .leading, spacing: 8) {
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(grantedCount) of \(steps.count) permissions allowed")

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
                .accessibilityLabel("Allow \(step.title)")
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
