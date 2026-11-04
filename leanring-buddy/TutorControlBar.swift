//
//  TutorControlBar.swift
//  leanring-buddy
//
//  The tutor's home at the top of the screen, grown out of the notch: what
//  it is doing, the sentence it is saying, and on hover the whole
//  conversation so far, with Stop, Clear and the follow-ups it offered.
//
//  Why the notch. It is the one place on a Mac screen that is never study
//  material, so living there costs the student nothing, and it is where the
//  eye already goes for status. On a Mac without a notch the same shape hangs
//  from the middle of the menu bar.
//
//  Why a transcript. A spoken explanation is gone once said. A student who
//  missed a sentence, or wants the third step again, can read it here, and
//  each day's conversation is also saved as a plain text file to come back
//  to (~/Library/Application Support/ClickyLocal/Transcripts).
//
//  Its own small window because the overlays that hold the drawing are
//  click-through, and have to be: they cover the whole screen.
//

import AppKit
import Combine
import SwiftUI

/// A next question the tutor offered, or text it offered to copy.
struct TutorFollowUpButton: Identifiable, Equatable {
    let id = UUID()
    let title: String
    /// Asked as the student's next question when tapped.
    let question: String?
    /// Put on the clipboard when tapped, for code or a formula.
    let textToCopy: String?

    static func == (lhs: TutorFollowUpButton, rhs: TutorFollowUpButton) -> Bool { lhs.id == rhs.id }
}

/// One turn of the conversation as the student experienced it.
struct TranscriptEntry: Identifiable {
    enum Speaker { case student, tutor }
    var id = UUID()
    let speaker: Speaker
    var text: String
    var lessonTitle: String?
    var time = Date()
}

/// The two views of the opened notch.
enum NotchTab { case lesson, transcript, settings }

/// What the tutor is doing, for the status in the notch.
enum TutorActivity: Equatable {
    case ready, listening, thinking, speaking
}

@MainActor
final class TutorControlBarModel: ObservableObject {
    @Published var caption: String = ""
    @Published var followUps: [TutorFollowUpButton] = []
    @Published var isSpeaking = false
    @Published var hasDrawing = false
    @Published var copiedButtonID: UUID?
    @Published var activity: TutorActivity = .ready
    @Published private(set) var transcript: [TranscriptEntry] = []
    @Published var isExpanded = false
    @Published var selectedTab: NotchTab = .lesson
    /// Held open regardless of the mouse, while setup still needs the
    /// student (a missing permission).
    @Published var isPinnedOpen = false

    private let transcriptStore = TranscriptStore()

    /// Today's conversation comes back after a relaunch, so the notch shows
    /// what was learned earlier in the day, not only since the app started.
    init() {
        transcript = transcriptStore.loadToday()
    }

    func recordStudent(_ words: String) {
        transcript.append(TranscriptEntry(speaker: .student, text: words))
        transcriptStore.record(.student, text: words)
        trimTranscript()
    }

    /// Adds a spoken sentence to the tutor's current turn, starting one if
    /// the last entry was the student's.
    func recordTutorSentence(_ sentence: String) {
        let startsNewTurn = transcript.last?.speaker != .tutor
        if startsNewTurn {
            transcript.append(TranscriptEntry(speaker: .tutor, text: sentence))
        } else if let last = transcript.indices.last {
            transcript[last].text += " " + sentence
        }
        transcriptStore.record(startsNewTurn ? .tutorTurnStart : .sentence, text: sentence)
    }

    func recordLessonTitle(_ title: String) {
        guard let last = transcript.indices.last, transcript[last].speaker == .tutor else { return }
        transcript[last].lessonTitle = title
        transcriptStore.record(.lessonTitle, text: title)
    }

    /// The conversation as plain text, for copying.
    var transcriptText: String {
        transcript.map { entry in
            (entry.speaker == .student ? "You: " : "Buddy: ") + entry.text
        }.joined(separator: "\n\n")
    }

    /// Today's conversation as a readable document, for long answers that are
    /// easier to read in an editor than in the notch.
    var todaysTranscriptDocument: URL { transcriptStore.todaysReadableFile }

    private func trimTranscript() {
        if transcript.count > 80 { transcript.removeFirst(transcript.count - 80) }
    }
}

