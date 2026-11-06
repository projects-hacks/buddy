// Checks lecture mode's parts that need no permission: time reading from
// sample screen text, finding a transcript among page texts, the
// exclusions, cutting a real lecture's captions to the minute before a
// time, the note's length, the rolling buffer's arithmetic, and YouTube's
// caption tracks for real public lectures.
//
// usage: zsh scripts/lecture_mode/run_check.sh [path to a WebVTT caption file]
import Foundation

var failures = 0
func check(_ condition: Bool, _ name: String) {
    print(condition ? "pass  \(name)" : "FAIL  \(name)")
    if !condition { failures += 1 }
}

// MARK: time
check(LectureClock.seconds(fromClockText: "12:34") == 754, "clock 12:34")
check(LectureClock.seconds(fromClockText: "1:02:03") == 3723, "clock 1:02:03")
check(LectureClock.seconds(fromClockText: "0:05") == 5, "clock 0:05")
check(LectureClock.seconds(fromClockText: "3:75") == nil, "clock 3:75 rejected")
check(LectureClock.seconds(fromClockText: "12") == nil, "clock 12 rejected")
check(LectureClock.seconds(fromClockText: "1:5") == nil, "clock 1:5 rejected")
check(LectureClock.clockText(fromSeconds: 3723) == "1:02:03", "clock text 1:02:03")
check(LectureClock.playbackPosition(fromSeekBarDescription: "12 Minutes 34 Seconds of 48 Minutes 10 Seconds")
      == LecturePlaybackPosition(currentSeconds: 754, totalSeconds: 2890), "YouTube seek bar description")
check(LectureClock.playbackPosition(fromSeekBarDescription: "1:23 of 10:45")
      == LecturePlaybackPosition(currentSeconds: 83, totalSeconds: 645), "video.js seek bar description")
check(LectureClock.playbackPosition(fromScreenTexts: ["Subscribe", "12:34 / 48:10", "Settings"])
      == LecturePlaybackPosition(currentSeconds: 754, totalSeconds: 2890), "screen text 12:34 / 48:10")
check(LectureClock.playbackPosition(fromScreenTexts: ["12:34", "/", "48:10"])
      == LecturePlaybackPosition(currentSeconds: 754, totalSeconds: 2890), "split accessibility texts")
check(LectureClock.playbackPosition(fromScreenTexts: ["1:02:03 / 1:30:00 • Dynamic programming"])
      == LecturePlaybackPosition(currentSeconds: 3723, totalSeconds: 5400), "hours and chapter name")
check(LectureClock.playbackPosition(fromScreenTexts: ["page 3 / 10", "Updated 12:30", "4/5 stars"]) == nil, "no player time")
check(LectureClock.playbackPosition(fromScreenTexts: ["50:00 / 12:00"]) == nil, "current beyond length rejected")
check(LectureClock.playbackPosition(fromScreenTexts: ["LIVE", "Live chat"]) == nil, "live stream has no time")
check(LectureClock.showsAnAdvert(screenTexts: ["Sponsored", "Skip Ad", "0:05 / 0:15"]), "advert seen")
check(!LectureClock.showsAnAdvert(screenTexts: ["Lecture 1: Algorithms", "12:34 / 48:10"]), "no advert")

// MARK: transcript in a page
let youTubePanelTexts = [
    "Transcript", "Search in video",
    "2 minutes, 1 second because the", "2:01", "because the",
    "2:04", "running time depends on the input",
    "2:08", "so the worst case is the one to look at",
    "2:12", "and that gives an upper bound",
    "2:15", "on how long it can take",
    "2:19", "for any input of size n",
    "2:22", "which is what big O means",
]
let youTubeCues = LectureTranscriptFinder.transcriptCues(inReadingOrder: youTubePanelTexts)
check(youTubeCues.count == 7 && youTubeCues.first == TimedTranscriptCue(startSeconds: 121, text: "because the"),
      "YouTube transcript panel, label and visible text merged (\(youTubeCues.count) cues)")
