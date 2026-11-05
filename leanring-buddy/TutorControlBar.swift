//
//  TutorControlBar.swift
//  leanring-buddy
//
//  The tutor's home at the top of the screen, grown out of the notch.
//  Closed, it says one thing on each side: what Buddy is doing, and what it
//  is about, with the sentence being said under it. On hover it opens on the
//  Lesson tab (NotchLessonTab.swift), the Chat tab with the whole day's
//  conversation, or Settings, with the Notebook and the Map a click away.
//
//  Why the notch. It is the one place on a Mac screen that is never study
//  material, so living there costs the student nothing, and it is where the
//  eye already goes for status. On a Mac without a notch the same shape hangs
//  from the middle of the menu bar.
//
//  Why a transcript. A spoken explanation is gone once said. A student who
//  missed a sentence, or wants the third step again, can read it here, and
//  each day's conversation is also saved as a plain text file to come back
//  to (~/Library/Application Support/Buddy/Transcripts).
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
    /// Which brain answered, kept in memory only, for the Chat tab's time
    /// tooltip now that the closed notch no longer names it.
    var answeredBy: String?
}

/// The views of the opened notch: Lesson, Chat (the day's conversation,
/// `transcript` in code and in the QA hooks) and Settings behind the gear.
enum NotchTab { case lesson, transcript, settings }

/// A permission Buddy cannot work without, for the closed notch's needs-you
/// state and the Lesson tab's alert row.
enum NotchMissingPermission: Equatable {
    case microphone, accessibility, screenRecording, screenContent

    /// One or two words beside the warning glyph in the closed notch.
    var closedNotchWord: String {
        switch self {
        case .microphone: return "can't hear you"
        case .accessibility: return "shortcut is off"
        case .screenRecording, .screenContent: return "can't see the screen"
        }
    }

    /// The alert row's sentence: what is wrong, then what to do.
    var alertSentence: String {
        switch self {
        case .microphone: return "Buddy can't hear you yet. Allow the Microphone to ask out loud."
        case .accessibility: return "Buddy can't notice Control + Option yet. Allow Accessibility so the shortcut works from any app."
        case .screenRecording: return "Buddy can't see your screen yet. Allow Screen Recording to ask about it."
        case .screenContent: return "Buddy can't read your screen yet. Allow Screen Content so it can point at things exactly."
        }
    }
}

/// An error on screen that Buddy offers to explain (ErrorOffer.swift), as
/// the Lesson tab's error card shows it.
struct NotchErrorOffer: Equatable {
    let applicationName: String
    /// The error as read, first line.
    let messageLine: String
    /// Where it points, "at render, app.js line 14", when known.
    let locationLine: String?
}

/// The start tiles on an empty day, built from the student's own memory and
/// Notebook. Refreshed each time the notch opens.
struct NotchHomeSuggestions: Equatable {
    struct FadingIdea: Equatable {
        let name: String
        /// "Learned Tuesday, fading".
        let learnedText: String
    }
    struct LastStudyDay: Equatable {
        let dayIdentifier: String
        /// "Yesterday's lessons", or "Monday's lessons".
        let title: String
        let pageCount: Int
        let firstLessonTitle: String
    }
    var fadingIdea: FadingIdea?
    var lastStudyDay: LastStudyDay?
}

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
    /// Which brain is answering. Not shown in the closed notch any more (a
    /// student does not know or care what Argon is); kept with each turn
    /// for the Chat tab's tooltip and the log.
    @Published var answeredBy: String = ""
    /// Teaching board hook (TeachingBoardSession): true while the board is
    /// open, so the notch can say "On the board" for the whole session.
    @Published var isBoardOpen = false
    /// The talk-over microphone is open while an answer plays, so a small
    /// mic beside "explaining" says the student can just talk.
    @Published var isListeningWhileExplaining = false
    enum TalkOverPause: Equatable {
        /// The student started talking over the answer; Buddy stopped for them.
        case cuttingIn
        /// "Hold on": paused until "go on".
        case held
    }
    /// Buddy paused for the student, shown as listening with "Buddy paused"
    /// on the right: the answer is waiting, not lost.
    @Published var talkOverPause: TalkOverPause?
    /// What the student is saying over the answer, live.
    @Published var talkOverHeardWords = ""
    /// Lecture mode is keeping the front app's last minute of sound
    /// (LectureAudioBuffer.swift). Shown as a small glyph whenever it is,
    /// the way macOS shows the microphone, so nothing is heard unseen.
    @Published var isKeepingLectureSound = false
    /// "lecture at 12:40", while an answer that used the lecture plays.
    @Published var lectureSourceLabel: String?
    /// A permission still missing, for the needs-you state.
    @Published var missingPermission: NotchMissingPermission?
    /// Google Cloud's sign-in expired, so Argon on Vertex cannot answer.
    @Published var signInProblemMessage: String?
    /// Opens setup on the permissions step, for the permission alert.
    var onAllowPermission: () -> Void = {}
    /// An error Buddy offers to explain, while the glow is live.
    @Published var errorOffer: NotchErrorOffer?
    var onExplainError: () -> Void = {}
    var onDismissError: () -> Void = {}
    /// The start tiles for an empty day.
    @Published var homeSuggestions = NotchHomeSuggestions()
    /// Asked each time the notch opens, so the tiles are current.
    var onRefreshHomeSuggestions: () -> Void = {}
    /// Opens the Notebook, on a day when one is given.
    var onOpenNotebook: (_ dayIdentifier: String?) -> Void = { _ in }
    /// Puts words in the chat box for the student to finish, with the
    /// keyboard in it and the cursor at the offset (the end when nil).
    var onPutInChatBox: (_ draft: String, _ cursorOffset: Int?) -> Void = { _, _ in }
    /// The app the last question was asked in, for the card's eyebrow.
    /// In memory only: after a relaunch the eyebrow shows the time alone.
    @Published var lastLessonApplicationName: String?
    /// Go deeper continues on the board, which suits a teach or normal
    /// question; a quick answer or a re-explanation does not offer it.
    @Published var lastAnswerOffersGoDeeper = false
    /// Whether finished lessons are being kept, for "Saved to your Notebook".
    @Published var isKeepingLessonsInNotebook = true
    /// What the student is saying, live while the keys are held, then the
    /// question as sent while the answer is prepared.
    @Published var heardWords: String = ""
    /// Ideas from earlier sessions the current answer builds on.
    @Published var buildsOn: [String] = []
    /// The step Buddy is waiting for the student to do, while it guides them
    /// through a task in an app. Shown under the notch so it is clear Buddy
    /// is watching for it, and how to stop that (Esc).
    @Published var guideInstruction: String?
    /// What the wait is spent on, said beside the amber dot: "reading your
    /// screen", then "thinking". A few seconds of silence read as broken;
    /// the same seconds with a stage name read as work.
    @Published var waitingStage: String?
    struct UpdateBanner: Equatable {
        let text: String
        let isWorking: Bool
        let canInstall: Bool
    }
    /// A newer Buddy, while one is available or installing.
    @Published var updateBanner: UpdateBanner?
    var onInstallUpdate: () -> Void = {}
    var onShowReleaseNotes: () -> Void = {}
    /// A key that stopped working, shown open in the notch until fixed.
    @Published var keyProblemMessage: String?
    /// Opens setup on the keys, for the key problem banner.
    var onFixKeys: () -> Void = {}
    /// Whether there is an answer to play again, and how, for Replay on the
    /// last lesson.
    @Published var canReplayLastAnswer = false
    var onReplayLastAnswer: () -> Void = {}
    /// Opens the map of what the student knows in its own window
    /// (KnowledgeMapWindow.swift), on an idea when one is named.
    var onOpenKnowledgeMap: (_ focusingIdeaNamed: String?) -> Void = { _ in }
    @Published private(set) var transcript: [TranscriptEntry] = []
    @Published var isExpanded = false {
        didSet { if isExpanded && !oldValue { onRefreshHomeSuggestions() } }
    }
    /// Where to put the cursor in the chat box once it has the keyboard,
    /// counted in characters from the start: "teach me | from scratch".
    @Published var chatCursorOffset: Int?
    /// The update alert shows on one opening a day at most; the gear's pip
    /// stays until the update is installed.
    private static let updateAlertShownDayDefaultsKey = "notchUpdateAlertShownDay"
    var hasShownUpdateAlertToday: Bool {
        UserDefaults.standard.string(forKey: Self.updateAlertShownDayDefaultsKey) == Self.todayIdentifier
    }
    func noteUpdateAlertShown() {
        UserDefaults.standard.set(Self.todayIdentifier, forKey: Self.updateAlertShownDayDefaultsKey)
    }
    private static var todayIdentifier: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
    @Published var selectedTab: NotchTab = .lesson
    /// Held open regardless of the mouse, while setup still needs the
    /// student (a missing permission).
    @Published var isPinnedOpen = false
    /// Hook for ErrorOffer.swift: the black shape's size as last laid out,
    /// so the error glow sits just under it. Not published, since it changes
    /// every frame of an animation and nothing in the notch draws from it.
    var laidOutShapeSize: CGSize = .zero
    /// What is typed in the chat box. Kept when the notch closes, so a
    /// question half written is still there when it opens again.
    @Published var chatDraft = ""
    /// The chat box has the keyboard. The notch stays open while it does,
    /// whatever the mouse does, so moving the pointer away mid-sentence does
    /// not throw the question away.
    @Published var isChatFocused = false
    /// Set to put the keyboard in the chat box as soon as it is on screen;
    /// it may not exist yet when asked, since it appears with the open notch.
    @Published var wantsChatFocus = false
    /// Long enough for a pasted function or error message, short enough that
    /// a whole pasted file does not crowd out the screen in the prompt.
    static let chatCharacterLimit = 2000

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
            transcript.append(TranscriptEntry(speaker: .tutor, text: sentence,
                                              answeredBy: answeredBy.isEmpty ? nil : answeredBy))
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
/// Both live in ~/Library/Application Support/Buddy/Transcripts and
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
        .appendingPathComponent("Library/Application Support/\(AppIdentity.dataName)/Transcripts")

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

