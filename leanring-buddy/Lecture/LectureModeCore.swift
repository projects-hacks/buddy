//
//  LectureModeCore.swift
//  leanring-buddy
//
//  The parts of lecture mode that touch nothing on the Mac: reading a
//  playback time out of text, finding a timestamped transcript in what a
//  page or the screen shows, deciding which apps and sites must never be
//  heard, cutting a transcript to the minute before a time, the note the
//  tutor is given, and the arithmetic of the rolling audio buffer.
//
//  Kept apart from the code that reads the screen and the audio so that
//  scripts/lecture_mode can compile and test it on its own, with sample
//  screen text and no permissions.
//

import Foundation

// MARK: - Playback time

/// Where a video player is: the time shown, and its length when the player
/// shows one (a live stream shows none).
nonisolated struct LecturePlaybackPosition: Equatable, Sendable {
    let currentSeconds: Int
    let totalSeconds: Int?
}

nonisolated enum LectureClock {
    /// "12:34" is 754 seconds, "1:02:03" is 3723. Nil for anything that is
    /// not a well formed clock, so "3:75" or "12" are never read as times.
    static func seconds(fromClockText clockText: String) -> Int? {
        let trimmedClockText = clockText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmedClockText.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 2, part.allSatisfy(\.isASCII), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        // The last two parts always have two digits ("1:05", never "1:5").
        guard parts[parts.count - 1].count == 2 else { return nil }
        if parts.count == 3 { guard parts[1].count == 2 else { return nil } }
        let secondsPart = numbers[numbers.count - 1]
        let minutesPart = numbers[numbers.count - 2]
        guard secondsPart < 60 else { return nil }
        if parts.count == 3 {
            guard minutesPart < 60 else { return nil }
            return numbers[0] * 3600 + minutesPart * 60 + secondsPart
        }
        return minutesPart * 60 + secondsPart
    }

    /// 754 is "12:34" and 3723 is "1:02:03", the way players write it.
    static func clockText(fromSeconds totalSeconds: Int) -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Reads a spoken duration at the start of a text, the way players
    /// describe time to screen readers: "12 Minutes 34 Seconds of 48 Minutes"
    /// or "2 minutes, 1 second because the". Returns the seconds and the text
    /// after the duration. Nil when the text does not start with one.
    static func spokenDurationPrefix(of text: String) -> (seconds: Int, remainingText: String)? {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }).map(String.init)
        var totalSeconds = 0
        var wordIndex = 0
        var unitsRead = 0
        while wordIndex + 1 < words.count {
            guard let number = Int(words[wordIndex]) else { break }
            let unitWord = words[wordIndex + 1].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",."))
            let secondsPerUnit: Int
            switch unitWord {
            case "hour", "hours": secondsPerUnit = 3600
            case "minute", "minutes": secondsPerUnit = 60
            case "second", "seconds": secondsPerUnit = 1
            default: secondsPerUnit = 0
            }
            guard secondsPerUnit > 0 else { break }
            totalSeconds += number * secondsPerUnit
            unitsRead += 1
            wordIndex += 2
            if wordIndex < words.count, words[wordIndex].lowercased() == "and" { wordIndex += 1 }
        }
        guard unitsRead > 0 else { return nil }
        let remainingText = words[wordIndex...].joined(separator: " ")
        return (totalSeconds, remainingText)
    }

    /// A time written either way: "12:34" or "12 Minutes 34 Seconds".
    static func seconds(fromClockOrSpokenText text: String) -> Int? {
        if let clockSeconds = seconds(fromClockText: text) { return clockSeconds }
        if let spoken = spokenDurationPrefix(of: text), spoken.remainingText.isEmpty { return spoken.seconds }
        return nil
    }

    /// Reads a seek bar's description for screen readers: YouTube's
    /// "12 Minutes 34 Seconds of 48 Minutes 10 Seconds", or the "1:23 of
    /// 10:45" of players built on video.js (Coursera, edX and many more).
    static func playbackPosition(fromSeekBarDescription seekBarDescription: String) -> LecturePlaybackPosition? {
        let halves = seekBarDescription.components(separatedBy: " of ")
        guard halves.count == 2,
              let currentSeconds = seconds(fromClockOrSpokenText: halves[0].trimmingCharacters(in: .whitespaces)),
              let totalSeconds = seconds(fromClockOrSpokenText: halves[1].trimmingCharacters(in: .whitespaces)),
              totalSeconds > 0, currentSeconds <= totalSeconds else { return nil }
        return LecturePlaybackPosition(currentSeconds: currentSeconds, totalSeconds: totalSeconds)
    }

    private static let currentSlashTotalPattern = try! NSRegularExpression(
        pattern: #"(?<![\d:])((?:\d{1,2}:)?\d{1,2}:\d{2})\s*/\s*((?:\d{1,2}:)?\d{1,2}:\d{2})(?![\d:])"#)

    /// The "12:34 / 48:10" every player shows under the video. Texts are
    /// tried alone and joined with their next one or two, because an
    /// accessibility tree often splits it as "12:34", "/", "48:10".
    /// The first plausible one wins: in a page the player comes first.
    static func playbackPosition(fromScreenTexts screenTexts: [String]) -> LecturePlaybackPosition? {
        for textIndex in screenTexts.indices {
            var joinedText = ""
            for offset in 0..<3 where textIndex + offset < screenTexts.count {
                joinedText += (offset == 0 ? "" : " ") + screenTexts[textIndex + offset]
                // A long text is a paragraph that happens to hold times, not a player.
                guard joinedText.count <= 80 else { break }
                if let position = currentSlashTotal(in: joinedText) { return position }
            }
        }
        return nil
    }

    private static func currentSlashTotal(in text: String) -> LecturePlaybackPosition? {
        let fullRange = NSRange(text.startIndex..., in: text)
        for match in currentSlashTotalPattern.matches(in: text, range: fullRange) {
            guard let currentRange = Range(match.range(at: 1), in: text),
                  let totalRange = Range(match.range(at: 2), in: text),
                  let currentSeconds = seconds(fromClockText: String(text[currentRange])),
                  let totalSeconds = seconds(fromClockText: String(text[totalRange])),
                  totalSeconds > 0, currentSeconds <= totalSeconds else { continue }
            return LecturePlaybackPosition(currentSeconds: currentSeconds, totalSeconds: totalSeconds)
        }
        return nil
    }

    /// Words players show while an advert plays. During one, the time on
    /// screen is the advert's, so no transcript line can be placed by it.
    static func showsAnAdvert(screenTexts: [String]) -> Bool {
        let advertPhrases = ["skip ad", "skip ads", "video will play after ad", "visit advertiser",
                             "ad 1 of", "ad 2 of", "ad 3 of", "ad will end in", "your video will begin in"]
        for screenText in screenTexts {
            let lowercasedText = screenText.lowercased().trimmingCharacters(in: .whitespaces)
            if lowercasedText.count > 60 { continue }
            if advertPhrases.contains(where: { lowercasedText.contains($0) }) { return true }
        }
        return false
    }
}

