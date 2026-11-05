//
//  ProseSpeechQueue.swift
//  leanring-buddy
//
//  The voice of an answer that came back as prose rather than a drawing
//  program: complete sentences are cut from the stream as it arrives,
//  queued, and spoken one after another by the session's engine (Deepgram,
//  Kokoro or the system voice), each sentence's marks drawn as the words
//  carrying them are said. Also owns those three engines, which the
//  narration voice and the spoken failures share.
//

import Foundation

@MainActor
final class ProseSpeechQueue {
    /// How one sentence's marks follow its speech: `reached` as each word
    /// is said, `finished` once the sentence is over.
    struct SegmentMarks {
        let reached: (_ characterOffset: Int) -> Void
        let finished: () -> Void
    }

    lazy var speechClient = LocalSpeechSynthesisClient()

    /// Neural voice, used when its helper process comes up.
    ///
    /// The machine has no premium or enhanced system voice installed, so every
    /// AVSpeechSynthesizer option is the compact tier and sounds plainly
    /// synthetic. This is the difference between a voice you can listen to for
    /// an hour of study and one you cannot.
    /// Hosted voice. Preferred when a key is present: measured 0.16s to first
    /// byte against Kokoro's 0.77s render, and it is a far better voice than
    /// any compact system one.
    lazy var deepgramClient = DeepgramSpeechClient()

    lazy var kokoroClient = KokoroSpeechClient(
        helperScriptPath: Self.kokoroHelperScriptPath
    )

    /// Which voice is in use this session, decided once at startup.
    enum VoiceEngine { case deepgram, kokoro, system }
    private(set) var voiceEngine: VoiceEngine = .system
    /// The prose path's Deepgram voice, benched for five minutes after a
    /// failure and then tried again, instead of the system voice for good.
    private var deepgramVoiceBenchedUntil = Date.distantPast

    /// Whether the neural voice is available this session. False falls back to
    /// the system voice, which is worse but always works.
    private var isUsingNeuralVoice = false

    /// How much of the streamed response has already been handed to speech.
    private var streamedCharactersAlreadyQueued = 0

    /// Complete sentences waiting to be spoken, in order.
    private var pendingSpeechSegments: [ParsedTeacherResponse] = []

    /// Consumer draining `pendingSpeechSegments`, nil when nothing is speaking.
    private var speechConsumerTask: Task<Void, Never>?
    /// Which consumer the handle above belongs to. A cancelled consumer can
    /// still be unwinding when the next one starts, and when it ends it must
    /// clear only its own handle, never the new consumer's.
    private var currentSpeechConsumerIdentifier: UUID?

    /// A sentence with words is about to be spoken.
    var onSentenceStarted: (_ spokenText: String) -> Void = { _ in }
    /// Speech is about to play, for the voice state.
    var onWillSpeak: () -> Void = {}
    /// The marks of one sentence, set up just before it is spoken.
    var marksForSegment: (ParsedTeacherResponse) -> SegmentMarks = { _ in
        SegmentMarks(reached: { _ in }, finished: {})
    }
    var onDeepgramWorked: () -> Void = {}
    var onDeepgramKeyProblem: (Error) -> Void = { _ in }

    /// Location of the speech helper: shipped inside the app, so it is found
    /// on any Mac and wherever the source checkout lives. Overridable through
    /// defaults, for trying a changed script without a rebuild.
    static var kokoroHelperScriptPath: String {
        if let overridePath = UserDefaults.standard.string(forKey: "kokoroHelperScriptPath") {
            return overridePath
        }
        return Bundle.main.path(forResource: "kokoro_speech_server", ofType: "py") ?? ""
    }

    /// Whether sentences are queued or being spoken.
    var isSpeaking: Bool { speechConsumerTask != nil }

    /// Whether any of the three engines is producing audio.
    var isAnyEnginePlaying: Bool {
        speechClient.isPlaying || kokoroClient.isPlaying || deepgramClient.isPlaying
    }

    /// Picks the session's voice.
    func chooseVoice() async {
        // Ordered by quality. Deepgram first because it is both the best
        // voice and the fastest to first audio; Kokoro next because it
        // needs no network; the system voice last because every installed
        // one here is the compact tier and sounds it.
        if deepgramClient.isConfigured {
            voiceEngine = .deepgram
            TutorDebugLog.write("🔊 voice: Deepgram \(deepgramClient.voiceName)")
        } else if await kokoroClient.start() {
            voiceEngine = .kokoro
            isUsingNeuralVoice = true
        } else {
            voiceEngine = .system
            TutorDebugLog.write("🔈 no neural voice available, using the system voice")
        }
    }