/// A borderless panel can never take the keyboard by default. This one can,
/// only for the chat box: `becomesKeyOnlyIfNeeded` keeps clicks on buttons
/// from taking it, and being non-activating keeps the app being studied in
/// front, so its name and window are what the answer is about.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class TutorControlBarController {
    let model = TutorControlBarModel()
    private var panel: NSPanel?
    private var hostingView: NSHostingView<TutorNotchView>?

    private let onAsk: (String) -> Void
    private let onAskTyped: (String) -> Void
    private let onStop: () -> Void
    private let onClear: () -> Void
    private let settingsView: () -> AnyView

    /// The size of the black shape as last laid out, which is what the mouse
    /// is tested against. The window itself is larger and transparent.
    private var notchShapeSize: CGSize = .zero
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    /// Runs only while the pointer is over the notch or the notch is open:
    /// once the window takes the mouse, the global monitor stops hearing it.
    private var hoverPollTimer: Timer?
    private var pointerEnteredNotchAt: Date?
    private var pointerLeftNotchAt: Date?

    /// A short dwell before opening, so a pointer passing through the menu bar
    /// does not throw the notch open, and a longer grace before closing, so a
    /// small overshoot past the edge does not slam it shut.
    private static let openAfterSeconds: TimeInterval = 0.09
    private static let closeAfterSeconds: TimeInterval = 0.32
    /// Space around the open shape that still counts as over it.
    private static let openShapeMargin: CGFloat = 16

    init(
        onAsk: @escaping (String) -> Void,
        onAskTyped: @escaping (String) -> Void,
        onStop: @escaping () -> Void,
        onClear: @escaping () -> Void,
        settingsView: @escaping () -> AnyView
    ) {
        self.onAsk = onAsk
        self.onAskTyped = onAskTyped
        self.onStop = onStop
        self.onClear = onClear
        self.settingsView = settingsView
        model.onPutInChatBox = { [weak self] draft, cursorOffset in
            self?.openChat(withDraft: draft, cursorOffset: cursorOffset)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel = self.makePanel()
            self.placePanel()
            self.watchMouse()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.placePanel() }
        }
    }

    private static var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// The window never changes size. Resizing it per frame cannot keep up
    /// with a spring, so the shape grows and shrinks inside a fixed, clear
    /// window and the mouse passes through everywhere the shape is not.
    /// The screen the panel was put on. Hover is tested against it, not
    /// against whichever screen has focus now, which can be a different one.
    private var placedScreenFrame: NSRect?

    private func placePanel() {
        guard let panel, let screen = Self.notchScreen else { return }
        placedScreenFrame = screen.frame
        let size = TutorNotchView.windowSize(for: screen)
        panel.setFrame(NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        ), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let screen = Self.notchScreen
        let windowSize = screen.map(TutorNotchView.windowSize(for:)) ?? CGSize(width: 720, height: 700)
        let panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above the menu bar, which is where the notch is.
        // One above the drawing overlay, which shares .screenSaver and is
        // brought forward on every answer: opened, the notch must sit over
        // the drawing, never under its cards.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // Non-activating so a click here does not pull focus from the app the
        // student is studying in.
        panel.becomesKeyOnlyIfNeeded = true
        // Clicking into another app takes the keyboard back. The chat box
        // lets go of the notch then, so it closes like any other hover.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            TutorDebugLog.write("⌨️ notch gave up the keyboard")
            Task { @MainActor in self?.model.isChatFocused = false }
        }

        let notchWidth = Self.notchWidth(of: screen)
        let notchHeight = max(screen?.safeAreaInsets.top ?? 0, NSStatusBar.system.thickness)

        let view = TutorNotchView(
            model: model,
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            windowSize: windowSize,
            onAsk: { [weak self] question in
                InterfaceSounds.shared.play(.sent)
                self?.onAsk(question)
            },
            onCopy: { [weak self] button in self?.copy(button) },
            onCopyTranscript: { [weak self] in self?.copyTranscript() },
            onCopyLesson: { [weak self] lessonText in self?.copyLesson(lessonText) },
            onStop: { [weak self] in self?.onStop() },
            onClear: { [weak self] in self?.onClear() },
            onSendTyped: { [weak self] question in self?.sendTyped(question) },
            onFinishTyping: { [weak self] in self?.finishTyping() },
            onChatFocused: { [weak self] in self?.rememberAppBeingStudied() },
            onShapeSizeChange: { [weak self] size in
                // Hover depends on this arriving, so its first arrival is logged.
                if self?.notchShapeSize == .zero {
                    TutorDebugLog.write("🫥 notch shape laid out: \(Int(size.width))×\(Int(size.height))")
                }
                self?.notchShapeSize = size
                // Hook for ErrorOffer.swift: its glow hangs under the shape.
                self?.model.laidOutShapeSize = size
                self?.updateHover()
            },
            onOpenRequested: { [weak self] in self?.openByStudent() },
            settingsView: settingsView
        )
        let hostingView = NSHostingView(rootView: view)
        // The window is sized by placePanel, never by the content: letting
        // SwiftUI resize it mid-animation is what made the notch jump.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        self.hostingView = hostingView
        return panel
    }

    /// Where the black shape is on screen: hanging from the top centre.
    private var notchShapeRectOnScreen: NSRect? {
        guard let screenFrame = placedScreenFrame ?? Self.notchScreen?.frame, notchShapeSize != .zero else { return nil }
        return NSRect(
            x: screenFrame.midX - notchShapeSize.width / 2,
            y: screenFrame.maxY - notchShapeSize.height,
            width: notchShapeSize.width,
            height: notchShapeSize.height
        )
    }

    private func watchMouse() {
        // Global while the pointer is over other apps, local once the notch
        // itself has the mouse.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.updateHover() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateHover()
            return event
        }
    }

    private func updateHover() {
        guard let panel, let shapeRect = notchShapeRectOnScreen else { return }
        let pointer = NSEvent.mouseLocation
        let isButtonDown = NSEvent.pressedMouseButtons & 1 != 0

        // The window takes the mouse only over the shape itself.
        let isOverShape = shapeRect.insetBy(dx: -1, dy: -1).contains(pointer)
        let shouldPassThrough = !(isOverShape || (isButtonDown && !panel.ignoresMouseEvents))
        if panel.ignoresMouseEvents != shouldPassThrough {
            panel.ignoresMouseEvents = shouldPassThrough
        }

        // Open, the margin around the shape still counts, so leaving takes
        // intent. Closed, the strip up to the screen edge counts, so flinging
        // the pointer to the top of the screen lands on it.
        let hoverRect = model.isExpanded
            ? shapeRect.insetBy(dx: -Self.openShapeMargin, dy: -Self.openShapeMargin)
            : NSRect(x: shapeRect.minX - 12, y: shapeRect.minY, width: shapeRect.width + 24, height: shapeRect.height + 4)
        let isInside = hoverRect.contains(pointer)
        let now = Date()

        if isInside {
            pointerLeftNotchAt = nil
            if pointerEnteredNotchAt == nil { pointerEnteredNotchAt = now }
            if !model.isExpanded, !isHeldClosedUntilPointerLeaves, let entered = pointerEnteredNotchAt,
               now.timeIntervalSince(entered) >= Self.openAfterSeconds {
                openByStudent()
            }
        } else {
            pointerEnteredNotchAt = nil
            isHeldClosedUntilPointerLeaves = false
            if pointerLeftNotchAt == nil { pointerLeftNotchAt = now }
            // Not while a button is held: a text selection or a scroll-bar
            // drag can wander outside and should not lose the notch.
            if model.isExpanded, !model.isPinnedOpen, !model.isChatFocused, !model.wantsChatFocus,
               !isButtonDown, let left = pointerLeftNotchAt,
               now.timeIntervalSince(left) >= Self.closeAfterSeconds {
                setExpanded(false)
            }
        }

        let needsPolling = isInside || model.isExpanded
        if needsPolling, hoverPollTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateHover() }
            }
            RunLoop.main.add(timer, forMode: .common)
            hoverPollTimer = timer
        } else if !needsPolling, let timer = hoverPollTimer {
            timer.invalidate()
            hoverPollTimer = nil
        }
    }

    /// Opened by the student's hover or click, which gets the water drop.
    /// Opened by the app (setup, the Dock icon) it stays silent.
    private func openByStudent() {
        guard !model.isExpanded else { return }
        InterfaceSounds.shared.play(.drop)
        setExpanded(true)
    }

    /// Closes the notch from the keyboard. It stays closed while the pointer
    /// is still over it, until the pointer leaves, so hover does not reopen
    /// it a moment later. Returns whether there was anything to close.
    @discardableResult
    func closeFromKeyboard() -> Bool {
        guard model.isExpanded, !model.isPinnedOpen else { return false }
        isHeldClosedUntilPointerLeaves = true
        setExpanded(false)
        return true
    }

    private var isHeldClosedUntilPointerLeaves = false

    /// Closed for a window that needs the space, such as setup. It stays
    /// closed until the pointer leaves and comes back.
    func putAway() {
        model.isChatFocused = false
        model.wantsChatFocus = false
        isHeldClosedUntilPointerLeaves = true
        setExpanded(false)
    }

    // MARK: Typing

    /// The app the student was in before the chat box took the keyboard,
    /// given the keyboard back when they send or put the box away.
    private var appBeingStudied: NSRunningApplication?

    private func rememberAppBeingStudied() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            appBeingStudied = front
        }
    }

    /// Opens the notch on the conversation with the keyboard in the chat box.
    func openChat() {
        openChat(on: .transcript)
    }

    /// Opens the notch with words already in the chat box and the cursor
    /// where the student finishes them, for the start tiles and the Map's
    /// Teach it back: "teach me | from scratch".
    func openChat(withDraft draft: String, cursorOffset: Int? = nil) {
        model.chatDraft = draft
        model.chatCursorOffset = cursorOffset ?? draft.count
        openChat(on: model.selectedTab == .settings ? .lesson : model.selectedTab)
    }

    private func openChat(on tab: NotchTab) {
        rememberAppBeingStudied()
        model.selectedTab = tab
        isHeldClosedUntilPointerLeaves = false
        // Its own sound, so typing and talking are told apart by ear.
        InterfaceSounds.shared.play(.type)
        if !model.isExpanded { setExpanded(true) }
        panel?.makeKey()
        model.wantsChatFocus = true
        TutorDebugLog.write("⌨️ chat open: panel key=\(panel?.isKeyWindow == true) app active=\(NSApp.isActive)")
    }

    /// Sent from the chat box. The notch closes so the whole screen is free
    /// for the drawing, the way it is after a spoken question, and the
    /// answer appears in the conversation as it is said.
    private func sendTyped(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.chatDraft = ""
        InterfaceSounds.shared.play(.sent)
        finishTyping()
        onAskTyped(trimmed)
    }

    #if DEBUG
    /// The send button, for scripted tests.
    func qaSendDraft() { sendTyped(model.chatDraft) }
    func qaFinishTyping() { finishTyping() }
    /// A real key event into the panel, the path a keypress takes.
    func qaPressReturn(withShift: Bool) {
        guard let panel, let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: withShift ? [.shift] : [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ) else { return }
        panel.sendEvent(event)
    }
    #endif

    /// Esc in the chat box, or after sending: closes the notch and gives the
    /// keyboard back to the app the student was in.
    private func finishTyping() {
        model.isChatFocused = false
        model.wantsChatFocus = false
        panel?.makeFirstResponder(nil)
        isHeldClosedUntilPointerLeaves = true
        setExpanded(false)
        // The studied app never stopped being frontmost, so activating it is
        // a no-op; Buddy has to step back for the keyboard to return to it.
        if NSApp.isActive { NSApp.deactivate() }
        appBeingStudied?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            TutorDebugLog.write("⌨️ chat put away: panel key=\(self?.panel?.isKeyWindow == true), app active=\(NSApp.isActive)")
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard model.isExpanded != expanded else { return }
        model.isExpanded = expanded
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
        InterfaceSounds.shared.play(.tick)
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.transcriptText, forType: .string)
        InterfaceSounds.shared.play(.tick)
    }

    /// The last lesson's own text, from the card's Copy.
    private func copyLesson(_ lessonText: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lessonText, forType: .string)
        InterfaceSounds.shared.play(.tick)
    }
}