// MARK: - Transcripts

/// One line of a transcript: when it starts in the video, and what is said.
nonisolated struct TimedTranscriptCue: Equatable, Sendable {
    let startSeconds: Double
    let text: String
}

nonisolated enum LectureTranscriptWindow {
    /// How far back from the playback time the tutor is given.
    static let lookBackSeconds: Double = 60

    /// The lines said in the minute before `playbackSeconds`, oldest first.
    /// The line already being said at that moment is included, since that
    /// is often the very sentence the student is asking about.
    static func cuesBefore(playbackSeconds: Double, in cues: [TimedTranscriptCue],
                           lookBackSeconds: Double = lookBackSeconds) -> [TimedTranscriptCue] {
        let windowStart = playbackSeconds - lookBackSeconds
        return cues.filter { cue in cue.startSeconds >= windowStart && cue.startSeconds <= playbackSeconds + 1 }
    }

    /// The heard words from about a minute before the end of the audio,
    /// started at the beginning of a sentence when one begins within the
    /// 30 seconds before that, so the passage does not open mid-thought.
    /// Empty when nothing was said in that minute.
    static func lastMinute(ofTimedWords timedWords: [(word: String, startSeconds: Double)],
                           audioDurationSeconds: Double) -> String {
        let cutoffSeconds = audioDurationSeconds - lookBackSeconds
        guard var firstIndex = timedWords.firstIndex(where: { $0.startSeconds >= cutoffSeconds }) else { return "" }
        var searchIndex = firstIndex
        while searchIndex > 0, timedWords[searchIndex].startSeconds >= cutoffSeconds - 30 {
            let previousWord = timedWords[searchIndex - 1].word
            if previousWord.hasSuffix(".") || previousWord.hasSuffix("?") || previousWord.hasSuffix("!") {
                firstIndex = searchIndex
                break
            }
            searchIndex -= 1
        }
        return timedWords[firstIndex...].map(\.word).joined(separator: " ")
    }

    /// The lines as one passage. Auto-generated captions repeat the end of
    /// one line at the start of the next; those repeats are dropped.
    static func passage(from cues: [TimedTranscriptCue]) -> String {
        var passageWords: [String] = []
        for cue in cues {
            let cueWords = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
            var overlapLength = min(cueWords.count, passageWords.count, 8)
            while overlapLength > 0 {
                let passageTail = passageWords.suffix(overlapLength).map { $0.lowercased() }
                let cueHead = cueWords.prefix(overlapLength).map { $0.lowercased() }
                if passageTail == cueHead { break }
                overlapLength -= 1
            }
            passageWords.append(contentsOf: cueWords.dropFirst(overlapLength))
        }
        return passageWords.joined(separator: " ")
    }
}