let courseraTexts = [
    "Play video starting at 0 seconds and follow transcript", "Welcome back.", "Today: gradient descent.",
    "Play video starting at 12 seconds and follow transcript", "The idea is to take small steps",
    "Play video starting at 25 seconds and follow transcript", "downhill on the cost function.",
    "Play video starting at 39 seconds and follow transcript", "Each step uses the gradient.",
    "Play video starting at 51 seconds and follow transcript", "The learning rate sets the size.",
    "Play video starting at 1 minute 4 seconds and follow transcript", "Too large and it overshoots.",
]
let courseraCues = LectureTranscriptFinder.transcriptCues(inReadingOrder: courseraTexts)
check(courseraCues.count == 6 && courseraCues.last?.startSeconds == 64, "Coursera transcript (\(courseraCues.count) cues)")
let recommendationTexts = ["12:04", "Dynamic Programming", "MIT", "45:10", "Graphs", "3:22", "Sorting", "1:01:00",
                           "Hashing", "8:15", "Trees", "22:00", "Heaps", "5:00", "Tries"]
check(LectureTranscriptFinder.transcriptCues(inReadingOrder: recommendationTexts).isEmpty, "recommendation durations are not a transcript")
let chapterTexts = ["0:00 Intro", "4:30 Arrays", "11:20 Linked lists", "19:45 Stacks", "27:10 Queues", "35:00 Summary"]
check(LectureTranscriptFinder.transcriptCues(inReadingOrder: chapterTexts).isEmpty, "chapter list is not a transcript")
let commentTexts = ["3 minutes ago", "great lecture", "5 minutes ago", "thanks", "7 minutes ago", "at 12:34 he says"]
check(LectureTranscriptFinder.transcriptCues(inReadingOrder: commentTexts).isEmpty, "comment ages are not a transcript")

// MARK: transcript on the screen, from recognised text with boxes
let listing = """
t1 [100, 80, 700, 40] Lecture 1: Algorithms and Computation
t2 [120, 900, 160, 30] 12:34 / 48:10
t3 [1500, 200, 60, 28] 12:10
t4 [1580, 200, 380, 28] so an algorithm is a function
t5 [1500, 250, 60, 28] 12:15
t6 [1580, 250, 380, 28] from inputs to outputs, and
t7 [1580, 280, 300, 28] it has to be correct
t8 [1500, 330, 60, 28] 12:21
t9 [1580, 330, 380, 28] for every input in the problem
t10 [1500, 380, 60, 28] 12:26
t11 [1580, 380, 380, 28] and it should be efficient
t12 [1500, 430, 60, 28] 12:31
t13 [1580, 430, 380, 28] which is what this class is about
"""
let listedCues = LectureTranscriptFinder.transcriptCues(inScreenListing: listing)
check(listedCues.count == 5 && listedCues.count > 1 && listedCues[1].text == "from inputs to outputs, and it has to be correct",
      "screen listing panel by position (\(listedCues.count) cues)")
check(LectureClock.playbackPosition(fromScreenTexts: ListedScreenText.texts(inListing: listing))?.currentSeconds == 754, "time from listing")

// MARK: exclusions
func excluded(_ bundle: String?, _ name: String?, _ title: String?, _ url: String?) -> Bool {
    LectureCaptureExclusions.reasonToExclude(bundleIdentifier: bundle, applicationName: name, windowTitle: title,
                                             pageURL: url.flatMap(URL.init(string:))) != nil
}
check(excluded("us.zoom.xos", "zoom.us", nil, nil), "Zoom app")
check(excluded("com.microsoft.teams2", "Microsoft Teams", nil, nil), "Teams app")
check(excluded("com.apple.FaceTime", "FaceTime", nil, nil), "FaceTime")
check(excluded("com.hnc.Discord", "Discord", nil, nil), "Discord")
check(excluded("com.tinyspeck.slackmacgap", "Slack", nil, nil), "Slack")
check(excluded("com.cisco.webexmeetingsapp", "Webex", nil, nil), "Webex")
check(excluded("com.skype.skype", "Skype", nil, nil), "Skype")
check(excluded("net.whatsapp.WhatsApp", "WhatsApp", nil, nil), "WhatsApp")
check(excluded("com.apple.Music", "Music", nil, nil), "Music")
check(excluded("com.spotify.client", "Spotify", nil, nil), "Spotify")
check(excluded("com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", "Google Meet", nil, nil), "Meet web app")
check(excluded("com.google.Chrome", "Google Chrome", "Meet - abc-defg-hij", "https://meet.google.com/abc-defg-hij"), "Meet tab")
check(excluded("com.apple.Safari", "Safari", nil, "https://teams.microsoft.com/v2/"), "Teams tab")
check(excluded("com.apple.Safari", "Safari", nil, "https://app.zoom.us/wc/123/join"), "Zoom web client")
check(excluded("com.google.Chrome", "Google Chrome", nil, "https://music.youtube.com/watch?v=abc"), "YouTube Music")
check(excluded("com.google.Chrome", "Google Chrome", "Meet - abc", nil), "Meet by title when no address")
check(!excluded("com.google.Chrome", "Google Chrome", "Slack tips - YouTube", "https://www.youtube.com/watch?v=ZA-tUyM_y7s"), "YouTube video about Slack allowed")
check(!excluded("com.apple.Safari", "Safari", nil, "https://zoom.us/rec/play/abc"), "recorded Zoom class allowed")
check(!excluded("com.colliderli.iina", "IINA", "lecture3.mp4", nil), "video player app allowed")
check(!excluded("com.google.Chrome", "Google Chrome", nil, "https://www.coursera.org/learn/ml/lecture/abc/intro"), "Coursera allowed")