// MARK: - The view

/// How the notch moves, in one place so opening, closing and everything that
/// changes inside it feel like one object.
enum NotchMotion {
    /// Opening overshoots a touch, the way a sheet pulled out of the notch
    /// would; closing settles without a bounce so it reads as put away.
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let close = Animation.spring(response: 0.34, dampingFraction: 1.0)
    /// Content arrives just after the shape starts to grow, and leaves before
    /// it starts to shrink, so nothing is ever cut off by the edge.
    static let contentIn = Animation.easeOut(duration: 0.26).delay(0.07)
    static let contentOut = Animation.easeIn(duration: 0.1)
    static let change = Animation.smooth(duration: 0.28)
    static let reduced = Animation.easeInOut(duration: 0.18)
    /// Every hover change in the notch: fills rise and text brightens.
    static let hover = Animation.easeOut(duration: 0.13)
}

/// Fades content through a light blur and a slight drop from the top edge,
/// so it seems to come out of the notch rather than pop in.
private struct NotchContentFade: ViewModifier {
    let isHidden: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isHidden ? 0 : 1)
            .blur(radius: isHidden && !reduceMotion ? 6 : 0)
            .scaleEffect(isHidden && !reduceMotion ? 0.97 : 1, anchor: .top)
    }
}

private extension AnyTransition {
    static func notchContent(reduceMotion: Bool) -> AnyTransition {
        let fade = AnyTransition.modifier(
            active: NotchContentFade(isHidden: true, reduceMotion: reduceMotion),
            identity: NotchContentFade(isHidden: false, reduceMotion: reduceMotion)
        )
        return .asymmetric(
            insertion: fade.animation(reduceMotion ? NotchMotion.reduced : NotchMotion.contentIn),
            removal: fade.animation(reduceMotion ? NotchMotion.reduced : NotchMotion.contentOut)
        )
    }
}