/// Finds a timestamped transcript among the texts of a page or a screen.
///
/// YouTube's transcript panel, Coursera's interactive transcript, Khan
/// Academy's and LinkedIn Learning's all show a time before each line. What
/// separates a transcript from other times on a page (video lengths beside
/// recommendations, chapter lists) is that its times climb steadily a few
/// seconds apart, so that is what is looked for.
nonisolated enum LectureTranscriptFinder {
    /// What one text is, for the purpose of finding cues.
    enum TranscriptItem: Equatable {
        /// "2:01" alone, or Coursera's "Play video starting at 2 minutes 1 second".
        case timestampOnly(seconds: Int)
        /// A time and the words together: "2:01 because the" or, from a
        /// screen reader label, "2 minutes, 1 second because the".
        case timestampedText(seconds: Int, text: String)
        case plainText(String)
    }

    static func classify(_ itemText: String) -> TranscriptItem {
        let trimmedText = itemText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let clockSeconds = LectureClock.seconds(fromClockText: trimmedText) {
            return .timestampOnly(seconds: clockSeconds)
        }
        let lowercasedText = trimmedText.lowercased()
        let courseraPrefix = "play video starting at "
        if lowercasedText.hasPrefix(courseraPrefix),
           let spoken = LectureClock.spokenDurationPrefix(of: String(trimmedText.dropFirst(courseraPrefix.count))) {
            return .timestampOnly(seconds: spoken.seconds)
        }
        // "2:01 because the" as one recognised line.
        if let firstSpace = trimmedText.firstIndex(of: " ") {
            let leadingWord = String(trimmedText[..<firstSpace])
            let rest = String(trimmedText[firstSpace...]).trimmingCharacters(in: .whitespaces)
            if let clockSeconds = LectureClock.seconds(fromClockText: leadingWord), !rest.isEmpty,
               !rest.hasPrefix("/"), !rest.hasPrefix("of ") {
                return .timestampedText(seconds: clockSeconds, text: rest)
            }
        }
        // A screen reader label: the duration then a comma or the words.
        if let spoken = LectureClock.spokenDurationPrefix(of: trimmedText), !spoken.remainingText.isEmpty,
           !spoken.remainingText.lowercased().hasPrefix("of "),
           !spoken.remainingText.lowercased().hasPrefix("ago") {
            return .timestampedText(seconds: spoken.seconds, text: spoken.remainingText)
        }
        return .plainText(trimmedText)
    }

    /// Builds cues from texts in reading order: each time takes the words
    /// after it up to the next time. Then keeps the longest run that reads
    /// like a transcript, or nothing.
    static func transcriptCues(inReadingOrder itemTexts: [String]) -> [TimedTranscriptCue] {
        var cues: [TimedTranscriptCue] = []
        var openCueStart: Int?
        var openCueWords: [String] = []

        func closeOpenCue() {
            if let openCueStart {
                let cueText = openCueWords.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !cueText.isEmpty { cues.append(TimedTranscriptCue(startSeconds: Double(openCueStart), text: cueText)) }
            }
            openCueStart = nil
            openCueWords = []
        }

        for itemText in itemTexts {
            switch classify(itemText) {
            case .timestampOnly(let seconds):
                // A screen reader label already opened this same line: its
                // visible time follows and repeats it.
                if openCueStart == seconds { continue }
                closeOpenCue()
                openCueStart = seconds
            case .timestampedText(let seconds, let text):
                closeOpenCue()
                openCueStart = seconds
                openCueWords = [text]
            case .plainText(let text):
                guard openCueStart != nil, !text.isEmpty else { continue }
                // The same words twice in a row: a label and its visible text.
                if openCueWords.last == text || (text.count >= 8 && openCueWords.joined(separator: " ").hasSuffix(text)) { continue }
                openCueWords.append(text)
            }
        }
        closeOpenCue()
        return mergeRepeatedStarts(cues).bestTranscriptRun()
    }

    /// One line read twice (its label, then its visible text) becomes one.
    private static func mergeRepeatedStarts(_ cues: [TimedTranscriptCue]) -> [TimedTranscriptCue] {
        var merged: [TimedTranscriptCue] = []
        for cue in cues {
            if let previous = merged.last, previous.startSeconds == cue.startSeconds {
                if cue.text.count > previous.text.count { merged[merged.count - 1] = cue }
                continue
            }
            merged.append(cue)
        }
        return merged
    }

    /// The fewest lines that count as a transcript rather than a coincidence.
    static let minimumCuesInTranscript = 6

    /// Lines from recognised screen text, using where each one sits: a
    /// transcript is a column of times with the words beside or under each.
    /// `listing` is the screen index's "id [x, y, w, h] text" lines.
    static func transcriptCues(inScreenListing listing: String) -> [TimedTranscriptCue] {
        let listedTexts = ListedScreenText.parse(listing: listing)
        var timestampTexts: [(text: ListedScreenText, seconds: Int, inlineText: String?)] = []
        for listedText in listedTexts {
            switch classify(listedText.text) {
            case .timestampOnly(let seconds): timestampTexts.append((listedText, seconds, nil))
            case .timestampedText(let seconds, let text): timestampTexts.append((listedText, seconds, text))
            case .plainText: continue
            }
        }
        // The column holding the most times is the transcript's.
        var bestColumn: [(text: ListedScreenText, seconds: Int, inlineText: String?)] = []
        for candidate in timestampTexts {
            let column = timestampTexts.filter { abs($0.text.x - candidate.text.x) <= 16 }
            if column.count > bestColumn.count { bestColumn = column }
        }
        guard bestColumn.count >= 4 else { return [] }
        bestColumn.sort { $0.text.y < $1.text.y }
        let columnX = bestColumn.map(\.text.x).min() ?? 0

        var cues: [TimedTranscriptCue] = []
        for (entryIndex, entry) in bestColumn.enumerated() {
            let nextEntryY = entryIndex + 1 < bestColumn.count ? bestColumn[entryIndex + 1].text.y : entry.text.y + 4 * max(entry.text.height, 20)
            let wordsBesideOrUnder = listedTexts
                .filter { other in
                    other.y >= entry.text.y - 6 && other.y < nextEntryY - 6
                        && other.x >= columnX - 16 && other.x <= columnX + 420
                        && !bestColumn.contains(where: { $0.text == other })
                }
                .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
                .map(\.text)
            let cueText = ([entry.inlineText].compactMap { $0 } + wordsBesideOrUnder).joined(separator: " ")
            if !cueText.isEmpty { cues.append(TimedTranscriptCue(startSeconds: Double(entry.seconds), text: cueText)) }
        }
        return cues.bestTranscriptRun(minimumCues: 4)
    }
}