// MARK: video pages
check(LectureVideoPage.youTubeVideoIdentifier(from: URL(string: "https://www.youtube.com/watch?v=ZA-tUyM_y7s&t=754s")!) == "ZA-tUyM_y7s", "watch link")
check(LectureVideoPage.youTubeVideoIdentifier(from: URL(string: "https://youtu.be/ZA-tUyM_y7s")!) == "ZA-tUyM_y7s", "short link")
check(LectureVideoPage.youTubeVideoIdentifier(from: URL(string: "https://www.youtube.com/live/ZA-tUyM_y7s")!) == "ZA-tUyM_y7s", "live link")
check(LectureVideoPage.youTubeVideoIdentifier(from: URL(string: "https://music.youtube.com/watch?v=ZA-tUyM_y7s")!) == nil, "music link ignored")
check(LectureVideoPage.pageURL(fromAddressBarText: "youtube.com/watch?v=ZA-tUyM_y7s")?.host == "youtube.com", "address bar without scheme")
check(LectureVideoPage.pageURL(fromAddressBarText: "what is a heap") == nil, "a search is not an address")

// MARK: json3
let json3 = #"{"events":[{"tStartMs":0,"dDurationMs":2000,"segs":[{"utf8":"hello"},{"utf8":" everyone","tOffsetMs":400}]},{"tStartMs":1900,"aAppend":1,"segs":[{"utf8":"\n"}]},{"tStartMs":2100,"segs":[{"utf8":"today: sorting"}]}]}"#
let json3Cues = YouTubeCaptions.cues(fromJSON3: Data(json3.utf8))
check(json3Cues == [TimedTranscriptCue(startSeconds: 0, text: "hello everyone"), TimedTranscriptCue(startSeconds: 2.1, text: "today: sorting")], "json3 parse")
check(YouTubeCaptions.cues(fromJSON3: Data()).isEmpty, "empty json3 body is no cues")
let sampleTracks = [
    YouTubeCaptionTrack(baseURL: URL(string: "https://www.youtube.com/api/timedtext?lang=en&kind=asr")!, languageCode: "en", isAutoGenerated: true, displayName: "English (auto-generated)"),
    YouTubeCaptionTrack(baseURL: URL(string: "https://www.youtube.com/api/timedtext?lang=en")!, languageCode: "en", isAutoGenerated: false, displayName: "English"),
    YouTubeCaptionTrack(baseURL: URL(string: "https://www.youtube.com/api/timedtext?lang=uk")!, languageCode: "uk", isAutoGenerated: false, displayName: "Ukrainian"),
]
check(YouTubeCaptions.chooseTrack(from: sampleTracks, defaultTrackIndex: nil, preferredLanguageCodes: ["uk"])?.languageCode == "en"
      && YouTubeCaptions.chooseTrack(from: sampleTracks, defaultTrackIndex: nil, preferredLanguageCodes: ["uk"])?.isAutoGenerated == false,
      "track: human captions in the spoken language beat the student's language")
