//
//  NotebookRecorder.swift
//  leanring-buddy
//
//  Keeps each finished lesson as a notebook page.
//
//  A lesson is held, not written, while it is still being spoken: the
//  question, what was said, and a snapshot of the board taken the moment the
//  program has finished running (every card and mark exists by then, before
//  the student can close a card or scroll the marks away). Only when the
//  answer ends without being cancelled is the page written. A question that
//  is cancelled (asked over, Stop) leaves nothing on disk: the held lesson is
//  dropped when the next question starts, and keeping it is only ever asked
//  for by the answer that held it, after checking it was not cancelled. A
//  lesson cleared away while still being spoken (Esc, Clear) stops there and
//  counts as cancelled too.
//
//  Guide steps and how-to replays are not lessons and are never held (the
//  hooks in CompanionManager sit only on the lesson paths). An answer that
//  came back as prose is still a page, with words only.
//
//  The ideas come from learning memory, which files the lesson alongside
//  and usually finishes after the page is written, so they are added to the
//  page when they arrive.
//

import AppKit
import Foundation

@MainActor
final class NotebookRecorder {
    /// The student's switch in the Notebook window. On unless turned off.
    static let keepsLessonsDefaultsKey = "notebookKeepsLessons"
    static var keepsLessons: Bool {
        get { UserDefaults.standard.object(forKey: keepsLessonsDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: keepsLessonsDefaultsKey) }
    }

    /// Ideas that arrive this long after a page are not taken to be its own.
    private static let ideasMatchWindowSeconds: TimeInterval = 15 * 60

    private struct HeldLesson {
        let pageID: UUID
        let askedAt: Date
        let question: String
        let lessonTitle: String?
        let paragraphs: [String]
        let answeredBy: String?
        let screenshotJPEGData: Data?
        let canvasSize: CGSize
        let drawingSnapshotTask: Task<NotebookDrawingSnapshot?, Never>?
    }

    private let drawingOverlay: DrawingOverlay
    let store: NotebookStore
    private let screenCropMaker = NotebookScreenCropMaker()
    private var heldLesson: HeldLesson?
    /// Set when the answer under way was cleared away mid-lesson.
    private var currentAnswerWasDismissed = false
    /// The last lesson's ideas, for a page still being written when they came.
    private var lastFiledIdeas: (question: String, ideas: [NotebookPage.Idea], filedAt: Date)?
    /// The last page written, for ideas that come after it.
    private var lastWrittenPage: (storedPage: NotebookStoredPage, question: String)?

    /// Told after a page is written or changed, for the Notebook window.
    var onNotebookChanged: () -> Void = {}

    init(drawingOverlay: DrawingOverlay) {
        self.drawingOverlay = drawingOverlay
        self.store = NotebookStore(rootFolder: NotebookStore.standardRootFolder)
    }

    // MARK: - Hooks from the answer pipeline

    /// A new question: whatever the last one held is not going to be kept.
    func newQuestionStarted() {
        dropHeldLesson()
        currentAnswerWasDismissed = false
    }

    /// The lesson was cleared away (Esc, Clear) while still being spoken.
    /// It stops there, so it is treated as cancelled: nothing is kept, and a
    /// lesson its own answer holds after this point is refused.
    func answerWasDismissed() {
        dropHeldLesson()
        currentAnswerWasDismissed = true
    }

    private func dropHeldLesson() {
        heldLesson?.drawingSnapshotTask?.cancel()
        heldLesson = nil
    }

    /// Holds a lesson answered as a drawing program. Called once the whole
    /// program has run, so the board holds everything it drew.
    func holdDrawnLesson(question: String, lessonTitle: String?, program: String,
                         screenshotJPEGData: Data, canvasSize: CGSize, answeredBy: String) {
        guard Self.keepsLessons, !Task.isCancelled, !currentAnswerWasDismissed else { return }
        let drawingOverlay = self.drawingOverlay
        let snapshotTask = Task { @MainActor () -> NotebookDrawingSnapshot? in
            guard let script = NotebookDrawingSnapshot.snapshotScript,
                  let json = await drawingOverlay.evaluateInIsolatedWorld(script: script) as? String else { return nil }
            return NotebookDrawingSnapshot.parse(json: json)
        }
        heldLesson = HeldLesson(
            pageID: UUID(), askedAt: Date(), question: question, lessonTitle: lessonTitle,
            paragraphs: NotebookText.paragraphs(inProgram: program), answeredBy: answeredBy,
            screenshotJPEGData: screenshotJPEGData, canvasSize: canvasSize, drawingSnapshotTask: snapshotTask)
    }

    /// Holds a lesson that came back as plain prose: a page of words only.
    func holdTextLesson(question: String, spokenAnswer: String, answeredBy: String) {
        guard Self.keepsLessons, !Task.isCancelled, !currentAnswerWasDismissed else { return }
        let paragraphs = NotebookText.paragraphs(inProse: spokenAnswer)
        guard !paragraphs.isEmpty else { return }
        heldLesson = HeldLesson(
            pageID: UUID(), askedAt: Date(), question: question, lessonTitle: nil, paragraphs: paragraphs,
            answeredBy: answeredBy, screenshotJPEGData: nil, canvasSize: .zero, drawingSnapshotTask: nil)
    }