/// One line of the screen index listing, with its box in screenshot pixels.
nonisolated struct ListedScreenText: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let text: String

    private static let listingLinePattern = try! NSRegularExpression(
        pattern: #"^\S+ \[(-?\d+), (-?\d+), (\d+), (\d+)\] (.*)$"#)

    static func parse(listing: String) -> [ListedScreenText] {
        listing.split(separator: "\n").compactMap { line in
            let lineText = String(line)
            let fullRange = NSRange(lineText.startIndex..., in: lineText)
            guard let match = listingLinePattern.firstMatch(in: lineText, range: fullRange) else { return nil }
            func group(_ groupIndex: Int) -> String {
                guard let range = Range(match.range(at: groupIndex), in: lineText) else { return "" }
                return String(lineText[range])
            }
            guard let x = Int(group(1)), let y = Int(group(2)), let width = Int(group(3)), let height = Int(group(4)) else { return nil }
            return ListedScreenText(x: x, y: y, width: width, height: height, text: group(5))
        }
    }

    /// Only the words, for the time and advert checks.
    static func texts(inListing listing: String) -> [String] {
        parse(listing: listing).map(\.text)
    }
}

nonisolated extension Array where Element == TimedTranscriptCue {
    /// The longest stretch whose times climb a few seconds apart, the way
    /// a transcript's do. Fewer than `minimumCues` lines is not a transcript.
    func bestTranscriptRun(minimumCues: Int = LectureTranscriptFinder.minimumCuesInTranscript) -> [TimedTranscriptCue] {
        var bestRun: [TimedTranscriptCue] = []
        var currentRun: [TimedTranscriptCue] = []
        for cue in self {
            if let previous = currentRun.last,
               cue.startSeconds < previous.startSeconds || cue.startSeconds - previous.startSeconds > 120 {
                if currentRun.count > bestRun.count { bestRun = currentRun }
                currentRun = []
            }
            currentRun.append(cue)
        }
        if currentRun.count > bestRun.count { bestRun = currentRun }
        guard bestRun.count >= minimumCues else { return [] }

        let gaps = zip(bestRun.dropFirst(), bestRun).map { later, earlier in later.startSeconds - earlier.startSeconds }.sorted()
        let medianGap = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
        let averageTextLength = Double(bestRun.map(\.text.count).reduce(0, +)) / Double(bestRun.count)
        // Chapter lists are minutes apart; captions a few seconds, and a
        // paragraph-style transcript (Coursera) under a minute.
        guard medianGap <= 45, averageTextLength <= 400 else { return [] }
        return bestRun
    }
}