/// Keeps each day's conversation on disk in two forms.
///
/// `YYYY-MM-DD.jsonl` is the record the app reads back: one event per line,
/// only ever appended to, so a crash mid-answer loses at most the sentence
/// being written and never corrupts what came before. `YYYY-MM-DD.md` is the
/// same conversation for a person to read: questions as headings, answers as
/// paragraphs, lesson names in italics.
///
/// Both live in ~/Library/Application Support/ClickyLocal/Transcripts and
/// never leave the Mac.
private final class TranscriptStore {
    enum EventKind: String, Codable {
        case student, tutorTurnStart = "tutor", sentence, lessonTitle = "lesson"
    }

    private struct Event: Codable {
        let kind: EventKind
        let text: String
        let time: Date
    }

    /// Disk writes happen here, never on the main thread, which is busy
    /// streaming the answer and pacing the pen.
    private let queue = DispatchQueue(label: "clicky.transcript-store", qos: .utility)
    private let folder: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClickyLocal/Transcripts")

    private static func dayName(for moment: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: moment)
    }

    var todaysReadableFile: URL {
        folder.appendingPathComponent("\(Self.dayName(for: Date())).md")
    }

    func record(_ kind: EventKind, text: String) {
        let event = Event(kind: kind, text: text, time: Date())
        queue.async { [folder] in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let day = Self.dayName(for: event.time)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if var line = try? encoder.encode(event) {
                line.append(0x0A)
                Self.append(line, to: folder.appendingPathComponent("\(day).jsonl"))
            }
            Self.append(Data(Self.readableText(for: event).utf8), to: folder.appendingPathComponent("\(day).md"))
        }
    }

    /// Rebuilds today's turns from the event record.
    func loadToday() -> [TranscriptEntry] {
        importOlderPlainTextIfNeeded()
        let file = folder.appendingPathComponent("\(Self.dayName(for: Date())).jsonl")
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [TranscriptEntry] = []
        for line in contents.split(separator: "\n") {
            guard let event = try? decoder.decode(Event.self, from: Data(line.utf8)) else { continue }
            switch event.kind {
            case .student:
                entries.append(TranscriptEntry(speaker: .student, text: event.text, time: event.time))
            case .tutorTurnStart:
                entries.append(TranscriptEntry(speaker: .tutor, text: event.text, time: event.time))
            case .sentence:
                if let last = entries.indices.last, entries[last].speaker == .tutor {
                    entries[last].text += " " + event.text
                } else {
                    entries.append(TranscriptEntry(speaker: .tutor, text: event.text, time: event.time))
                }
            case .lessonTitle:
                if let last = entries.indices.last, entries[last].speaker == .tutor {
                    entries[last].lessonTitle = event.text
                }
            }
        }
        return Array(entries.suffix(80))
    }

    /// Earlier builds kept a plain `[HH:mm] You: ...` text file per day. The
    /// day's file is converted once, so a conversation from before the
    /// switch still shows in the notch.
    private func importOlderPlainTextIfNeeded() {
        let day = Self.dayName(for: Date())
        let eventFile = folder.appendingPathComponent("\(day).jsonl")
        let olderFile = folder.appendingPathComponent("\(day).txt")
        guard !FileManager.default.fileExists(atPath: eventFile.path),
              let older = try? String(contentsOf: olderFile, encoding: .utf8) else { return }

        let timeParser = DateFormatter()
        timeParser.dateFormat = "yyyy-MM-dd HH:mm"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var events = Data()
        var readable = ""
        var lastSpeaker = ""
        for line in older.split(separator: "\n") {
            // "[15:05] You: words" or "[15:05] Tutor: words"
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let time = String(line[line.index(after: line.startIndex)..<close])
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let speaker = String(rest[..<colon])
            let text = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let moment = timeParser.date(from: "\(day) \(time)") ?? Date()
            let kind: EventKind = speaker == "You" ? .student : (lastSpeaker == "Tutor" ? .sentence : .tutorTurnStart)
            lastSpeaker = speaker
            let event = Event(kind: kind, text: text, time: moment)
            if var encoded = try? encoder.encode(event) {
                encoded.append(0x0A)
                events.append(encoded)
            }
            readable += Self.readableText(for: event)
        }
        try? events.write(to: eventFile)
        try? Data(readable.utf8).write(to: folder.appendingPathComponent("\(day).md"))
    }

    private static func readableText(for event: Event) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: event.time)
        switch event.kind {
        case .student: return "\n\n## \(time) · You\n\n\(event.text)\n"
        case .tutorTurnStart: return "\n**Buddy**\n\n\(event.text)"
        case .sentence: return " \(event.text)"
        case .lessonTitle: return "\n\n*Lesson: \(event.text)*\n"
        }
    }

    private static func append(_ data: Data, to file: URL) {
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }
}