struct TutorNotchView: View {
    @ObservedObject var model: TutorControlBarModel
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let windowSize: CGSize
    let onAsk: (String) -> Void
    let onCopy: (TutorFollowUpButton) -> Void
    let onCopyTranscript: () -> Void
    let onCopyLesson: (String) -> Void
    let onStop: () -> Void
    let onClear: () -> Void
    let onSendTyped: (String) -> Void
    let onFinishTyping: () -> Void
    let onChatFocused: () -> Void
    /// The shape's laid-out size, so the controller knows where the mouse
    /// should be caught and where it should pass through.
    let onShapeSizeChange: (CGSize) -> Void
    let onOpenRequested: () -> Void
    let settingsView: () -> AnyView

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabIndicator

    /// Nothing to say: the shape shrinks to the camera housing and disappears
    /// into it, leaving the menu bar either side free. It spreads out the
    /// moment there is something to show, the way a live activity does.
    private var isIdle: Bool {
        !model.isExpanded && model.activity == .ready && model.caption.isEmpty
            && (model.followUps.isEmpty || model.isSpeaking) && model.guideInstruction == nil
            && !model.isBoardOpen   // Teaching board hook: never idle while the board is open.
            && needsYouWord == nil && model.errorOffer == nil && model.talkOverPause == nil
    }
    /// Idle, but the front app's sound is being kept: the shape stays just
    /// wider than the camera, with the lecture glyph on the right and
    /// nothing else, like the menu bar's microphone light.
    private var isShowingOnlyTheLectureGlyph: Bool { isIdle && model.isKeepingLectureSound }
    private var isResting: Bool { isIdle && !model.isKeepingLectureSound }

    /// Wide enough for the longest stage ("reading your screen") on one
    /// side and a lesson name on the other.
    private var activeWidth: CGFloat { notchWidth + 300 }

    private var collapsedWidth: CGFloat {
        if isResting { return notchWidth }
        if isShowingOnlyTheLectureGlyph { return notchWidth + 64 }
        return activeWidth
    }
    private var expandedWidth: CGFloat { max(activeWidth, 600) }

    /// The concave curves where the shape meets the top edge, as the real
    /// notch has, so the panel reads as part of the hardware.
    private var shoulderRadius: CGFloat { model.isExpanded ? 14 : 7 }
    private var bottomRadius: CGFloat { model.isExpanded ? 26 : 13 }

    /// The fixed window the shape lives in: room for the widest, tallest open
    /// state plus its shadow. Clear everywhere the shape is not.
    static func windowSize(for screen: NSScreen) -> CGSize {
        CGSize(width: 760, height: min(screen.frame.height * 0.85, 820))
    }

    var body: some View {
        notchShape
            .frame(width: windowSize.width, height: windowSize.height, alignment: .top)
    }

    private var notchShape: some View {
        VStack(spacing: 0) {
            statusRow
            if model.isExpanded {
                expandedContent
                    .transition(.notchContent(reduceMotion: reduceMotion))
            } else {
                collapsedExtras
            }
        }
        .frame(width: model.isExpanded ? expandedWidth : collapsedWidth)
        .padding(.horizontal, shoulderRadius)
        // Content is clipped to the shape while it animates; the fill and its
        // shadow go behind, outside the clip, so the shadow is not cut off.
        .clipShape(NotchShape(shoulderRadius: shoulderRadius, bottomRadius: bottomRadius))
        .background(
            NotchShape(shoulderRadius: shoulderRadius, bottomRadius: bottomRadius)
                .fill(DS.Notch.fill)
                .shadow(color: .black.opacity(model.isExpanded ? 0.45 : 0), radius: 22, y: 10)
        )
        .contentShape(NotchShape(shoulderRadius: shoulderRadius, bottomRadius: bottomRadius))
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { proxy in proxy.size } action: { size in
            onShapeSizeChange(size)
        }
        .animation(reduceMotion ? NotchMotion.reduced : (model.isExpanded ? NotchMotion.open : NotchMotion.close),
                   value: model.isExpanded)
        .animation(reduceMotion ? NotchMotion.reduced : NotchMotion.open, value: isIdle)
        .animation(reduceMotion ? NotchMotion.reduced : NotchMotion.open, value: isShowingOnlyTheLectureGlyph)
        .animation(reduceMotion ? NotchMotion.reduced : NotchMotion.change, value: model.caption)
        .animation(reduceMotion ? NotchMotion.reduced : NotchMotion.change, value: model.followUps)
        .animation(reduceMotion ? NotchMotion.reduced : NotchMotion.change, value: model.guideInstruction)
        .animation(reduceMotion ? NotchMotion.reduced : NotchMotion.change, value: isShowingHeardWords)
        .animation(reduceMotion ? NotchMotion.reduced : NotchMotion.change, value: model.errorOffer)
        .animation(reduceMotion ? NotchMotion.reduced : NotchMotion.change, value: model.talkOverPause)
        // New words arrive several times a second; a quick ease keeps the
        // height change from lagging behind the speaker.
        .animation(.easeOut(duration: 0.12), value: model.heardWords)
        .animation(.easeOut(duration: 0.12), value: model.talkOverHeardWords)
        .animation(reduceMotion ? NotchMotion.reduced : NotchMotion.change, value: model.selectedTab)
    }