// MARK: - Video pages

nonisolated enum LectureVideoPage {
    /// The eleven-character video id of a YouTube watch, live, embed or
    /// short link. Nil for any other page, YouTube Music included.
    static func youTubeVideoIdentifier(from pageURL: URL) -> String? {
        guard let host = pageURL.host?.lowercased() else { return nil }
        let pathParts = pageURL.path.split(separator: "/").map(String.init)
        var candidate: String?
        if host == "youtu.be" {
            candidate = pathParts.first
        } else if host == "youtube.com" || host == "www.youtube.com" || host == "m.youtube.com"
                    || host == "youtube-nocookie.com" || host == "www.youtube-nocookie.com" {
            if pathParts.first == "watch" {
                candidate = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "v" })?.value
            } else if pathParts.count >= 2, ["live", "embed", "shorts", "v"].contains(pathParts[0]) {
                candidate = pathParts[1]
            }
        }
        guard let candidate, candidate.count == 11,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return candidate
    }

    /// An address bar's text as a URL. Address bars often leave out the
    /// scheme ("youtube.com/watch?v=..."), and a search typed there is not one.
    static func pageURL(fromAddressBarText addressBarText: String) -> URL? {
        let trimmedText = addressBarText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !trimmedText.contains(" ") else { return nil }
        let withScheme = trimmedText.contains("://") ? trimmedText : "https://" + trimmedText
        guard let url = URL(string: withScheme), let host = url.host, host.contains(".") else { return nil }
        return url
    }
}

// MARK: - Never heard

