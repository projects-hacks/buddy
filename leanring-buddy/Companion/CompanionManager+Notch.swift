//
//  CompanionManager+Notch.swift
//  leanring-buddy
//
//  What the notch, the Map and the Notebook ask of Buddy, and the
//  updater's banner.
//

import AppKit
import Combine
import Foundation

extension CompanionManager {
    func closeNotchForSetup() { controlBar.putAway() }

    /// Opened from the notch, Settings and a lesson's Builds on chip, on that
    /// idea when one is named. The open notch sits above every window, so it
    /// is put away first.
    func openKnowledgeMap(focusingIdeaNamed ideaName: String? = nil) {
        controlBar.putAway()
        knowledgeMapWindow.show(focusingIdeaNamed: ideaName)
    }

    /// The Map's Teach it back: the words go in the chat box for the
    /// student to send, and TeachBackIntent starts teach-back from them.
    func putTeachBackInChatBox(ideaName: String) {
        controlBar.openChat(withDraft: "let me explain \(ideaName) to you")
    }

    /// What a Notebook page's buttons do. Notebook hook.
    func connectNotebookWindowButtons() {
        let notebookModel = NotebookWindowController.shared.model
        // Only the last lesson can be drawn again: its voice and drawing are
        // kept in memory; older pages are kept as words and pictures only.
        notebookModel.canReplay = { [weak self, weak notebookModel] storedPage in
            guard let self, let notebookModel else { return false }
            return self.controlBar.model.canReplayLastAnswer && storedPage.id == notebookModel.newestPage?.id
        }
        notebookModel.onReplay = { [weak self] _ in
            guard let self else { return }
            // The window steps aside while the lesson plays on the real
            // screen, and comes back once it has been said.
            NotebookWindowController.shared.stepAsideForReplay()
            guard self.replayLastAnswer(startedBy: "Replay in the Notebook") else { return }
            let replayTask = self.currentResponseTask
            Task { @MainActor in
                await replayTask?.value
                NotebookWindowController.shared.show()
            }
        }
        notebookModel.onTeachBack = { [weak self] storedPage in
            // Inside a sentence, so the name as the model wrote it, not as a title.
            let topic = storedPage.page.lessonTitle ?? storedPage.page.displayTitle
            self?.controlBar.openChat(withDraft: "let me explain \(topic) back to you")
        }
        notebookModel.onAskFollowUp = { [weak self] storedPage in
            self?.controlBar.openChat(withDraft: "About \u{201C}\(storedPage.page.displayTitle)\u{201D}: ")
        }
        notebookModel.onOpenIdea = { [weak self] ideaName in self?.openKnowledgeMap(focusingIdeaNamed: ideaName) }
        notebookModel.onShowTranscripts = { [weak self] in self?.openTranscriptsFolder() }
    }

    /// The empty day's start tiles, from memory and the Notebook, read each
    /// time the notch opens so they are never stale.
    func refreshNotchHomeSuggestions() {
        let model = controlBar.model
        model.isKeepingLessonsInNotebook = NotebookRecorder.keepsLessons
        guard model.transcript.isEmpty else { return }
        if let fadingConcept = learningMemory.ideaFadingMost() {
            let lastExplainedAt = fadingConcept.lastExplainedAt
            let isWithinTheWeek = Date().timeIntervalSince(lastExplainedAt) < 6 * 86_400
            let learnedDay = Calendar.current.isDateInYesterday(lastExplainedAt) ? "yesterday"
                : (isWithinTheWeek ? lastExplainedAt.formatted(.dateTime.weekday(.wide))
                                   : "on " + lastExplainedAt.formatted(.dateTime.day().month(.wide)))
            model.homeSuggestions.fadingIdea = .init(name: fadingConcept.name,
                                                     learnedText: "Learned \(learnedDay), fading")
        } else {
            model.homeSuggestions.fadingIdea = nil
        }
        Task { @MainActor in
            let days = await NotebookWindowController.shared.store.loadDays()
            let earlierDay = days.first { !Calendar.current.isDateInToday($0.date) && !$0.pages.isEmpty }
            guard let earlierDay else {
                model.homeSuggestions.lastStudyDay = nil
                return
            }
            let title = Calendar.current.isDateInYesterday(earlierDay.date)
                ? "Yesterday's lessons"
                : "\(earlierDay.date.formatted(.dateTime.weekday(.wide)))'s lessons"
            // Pages are kept newest last within a day; the day reads from its first.
            let firstPage = earlierDay.pages.min { $0.page.createdAt < $1.page.createdAt }
            model.homeSuggestions.lastStudyDay = .init(
                dayIdentifier: earlierDay.id, title: title, pageCount: earlierDay.pages.count,
                firstLessonTitle: firstPage?.page.displayTitle ?? "your first lesson")
        }
    }