    // MARK: The closed notch

    /// The needs-you word, when something only the student can fix stops
    /// Buddy: shown closed, in amber, so a failed key is seen, not only
    /// heard as the failure tone. Never while Buddy is busy.
    private var needsYouWord: String? {
        guard model.activity == .ready, model.guideInstruction == nil else { return nil }
        if let missingPermission = model.missingPermission { return missingPermission.closedNotchWord }
        if model.keyProblemMessage != nil { return "key problem" }
        if model.signInProblemMessage != nil { return "sign-in expired" }
        return nil
    }

    /// Talked over: the student is speaking and Buddy has stopped for them.
    /// Shown as listening, so there is one state to learn, with the answer
    /// waiting on the right.
    private var isTalkedOver: Bool { model.talkOverPause != nil }

    // The row level with the camera: one thing on the left, one on the right.
    private var statusRow: some View {
        HStack(spacing: 0) {
            leftStatus
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isIdle ? 0 : 1)

            Spacer().frame(width: notchWidth)

            rightStatus
                .frame(maxWidth: .infinity, alignment: .trailing)
                .opacity(isResting ? 0 : 1)
        }
        .padding(.horizontal, isResting ? 0 : 14)
        .frame(height: notchHeight)
        .contentShape(Rectangle())
        // A click opens it at once, for anyone who clicks rather than waits.
        .onTapGesture { if !model.isExpanded { onOpenRequested() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusAccessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private var leftStatus: some View {
        if let needsYouWord {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 10.5, weight: .bold))
                Text(needsYouWord)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(DS.Colors.warning)
            .transition(.opacity)
        } else {
            HStack(spacing: 6) {
                ActivityDot(colour: activityColour,
                            isBusy: model.activity == .listening || model.activity == .thinking || isTalkedOver,
                            reduceMotion: reduceMotion)
                // One line, always: a status that wraps under the camera
                // reads as broken. Long stages shrink a little before that.
                Text(activityWord)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Notch.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.opacity)
                if model.activity == .speaking && model.isListeningWhileExplaining && !isTalkedOver {
                    Image(systemName: "mic")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(DS.Notch.textSecondary)
                        .transition(.opacity)
                }
            }
            .animation(NotchMotion.change, value: model.activity)
            .animation(NotchMotion.change, value: model.waitingStage)
            .animation(NotchMotion.change, value: model.isListeningWhileExplaining)
        }
    }

    /// What the right side says, and the glyph before it.
    private var rightSideContent: (glyph: String?, text: String) {
        if needsYouWord != nil { return (nil, "hover to fix") }
        // Teaching board hook: the board's label wins for the whole session.
        if model.isBoardOpen && !isTalkedOver { return (nil, "On the board") }
        if isTalkedOver { return (nil, "Buddy paused") }
        if model.errorOffer != nil && model.activity == .ready { return (nil, model.errorOffer?.applicationName ?? "") }
        if let lectureSourceLabel = model.lectureSourceLabel, model.activity == .speaking {
            return ("tv", lectureSourceLabel)
        }
        if isShowingOnlyTheLectureGlyph { return ("tv", "") }
        // While the student speaks, nothing competes with their words.
        if model.activity == .listening { return (model.isKeepingLectureSound ? "tv" : nil, "") }
        return (model.isKeepingLectureSound ? "tv" : nil, currentLessonTitle ?? "")
    }

    private var rightStatus: some View {
        let content = rightSideContent
        return HStack(spacing: 6) {
            if let glyph = content.glyph {
                Image(systemName: glyph)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(DS.Notch.textSecondary)
                    .nativeTooltip(model.isKeepingLectureSound
                                   ? "Buddy is keeping the last minute of this app's sound, on this Mac, in case you ask about the lecture."
                                   : nil)
            }
            if !content.text.isEmpty {
                Text(content.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Notch.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
            }
        }
        .animation(NotchMotion.change, value: content.text)
    }

    private var statusAccessibilityLabel: String {
        if let missingPermission = model.missingPermission, needsYouWord != nil {
            return "Buddy needs you. \(missingPermission.alertSentence) Open the notch to fix."
        }
        if let keyProblemMessage = model.keyProblemMessage, needsYouWord != nil {
            return "Buddy needs you. \(keyProblemMessage) Open the notch to fix."
        }
        if let signInProblemMessage = model.signInProblemMessage, needsYouWord != nil {
            return "Buddy needs you. \(signInProblemMessage) Open the notch to fix."
        }
        if model.errorOffer != nil && model.activity == .ready {
            return "Buddy noticed an error on screen. Open the notch to have it explained."
        }
        var parts = ["Buddy, \(isTalkedOver ? "listening, paused for you" : activityWord)."]
        if model.activity == .speaking && model.isListeningWhileExplaining { parts.append("You can talk to interrupt.") }
        if model.isKeepingLectureSound { parts.append("Keeping the lecture's last minute of sound.") }
        if let title = currentLessonTitle, !isIdle { parts.append(title + ".") }
        return parts.joined(separator: " ")
    }

    /// Under the notch while collapsed: the sentence being said, the words
    /// heard, the guide step, the error offered, or the follow-ups.
    @ViewBuilder
    private var collapsedExtras: some View {
        if model.talkOverPause == .cuttingIn && !model.talkOverHeardWords.isEmpty {
            heardWordsRow(words: model.talkOverHeardWords, isLive: true)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
                .frame(width: collapsedWidth)
                .transition(.notchContent(reduceMotion: reduceMotion))
        } else if !model.caption.isEmpty {
            Text(model.caption)
                .font(.system(size: 13, weight: .medium))
                .lineSpacing(2)
                .foregroundStyle(DS.Notch.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .padding(.horizontal, 26)
                .padding(.top, 3)
                .padding(.bottom, 13)
                .frame(width: collapsedWidth)
                .transition(.notchContent(reduceMotion: reduceMotion))
        } else if isShowingHeardWords {
            heardWordsRow(words: model.heardWords, isLive: model.activity == .listening)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
                .frame(width: collapsedWidth)
                .transition(.notchContent(reduceMotion: reduceMotion))
        } else if let guideInstruction = model.guideInstruction, model.activity == .ready {
            guideRow(guideInstruction)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
                .frame(width: collapsedWidth)
                .transition(.notchContent(reduceMotion: reduceMotion))
        } else if model.errorOffer != nil, model.activity == .ready, needsYouWord == nil {
            errorOfferRow
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
                .frame(width: collapsedWidth)
                .transition(.notchContent(reduceMotion: reduceMotion))
        } else if !model.followUps.isEmpty && !model.isSpeaking && needsYouWord == nil {
            followUpRow
                .padding(.bottom, 10)
                .frame(width: collapsedWidth)
                .transition(.notchContent(reduceMotion: reduceMotion))
        }
    }

    /// The step being waited for, and the way out.
    private func guideRow(_ instruction: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DS.Notch.dotTurn)
            Text(instruction)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Notch.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("esc to stop")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DS.Notch.textMinimum)
        }
    }

    /// An error in front of the student, offered closed: hovering opens the
    /// notch on the error card, where Explain is one click.
    private var errorOfferRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(DS.Notch.errorGlowEdge)
            Text("An error on screen.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Notch.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("hover to explain")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DS.Notch.textMinimum)
        }
    }

    private var isShowingHeardWords: Bool {
        (model.activity == .listening || model.activity == .thinking) && !model.heardWords.isEmpty
    }

    /// The student's own words, bright while they are still speaking and
    /// dimmed once sent. Cut from the front, so the newest words stay in view
    /// however long the question runs.
    private func heardWordsRow(words: String, isLive: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: isLive ? "waveform" : "text.bubble")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DS.Notch.textMinimum)
                .contentTransition(.symbolEffect(.replace))
            Text(Self.newestWords(of: words))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isLive ? DS.Notch.textPrimary : DS.Notch.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.easeOut(duration: 0.15), value: model.activity)
    }

    /// About two lines' worth from the end, cut at a word. SwiftUI's own
    /// head truncation cuts two-line text mid-word on the second line.
    private static func newestWords(of words: String) -> String {
        let roughlyTwoLines = 88
        guard words.count > roughlyTwoLines else { return words }
        let tail = words.suffix(roughlyTwoLines)
        let fromWordStart = tail.firstIndex(of: " ").map { tail[tail.index(after: $0)...] } ?? tail
        return "\u{2026}" + fromWordStart
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

    // MARK: The open notch

    private var expandedContent: some View {
        VStack(spacing: 14) {
            NotchTabRow(model: model, indicatorNamespace: tabIndicator)
                .padding(.horizontal, 18)

            Group {
                switch model.selectedTab {
                case .settings:
                    settingsView()
                        .padding(.horizontal, 18)
                        .padding(.bottom, 16)
                case .transcript:
                    chatContent
                case .lesson:
                    lessonContent
                }
            }
            .id(model.selectedTab)
            .transition(.opacity)
        }
        .padding(.top, 6)
        .onDisappear {
            // The update alert counts as seen once the notch it was in closes.
            if currentAlert.map({ if case .update = $0 { return true } else { return false } }) == true {
                model.noteUpdateAlertShown()
            }
        }
    }

    /// The one alert the Lesson tab shows at most, most pressing first:
    /// a missing permission, a key or sign-in problem, then an update. The
    /// update waits for an answer to finish and shows on one opening a day.
    private var currentAlert: NotchAlert? {
        if let missingPermission = model.missingPermission {
            return .permission(missingPermission.alertSentence)
        }
        if let keyProblemMessage = model.keyProblemMessage { return .key(keyProblemMessage) }
        if let signInProblemMessage = model.signInProblemMessage { return .signIn(signInProblemMessage) }
        if let updateBanner = model.updateBanner, !model.isSpeaking,
           updateBanner.isWorking || !model.hasShownUpdateAlertToday {
            return .update(updateBanner)
        }
        return nil
    }

    private var lessonContent: some View {
        VStack(spacing: 14) {
            if let currentAlert {
                NotchAlertRow(alert: currentAlert, model: model)
                    .padding(.horizontal, 18)
                    .transition(.opacity)
            }
            if let errorOffer = model.errorOffer {
                NotchErrorCard(errorOffer: errorOffer, model: model)
                    .padding(.horizontal, 18)
                    .transition(.opacity)
            }
            // Notebook hook: an export's result, when notifications are off.
            NotebookNotchExportNotice()
                .padding(.horizontal, 18)

            Group {
                if model.transcript.isEmpty {
                    NotchHomeView(model: model)
                } else if model.errorOffer != nil {
                    // The error leads while it is offered; the lesson folds
                    // to one row under it and opens on a click.
                    FoldedLessonRow(model: model, onAsk: onAsk, onCopy: onCopy, onCopyLesson: onCopyLesson,
                                    onStop: onStop)
                } else {
                    LessonCard(model: model, onAsk: onAsk, onCopy: onCopy, onCopyLesson: onCopyLesson, onStop: onStop)
                }
            }
            .padding(.horizontal, 18)

            chatBox
                .padding(.horizontal, 18)

            if !model.transcript.isEmpty {
                lessonFooter
                    .padding(.horizontal, 18)
            }
        }
        .padding(.bottom, model.transcript.isEmpty ? 18 : 14)
        .animation(NotchMotion.change, value: model.errorOffer)
    }

    private var chatContent: some View {
        VStack(spacing: 14) {
            if let currentAlert {
                NotchAlertRow(alert: currentAlert, model: model)
                    .padding(.horizontal, 18)
            }
            transcriptList
                .padding(.horizontal, 18)
            chatBox
                .padding(.horizontal, 18)
            HStack(spacing: 8) {
                if !model.transcript.isEmpty {
                    NotchButton(systemImage: "doc.on.doc", title: "Copy all", action: onCopyTranscript)
                        .accessibilityLabel("Copy today's conversation")
                }
                Spacer()
                stopAndClearButtons
            }
            .padding(.horizontal, 18)
        }
        .padding(.bottom, 14)
    }

    private var chatBox: some View {
        NotchChatBox(
            model: model,
            placeholder: model.selectedTab == .lesson && !model.transcript.isEmpty
                ? "Ask a follow-up" : "Type a question about your screen",
            onSend: { question in
                model.selectedTab = .transcript
                onSendTyped(question)
            },
            onDismiss: onFinishTyping,
            onFocused: onChatFocused
        )
    }

    /// Under a lesson: where it was kept, and what can be done mid-answer.
    private var lessonFooter: some View {
        HStack(spacing: 8) {
            if model.isKeepingLessonsInNotebook && !model.isSpeaking {
                NotchQuietTextButton(title: "Saved to your Notebook",
                                     accessibilityText: "Saved to your Notebook. Open it") {
                    model.onOpenNotebook(nil)
                }
            }
            Spacer()
            stopAndClearButtons
        }
        .frame(minHeight: 30)
    }

    @ViewBuilder
    private var stopAndClearButtons: some View {
        HStack(spacing: 8) {
            if model.isSpeaking {
                NotchButton(systemImage: "stop.fill", title: "Stop", action: onStop)
                    .transition(.opacity)
            }
            if model.hasDrawing {
                NotchButton(systemImage: "xmark", title: "Clear drawing", keyHint: "esc", action: onClear)
                    .accessibilityLabel("Clear drawing")
                    .transition(.opacity)
            }
        }
        .animation(NotchMotion.change, value: model.isSpeaking)
        .animation(NotchMotion.change, value: model.hasDrawing)
    }

    private var transcriptList: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.transcript.isEmpty {
                        Text("Everything you ask today, and everything Buddy explains, is written here.")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Notch.textMinimum)
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
                guard let last = model.transcript.last else { return }
                withAnimation(NotchMotion.change) { reader.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var currentLessonTitle: String? {
        model.transcript.last(where: { $0.lessonTitle != nil })?.lessonTitle
    }

    private var activityWord: String {
        if isTalkedOver { return "listening" }
        switch model.activity {
        case .ready: return model.guideInstruction == nil ? "ready" : "your turn"
        case .listening: return "listening"
        case .thinking: return model.waitingStage ?? "thinking"
        case .speaking: return "explaining"
        }
    }

    private var activityColour: Color {
        if isTalkedOver { return DS.Notch.dotListening }
        switch model.activity {
        case .ready: return model.guideInstruction == nil ? DS.Notch.dotReady : DS.Notch.dotTurn
        case .listening: return DS.Notch.dotListening
        case .thinking: return DS.Notch.dotThinking
        case .speaking: return DS.Notch.dotSpeaking
        }
    }
}

/// The status light. While listening or thinking a ring breathes out of it,
/// so a glance tells the student the tutor heard them and is working.
private struct ActivityDot: View {
    let colour: Color
    let isBusy: Bool
    let reduceMotion: Bool

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 7, height: 7)
            .shadow(color: colour.opacity(0.8), radius: 3)
            .background {
                if isBusy && !reduceMotion {
                    Circle()
                        .stroke(colour, lineWidth: 1.5)
                        .phaseAnimator([0.0, 1.0]) { ring, phase in
                            ring
                                .scaleEffect(1 + phase * 1.3)
                                .opacity(0.85 - phase * 0.85)
                        } animation: { phase in
                            phase == 1.0 ? .easeOut(duration: 1.1) : .linear(duration: 0)
                        }
                        .frame(width: 7, height: 7)
                }
            }
            .animation(NotchMotion.change, value: colour)
    }
}