/// Apps and sites whose sound lecture mode never captures or transcribes.
///
/// Calls and meetings carry other people's voices, who have not agreed to
/// be recorded, so they are out whatever else is true. Music is out because
/// it is not a lecture and transcribing it would only spend the student's
/// money. Any app that is using a microphone is also treated as a call; that
/// check is made where the audio is, in `LectureAudioBuffer`.
nonisolated enum LectureCaptureExclusions {
    static let callAppBundleIdentifiers: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.apple.FaceTime",
        "com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary", "com.tinyspeck.slackmacgap",
        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager", "Cisco-Systems.Spark",
        "com.skype.skype", "com.microsoft.SkypeForBusiness", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "org.whispersystems.signal-desktop",
        "com.apple.MobileSMS", "com.logmein.GoToMeeting", "com.logmein.goto", "com.ringcentral.glip",
        "com.amazon.Amazon-Chime", "com.tencent.xinWeChat", "jp.naver.line.mac", "com.viber.osx",
        "im.riot.app", "app.tuple.app", "co.teamport.around", "com.bluejeansnet.Blue", "com.electron.lark"
    ]

    static let musicAppBundleIdentifiers: Set<String> = [
        "com.apple.Music", "com.apple.iTunes", "com.spotify.client", "com.tidal.desktop",
        "com.deezer.deezer-desktop", "com.amazon.music", "com.pandora.desktop"
    ]

    /// For apps known only by name, such as a meeting site installed as a
    /// web app ("Google Meet" from Chrome has a generated bundle identifier).
    static let callAppNameWords = ["zoom", "teams", "google meet", "facetime", "discord", "slack", "webex",
                                   "skype", "whatsapp", "telegram", "signal", "gotomeeting", "chime", "whereby"]

    /// Host, and the start of the path when only part of a site is a call.
    static let callSites: [(host: String, pathPrefix: String)] = [
        ("meet.google.com", ""), ("teams.microsoft.com", ""), ("teams.live.com", ""), ("teams.cloud.microsoft", ""),
        ("zoom.us", "/wc"), ("zoom.us", "/j/"), ("app.zoom.us", ""), ("webex.com", ""), ("discord.com", ""),
        ("app.slack.com", ""), ("web.whatsapp.com", ""), ("web.skype.com", ""), ("whereby.com", ""),
        ("meet.jit.si", ""), ("8x8.vc", ""), ("gather.town", ""), ("around.co", ""), ("web.telegram.org", ""),
        ("messenger.com", ""), ("facetime.apple.com", ""), ("app.chime.aws", ""), ("meet.goto.com", ""),
        ("app.gotomeeting.com", ""), ("bluejeans.com", "")
    ]

    static let musicSites = ["music.youtube.com", "open.spotify.com", "music.apple.com", "soundcloud.com",
                             "tidal.com", "deezer.com", "pandora.com", "bandcamp.com", "music.amazon.com"]

    /// Window titles that mean a meeting, used only when the page's address
    /// cannot be read (a video titled "Slack tips" is not a huddle).
    static let callWindowTitleWords = ["meet - ", "google meet", "microsoft teams", "zoom meeting", "zoom workplace",
                                       "webex", "huddle", "facetime", "whatsapp", "discord"]

    /// Why this app or page must not be heard, or nil when it may be.
    static func reasonToExclude(bundleIdentifier: String?, applicationName: String?,
                                windowTitle: String?, pageURL: URL?) -> String? {
        if let bundleIdentifier {
            if callAppBundleIdentifiers.contains(bundleIdentifier) { return "a call or chat app" }
            if musicAppBundleIdentifiers.contains(bundleIdentifier) { return "a music app" }
        }
        let lowercasedName = (applicationName ?? "").lowercased()
        if callAppNameWords.contains(where: { lowercasedName.contains($0) }) { return "a call or chat app" }

        if let pageURL, let host = pageURL.host?.lowercased() {
            let path = pageURL.path.lowercased()
            for callSite in callSites where host == callSite.host || host.hasSuffix("." + callSite.host) {
                if callSite.pathPrefix.isEmpty || path.hasPrefix(callSite.pathPrefix) { return "a meeting in the browser" }
            }
            for musicSite in musicSites where host == musicSite || host.hasSuffix("." + musicSite) {
                return "a music site"
            }
            return nil
        }
        let lowercasedTitle = (windowTitle ?? "").lowercased()
        if callWindowTitleWords.contains(where: { lowercasedTitle.contains($0) }) { return "a meeting in the browser" }
        return nil
    }
}

// MARK: - When the sound may be sent

/// Whether a question may have the front app's buffered sound transcribed
/// (sent to Deepgram when a key is set) and the words added to the prompt.
///
/// Only with evidence that the question is about a lecture: a player's
/// time was read from the page or the screen, or the student asked about
/// what was said. Anything else that happens to be playing (music in
/// another tab while they ask about code) is never sent and never added.
nonisolated enum LectureAudioGate {
    static func maySendSound(playbackPosition: LecturePlaybackPosition?, question: String) -> Bool {
        playbackPosition != nil || questionIsAboutWhatWasSaid(question)
    }

    /// Phrases that only make sense about someone speaking. Kept narrow on
    /// purpose: "what does this error mean" is not about a lecture.
    static func questionIsAboutWhatWasSaid(_ question: String) -> Bool {
        let lowercasedQuestion = " " + question.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "?", with: " ")
            .replacingOccurrences(of: ",", with: " ") + " "
        let phrases = [" he said", " she said", " they said", " just said", " was said", " he say", " she say",
                       " he's saying", " she's saying", " he is saying", " she is saying", " they're saying",
                       " did he mean", " does he mean", " did she mean", " does she mean", " did they mean",
                       " he meant", " she meant", " he means", " she means", " he just", " she just",
                       " lecturer", " professor", " instructor", " teacher", " speaker",
                       " the video", " this video", " the lecture", " this lecture", " the talk",
                       " explain what he", " explain what she", " explain what they", " just explained",
                       " he explained", " she explained", " went over", " he mentioned", " she mentioned",
                       " what was that", " he's talking about", " she's talking about"]
        return phrases.contains { lowercasedQuestion.contains($0) }
    }
}