let spanishLecture = [
    YouTubeCaptionTrack(baseURL: URL(string: "https://www.youtube.com/api/timedtext?lang=es&kind=asr")!, languageCode: "es", isAutoGenerated: true, displayName: "Spanish (auto-generated)"),
    YouTubeCaptionTrack(baseURL: URL(string: "https://www.youtube.com/api/timedtext?lang=en")!, languageCode: "en", isAutoGenerated: false, displayName: "English"),
]
check(YouTubeCaptions.chooseTrack(from: spanishLecture, defaultTrackIndex: nil, preferredLanguageCodes: ["en-US"])?.languageCode == "es",
      "track: a Spanish lecture is quoted in Spanish, as spoken")

// MARK: the minute before a time, on a real lecture's captions
func cuesFromWebVTT(_ vttText: String) -> [TimedTranscriptCue] {
    var cues: [TimedTranscriptCue] = []
    for block in vttText.components(separatedBy: "\n\n") {
        let lines = block.split(separator: "\n").map(String.init)
        guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
        let start = lines[timingIndex].components(separatedBy: " --> ")[0]
        let parts = start.split(separator: ":").map { Double($0) ?? 0 }
        guard parts.count == 3 else { continue }
        let text = lines[(timingIndex + 1)...].joined(separator: " ")
        cues.append(TimedTranscriptCue(startSeconds: parts[0] * 3600 + parts[1] * 60 + parts[2], text: text))
    }
    return cues
}
if CommandLine.arguments.count > 1, let vttText = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) {
    let lectureCues = cuesFromWebVTT(vttText)
    let window = LectureTranscriptWindow.cuesBefore(playbackSeconds: 754, in: lectureCues)
    check(!lectureCues.isEmpty && !window.isEmpty, "real lecture: \(lectureCues.count) cues, \(window.count) in the minute before 12:34")
    check(window.allSatisfy { $0.startSeconds >= 694 && $0.startSeconds <= 755 }, "real lecture: window bounds")
    let passage = LectureTranscriptWindow.passage(from: window)
    let note = LectureNote.transcriptNote(passage: passage, playbackSeconds: 754, sourceDescription: "transcript, YouTube captions")
    check(note.count <= LectureNote.maximumCharacters, "real lecture: note \(note.count) characters")
    print("      window \(window.first.map { LectureClock.clockText(fromSeconds: Int($0.startSeconds)) } ?? "-") to \(window.last.map { LectureClock.clockText(fromSeconds: Int($0.startSeconds)) } ?? "-"), passage \(passage.count) characters")
    print("      note: \(note.prefix(160))...")
    let longPassage = String(repeating: "the lecturer keeps talking about sorting ", count: 80)
    check(LectureNote.transcriptNote(passage: longPassage, playbackSeconds: 754, sourceDescription: "transcript").count <= 1500, "long passage trimmed under 1500")
}
check(LectureTranscriptWindow.passage(from: [TimedTranscriptCue(startSeconds: 0, text: "then take the sum of"),
                                             TimedTranscriptCue(startSeconds: 2, text: "the sum of all the elements")]) == "then take the sum of all the elements",
      "auto-caption overlap removed")

// MARK: when the sound may be sent
// No playback time anywhere and an unrelated question: nothing is
// transcribed, so no heard-words note can be added.
let codingListing = """
t1 [100, 80, 700, 40] main.py - Visual Studio Code
t2 [120, 200, 600, 30] def binary_search(items, target):
t3 [1500, 40, 300, 30] Lo-fi beats to study to
"""
let codingPosition = LectureClock.playbackPosition(fromScreenTexts: ListedScreenText.texts(inListing: codingListing))
check(codingPosition == nil, "gate: no player time on a coding screen")
check(!LectureAudioGate.maySendSound(playbackPosition: codingPosition, question: "why does this function return none"),
      "gate: unrelated question with music playing sends nothing")
