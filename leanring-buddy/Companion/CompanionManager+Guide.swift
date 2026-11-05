//
//  CompanionManager+Guide.swift
//  leanring-buddy
//
//  Guide mode's steps and the replay of kept how-tos.
//

import AppKit
import Foundation

extension CompanionManager {
    var howToCount: Int { howToMemory.count }

    func stopGuide(reason: String) {
        if reason != "task finished" { howToMemory.abandonRecording() }
        currentReplay = nil
        guard currentGuideStep != nil || guideWatcher.isWatching else { return }
        TutorDebugLog.write("🧭 guide stopped: \(reason)")
        guideWatcher.stop()
        currentGuideStep = nil
        guideStepsGiven = 0
        guideBaseline = nil
        guidedApplication = nil
        guideChangedRegion = nil
        controlBar.model.guideInstruction = nil
    }

    /// The student did something and the screen changed: look again, as if
    /// they had asked what next.
    func continueGuide(changedRegion: CGRect) {
        guard let step = currentGuideStep else { return }
        guideChangedRegion = changedRegion
        if let replay = currentReplay {
            continueReplay(replay, after: step)
            return
        }
        TutorDebugLog.write("🧭 guide: step \(guideStepsGiven) looks done, looking again")
        shortcutReleasedAt = nil
        sendTranscriptToTutorWithScreenshot(transcript: GuideMode.continuationQuestion(after: step), guideStep: step)
    }
    // MARK: Replaying how-tos

    /// Looks at the screen, finds the step's control by its label, and says
    /// and draws the saved step: no model. False when the control is not
    /// there, so the caller can hand over to the model.
    func replayHowToStep(_ howTo: HowTo, stepIndex: Int, question: String, startedBy originalQuestion: String,
                                 application: NSRunningApplication?) async -> Bool {
        guard stepIndex < howTo.steps.count else { return false }
        let step = howTo.steps[stepIndex]
        voiceState = .processing
        controlBar.model.waitingStage = "reading your screen"
        guard let screen = await captureScreenForReplay(), !Task.isCancelled else {
            voiceState = .idle
            return false
        }
        var targetIdentifier: String?
        if let label = step.targetLabel {
            guard let found = HowToMatching.targetIdentifier(forLabel: label, in: screen.labels) else {
                TutorDebugLog.write("📒 replay: \"\(label)\" is not on screen")
                voiceState = .idle
                return false
            }
            targetIdentifier = found
        }
        TutorDebugLog.write("📒 replaying \"\(howTo.title)\" step \(stepIndex + 1) of \(howTo.steps.count), no model")
        logStage("replay ready")

        let program = HowToMemory.program(for: step, targetIdentifier: targetIdentifier)
        clearAnnotations()
        if let screenForDrawing = screen.screen {
            lessonPlayer.begin(on: screenForDrawing, canvasSize: screen.canvasSize, targets: screen.boxes,
                               targetLabels: screen.labels, screenInkHex: "#3380FF",
                               screenThumbnail: GuideWatcher.thumbnail(fromImageData: screen.capture.imageData))
            followMarks(displayFrame: screen.capture.displayFrame, canvasSize: screen.canvasSize,
                        targets: screen.boxes, labels: screen.labels)
        }
        currentAnswerFormat = .program
        controlBar.model.answeredBy = "from memory"
        voiceState = .responding
        lessonPlayer.feed(accumulatedText: program)
        await lessonPlayer.finish(fullText: program)
        // Replaced while it played: the step is not kept or watched. True,
        // so the caller does not hand a cancelled step to the model either.
        guard !Task.isCancelled else { return true }
        conversation.remember(question: question, answer: program)

        let isLastStep = stepIndex + 1 >= howTo.steps.count || step.instruction == nil
        if isLastStep {
            howToMemory.noteReplayed(howTo, askedAs: originalQuestion)
            controlBar.model.recordLessonTitle(howTo.title)
            stopGuide(reason: "task finished")
        } else if let instruction = step.instruction {
            currentReplay = (howTo, stepIndex + 1, originalQuestion)
            currentGuideStep = GuideStep(instruction: instruction, doneWhen: step.doneWhen ?? "")
            guideStepsGiven = stepIndex + 1
            guideBaseline = (screen.capture.imageData, screen.capture.displayFrame)
            guidedApplication = application
            controlBar.model.guideInstruction = instruction
        }

        // As after a model's answer: the status holds until the voice ends,
        // then the watcher waits for the student.
        while proseSpeech.isSpeaking || isAnyVoicePlaying {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { break }
        }
        voiceState = .idle
        await lessonPlayer.waitUntilSpoken()
        talkOverListener.stop()
        controlBar.model.caption = ""
        if !isLastStep, !Task.isCancelled, let currentGuideStep, let guideBaseline {
            guideWatcher.watch(step: currentGuideStep, baselineScreenshot: guideBaseline.imageData,
                               displayFrame: guideBaseline.displayFrame, guidedApplication: guidedApplication)
        }
        return true
    }

    /// The student did a replayed step. The next saved step is replayed if
    /// its control is now on screen; if not, something differs from last
    /// time, so the model looks and carries on, and the walkthrough it gives
    /// replaces the saved one.
    private func continueReplay(_ replay: (howTo: HowTo, nextStepIndex: Int, question: String), after step: GuideStep) {
        shortcutReleasedAt = nil
        answerStartedAt = Date()
        SpendingMeter.shared.countQuestion(isGuideStep: true)
        cancelCurrentResponseTask()
        cancelSpeechAndClearQueue()
        let question = GuideMode.continuationQuestion(after: step)
        let application = guidedApplication
        currentResponseTask = Task { [weak self] in
            guard let self else { return }
            let replayed = await self.replayHowToStep(replay.howTo, stepIndex: replay.nextStepIndex, question: question,
                                                      startedBy: replay.question, application: application)
            guard !replayed, !Task.isCancelled else { return }
            self.howToMemory.noteReplayFailed(replay.howTo)
            self.howToMemory.startRecording(question: replay.question, application: application,
                                            seededWith: Array(replay.howTo.steps.prefix(replay.nextStepIndex)),
                                            replacing: replay.howTo.id)
            self.currentReplay = nil
            self.sendTranscriptToTutorWithScreenshot(transcript: question, guideStep: step,
                                                     howToTakeover: (replay.howTo, replay.nextStepIndex))
        }
    }

    /// The screen under the cursor, captured and read, for a replay.
    private func captureScreenForReplay() async -> (capture: CompanionScreenCapture, canvasSize: CGSize,
                                                    boxes: [String: [Double]], labels: [String: String],
                                                    screen: NSScreen?)? {
        guard let captures = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(), !captures.isEmpty else {
            return nil
        }
        let primary = captures.first(where: { $0.isCursorScreen }) ?? captures[0]
        displayFrameForCurrentAnswer = primary.displayFrame
        let displaySize = CGSize(width: primary.displayWidthInPoints, height: primary.displayHeightInPoints)
        await screenIndex.rebuild(fromScreenshot: primary.imageData, displayIndex: 0, displayBoundsInPoints: displaySize)
        let canvasSize = CGSize(width: primary.screenshotWidthInPixels, height: primary.screenshotHeightInPixels)
        let (_, boxes) = screenIndex.listingWithBoxes(canvasSize: canvasSize, displaySizeInPoints: displaySize)
        let screen = NSScreen.screens.first { $0.frame == primary.displayFrame } ?? NSScreen.main
        return (primary, canvasSize, boxes, screenIndex.lastListedLabels, screen)
    }
}