// MARK: - The note for the tutor

nonisolated enum LectureNote {
    /// The whole note stays under this, so a lecture never crowds out the screen.
    static let maximumCharacters = 1500

    /// Said once, after the words, so the model knows whose words they are.
    private static let guidance = "these are the lecturer's own words just before the student asked, not the student's. when they ask what was said or meant (\"what did he mean\", \"explain what she just said\"), answer from these words, quote a few of them, and tie them to what is on screen. if the question is about something else, ignore this."

    /// From a transcript placed by the playback time.
    static func transcriptNote(passage: String, playbackSeconds: Int, sourceDescription: String) -> String {
        let heading = "LECTURE, last 60 seconds before \(LectureClock.clockText(fromSeconds: playbackSeconds)) (\(sourceDescription)):"
        return assemble(heading: heading, passage: passage)
    }

    /// From the video's own sound, transcribed now.
    static func heardNote(passage: String, secondsCovered: Int, heardBy: String) -> String {
        let heading = "LECTURE, about the last \(secondsCovered) seconds of the video's sound (transcribed by \(heardBy), so a term may be misheard):"
        return assemble(heading: heading, passage: passage)
    }

    /// When macOS has just asked the student to let Buddy hear the video.
    static let permissionJustAskedNote = "LECTURE: you cannot hear the video in front of them yet. macOS is asking them right now to let Buddy hear the sound of the app in front. if their question needs what the lecturer just said, answer from the screen and say in one short sentence that once they allow it you will know what was just said."

    private static func assemble(heading: String, passage: String) -> String {
        let spaceForPassage = maximumCharacters - heading.count - guidance.count - 8
        var quotedPassage = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        if quotedPassage.count > spaceForPassage {
            // The newest words matter most: the cut is made at the start,
            // on a word boundary.
            let keptTail = String(quotedPassage.suffix(max(0, spaceForPassage - 3)))
            let fromFirstWholeWord = keptTail.firstIndex(of: " ").map { keptTail[keptTail.index(after: $0)...] } ?? Substring(keptTail)
            quotedPassage = "..." + fromFirstWholeWord
        }
        return heading + "\n\"" + quotedPassage + "\"\n" + guidance
    }
}

// MARK: - Rolling audio buffer