    /// Opens the folder holding each day's saved transcript, from the
    /// Notebook's More menu.
    func openTranscriptsFolder() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(AppIdentity.dataName)/Transcripts")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// What only the student can fix, for the notch's needs-you state and
    /// its alert row: a missing permission, and an expired Google Cloud
    /// sign-in. The notch is never pinned open for these any more (the
    /// setup window walks through permissions, and a pinned notch could be
    /// trapped open after "Skip for now"); it says so closed, in amber, and
    /// Allow opens setup on the step. Runs every permission poll, and clears
    /// itself once fixed.
    func updateNotchNeeds() {
        let model = controlBar.model
        let missingPermission: NotchMissingPermission?
        if !hasScreenRecordingPermission {
            missingPermission = .screenRecording
        } else if !hasMicrophonePermission {
            missingPermission = .microphone
        } else if !hasAccessibilityPermission {
            missingPermission = .accessibility
        } else if !hasScreenContentPermission {
            missingPermission = .screenContent
        } else {
            missingPermission = nil
        }
        // While the setup window is up it is the one asking.
        let shownPermission = setupWindow.isVisible ? nil : missingPermission
        if model.missingPermission != shownPermission { model.missingPermission = shownPermission }

        let signInExpired = !isLocalModelReachable && usesVertexForArgon && brainKind == .hosted
        let signInMessage = signInExpired ? "Your Google Cloud sign-in expired. Sign in again in Terminal." : nil
        if model.signInProblemMessage != signInMessage { model.signInProblemMessage = signInMessage }
    }

    /// Opens the notch on a tab for a few seconds, then lets the mouse decide.
    /// For the Dock icon, which has no window of its own to show.
    func openNotchBriefly(on tab: NotchTab) {
        let model = controlBar.model
        model.selectedTab = tab
        model.isPinnedOpen = true
        model.isExpanded = true
        briefOpenTask?.cancel()
        briefOpenTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            model.isPinnedOpen = false
            model.isExpanded = false
        }
    }

    /// Forgets the learning memory and the hint steps together, as Settings
    /// promises.
    func forgetLearningMemory() {
        learningMemory.forgetEverything()
        practiceHintLadder.forgetAll()
        howToMemory.forgetAll()
    }

    /// An available update shows in the open notch, with its progress, until
    /// installed; a failure keeps the banner with what went wrong.
    func bindUpdater() {
        let model = controlBar.model
        model.onInstallUpdate = { [weak self] in Task { await self?.appUpdater.installAvailableUpdate() } }
        model.onShowReleaseNotes = { [weak self] in
            if let page = self?.appUpdater.availableRelease?.pageURL { NSWorkspace.shared.open(page) }
        }
        updaterStateCancellable = appUpdater.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let version = self.appUpdater.availableRelease?.version ?? ""
                switch state {
                case .available: model.updateBanner = .init(text: "Buddy \(version) is ready. Updating restarts Buddy.", isWorking: false, canInstall: true)
                case .downloading: model.updateBanner = .init(text: "Downloading Buddy \(version)...", isWorking: true, canInstall: false)
                case .installing: model.updateBanner = .init(text: "Checking and installing Buddy \(version)...", isWorking: true, canInstall: false)
                case .failed(let message) where self.appUpdater.availableRelease != nil:
                    model.updateBanner = .init(text: message, isWorking: false, canInstall: true)
                default: model.updateBanner = nil
                }
            }
        appUpdater.startAutomaticChecks()
    }
}