// MARK: - The tab row

/// Lesson and Chat as labelled tabs on the left; the Notebook and the Map,
/// which open their own windows, as text buttons on the right; Settings
/// last, behind the gear.
private struct NotchTabRow: View {
    @ObservedObject var model: TutorControlBarModel
    let indicatorNamespace: Namespace.ID

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                NotchTabButton(title: "Lesson", systemImage: "book.closed", tab: .lesson, position: 1,
                               model: model, indicatorNamespace: indicatorNamespace)
                NotchTabButton(title: "Chat", systemImage: "bubble.left", tab: .transcript, position: 2,
                               model: model, indicatorNamespace: indicatorNamespace)
            }
            .padding(2)
            .background(Capsule().fill(DS.Notch.track))

            Spacer()

            // Notebook hook: every lesson kept as a page, in its own window.
            NotchWindowButton(title: "Notebook", systemImage: "book.pages",
                              accessibilityText: "Open Notebook, opens a window") {
                model.onOpenNotebook(nil)
            }
            // Not a tab: the map opens in its own window, which can take
            // the keyboard for search where the notch never does.
            NotchWindowButton(title: "Map", systemImage: "point.3.connected.trianglepath.dotted",
                              accessibilityText: "Open Map of what you know, opens a window") {
                model.onOpenKnowledgeMap(nil)
            }
            NotchGearButton(model: model, indicatorNamespace: indicatorNamespace)
        }
        .frame(height: 30)
    }
}