check(!LectureAudioGate.maySendSound(playbackPosition: nil, question: "what does this error mean"), "gate: 'mean' about an error is not a lecture")
check(!LectureAudioGate.maySendSound(playbackPosition: nil, question: "can you explain that line"), "gate: 'explain that' alone is not a lecture")
check(!LectureAudioGate.maySendSound(playbackPosition: nil, question: "what should this say instead"), "gate: 'say' about code is not a lecture")
check(LectureAudioGate.maySendSound(playbackPosition: LecturePlaybackPosition(currentSeconds: 754, totalSeconds: 2890),
                                    question: "why does this function return none"), "gate: a player's time is evidence")
check(LectureAudioGate.maySendSound(playbackPosition: LecturePlaybackPosition(currentSeconds: 754, totalSeconds: 2890),
                                    question: "what is this"), "gate: a player's time from the screen listing is evidence")
check(LectureAudioGate.maySendSound(playbackPosition: nil, question: "what did he mean by that?"), "gate: what did he mean")
check(LectureAudioGate.maySendSound(playbackPosition: nil, question: "explain what she just said"), "gate: explain what she just said")
check(LectureAudioGate.maySendSound(playbackPosition: nil, question: "what is the professor talking about"), "gate: the professor")
check(LectureAudioGate.maySendSound(playbackPosition: nil, question: "didn\u{2019}t get the last part of the video"), "gate: the video")
check(LectureAudioGate.maySendSound(playbackPosition: LectureClock.playbackPosition(fromScreenTexts: ListedScreenText.texts(inListing: listing)),
                                    question: "why"), "gate: time read from a lecture's screen listing")

// MARK: heard words, cut to the last minute at a sentence start
var heardWords: [(word: String, startSeconds: Double)] = []
for second in stride(from: 0.0, to: 90.0, by: 1.0) {
    // A sentence ends every ten seconds: "word9." at 9, 19, 29...
    heardWords.append((Int(second) % 10 == 9 ? "word\(Int(second))." : "word\(Int(second))", second))
}
let lastMinute = LectureTranscriptWindow.lastMinute(ofTimedWords: heardWords, audioDurationSeconds: 90)
check(lastMinute.hasPrefix("word30 "), "heard words: starts at the sentence that opens the last minute (\(lastMinute.prefix(8)))")
let midSentence = heardWords.map { (word: $0.word.replacingOccurrences(of: ".", with: ""), startSeconds: $0.startSeconds) }
check(LectureTranscriptWindow.lastMinute(ofTimedWords: midSentence, audioDurationSeconds: 90).hasPrefix("word30 "),
      "heard words: no sentence ends, cut at 60 seconds")
check(LectureTranscriptWindow.lastMinute(ofTimedWords: [("hello.", 1)], audioDurationSeconds: 90).isEmpty,
      "heard words: nothing said in the last minute")
let sentenceBefore = heardWords.enumerated().map { index, entry in (word: index == 24 ? "word24." : entry.word.replacingOccurrences(of: ".", with: ""), startSeconds: entry.startSeconds) }
check(LectureTranscriptWindow.lastMinute(ofTimedWords: sentenceBefore, audioDurationSeconds: 90).hasPrefix("word25 "),
      "heard words: reaches back to a sentence start within 30 seconds")