@MainActor
final class TutorControlBarController {
    let model = TutorControlBarModel()
    private var panel: NSPanel?
    private var hostingView: NSHostingView<TutorNotchView>?
    private var cancellables: Set<AnyCancellable> = []

    private let onAsk: (String) -> Void
    private let onStop: () -> Void
    private let onClear: () -> Void
    private let settingsView: () -> AnyView

    init(
        onAsk: @escaping (String) -> Void,
        onStop: @escaping () -> Void,
        onClear: @escaping () -> Void,
        settingsView: @escaping () -> AnyView
    ) {
        self.onAsk = onAsk
        self.onStop = onStop
        self.onClear = onClear
        self.settingsView = settingsView

        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// Keeps the panel hugging the notch at whatever size its content needs.
    private func refresh() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let hostingView else { return }

        let size = hostingView.fittingSize
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        guard let screen else { return }
        panel.setFrame(NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        ), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above the menu bar, which is where the notch is.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // Non-activating so a click here does not pull focus from the app the
        // student is studying in.
        panel.becomesKeyOnlyIfNeeded = true

        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        let notchWidth = Self.notchWidth(of: screen)
        let notchHeight = max(screen?.safeAreaInsets.top ?? 0, NSStatusBar.system.thickness)

        let view = TutorNotchView(
            model: model,
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            onAsk: { [weak self] question in self?.onAsk(question) },
            onCopy: { [weak self] button in self?.copy(button) },
            onCopyTranscript: { [weak self] in self?.copyTranscript() },
            onStop: { [weak self] in self?.onStop() },
            onClear: { [weak self] in self?.onClear() },
            settingsView: settingsView
        )
        let hostingView = NSHostingView(rootView: view)
        panel.contentView = hostingView
        self.hostingView = hostingView
        return panel
    }

    /// Width of the camera housing, from the areas macOS reports either side
    /// of it. A screen without one gets a modest width under the menu bar.
    private static func notchWidth(of screen: NSScreen?) -> CGFloat {
        guard let screen,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return 180 }
        return max(120, right.minX - left.maxX)
    }

    private func copy(_ button: TutorFollowUpButton) {
        guard let text = button.textToCopy else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.copiedButtonID = button.id
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.transcriptText, forType: .string)
    }
}

// MARK: - The view

struct TutorNotchView: View {
    @ObservedObject var model: TutorControlBarModel
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let onAsk: (String) -> Void
    let onCopy: (TutorFollowUpButton) -> Void
    let onCopyTranscript: () -> Void
    let onStop: () -> Void
    let onClear: () -> Void
    let settingsView: () -> AnyView

    /// Wide enough for a status either side of the camera.
    private var collapsedWidth: CGFloat { notchWidth + 230 }
    private var expandedWidth: CGFloat { max(collapsedWidth, 600) }

