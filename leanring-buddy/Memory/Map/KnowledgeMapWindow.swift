//
//  KnowledgeMapWindow.swift
//  leanring-buddy
//
//  The window the map of what the student knows lives in, opened from the
//  notch and from Settings. A real window, like setup, because searching
//  needs the keyboard and the notch never takes it.
//
//  It keeps the map in step with memory (a lesson filed while it is open
//  grows in as a new idea), runs the one-time relation pass for older stores
//  on its first opening, and hands Quick recap to the normal answer flow:
//  the window steps aside first, and the app being studied gets the
//  keyboard back, so the answer is spoken and drawn where the student was.
//

import AppKit
import SwiftUI

@MainActor
final class KnowledgeMapWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = KnowledgeMapModel()
    private let learningMemory: LearningMemory
    private let askQuestion: (String) -> Void
    private let relationPassReply: (String) async -> String?

    private var memoryObserver: NSObjectProtocol?
    private var scrollMonitor: Any?
    private var layoutTask: Task<Void, Never>?
    private var isRunningRelationPass = false
    /// The app the student was in when the map opened, given the keyboard
    /// back when the map steps aside for an answer.
    private var appToReturnTo: NSRunningApplication?

    /// Ideas the student has already seen on the map, so the ones learned
    /// since grow in when it next opens, even across relaunches.
    private static let seenConceptIDsDefaultsKey = "knowledgeMapSeenConceptIDs"

    /// Teach it back: the words go in the notch's chat box for now.
    var onTeachBack: (RememberedConcept) -> Void = { _ in }
    /// Opens the Notebook on a lesson, by its title.
    var onOpenLesson: (String) -> Void = { _ in }
    private var keyMonitor: Any?

    init(learningMemory: LearningMemory,
         askQuestion: @escaping (String) -> Void,
         relationPassReply: @escaping (String) async -> String?) {
        self.learningMemory = learningMemory
        self.askQuestion = askQuestion
        self.relationPassReply = relationPassReply
        super.init()
        model.onReteach = { [weak self] concept in self?.quickRecap(concept) }
        model.onForget = { [weak self] concept in self?.forget(concept) }
        model.onTeachBack = { [weak self] concept in
            self?.stepAside()
            self?.onTeachBack(concept)
        }
        model.onOpenLesson = { [weak self] lessonTitle in self?.onOpenLesson(lessonTitle) }
        model.onTurnOnMemory = { [weak self] in
            UserDefaults.standard.set(true, forKey: LearningMemory.enabledDefaultsKey)
            self?.reloadMap(animated: false)
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Opens on an idea when one is named, as a lesson's Builds on chip does.
    func show(focusingIdeaNamed ideaName: String?) {
        show()
        guard let ideaName else { return }
        model.focusWhenLaidOut(onIdeaNamed: ideaName)
    }

    /// The map's window closed, for the QA channel's scripts.
    func close() {
        window?.orderOut(nil)
    }

    func show() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            appToReturnTo = frontmost
        }
        let window = self.window ?? makeWindow()
        let isFirstShowing = self.window == nil
        self.window = window
        startObserving()
        reloadMap(animated: !isFirstShowing)
        // A menu bar app is never the active app on its own; it has to ask,
        // or the window opens behind everything and cannot take typing.
        NSApp.activate()
        if isFirstShowing { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        runRelationPassIfNeeded()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Map of what you know"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 560)
        window.setFrameAutosaveName("BuddyKnowledgeMap")
        window.delegate = self
        // Dark chrome around a paper canvas, whatever the system appearance.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(DS.Colors.background)
        let hostingView = NSHostingView(rootView: KnowledgeMapView(model: model))
        // The window sets the size (with its own minimum), never the content:
        // measured at zero width, wrapped text asks for a towering window.
        hostingView.sizingOptions = []
        window.contentView = hostingView
        return window
    }

    // MARK: Keeping the map in step with memory

    private func startObserving() {
        if memoryObserver == nil {
            memoryObserver = NotificationCenter.default.addObserver(
                forName: LearningMemory.didChangeNotification, object: learningMemory, queue: .main
            ) { [weak self] _ in
                // Posted on the main actor and delivered on the main queue.
                MainActor.assumeIsolated {
                    guard let self, self.isVisible else { return }
                    self.reloadMap(animated: true)
                }
            }
        }
        if scrollMonitor == nil {
            // Two-finger scrolling pans the map, and a mouse wheel or
            // Command-scroll zooms it. SwiftUI has no scroll-wheel gesture on
            // macOS, so the window's own scroll events are read here.
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Local monitors are called on the main thread.
                MainActor.assumeIsolated { self?.handleScroll(event) ?? event }
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.handleKey(event) ?? event }
            }
        }
    }

    /// Arrow keys move the selection along the links, Return gives a quick
    /// recap and Delete asks to forget, while nothing is being typed.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, !(window.firstResponder is NSTextView),
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
        switch event.keyCode {
        case 123: model.selectLinkedIdea(towards: CGVector(dx: -1, dy: 0))
        case 124: model.selectLinkedIdea(towards: CGVector(dx: 1, dy: 0))
        case 125: model.selectLinkedIdea(towards: CGVector(dx: 0, dy: 1))
        case 126: model.selectLinkedIdea(towards: CGVector(dx: 0, dy: -1))
        case 36, 76:
            guard let concept = model.selectedNode?.concept else { return event }
            quickRecap(concept)
        case 51, 117:
            guard model.selectedNode != nil else { return event }
            NotificationCenter.default.post(name: KnowledgeMapModel.forgetRequestedNotification, object: model)
        default:
            return event
        }
        return nil
    }

    /// Returns nil when the map used the event, the event otherwise.
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, let contentView = window.contentView else { return event }
        let pointInContent = contentView.convert(event.locationInWindow, from: nil)
        let fromTop = contentView.isFlipped ? pointInContent.y : contentView.bounds.height - pointInContent.y
        // The map sits under the header, and its coordinates start at its
        // own top-left corner.
        let headerHeight = contentView.bounds.height - model.viewSize.height
        let pointInMap = CGPoint(x: pointInContent.x, y: fromTop - headerHeight)
        guard pointInMap.y >= 0, !model.layout.nodes.isEmpty else { return event }
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            model.pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        } else {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 120 : event.scrollingDeltaY / 8
            model.zoom(by: pow(1.25, delta), around: pointInMap)
        }
        return nil
    }

    private func stopObserving() {
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        memoryObserver = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Lays the map out off the main actor (300 ideas take a moment in a
    /// debug build) and shows it, new ideas growing in.
    private func reloadMap(animated: Bool) {
        model.isMemoryEnabled = learningMemory.isEnabled
        let concepts = learningMemory.index.concepts
        let now = Date()
        let seenIDs = Set((UserDefaults.standard.stringArray(forKey: Self.seenConceptIDsDefaultsKey) ?? [])
            .compactMap(UUID.init(uuidString:)))
        // The very first opening shows the map as it is; growing every idea
        // in at once would only be noise.
        let appearingIDs = seenIDs.isEmpty ? [] : Set(concepts.map(\.id)).subtracting(seenIDs)
        layoutTask?.cancel()
        layoutTask = Task { [weak self] in
            let layout = await Task.detached(priority: .userInitiated) {
                KnowledgeMapLayout.make(concepts: concepts, now: now)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.model.apply(layout, appearingIDs: appearingIDs, animated: animated || !appearingIDs.isEmpty)
            UserDefaults.standard.set(concepts.map(\.id.uuidString), forKey: Self.seenConceptIDsDefaultsKey)
        }
    }

    private func runRelationPassIfNeeded() {
        guard !isRunningRelationPass, !KnowledgeMapRelationPass.hasFinished(),
              learningMemory.index.concepts.contains(where: { $0.relations == nil }) else { return }
        isRunningRelationPass = true
        model.isFindingRelations = true
        Task { [weak self, learningMemory, relationPassReply] in
            await KnowledgeMapRelationPass.runIfNeeded(memory: learningMemory, ask: relationPassReply)
            self?.isRunningRelationPass = false
            self?.model.isFindingRelations = false
        }
    }

    // MARK: Actions from the map

    /// Quick recap: asks for the idea again through the normal answer flow,
    /// worded as a fresh request about a named idea, short. "Again",
    /// "simpler" or "another way" would read as the student not following
    /// the last lesson, which marks that lesson's ideas as lost.
    private func quickRecap(_ concept: RememberedConcept) {
        let question: String
        if let angle = concept.lastAngle, !angle.isEmpty {
            question = "give me a quick recap of \(concept.name) in about thirty seconds, with a different example from last time's \(angle)"
        } else {
            question = "give me a quick recap of \(concept.name) in about thirty seconds"
        }
        TutorDebugLog.write("🗺️ map: quick recap of \(concept.name)")
        stepAside()
        // A moment for the window to leave the screen and the studied app to
        // come forward before the screen is captured for the answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [askQuestion] in
            askQuestion(question)
        }
    }

    /// Out of the way of the answer, which is drawn over the app being
    /// studied. Opening the map again brings it back as it was.
    private func stepAside() {
        window?.orderOut(nil)
        model.hoveredID = nil
        appToReturnTo?.activate()
    }

    private func forget(_ concept: RememberedConcept) {
        model.selectedID = nil
        learningMemory.forgetConcept(id: concept.id)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopObserving()
        model.selectedID = nil
        model.searchText = ""
        appToReturnTo?.activate()
    }
}

extension ClaudeVisionProvider {
    private static let conceptRelationsPrompt: String? = Bundle.main
        .url(forResource: "ConceptRelationsPrompt", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// One batch of the map's one-time relation pass (KnowledgeMapRelations.swift):
    /// names and summaries only. About $0.004 for 20 ideas.
    func conceptRelationPassReply(message: String) async -> String? {
        guard let systemPrompt = Self.conceptRelationsPrompt else { return nil }
        return await quickHaikuReply(system: systemPrompt, message: message, maximumTokens: 1_500, timeout: 30)
    }
}
