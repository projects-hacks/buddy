//
//  GuideCoordinator.swift
//  leanring-buddy
//
//  The state of a task being guided one step at a time: the step waiting
//  to be done, how many have been given, the screen it was given against,
//  the app it is in, the watcher that notices it done, and a kept how-to
//  being replayed. What a step says and draws is answered by the manager's
//  question path or its replay; this only keeps track and watches.
//

import AppKit
import Foundation

@MainActor
final class GuideCoordinator {
    private(set) var currentStep: GuideStep?
    private(set) var stepsGiven = 0
    /// The screen the current step was given against, for the watcher.
    private(set) var baseline: (imageData: Data, displayFrame: CGRect)?
    /// The app the guide started in, kept for the whole task.
    private(set) var guidedApplication: NSRunningApplication?
    /// Where the screen changed when the last step looked done.
    var changedRegion: CGRect?

    /// A saved how-to being replayed: which step comes next, and the
    /// question that started it.
    var currentReplay: (howTo: HowTo, nextStepIndex: Int, question: String)?

    /// The student did something and the screen changed after a step.
    var onStepLooksDone: (_ changedRegion: CGRect) -> Void = { _ in }
    /// The notch's line for the step waiting, or nil once there is none.
    var onInstructionChanged: (_ instruction: String?) -> Void = { _ in }

    lazy var watcher: GuideWatcher = {
        let watcher = GuideWatcher()
        watcher.onStepLooksDone = { [weak self] changedRegion in self?.onStepLooksDone(changedRegion) }
        return watcher
    }()

    // How-tos (HowToMemory.swift): finished guides, replayed with no model.
    lazy var howToMemory: HowToMemory = {
        let memory = HowToMemory()
        memory.writeCues = { [weak self] howTo in await self?.writeHowToCues(howTo) }
        return memory
    }()
    private let writeHowToCues: (_ howTo: HowTo) async -> (title: String, phrasings: [String])?

    init(writeHowToCues: @escaping (_ howTo: HowTo) async -> (title: String, phrasings: [String])?) {
        self.writeHowToCues = writeHowToCues
    }

    /// A step is waiting, being watched for, or a how-to is being replayed.
    var isGuiding: Bool { currentStep != nil || watcher.isWatching || currentReplay != nil }

    /// Whether another step may be given; past the cap the guide ends.
    var hasRoomForAnotherStep: Bool { stepsGiven < GuideMode.maximumSteps }

    func stop(reason: String) {
        if reason != "task finished" { howToMemory.abandonRecording() }
        currentReplay = nil
        guard currentStep != nil || watcher.isWatching else { return }
        TutorDebugLog.write("🧭 guide stopped: \(reason)")
        watcher.stop()
        currentStep = nil
        stepsGiven = 0
        baseline = nil
        guidedApplication = nil
        changedRegion = nil
        onInstructionChanged(nil)
    }

    /// The model's answer ended with a step to wait for.
    func takeStep(_ step: GuideStep, baseline stepBaseline: (imageData: Data, displayFrame: CGRect)?,
                  applicationInFront: NSRunningApplication?) {
        currentStep = step
        stepsGiven += 1
        baseline = stepBaseline
        if guidedApplication == nil, applicationInFront?.bundleIdentifier != Bundle.main.bundleIdentifier {
            guidedApplication = applicationInFront
        }
        onInstructionChanged(step.instruction)
        TutorDebugLog.write("🧭 guide: step \(stepsGiven) is \(step.instruction)")
    }

    /// A saved how-to's step was replayed and the next one waits.
    func takeReplayedStep(_ step: GuideStep, replay: (howTo: HowTo, nextStepIndex: Int, question: String),
                          baseline stepBaseline: (imageData: Data, displayFrame: CGRect),
                          application: NSRunningApplication?) {
        currentReplay = replay
        currentStep = step
        stepsGiven = replay.nextStepIndex
        baseline = stepBaseline
        guidedApplication = application
        onInstructionChanged(step.instruction)
    }

    /// Watches for the waiting step to be done, when there is one.
    func watchCurrentStep() {
        guard let currentStep, let baseline else { return }
        watcher.watch(step: currentStep, baselineScreenshot: baseline.imageData,
                      displayFrame: baseline.displayFrame, guidedApplication: guidedApplication)
    }
}