// MARK: rolling buffer
let ring = LectureAudioRingBuffer(sampleRate: 10, capacitySeconds: 9)  // 90 samples
ring.append((0..<50).map { Int16($0) })
check(ring.storedSeconds == 5 && ring.newestSamples(seconds: 2) == (30..<50).map { Int16($0) }, "ring before wrap")
ring.append((50..<120).map { Int16($0) })
check(ring.storedSeconds == 9, "ring holds exactly its capacity after wrap")
check(ring.newestSamples(seconds: 9) == (30..<120).map { Int16($0) }, "ring after wrap is the newest 90, oldest first")
check(ring.newestSamples(seconds: 100).count == 90, "asking for more than is kept")
ring.append((0..<500).map { Int16($0 % 300) })
check(ring.newestSamples(seconds: 9) == (410..<500).map { Int16($0 % 300) }, "one append larger than the ring")
ring.removeAll()
check(ring.storedSeconds == 0 && ring.newestSamples(seconds: 5).isEmpty, "discard")
let ninetySeconds = LectureAudioRingBuffer(sampleRate: 16_000, capacitySeconds: 90)
check(ninetySeconds.capacityInSamples * 2 == 2_880_000, "90 s at 16 kHz Int16 is 2.88 MB")
let downsampler48 = LectureAudioDownsampler(sourceSampleRate: 48_000, targetSampleRate: 16_000)
var produced = 0
for _ in 0..<100 { produced += downsampler48.downsample([Float](repeating: 0.5, count: 480)).count }
check(produced == 16_000, "48 kHz to 16 kHz: one second in, 16000 out (\(produced))")
let downsampler44 = LectureAudioDownsampler(sourceSampleRate: 44_100, targetSampleRate: 16_000)
produced = 0
var lastValue: Int16 = 0
for _ in 0..<100 {
    let out = downsampler44.downsample([Float](repeating: 0.5, count: 441))
    produced += out.count
    lastValue = out.last ?? lastValue
}
check(abs(produced - 16_000) <= 1 && abs(Int(lastValue) - 16383) <= 1, "44.1 kHz to 16 kHz keeps the fraction across calls (\(produced))")
let tone = (0..<16_000).map { Int16(8000 * sin(Double($0) * 2 * .pi * 220 / 16_000)) }
check(LectureAudioRingBuffer.secondsWithSound(in: tone, sampleRate: 16_000) == 1.0, "a tone is sound")
check(LectureAudioRingBuffer.secondsWithSound(in: [Int16](repeating: 0, count: 32_000), sampleRate: 16_000) == 0, "digital silence is not")

// MARK: YouTube, live

// MARK: the lecture's words as they were heard
var heardLog = LectureHeardWordLog()
heardLog.update(request: 1, text: "so the next", at: 10)
heardLog.update(request: 1, text: "so the next step is", at: 11)
heardLog.update(request: 1, text: "So the next step is the API.", at: 12)
check(heardLog.allWords.map(\.heardAt) == [10, 10, 10, 11, 11, 12, 12], "a revised word keeps when it was first heard")
heardLog.update(request: 2, text: "Endpoints come next.", at: 70)
heardLog.update(request: 1, text: "So the next step is the API, which", at: 71)
check(heardLog.passage(since: 0) == "So the next step is the API, which Endpoints come next.", "an older request's late words stay before the newer request's")
check(heardLog.passage(since: 60) == "which Endpoints come next.", "since a time, only the words heard after it")
// Apple's recognizer starting its text over after a pause, in one request.
var restartLog = LectureHeardWordLog()
restartLog.update(request: 1, text: "Additional requirements, so", at: 1)
restartLog.update(request: 1, text: "Additional requirements, so the qualities of the system.", at: 3)
restartLog.update(request: 1, text: "And then", at: 6)
restartLog.update(request: 1, text: "And then we'll outline our core entities.", at: 8)
restartLog.update(request: 1, text: "This is like", at: 11)
check(restartLog.passage(since: 0) == "Additional requirements, so the qualities of the system. And then we'll outline our core entities. This is like",
      "a recognizer that starts over after a pause loses nothing")
check(restartLog.allWords.first?.heardAt == 1 && restartLog.allWords.last?.heardAt == 11, "each run keeps its own times")
restartLog.update(request: 1, text: "This is like the nouns", at: 12)
check(restartLog.passage(since: 0).hasSuffix("entities. This is like the nouns"), "the newest run still grows")
restartLog.update(request: 1, text: "Thus is like the nouns of", at: 13)
check(restartLog.passage(since: 0).hasSuffix("entities. Thus is like the nouns of"), "a revised first word is still the same run")

var phraseLog = LectureHeardWordLog()
phraseLog.update(request: 1, text: "one two", at: 1)
phraseLog.update(request: 1, text: "one two three four", at: 2)
let heardPhrases = phraseLog.phrases(since: 0, wordsPerPhrase: 3)
check(heardPhrases.count == 2 && heardPhrases[0].text == "one two three" && heardPhrases[0].startedAt == 1
      && heardPhrases[0].endedAt == 2 && heardPhrases[1].text == "four", "phrases carry their first and last word's time")

