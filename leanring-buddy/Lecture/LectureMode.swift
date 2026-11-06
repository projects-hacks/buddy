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
//  Then the words recognised on the Mac as the video played
//  (LectureLiveTranscript.swift), which need no waiting and send nothing,
//  and which also keep the lecturer on the speakers from being taken for
//  the student in what the microphone hears.
//
//  The sound as the last resort, the way Snipd keeps a rolling buffer and
//  transcribes only on demand: when neither gives words, the newest
//  65 of the 90 seconds kept of the front app's own sound
//  (LectureAudioBuffer.swift) are transcribed by Deepgram, or on the Mac
//  without a Deepgram key. Only for a lecture question: a player's time
//  was read, or the question is about what was said (LectureAudioGate).
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
        /// Kept so the sound can still be transcribed once the screen
        /// listing shows a player's time, when the page itself did not.
        let audioSnapshot: LectureAudioSnapshot?
        let frontApplicationPlayedSoundRecently: Bool
    }

    /// Told when the front app's sound starts or stops being kept, for the
    /// notch's lecture indicator.
    var onKeepingSoundChanged: (Bool) -> Void = { _ in }
    /// What the last note was taken from, for the notch's right side while
    /// that answer plays: "lecture at 12:40". Nil when the last question
    /// got no lecture note.
    private(set) var lastNoteSourceLabel: String?

    /// Called once at launch: starts watching which app is in front and
    /// whether it is playing sound.
    func startWatching() {
        audioBuffer.onTappingChanged = { [weak self] isTapping in self?.onKeepingSoundChanged(isTapping) }
        audioBuffer.startWatching()
    }

    /// The video's words of the last few seconds as phrases, so talking
    /// over an answer never takes the lecturer on the speakers for the
    /// student (TalkOverHearing.lectureWordMask).
    func recentLecturePhrases() -> [SpokenSentence] {
        let since = TalkOverListener.now - TalkOverTranscript.keptForSeconds - TalkOverHearing.lectureSlackSeconds
        return audioBuffer.liveTranscript.log.phrases(since: since).map {
            SpokenSentence(text: $0.text, startedAt: $0.startedAt, endedAt: $0.endedAt, isFromTheLecture: true)
        }
    }

    /// A question asked by holding the keys, with the lecturer's words taken
    /// out: with the video on the speakers, the microphone hears both. Nil
    /// when nothing of the student's is left, so the video is never sent as
    /// their question.
    func withoutTheLecture(_ transcript: String, heardSince: Double) -> String? {
        let now = TalkOverListener.now
        let phrases = audioBuffer.liveTranscript.log.phrases(since: heardSince - TalkOverHearing.lectureSlackSeconds).map {
            SpokenSentence(text: $0.text, startedAt: $0.startedAt, endedAt: $0.endedAt, isFromTheLecture: true)
        }
        guard !phrases.isEmpty else { return transcript }
        let rawTokens = transcript.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let tokens = rawTokens.map { (raw: $0, word: TalkOverHearing.words(of: $0).joined()) }.filter { !$0.word.isEmpty }
        // Every word was heard somewhere in the hold, so each may match the
        // lecture anywhere in it.
        let isTheLectures = TalkOverHearing.lectureWordMask(
            tokens.map(\.word), heardAt: tokens.map { _ in now }, spoken: phrases,
            slackSeconds: now - heardSince + TalkOverHearing.lectureSlackSeconds)
        let kept = tokens.indices.filter { !isTheLectures[$0] }.map { tokens[$0].raw }
        guard kept.count < tokens.count else { return transcript }
        TutorDebugLog.write("🎓 lecture: \(tokens.count - kept.count) of \(tokens.count) words heard were the video, left out")
        return kept.isEmpty ? nil : kept.joined(separator: " ")
    }

    private static func sourceLabel(for playbackPosition: LecturePlaybackPosition?) -> String {
        guard let playbackPosition else { return "the lecture" }
        return "lecture at " + LectureClock.clockText(fromSeconds: playbackPosition.currentSeconds)
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
                                 youTubeOutcome: nil, heardWordsTask: nil, audioSnapshot: nil,
                                 frontApplicationPlayedSoundRecently: playedSoundRecently)
            }

            // The sound is sent to be transcribed only when this is a
            // lecture question: a player's time was read, or the question
            // is about what was said. Music in another tab while asking
            // about code never leaves the Mac. When the gate passes, the
            // sound is transcribed alongside the transcript fetch, so the
            // slow path costs no extra waiting; if YouTube does serve the
            // captions, the sound's words are simply not used.
            let transcriptPanelIsInHand = reading.playbackPosition != nil && !reading.transcriptCues.isEmpty
            // Words already recognised as it played need nothing sent.
            let liveWordsAreInHand = audioBuffer.liveWordsForQuestion() != nil
            var heardWordsTask: Task<LectureHeardWords?, Never>?
            if !transcriptPanelIsInHand, !liveWordsAreInHand, !reading.showsAnAdvert, let audioSnapshot,
               LectureAudioGate.maySendSound(playbackPosition: reading.playbackPosition, question: question) {
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
            let pageForLog = reading.pageURL.map { ($0.host ?? "") + $0.path } ?? "no page address"
            let timeForLog = reading.playbackPosition.map { LectureClock.clockText(fromSeconds: $0.currentSeconds) } ?? "no player time"
            TutorDebugLog.write("🎓 lecture: \(applicationName), \(pageForLog), \(timeForLog), sound \(audioBuffer.stateForLog())\(heardWordsTask == nil ? "" : ", sending it to be heard")")
            return Gathering(applicationName: applicationName, reading: reading, exclusionReason: nil,
                             youTubeOutcome: youTubeOutcome, heardWordsTask: heardWordsTask, audioSnapshot: audioSnapshot,
                             frontApplicationPlayedSoundRecently: playedSoundRecently)
        }
    }

    /// The note for this turn, or nil when there is no lecture to add, in
    /// which case the prompt is exactly what it would have been without it.
    func note(for gatheringTask: Task<Gathering?, Never>, question: String, screenListing: String,
              waitingUntil deadline: Date) async -> String? {
        lastNoteSourceLabel = nil
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
            lastNoteSourceLabel = Self.sourceLabel(for: playbackPosition)
            return transcriptNote
        }

        // What it said, recognised on the Mac as it played: no waiting and
        // nothing sent.
        if LectureAudioGate.maySendSound(playbackPosition: playbackPosition, question: question),
           let live = audioBuffer.liveWordsForQuestion() {
            gathering.heardWordsTask?.cancel()
            TutorDebugLog.write("🎓 lecture: \(live.secondsCovered)s of \(gathering.applicationName)'s words, recognised as it played")
            lastNoteSourceLabel = Self.sourceLabel(for: playbackPosition)
            return LectureNote.heardNote(passage: live.passage, secondsCovered: live.secondsCovered,
                                         heardBy: "the Mac as it played")
        }

        // Started late when only the screen listing showed the player's
        // time, within the same deadline.
        var heardWordsTask = gathering.heardWordsTask
        if heardWordsTask == nil, let audioSnapshot = gathering.audioSnapshot,
           LectureAudioGate.maySendSound(playbackPosition: playbackPosition, question: question) {
            heardWordsTask = Task { await LectureAudioTranscriber.transcribe(audioSnapshot) }
        }
        if let heardWordsTask {
            if let heardValue = await Self.value(of: heardWordsTask, before: deadline), let heardWords = heardValue {
                TutorDebugLog.write("🎓 lecture: \(heardWords.secondsCovered)s of \(gathering.applicationName)'s sound, heard by \(heardWords.heardBy)")
                lastNoteSourceLabel = Self.sourceLabel(for: playbackPosition)
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
           LectureAudioGate.maySendSound(playbackPosition: playbackPosition, question: question),
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