    /// The answer ended and was not cancelled: the held lesson becomes a page.
    func keepHeldLesson() {
        guard !Task.isCancelled, !currentAnswerWasDismissed, let held = heldLesson else { return }
        heldLesson = nil
        guard Self.keepsLessons else { return }
        Task { await self.writePage(for: held) }
    }

    /// Learning memory filed a lesson under these ideas.
    func lessonWasFiled(_ lesson: LessonToRemember, concepts: [RememberedConcept]) {
        let ideas = concepts.map { concept in
            NotebookPage.Idea(
                name: concept.name,
                summary: concept.summary,
                stabilityDays: concept.stabilityDays,
                // FSRS stability is the time until recall falls to 90%, so
                // that is when looking again does the most good.
                reviewAround: concept.lastExplainedAt.addingTimeInterval(concept.stabilityDays * 86_400)
            )
        }
        guard !ideas.isEmpty else { return }
        lastFiledIdeas = (lesson.question, ideas, Date())
        if let lastWrittenPage, lastWrittenPage.question == lesson.question,
           lastWrittenPage.storedPage.page.ideas.isEmpty,
           Date().timeIntervalSince(lastWrittenPage.storedPage.page.createdAt) < Self.ideasMatchWindowSeconds {
            addIdeas(ideas, to: lastWrittenPage.storedPage)
        }
    }

    // MARK: - Writing

    private func writePage(for held: HeldLesson) async {
        let snapshot = await held.drawingSnapshotTask?.value
        var cards: [NotebookPage.Card] = []
        var cardSVGTexts: [String] = []
        for (cardIndex, card) in (snapshot?.cards ?? []).enumerated() {
            cards.append(NotebookPage.Card(fileName: "card-\(cardIndex + 1).svg", widthInPixels: card.widthInPixels,
                                           heightInPixels: card.heightInPixels, title: card.title))
            cardSVGTexts.append(card.svgText)
        }
        var screenCrop: NotebookScreenCropMaker.Crop?
        if let screenMarks = snapshot?.screenMarks, let screenshotJPEGData = held.screenshotJPEGData {
            screenCrop = await screenCropMaker.makeCrop(
                screenshotJPEGData: screenshotJPEGData, canvasSize: held.canvasSize, screenMarks: screenMarks)
        }

        var ideas: [NotebookPage.Idea] = []
        if let lastFiledIdeas, lastFiledIdeas.question == held.question,
           lastFiledIdeas.filedAt >= held.askedAt.addingTimeInterval(-Self.ideasMatchWindowSeconds) {
            ideas = lastFiledIdeas.ideas
        }

        let page = NotebookPage(
            id: held.pageID, createdAt: held.askedAt, lessonTitle: held.lessonTitle, question: held.question,
            paragraphs: held.paragraphs, cards: cards,
            screenCrop: screenCrop.map {
                NotebookPage.ScreenCrop(fileName: "screen.jpg", widthInPixels: $0.widthInPixels, heightInPixels: $0.heightInPixels)
            },
            ideas: ideas, answeredBy: held.answeredBy)
        do {
            let storedPage = try await store.write(page: page, cardSVGTexts: cardSVGTexts,
                                                   screenCropJPEGData: screenCrop?.jpegData)
            TutorDebugLog.write("📓 notebook: kept \"\(page.displayTitle)\", \(cards.count) card(s), \(screenCrop == nil ? "no" : "a") screen crop, \(storedPage.sizeInBytes / 1024) KB")
            lastWrittenPage = (storedPage, held.question)
            onNotebookChanged()
            // Filed while the page was being written.
            if ideas.isEmpty, let lastFiledIdeas, lastFiledIdeas.question == held.question {
                addIdeas(lastFiledIdeas.ideas, to: storedPage)
            }
        } catch {
            TutorDebugLog.write("⚠️ notebook: page not kept: \(error.localizedDescription)")
        }
    }

    private func addIdeas(_ ideas: [NotebookPage.Idea], to storedPage: NotebookStoredPage) {
        var updatedPage = storedPage.page
        updatedPage.ideas = ideas
        lastWrittenPage = (NotebookStoredPage(page: updatedPage, folder: storedPage.folder,
                                              sizeInBytes: storedPage.sizeInBytes, dayIdentifier: storedPage.dayIdentifier),
                           storedPage.page.question)
        Task {
            await store.updateIdeas(ideas, ofPageIn: storedPage.folder)
            onNotebookChanged()
        }
    }
}

// Notebook hook: everything CompanionManager has to connect, in one call
// from its start().
extension CompanionManager {
    func connectNotebook(recorder: NotebookRecorder) {
        learningMemory.onLessonFiled = { [weak recorder] lesson, concepts in
            recorder?.lessonWasFiled(lesson, concepts: concepts)
        }
        let notebookWindow = NotebookWindowController.shared
        notebookWindow.store = recorder.store
        recorder.onNotebookChanged = { [weak notebookWindow] in notebookWindow?.notebookDidChange() }
        // The open notch and an old lesson's cards sit above every window,
        // so both are put away before the Notebook window opens under them.
        notebookWindow.beforeOpening = { [weak self] in
            self?.clearAnnotations()
            self?.closeNotchForSetup()
        }
        NotebookExportNotifier.shared.connect(openNotch: { [weak self] in self?.openNotchBriefly(on: .lesson) })
    }
}
