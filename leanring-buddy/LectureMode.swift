//
//  LectureMode.swift
//  leanring-buddy
//
//  Lecture mode: when the student asks about a video lecture ("what did he
//  mean by that?"), the tutor is told what the lecturer just said, not only
//  what is on screen. There is no switch for it; it applies whenever the
//  app in front is playing or showing a lecture, and adds nothing otherwise.
//
//  Transcript first, the way YouTube and Chrome answer questions about a video:
//  the playback time is read from the player, and the lines from the
//  minute before it are taken from a transcript, in this order:
//    1. YouTube's caption track for the video, when YouTube serves it
//       (YouTubeCaptions.swift says why it often does not).
//    2. A transcript panel in the page, read through the accessibility
//       tree: YouTube's "Show transcript", Coursera's interactive
//       transcript, and any other page that puts a time before each line.
//    3. The same panel as recognised on the screenshot.
//  No audio, no permission, no cost.
//
//  The sound as a fallback, the way Snipd keeps a rolling buffer and
//  transcribes only on demand: when no transcript can be placed, the last
//  90 seconds of the front app's own sound (LectureAudioBuffer.swift) are
//  transcribed by Deepgram, or on the Mac without a Deepgram key.
//
//  Calls, meetings and music are never heard (LectureCaptureExclusions).
//  During an advert, nothing is added: the time on screen is the advert's.
//

import AppKit
import Foundation

@MainActor
final class LectureMode {
    static let shared = LectureMode()

    /// The longest lecture mode can hold up an answer, counted from the
    /// question. Capture and memory already take most of this, so the
    /// student waits longer only when the sound has to be transcribed.
    static let longestWaitAfterQuestionSeconds: TimeInterval = 3.0
    /// A watch page usually arrives in under a second.
    private static let longestYouTubeWaitSeconds: TimeInterval = 1.5

    private let audioBuffer = LectureAudioBuffer()
    private let youTubeTranscriptCache = YouTubeTranscriptCache()

    /// Everything gathered while the screen is captured.
    struct Gathering {
        let applicationName: String
        let reading: LecturePageReading
        let exclusionReason: String?
        let youTubeOutcome: YouTubeTranscriptOutcome?
        let heardWordsTask: Task<LectureHeardWords?, Never>?
        let frontApplicationPlayedSoundRecently: Bool
    }

    /// Called once at launch: starts watching which app is in front and
    /// whether it is playing sound.
    func startWatching() {
        audioBuffer.startWatching()
    }

    /// Starts gathering the moment a question arrives, so the page is read,
    /// the transcript fetched and the sound transcribed while the screen is
    /// captured and read.
    func beginGathering(question: String) -> Task<Gathering?, Never> {
        Task { @MainActor in
            guard let front = NSWorkspace.shared.frontmostApplication,
                  front.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
            // Taken first: the buffer keeps filling while the question is answered.
            let audioSnapshot = audioBuffer.snapshotForQuestion()
            let playedSoundRecently = audioBuffer.frontApplicationPlayedSound(withinSeconds: 120)
            let applicationName = front.localizedName ?? "the app"

            let processIdentifier = front.processIdentifier
            let bundleIdentifier = front.bundleIdentifier
            let reading = await Task.detached(priority: .userInitiated) {
                LecturePageReader.readFrontWindow(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier)
            }.value

            if let exclusionReason = LectureCaptureExclusions.reasonToExclude(
                bundleIdentifier: bundleIdentifier, applicationName: applicationName,
                windowTitle: reading.windowTitle, pageURL: reading.pageURL) {
                return Gathering(applicationName: applicationName, reading: reading, exclusionReason: exclusionReason,
                                 youTubeOutcome: nil, heardWordsTask: nil, frontApplicationPlayedSoundRecently: playedSoundRecently)
            }

            // The sound is transcribed alongside the transcript fetch unless
            // a transcript panel is already in hand, so the slow path costs
            // no extra waiting. When YouTube does serve the captions, the
            // sound's transcription is simply not used.
            let transcriptPanelIsInHand = reading.playbackPosition != nil && !reading.transcriptCues.isEmpty
            var heardWordsTask: Task<LectureHeardWords?, Never>?
            if !transcriptPanelIsInHand, !reading.showsAnAdvert, let audioSnapshot {
                heardWordsTask = Task { await LectureAudioTranscriber.transcribe(audioSnapshot) }
            }

            var youTubeOutcome: YouTubeTranscriptOutcome?
            if !transcriptPanelIsInHand, let pageURL = reading.pageURL,
               let videoIdentifier = LectureVideoPage.youTubeVideoIdentifier(from: pageURL) {
                let transcriptCache = youTubeTranscriptCache
                let fetchTask = Task {
                    await transcriptCache.transcript(forVideoIdentifier: videoIdentifier,
                                                     preferredLanguageCodes: Locale.preferredLanguages)
                }
                // A slow watch page must not cost the sound its turn. The
                // fetch carries on, and its outcome is cached for the next question.
                youTubeOutcome = await Self.value(of: fetchTask, before: Date().addingTimeInterval(Self.longestYouTubeWaitSeconds))
                TutorDebugLog.write("🎓 lecture: YouTube \(videoIdentifier): \(youTubeOutcome?.summary ?? "still fetching")")
            }
            return Gathering(applicationName: applicationName, reading: reading, exclusionReason: nil,
                             youTubeOutcome: youTubeOutcome, heardWordsTask: heardWordsTask,
                             frontApplicationPlayedSoundRecently: playedSoundRecently)
        }
    }