/// The last stretch of one app's sound, 16 kHz mono, in memory only.
///
/// A fixed ring of samples: writing past the end wraps to the start, so
/// the oldest sound is overwritten continuously and the buffer never grows.
/// Written from Core Audio's thread and read on the main thread, so every
/// access takes the lock.
nonisolated final class LectureAudioRingBuffer: @unchecked Sendable {
    let sampleRate: Int
    let capacityInSamples: Int
    private var samples: [Int16]
    private var nextWriteIndex = 0
    private var storedSampleCount = 0
    private let lock = NSLock()

    init(sampleRate: Int, capacitySeconds: Double) {
        self.sampleRate = sampleRate
        self.capacityInSamples = max(1, Int(Double(sampleRate) * capacitySeconds))
        self.samples = [Int16](repeating: 0, count: capacityInSamples)
    }

    func append(_ newSamples: [Int16]) {
        guard !newSamples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        // More than the whole ring at once: only its newest part can survive.
        let samplesToWrite = newSamples.count > capacityInSamples ? Array(newSamples.suffix(capacityInSamples)) : newSamples
        var readIndex = 0
        while readIndex < samplesToWrite.count {
            let roomBeforeWrap = capacityInSamples - nextWriteIndex
            let chunkLength = min(roomBeforeWrap, samplesToWrite.count - readIndex)
            samples.replaceSubrange(nextWriteIndex..<(nextWriteIndex + chunkLength),
                                    with: samplesToWrite[readIndex..<(readIndex + chunkLength)])
            readIndex += chunkLength
            nextWriteIndex = (nextWriteIndex + chunkLength) % capacityInSamples
        }
        storedSampleCount = min(capacityInSamples, storedSampleCount + samplesToWrite.count)
    }

    /// The newest `seconds` of sound, oldest sample first.
    func newestSamples(seconds: Double) -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        let wantedCount = min(storedSampleCount, Int(seconds * Double(sampleRate)))
        guard wantedCount > 0 else { return [] }
        let startIndex = (nextWriteIndex - wantedCount + capacityInSamples) % capacityInSamples
        if startIndex + wantedCount <= capacityInSamples {
            return Array(samples[startIndex..<(startIndex + wantedCount)])
        }
        return Array(samples[startIndex..<capacityInSamples]) + Array(samples[0..<(wantedCount - (capacityInSamples - startIndex))])
    }

    var storedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(storedSampleCount) / Double(sampleRate)
    }

    /// Forgets everything, which is what happens whenever the app in front
    /// changes or turns out to be a call.
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        nextWriteIndex = 0
        storedSampleCount = 0
    }

    /// How many seconds hold sound rather than silence, counted in tenths
    /// of a second. Protected video often reaches a tap as pure silence,
    /// and a buffer of silence is not worth transcribing.
    static func secondsWithSound(in samples: [Int16], sampleRate: Int) -> Double {
        let windowLength = max(1, sampleRate / 10)
        var loudWindowCount = 0
        var windowStart = 0
        while windowStart + windowLength <= samples.count {
            var sumOfSquares = 0.0
            for sampleIndex in windowStart..<(windowStart + windowLength) {
                let sampleValue = Double(samples[sampleIndex])
                sumOfSquares += sampleValue * sampleValue
            }
            let rootMeanSquare = (sumOfSquares / Double(windowLength)).squareRoot()
            if rootMeanSquare > 200 { loudWindowCount += 1 }
            windowStart += windowLength
        }
        return Double(loudWindowCount) / 10
    }
}

/// Turns a tap's mono float samples at its own rate (usually 48 kHz) into
/// 16 kHz Int16, which is all speech recognition needs and a third of the memory.
///
/// Each output sample is the average of the input samples it covers, which
/// also takes off the highest frequencies before they could fold back as
/// noise. The rate rarely divides evenly (44.1 kHz), so the boundary
/// between output samples is tracked as a fraction across calls.
nonisolated final class LectureAudioDownsampler {
    let sourceSampleRate: Double
    let targetSampleRate: Double
    private var sumOfCurrentOutputSample = 0.0
    private var inputSamplesInCurrentOutputSample = 0
    private var inputPositionInCurrentOutputSample = 0.0

    init(sourceSampleRate: Double, targetSampleRate: Double) {
        self.sourceSampleRate = sourceSampleRate
        self.targetSampleRate = targetSampleRate
    }

    func downsample(_ monoSamples: UnsafeBufferPointer<Float>) -> [Int16] {
        let inputSamplesPerOutputSample = sourceSampleRate / targetSampleRate
        var outputSamples: [Int16] = []
        outputSamples.reserveCapacity(Int(Double(monoSamples.count) / inputSamplesPerOutputSample) + 2)
        for inputSample in monoSamples {
            sumOfCurrentOutputSample += Double(inputSample)
            inputSamplesInCurrentOutputSample += 1
            inputPositionInCurrentOutputSample += 1
            if inputPositionInCurrentOutputSample >= inputSamplesPerOutputSample {
                let averagedSample = sumOfCurrentOutputSample / Double(inputSamplesInCurrentOutputSample)
                let clampedSample = max(-1.0, min(1.0, averagedSample))
                outputSamples.append(Int16(clampedSample * Double(Int16.max)))
                sumOfCurrentOutputSample = 0
                inputSamplesInCurrentOutputSample = 0
                inputPositionInCurrentOutputSample -= inputSamplesPerOutputSample
            }
        }
        return outputSamples
    }

    func downsample(_ monoSamples: [Float]) -> [Int16] {
        monoSamples.withUnsafeBufferPointer { downsample($0) }
    }
}