    /// The audio output may be another device after sleep, and a Deepgram
    /// failure while asleep says nothing about it now.
    func prepareAfterWake() {
        deepgramClient.prepareAfterWake()
        deepgramVoiceBenchedUntil = .distantPast
    }

    /// A new answer's stream starts from its beginning.
    func resetStreamPosition() {
        streamedCharactersAlreadyQueued = 0
    }

    /// Pulls any newly completed sentences out of the stream and queues them.
    func enqueueCompletedSentences(fromStreamedText streamedText: String) {
        guard let chunk = TeacherResponseParser.nextSpeakableChunk(
            fromStreamedText: streamedText,
            alreadySpokenCharacterCount: streamedCharactersAlreadyQueued
        ) else { return }

        streamedCharactersAlreadyQueued += chunk.count
        enqueueParsedSegment(TeacherResponseParser.parse(rawResponse: chunk))
    }

    /// Queues the tail that followed the last sentence terminator.
    func enqueueRemainder(ofStreamedText fullText: String) {
        guard streamedCharactersAlreadyQueued < fullText.count else { return }

        let startIndex = fullText.index(fullText.startIndex, offsetBy: streamedCharactersAlreadyQueued)
        let remainder = String(fullText[startIndex...])
        streamedCharactersAlreadyQueued = fullText.count

        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        enqueueParsedSegment(TeacherResponseParser.parse(rawResponse: remainder))
    }

    private func enqueueParsedSegment(_ segment: ParsedTeacherResponse) {
        // A segment that was nothing but tags still carries marks worth drawing.
        guard !segment.spokenText.isEmpty || !segment.directives.isEmpty else { return }

        if !segment.directives.isEmpty {
            TutorDebugLog.write("✏️ segment carries \(segment.directives.count) mark(s)")
        }

        pendingSpeechSegments.append(segment)
        startSpeechConsumerIfIdle()
    }

    private func startSpeechConsumerIfIdle() {
        guard speechConsumerTask == nil else { return }

        let consumerIdentifier = UUID()
        currentSpeechConsumerIdentifier = consumerIdentifier
        speechConsumerTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.currentSpeechConsumerIdentifier == consumerIdentifier {
                    self.speechConsumerTask = nil
                    self.currentSpeechConsumerIdentifier = nil
                }
            }

            // Audio for the sentence after the current one, rendered while the
            // current one plays. Without this the speech stopped for a second
            // and a half before every sentence, which is what made it sound
            // halting instead of fluent: rendering only started once the
            // previous sentence had finished.
            var prefetchedClipTask: Task<KokoroSpeechClient.GeneratedClip, Error>?