private struct NotchTabButton: View {
    let title: String
    let systemImage: String
    let tab: NotchTab
    let position: Int
    @ObservedObject var model: TutorControlBarModel
    let indicatorNamespace: Namespace.ID
    @State private var isHovering = false

    private var isSelected: Bool { model.selectedTab == tab }

    var body: some View {
        Button(action: { model.selectedTab = tab }) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(isSelected ? 0.95 : (isHovering ? 0.82 : 0.62)))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background {
                // One highlight that slides between tabs rather than two
                // that blink on and off.
                if isSelected {
                    Capsule()
                        .fill(DS.Notch.controlSelected)
                        .matchedGeometryEffect(id: "selected tab", in: indicatorNamespace)
                } else if isHovering {
                    Capsule().fill(DS.Notch.quietHover)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(NotchMotion.hover) { isHovering = hovering }
        }
        .accessibilityLabel(title)
        .accessibilityValue("tab, \(position) of 2")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Notebook and Map: they open a window, so they read as buttons, not tabs.
private struct NotchWindowButton: View {
    let title: String
    let systemImage: String
    let accessibilityText: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(isHovering ? 0.9 : 0.72))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(isHovering ? Color.white.opacity(0.08) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(NotchMotion.hover) { isHovering = hovering }
        }
        .accessibilityLabel(accessibilityText)
    }
}

private struct NotchGearButton: View {
    @ObservedObject var model: TutorControlBarModel
    let indicatorNamespace: Namespace.ID
    @State private var isHovering = false

    private var isSelected: Bool { model.selectedTab == .settings }
    private var hasUpdateReady: Bool { model.updateBanner != nil }