// A lecture heard playing from 1:00 to 2:00, paused, then rewound and
// played from 0:30 to 0:50, then 10:00 to 10:40 played much later.
var timeline = LectureHeardWordLog()
func say(_ request: Int, _ wordsPerSecond: [String], from wall: Double) {
    var text = ""
    for (offset, word) in wordsPerSecond.enumerated() {
        text += (text.isEmpty ? "" : " ") + word
        timeline.update(request: request, text: text, at: wall + Double(offset) + LectureHeardWordLog.recognitionLagSeconds)
    }
}
say(1, (60..<120).map { "a\($0)" }, from: 1000)          // video 60 to 119 heard at wall 1000 to 1059
for second in stride(from: 0.0, through: 60, by: 5) { timeline.noteAnchor(playbackSeconds: 60 + second, videoKey: "youtube:x", at: 1000 + second) }
say(2, (30..<50).map { "b\($0)" }, from: 1500)          // rewound: video 30 to 49 at wall 1500
for second in stride(from: 0.0, through: 20, by: 5) { timeline.noteAnchor(playbackSeconds: 30 + second, videoKey: "youtube:x", at: 1500 + second) }
say(3, (600..<640).map { "c\($0)" }, from: 9000)        // much later: 10:00 to 10:40
for second in stride(from: 0.0, through: 40, by: 5) { timeline.noteAnchor(playbackSeconds: 600 + second, videoKey: "youtube:x", at: 9000 + second) }
check(timeline.stretches(of: "youtube:x").count == 3, "a pause, a rewind and a jump make three stretches of playing")
let at1m44 = timeline.passage(endingAtPlayback: 104, videoKey: "youtube:x")
check(at1m44?.passage.hasPrefix("a60") == true && at1m44?.passage.hasSuffix("a104") == true,
      "asked at 1:44, paused long after: the minute before 1:44 (\(at1m44?.passage.prefix(12) ?? "none")...\(at1m44?.passage.suffix(5) ?? ""))")
let at0m50 = timeline.passage(endingAtPlayback: 50, videoKey: "youtube:x")
check(at0m50?.passage.hasPrefix("b30") == true && at0m50?.passage.contains("a") == false, "after the rewind: what was heard at 0:30 to 0:50")
check(timeline.passage(endingAtPlayback: 400, videoKey: "youtube:x") == nil, "a part never heard playing has no words")
check(timeline.passage(endingAtPlayback: 104, videoKey: "youtube:other") == nil, "another video's time has none of these words")
let at10m40 = timeline.passage(endingAtPlayback: 640, videoKey: "youtube:x")
check(at10m40?.passage.hasSuffix("c639") == true && at10m40?.secondsCovered == 40, "the latest stretch, covering forty seconds")
check(timeline.lastHeard()?.passage.hasSuffix("c639") == true, "with no player time, the last thing heard")
check(LectureVideoPage.key(pageURL: URL(string: "https://www.youtube.com/watch?v=fhdPyoO6aXI&t=104s"), windowTitle: nil) == "youtube:fhdPyoO6aXI",
      "the time in a YouTube link does not change the video")
var cappedLog = LectureHeardWordLog()
cappedLog.update(request: 1, text: Array(repeating: "w", count: LectureHeardWordLog.mostWordsKept + 50).joined(separator: " "), at: 1)
check(cappedLog.allWords.count == LectureHeardWordLog.mostWordsKept, "kept to the limit")
timeline.removeAll()
check(timeline.allWords.isEmpty && timeline.anchors.isEmpty, "emptied on request")

if ProcessInfo.processInfo.environment["LECTURE_CHECK_OFFLINE"] == nil {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        for (videoIdentifier, label) in [("ZA-tUyM_y7s", "MIT 6.006 lecture 1"), ("aircAruvnKk", "3Blue1Brown, neural networks"),
                                         ("rfscVS0vtbw", "freeCodeCamp Python course")] {
            let outcome = await YouTubeCaptions.fetchTranscript(videoIdentifier: videoIdentifier, preferredLanguageCodes: ["en-US"])
            print("live  \(label) (\(videoIdentifier)): \(outcome.summary)")
            if case .transcript(let cues, _) = outcome {
                let window = LectureTranscriptWindow.cuesBefore(playbackSeconds: 754, in: cues)
                print("      \(window.count) lines in the minute before 12:34")
            }
        }
        semaphore.signal()
    }
    semaphore.wait()
}

print(failures == 0 ? "\nall checks passed" : "\n\(failures) checks failed")
exit(failures == 0 ? 0 : 1)