            while !self.pendingSpeechSegments.isEmpty {
                guard !Task.isCancelled, self.currentSpeechConsumerIdentifier == consumerIdentifier else { break }

                let segment = self.pendingSpeechSegments.removeFirst()
                if !segment.spokenText.isEmpty {
                    self.onSentenceStarted(segment.spokenText)
                }

                self.onWillSpeak()

                let clipTaskForThisSegment = prefetchedClipTask
                prefetchedClipTask = nil

                // Start the next sentence rendering before speaking this one.
                // Only Kokoro needs this: it renders a whole clip before
                // playing, so without a lookahead every sentence began with a
                // second and a half of silence. Deepgram streams into the
                // engine as bytes arrive and reaches first audio in about a
                // sixth of a second, so there is no gap worth hiding.
                if self.voiceEngine == .kokoro,
                   let nextSegment = self.pendingSpeechSegments.first,
                   !nextSegment.spokenText.isEmpty {
                    prefetchedClipTask = self.kokoroClient.beginGeneratingClip(
                        for: nextSegment.spokenText
                    )
                }

                // A ceiling on how long one sentence may take. Without it a
                // single stalled playback holds the pipeline open and the user
                // gets no answer at all and no error explaining why, which is
                // precisely what an audio format mismatch caused: buffers were
                // silently dropped, the completion handler never fired, and
                // everything waited on a sentence that was never spoken.
                let finishedSpeaking: Void? = try? await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor in
                        await self.speak(segment: segment, prerenderedClip: clipTaskForThisSegment)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 45_000_000_000)
                        throw CancellationError()
                    }
                    try await group.next()
                    group.cancelAll()
                }

                if finishedSpeaking == nil {
                    TutorDebugLog.write("⚠️ sentence never finished speaking, abandoning the rest")
                    // Only the speech: the stream's place is kept, so the
                    // sentences still to come are spoken, not the answer again
                    // from its start.
                    self.abandonQueuedSpeech()
                    break
                }
            }
        }
    }

    /// Stops every voice and drops the sentences waiting, but keeps how far
    /// the answer's stream has been read.
    func abandonQueuedSpeech() {
        speechConsumerTask?.cancel()
        speechConsumerTask = nil
        currentSpeechConsumerIdentifier = nil
        pendingSpeechSegments.removeAll()
        speechClient.onWillSpeakRange = nil
        speechClient.stopPlayback()
        kokoroClient.onSpokenProgress = nil
        kokoroClient.stopPlayback()
        deepgramClient.onSpokenProgress = nil
        deepgramClient.stopPlayback()
    }

    /// Speaks one segment, drawing its marks as the words carrying them are said.
    ///
    /// Both engines report progress as a character offset into the text, but
    /// they measure it very differently. AVSpeechSynthesizer reports real word
    /// boundaries as it speaks them. Kokoro hands back a finished waveform with
    /// no timing at all, so its offsets are interpolated from elapsed playback.
    /// That is an estimate, and it only has to be close enough to land a mark
    /// in the right clause.
    private func speak(
        segment: ParsedTeacherResponse,
        prerenderedClip: Task<KokoroSpeechClient.GeneratedClip, Error>? = nil
    ) async {
        let marks = marksForSegment(segment)
        func drawMarksReached(upToCharacterOffset offset: Int) {
            marks.reached(offset)
        }

        // A segment that is nothing but tags still has marks worth drawing.
        guard !segment.spokenText.isEmpty else {
            drawMarksReached(upToCharacterOffset: Int.max)
            return
        }

        let isDeepgramBenched = Date() < deepgramVoiceBenchedUntil
        switch voiceEngine == .deepgram && isDeepgramBenched ? .system : voiceEngine {
        case .deepgram:
            deepgramClient.onSpokenProgress = { reachedOffset in
                drawMarksReached(upToCharacterOffset: reachedOffset)
            }
            do {
                // No prefetch needed here. Deepgram streams PCM into the audio
                // engine as it arrives, so the gap before a sentence is about
                // a sixth of a second rather than the second and a half that
                // made rendering ahead worth the complexity for Kokoro.
                try await deepgramClient.speakText(segment.spokenText)
                onDeepgramWorked()
            } catch {
                TutorDebugLog.write("⚠️ Deepgram failed: \(error.localizedDescription). system voice for \(Int(NarrationVoice.deepgramBenchSeconds / 60)) minutes.")
                deepgramVoiceBenchedUntil = Date().addingTimeInterval(NarrationVoice.deepgramBenchSeconds)
                onDeepgramKeyProblem(error)
                deepgramClient.onSpokenProgress = nil
                speechClient.onWillSpeakRange = { spokenRange, _ in
                    drawMarksReached(upToCharacterOffset: spokenRange.location + spokenRange.length)
                }
                try? await speechClient.speakText(segment.spokenText)
                speechClient.onWillSpeakRange = nil
            }
            deepgramClient.onSpokenProgress = nil

        case .kokoro:
            kokoroClient.onSpokenProgress = { reachedOffset in
                drawMarksReached(upToCharacterOffset: reachedOffset)
            }
            do {
                // Already rendering, or rendered, from the previous iteration.
                let clipTask = prerenderedClip
                    ?? kokoroClient.beginGeneratingClip(for: segment.spokenText)
                try await kokoroClient.play(clip: try await clipTask.value)
            } catch {
                // Falling back for the rest of the session rather than retrying
                // each sentence: whatever broke the helper will break it again,
                // and a stutter between every sentence is worse than a plainer
                // voice throughout.
                TutorDebugLog.write("⚠️ neural voice failed: \(error.localizedDescription). system voice from here.")
                isUsingNeuralVoice = false
                kokoroClient.onSpokenProgress = nil
                try? await speechClient.speakText(segment.spokenText)
            }
            kokoroClient.onSpokenProgress = nil
            if voiceEngine == .kokoro, !isUsingNeuralVoice { voiceEngine = .system }

        case .system:
            speechClient.onWillSpeakRange = { spokenRange, _ in
                drawMarksReached(upToCharacterOffset: spokenRange.location + spokenRange.length)
            }
            try? await speechClient.speakText(segment.spokenText)
            speechClient.onWillSpeakRange = nil
        }

        // Anything the progress callback never reached, because speech was cut
        // short or the tag sat past the final word.
        marks.finished()
    }
}