    /// The note for this turn, or nil when there is no lecture to add, in
    /// which case the prompt is exactly what it would have been without it.
    func note(for gatheringTask: Task<Gathering?, Never>, question: String, screenListing: String,
              waitingUntil deadline: Date) async -> String? {
        guard let gatheredValue = await Self.value(of: gatheringTask, before: deadline), let gathering = gatheredValue else {
            gatheringTask.cancel()
            return nil
        }
        if let exclusionReason = gathering.exclusionReason {
            TutorDebugLog.write("🎓 lecture: nothing read, \(gathering.applicationName) is \(exclusionReason)")
            return nil
        }

        let screenTexts = ListedScreenText.texts(inListing: screenListing)
        if gathering.reading.showsAnAdvert || LectureClock.showsAnAdvert(screenTexts: screenTexts) {
            gathering.heardWordsTask?.cancel()
            TutorDebugLog.write("🎓 lecture: an advert is playing, nothing added")
            return nil
        }

        let playbackPosition = gathering.reading.playbackPosition ?? LectureClock.playbackPosition(fromScreenTexts: screenTexts)
        if let playbackPosition, let transcriptNote = transcriptNote(gathering: gathering, screenListing: screenListing,
                                                                     playbackPosition: playbackPosition) {
            gathering.heardWordsTask?.cancel()
            return transcriptNote
        }

        if let heardWordsTask = gathering.heardWordsTask {
            if let heardValue = await Self.value(of: heardWordsTask, before: deadline), let heardWords = heardValue {
                TutorDebugLog.write("🎓 lecture: \(heardWords.secondsCovered)s of \(gathering.applicationName)'s sound, heard by \(heardWords.heardBy)")
                return LectureNote.heardNote(passage: heardWords.passage, secondsCovered: heardWords.secondsCovered,
                                             heardBy: heardWords.heardBy)
            }
            heardWordsTask.cancel()
            TutorDebugLog.write("🎓 lecture: the sound gave no words in time")
            return nil
        }

        // Nothing to read and nothing heard. The one moment worth asking to
        // hear the sound: something was playing and the question is about it.
        if !audioBuffer.hasAskedForPermission, gathering.frontApplicationPlayedSoundRecently,
           playbackPosition != nil || Self.questionIsAboutWhatWasSaid(question),
           audioBuffer.askForPermissionNow() {
            return LectureNote.permissionJustAskedNote
        }
        return nil
    }

    private func transcriptNote(gathering: Gathering, screenListing: String,
                                playbackPosition: LecturePlaybackPosition) -> String? {
        var candidates: [(cues: [TimedTranscriptCue], sourceDescription: String)] = []
        if case .transcript(let cues, let track)? = gathering.youTubeOutcome {
            var description = track.isAutoGenerated ? "transcript, YouTube's auto-generated captions" : "transcript, YouTube captions"
            if !track.languageCode.lowercased().hasPrefix("en") { description += ", in \(track.displayName)" }
            candidates.append((cues, description))
        }
        if !gathering.reading.transcriptCues.isEmpty {
            candidates.append((gathering.reading.transcriptCues, "transcript, from the panel on the page"))
        }
        let onScreenCues = LectureTranscriptFinder.transcriptCues(inScreenListing: screenListing)
        if !onScreenCues.isEmpty {
            candidates.append((onScreenCues, "transcript, as shown on screen"))
        }

        let playbackSeconds = Double(playbackPosition.currentSeconds)
        for candidate in candidates {
            let cuesInWindow = LectureTranscriptWindow.cuesBefore(playbackSeconds: playbackSeconds, in: candidate.cues)
            // A panel scrolled to another part of the lecture does not
            // reach the playback time and says nothing about this moment.
            guard let lastCue = cuesInWindow.last, playbackSeconds - lastCue.startSeconds <= 20 else { continue }
            let passage = LectureTranscriptWindow.passage(from: cuesInWindow)
            guard !passage.isEmpty else { continue }
            TutorDebugLog.write("🎓 lecture: \(cuesInWindow.count) lines before \(LectureClock.clockText(fromSeconds: playbackPosition.currentSeconds)), \(candidate.sourceDescription)")
            return LectureNote.transcriptNote(passage: passage, playbackSeconds: playbackPosition.currentSeconds,
                                              sourceDescription: candidate.sourceDescription)
        }
        return nil
    }

    /// Only decides whether a first question is worth the permission
    /// prompt; it never decides whether a note is added.
    private static func questionIsAboutWhatWasSaid(_ question: String) -> Bool {
        let lowercasedQuestion = " " + question.lowercased() + " "
        let phrases = [" said", " say ", " saying", " mean", " meant", " he ", " she ", " they just", " lecturer",
                       " professor", " teacher", " instructor", " video", " lecture", " talking about", " just explained",
                       " explain that", " what was that", " went over", " mentioned"]
        return phrases.contains { lowercasedQuestion.contains($0) }
    }

    /// A task's value, or nil once the deadline passes. A task that has
    /// already finished is given a twentieth of a second. Raced with
    /// a continuation rather than a task group, because a group waits for
    /// every child, and waiting on a task's value cannot be cancelled.
    private static func value<Value>(of task: Task<Value, Never>, before deadline: Date) async -> Value? {
        let secondsLeft = max(0.05, deadline.timeIntervalSinceNow)
        return await withCheckedContinuation { continuation in
            let resumeOnce = LectureResumeOnce()
            Task {
                let finishedValue = await task.value
                if resumeOnce.claim() { continuation.resume(returning: finishedValue) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(secondsLeft * 1_000_000_000))
                if resumeOnce.claim() { continuation.resume(returning: nil) }
            }
        }
    }
}