    var body: some View {
        VStack(spacing: 0) {
            statusRow
            if model.isExpanded {
                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                collapsedExtras
            }
        }
        .frame(width: model.isExpanded ? expandedWidth : collapsedWidth)
        .background(
            NotchShape(cornerRadius: model.isExpanded ? 22 : 14)
                .fill(Color.black)
        )
        .onHover { hovering in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                model.isExpanded = hovering || model.isPinnedOpen
            }
        }
        .fixedSize()
    }

    // The row level with the camera: status on the left, lesson on the right.
    private var statusRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(activityColour)
                    .frame(width: 7, height: 7)
                    .shadow(color: activityColour.opacity(0.8), radius: 3)
                Text(activityWord)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer().frame(width: notchWidth)

            Text(currentLessonTitle ?? "")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: notchHeight)
    }

    /// Under the notch while collapsed: the sentence being said, and the
    /// follow-ups once the answer is over.
    @ViewBuilder
    private var collapsedExtras: some View {
        if !model.caption.isEmpty {
            Text(model.caption)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .frame(width: collapsedWidth)
                .animation(.easeOut(duration: 0.15), value: model.caption)
        } else if !model.followUps.isEmpty && !model.isSpeaking {
            followUpRow
                .padding(.bottom, 10)
                .frame(width: collapsedWidth)
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 14) {
            HStack {
                NotchTabButton(systemImage: "book.closed", isSelected: model.selectedTab == .lesson) {
                    model.selectedTab = .lesson
                }
                NotchTabButton(systemImage: "text.bubble", isSelected: model.selectedTab == .transcript) {
                    model.selectedTab = .transcript
                }
                Spacer()
                NotchTabButton(systemImage: "gearshape", isSelected: model.selectedTab == .settings) {
                    model.selectedTab = .settings
                }
            }
            .padding(.horizontal, 18)

            if model.selectedTab == .settings {
                settingsView()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            } else {
                talkingContent
            }
        }
        .padding(.top, 6)
    }

    private var talkingContent: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(greeting)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Hold Control + Option and ask about anything on your screen.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Group {
                switch model.selectedTab {
                case .transcript: transcriptList
                default: LessonCard(model: model, onAsk: onAsk, onCopy: onCopy)
                }
            }
            .padding(.horizontal, 18)

            HStack(spacing: 8) {
                if !model.transcript.isEmpty {
                    NotchButton(systemImage: "doc.on.doc", title: "Copy", action: onCopyTranscript)
                    NotchButton(systemImage: "doc.text", title: "Open full transcript") {
                        NSWorkspace.shared.open(model.todaysTranscriptDocument)
                    }
                }
                Spacer()
                if model.isSpeaking {
                    NotchButton(systemImage: "stop.fill", title: "Stop", action: onStop)
                }
                if model.hasDrawing {
                    NotchButton(systemImage: "xmark", title: "Clear  esc", action: onClear)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.transcript.isEmpty {
                        Text("Everything you ask and everything explained is written down here.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }
                    ForEach(model.transcript) { entry in
                        TranscriptRow(entry: entry).id(entry.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 380)
            .onAppear { if let last = model.transcript.last { reader.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: model.transcript.count) { _, _ in
                if let last = model.transcript.last { reader.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// "Afternoon, Rajeev." from the time and the Mac's account name.
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let partOfDay = hour < 12 ? "Morning" : (hour < 18 ? "Afternoon" : "Evening")
        let firstName = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return firstName.isEmpty ? "\(partOfDay)." : "\(partOfDay), \(firstName)."
    }

    private var followUpRow: some View {
        HStack(spacing: 6) {
            ForEach(model.followUps) { button in
                FollowUpChip(button: button, isCopied: model.copiedButtonID == button.id) {
                    if let question = button.question { onAsk(question) } else { onCopy(button) }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var currentLessonTitle: String? {
        model.transcript.last(where: { $0.lessonTitle != nil })?.lessonTitle
    }

    private var activityWord: String {
        switch model.activity {
        case .ready: return "ready"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .speaking: return "explaining"
        }
    }

    private var activityColour: Color {
        switch model.activity {
        case .ready: return Color.white.opacity(0.45)
        case .listening: return Color(red: 0.98, green: 0.36, blue: 0.36)
        case .thinking: return Color(red: 1.0, green: 0.78, blue: 0.3)
        case .speaking: return Color(red: 0.2, green: 0.5, blue: 1.0)
        }
    }
}

/// The last lesson as a sheet of paper: what it was called, what was said,
/// and where to go next.
private struct LessonCard: View {
    @ObservedObject var model: TutorControlBarModel
    let onAsk: (String) -> Void
    let onCopy: (TutorFollowUpButton) -> Void

    private var lastTutorTurn: TranscriptEntry? {
        model.transcript.last(where: { $0.speaker == .tutor })
    }
    private var lastQuestion: String? {
        model.transcript.last(where: { $0.speaker == .student })?.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(lastTutorTurn?.lessonTitle ?? "Your lesson")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.7))
                if model.isSpeaking {
                    Text("· Explaining")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.45))
                }
                Spacer()
            }

            if let lastTutorTurn {
                if let lastQuestion {
                    Text("\u{201C}\(lastQuestion)\u{201D}")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.88))
                        .lineLimit(2)
                }
                Text(lastTutorTurn.text)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.78))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(red: 1.0, green: 0.93, blue: 0.72).opacity(0.65))
                    )
                if !model.followUps.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(model.followUps) { button in
                            GelChip(
                                title: model.copiedButtonID == button.id ? "Copied" : button.title,
                                systemImage: button.question != nil ? "arrow.turn.down.right" : "doc.on.doc"
                            ) {
                                if let question = button.question { onAsk(question) } else { onCopy(button) }
                            }
                        }
                    }
                }
            } else {
                Text("Ask about the code, diagram or question in front of you. The tutor explains out loud and draws on your screen as it goes.")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.97, green: 0.95, blue: 0.89))
                .overlay(DotGrid().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
    }
}