    var body: some View {
        Button(action: { model.selectedTab = isSelected ? .lesson : .settings }) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : (isHovering ? 0.85 : 0.65)))
                .frame(width: 30, height: 30)
                .background {
                    if isSelected {
                        Circle().fill(DS.Notch.controlSelected)
                    } else if isHovering {
                        Circle().fill(DS.Notch.quietHover)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if hasUpdateReady {
                        Circle()
                            .fill(DS.Colors.accentText)
                            .frame(width: 6, height: 6)
                            .overlay(Circle().stroke(Color.black, lineWidth: 2))
                            .offset(x: -5, y: 5)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(NotchMotion.hover) { isHovering = hovering }
        }
        .accessibilityLabel(hasUpdateReady ? "Settings, update ready" : "Settings")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The notch's own silhouette: flush with the top edge, with concave
/// shoulders where it meets the screen, the way the camera housing curves
/// into the menu bar, and rounded at the bottom. The rect includes the
/// shoulders, so content sits inset by `shoulderRadius` on each side.
private struct NotchShape: Shape {
    var shoulderRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulderRadius, bottomRadius) }
        set {
            shoulderRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let shoulder = min(shoulderRadius, rect.width / 4, rect.height / 2)
        let bottom = min(bottomRadius, (rect.width - 2 * shoulder) / 2, rect.height - shoulder)
        let bodyLeft = rect.minX + shoulder
        let bodyRight = rect.maxX - shoulder

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: bodyLeft, y: rect.minY + shoulder),
                          control: CGPoint(x: bodyLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: bodyLeft, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: bodyLeft + bottom, y: rect.maxY),
                          control: CGPoint(x: bodyLeft, y: rect.maxY))
        path.addLine(to: CGPoint(x: bodyRight - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: bodyRight, y: rect.maxY - bottom),
                          control: CGPoint(x: bodyRight, y: rect.maxY))
        path.addLine(to: CGPoint(x: bodyRight, y: rect.minY + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: bodyRight, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Chat

private struct TranscriptRow: View {
    let entry: TranscriptEntry
    @State private var isShowingAll = false
    @State private var isHovering = false

    /// Past this, an answer is folded to a few lines so one long lesson does
    /// not push every other turn out of view.
    private static let foldAfterCharacters = 360

    private var isLong: Bool { entry.text.count > Self.foldAfterCharacters }
    private var isFolded: Bool { isLong && !isShowingAll }

    /// Selectable text on macOS draws every line whatever its line limit, so
    /// a folded answer painted its whole length over the turns below it.
    /// Folded, it is plain text clipped to six lines; shown in full, it can
    /// be selected and copied.
    @ViewBuilder
    private var entryText: some View {
        if isFolded {
            Text(entry.text)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
        } else {
            Text(entry.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
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
                    Text(lessonTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Colors.accentText)
                        .lineLimit(1)
                }
                Text(timeText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.Notch.textMinimum)
                    // The model's name left the closed notch; it is here for
                    // anyone who wants to know which brain answered.
                    .nativeTooltip(entry.answeredBy.map { "Answered by \($0)" })
                if isHovering {
                    Button(action: copyThisTurn) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(DS.Notch.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .nativeTooltip("Copy this")
                    .accessibilityLabel("Copy this")
                }
            }

            entryText
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(.white.opacity(isStudent ? 0.95 : 0.86))
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
                        .foregroundStyle(DS.Colors.accentText)
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

/// One offered follow-up under the closed notch: a question to ask next,
/// or something to copy.
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
                Capsule().fill(DS.Colors.accent.opacity(isHovering ? 0.95 : 0.75))
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(NotchMotion.hover) { isHovering = hovering }
        }
        .nativeTooltip(button.question ?? "Copy to clipboard")
        .accessibilityLabel(button.question.map { "Ask: \($0)" } ?? "Copy \(button.title)")
    }
}

/// Typing instead of talking. The answer is the same as for a spoken
/// question, out loud and drawn, and both sides land in the conversation.
/// Return sends; Shift or Option with Return starts a new line.
private struct NotchChatBox: View {
    @ObservedObject var model: TutorControlBarModel
    let placeholder: String
    let onSend: (String) -> Void
    let onDismiss: () -> Void
    let onFocused: () -> Void
    @FocusState private var isFocused: Bool
    @State private var isHoveringSend = false

    private var limit: Int { TutorControlBarModel.chatCharacterLimit }
    private var canSend: Bool {
        !model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// The count only appears near the limit, where it is worth knowing.
    private var showsCharacterCount: Bool { model.chatDraft.count > limit * 4 / 5 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $model.chatDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .tint(.white)
                .lineLimit(1...5)
                .focused($isFocused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        insertLineBreakAtCursor()
                        return .handled
                    }
                    // Return on an empty box explains the error on offer.
                    if !canSend, model.errorOffer != nil {
                        model.onExplainError()
                        return .handled
                    }
                    send()
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                // Command 1 and 2 switch tabs and Command comma opens
                // Settings while the notch has the keyboard; nothing else.
                .onKeyPress(characters: CharacterSet(charactersIn: "12,"), phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    switch press.characters {
                    case "1": model.selectedTab = .lesson
                    case "2": model.selectedTab = .transcript
                    default: model.selectedTab = .settings
                    }
                    return .handled
                }
                .padding(.vertical, 10)
                .accessibilityLabel(placeholder)

            if showsCharacterCount {
                Text("\(model.chatDraft.count) / \(limit)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(model.chatDraft.count >= limit ? DS.Colors.warning : DS.Notch.textMinimum)
                    .padding(.bottom, 11)
            } else if model.chatDraft.isEmpty {
                // The shortcut, once, where typing happens.
                Text("\u{2303}\u{2325}T")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Notch.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                    .padding(.bottom, 9)
                    .accessibilityLabel("Control Option T opens this box from any app")
            }

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(canSend ? (isHoveringSend ? 1 : 0.88) : 0.3))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .pointerCursor(isEnabled: canSend)
            .onHover { hovering in
                withAnimation(NotchMotion.hover) { isHoveringSend = hovering }
            }
            .nativeTooltip("Send  return")
            .accessibilityLabel("Send")
            .padding(.bottom, 6)
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.white.opacity(isFocused ? 0.13 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.white.opacity(isFocused ? 0.28 : 0.1), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        // Pasting a whole file is cut at the limit rather than refused, so
        // what fits is kept and the count says why the rest is missing.
        .onChange(of: model.chatDraft) { _, newDraft in
            if newDraft.count > limit { model.chatDraft = String(newDraft.prefix(limit)) }
        }
        .onChange(of: isFocused) { _, focused in
            TutorDebugLog.write("⌨️ chat box focused=\(focused)")
            if focused { onFocused() }
            model.isChatFocused = focused
        }
        .onChange(of: model.isChatFocused) { _, focused in
            if !focused { isFocused = false }
        }
        .onChange(of: model.wantsChatFocus) { _, wanted in
            if wanted { takeFocus() }
        }
        .onAppear {
            if model.wantsChatFocus { takeFocus() }
        }
    }

    /// Shift + Return is bound to the same command as Return by macOS, so
    /// left alone it would send. The field's editor puts the line break where
    /// the cursor is, which a change to the text from here could not.
    private func insertLineBreakAtCursor() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
            model.chatDraft += "\n"
            return
        }
        editor.insertNewlineIgnoringFieldEditor(nil)
    }

    /// Asked again a few times while the notch finishes opening: SwiftUI
    /// refuses focus for a field that is still being inserted.
    private func takeFocus(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.08)) {
            guard model.wantsChatFocus else { return }
            isFocused = true
            DispatchQueue.main.async {
                if isFocused || attempt >= 8 {
                    TutorDebugLog.write("⌨️ chat box focus attempt \(attempt): \(isFocused)")
                    model.wantsChatFocus = false
                    placeCursorIfAsked()
                } else {
                    takeFocus(attempt: attempt + 1)
                }
            }
        }
    }

    /// Words put in the box for the student to finish ("teach me | from
    /// scratch") get the cursor where the missing word goes. The field's
    /// editor is the window's first responder once it has focus.
    private func placeCursorIfAsked() {
        guard let cursorOffset = model.chatCursorOffset else { return }
        model.chatCursorOffset = nil
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            let location = min(cursorOffset, (editor.string as NSString).length)
            editor.setSelectedRange(NSRange(location: location, length: 0))
        }
    }

    private func send() {
        guard canSend else { return }
        onSend(model.chatDraft)
    }
}

// MARK: - Buttons on black

/// The notch's ordinary button: white 10%, 20% on hover.
struct NotchButton: View {
    let systemImage: String
    let title: String
    /// A key that does the same, shown after the title in quieter text.
    var keyHint: String? = nil
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                if let keyHint {
                    Text(keyHint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Notch.textMinimum)
                        .padding(.leading, 2)
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(isHovering ? DS.Notch.controlHover : DS.Notch.control))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(NotchMotion.hover) { isHovering = hovering }
        }
    }
}

/// The one primary action in a notch block: the accent capsule.
struct NotchPrimaryButton: View {
    let systemImage: String?
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10.5, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(DS.Colors.textOnAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(isHovering ? DS.Colors.accentHover : DS.Colors.accent))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(NotchMotion.hover) { isHovering = hovering }
        }
    }
}

/// Text that acts, on black: secondary until hovered, then primary.
struct NotchQuietTextButton: View {
    let title: String
    var systemImage: String? = nil
    var accessibilityText: String? = nil
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isHovering ? DS.Notch.textPrimary : DS.Notch.textMinimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(NotchMotion.hover) { isHovering = hovering }
        }
        .accessibilityLabel(accessibilityText ?? title)
    }
}