/// Faint dots, like the squared paper the drawings use.
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 14
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)),
                                 with: .color(Color.black.opacity(0.09)))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}

/// A raised, glossy button for the next step, the way the paper cards'
/// actions read as things to press.
private struct GelChip: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color(red: 0.05, green: 0.12, blue: 0.3))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(LinearGradient(
                    colors: [Color(red: 0.78, green: 0.87, blue: 1.0), Color(red: 0.53, green: 0.69, blue: 0.98)],
                    startPoint: .top, endPoint: .bottom
                ))
            )
            .overlay(Capsule().stroke(Color(red: 0.2, green: 0.36, blue: 0.8).opacity(0.7), lineWidth: 1))
            .shadow(color: Color.black.opacity(isHovering ? 0.25 : 0.12), radius: isHovering ? 5 : 2, y: 1)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in isHovering = hovering }
    }
}

private struct NotchTabButton: View {
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.55))
                .frame(width: 38, height: 30)
                .background(
                    Capsule().fill(Color.white.opacity(isSelected ? 0.16 : (isHovering ? 0.08 : 0)))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in isHovering = hovering }
    }
}

/// The notch's own silhouette: square at the top where it meets the screen
/// edge, rounded at the bottom.
private struct NotchShape: Shape {
    var cornerRadius: CGFloat
    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct TranscriptRow: View {
    let entry: TranscriptEntry
    @State private var isShowingAll = false
    @State private var isHovering = false

    /// Past this, an answer is folded to a few lines so one long lesson does
    /// not push every other turn out of view.
    private static let foldAfterCharacters = 360

    private var isLong: Bool { entry.text.count > Self.foldAfterCharacters }
    private var isStudent: Bool { entry.speaker == .student }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: entry.time)
    }

    var body: some View {
        VStack(alignment: isStudent ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !isStudent {
                    Text("Buddy")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if let lessonTitle = entry.lessonTitle {
                    Text(lessonTitle.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Color(red: 0.45, green: 0.65, blue: 1.0))
                        .lineLimit(1)
                }
                Text(timeText)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                if isHovering {
                    Button(action: copyThisTurn) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Copy this")
                }
            }

            Text(entry.text)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(.white.opacity(isStudent ? 0.95 : 0.86))
                .textSelection(.enabled)
                .lineLimit(isLong && !isShowingAll ? 6 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, isStudent ? 11 : 0)
                .padding(.vertical, isStudent ? 7 : 0)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(isStudent ? Color.white.opacity(0.12) : Color.clear)
                )
                .frame(maxWidth: isStudent ? 440 : .infinity, alignment: isStudent ? .trailing : .leading)

            if isLong {
                Button(action: { withAnimation(.easeOut(duration: 0.18)) { isShowingAll.toggle() } }) {
                    Text(isShowingAll ? "Show less" : "Show more")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.45, green: 0.65, blue: 1.0))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .frame(maxWidth: .infinity, alignment: isStudent ? .trailing : .leading)
        .padding(.vertical, 2)
        .onHover { hovering in isHovering = hovering }
    }

    private func copyThisTurn() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }
}

/// One offered follow-up: a question to ask next, or something to copy.
private struct FollowUpChip: View {
    let button: TutorFollowUpButton
    let isCopied: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: button.question != nil ? "arrow.turn.down.right" : (isCopied ? "checkmark" : "doc.on.doc"))
                    .font(.system(size: 9, weight: .bold))
                Text(isCopied ? "Copied" : button.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color(red: 0.18, green: 0.43, blue: 0.92).opacity(isHovering ? 0.95 : 0.75))
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in isHovering = hovering }
        .help(button.question ?? "Copy to clipboard")
    }
}

private struct NotchButton: View {
    let systemImage: String
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(isHovering ? 0.2 : 0.1)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in isHovering = hovering }
    }
}
