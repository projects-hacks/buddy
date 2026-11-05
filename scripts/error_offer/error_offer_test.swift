//
//  error_offer_test.swift
//
//  Grades the error recognizer that decides when the notch offers to
//  explain an error, on the fixtures in fixtures/, and times it.
//
//    grade    precision and recall on the text fixtures, where each error
//             points, the dedupe, and the accessibility read range
//    vision   the same fixtures drawn as window-sized images and read back
//             with text recognition, as the watcher reads apps that expose
//             no text: recall through recognition, and CPU time per check
//
//  Built together with the app's own ErrorRecognizer.swift and
//  ErrorWindowReading.swift, so what is graded is what ships.
//

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Fixture {
    let name: String
    /// "terminal", "editor", "xcode", "judgeSite", "browserDeveloperTools",
    /// or "browser" for a page the watcher never reads.
    let placeName: String
    let expectedCause: String?
    let lines: [String]

    var place: ErrorReadingPlace? { ErrorReadingPlace(rawValue: placeName) }
}

func loadFixtures(_ path: String) -> [Fixture] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fatalError("cannot read \(path)")
    }
    var fixtures: [Fixture] = []
    var currentHeader: String?
    var currentLines: [String] = []
    func finish() {
        guard let header = currentHeader else { return }
        // "### name [place] cause=file:line"
        let afterHashes = header.dropFirst(4)
        let name = String(afterHashes.prefix { $0 != " " })
        let placeName = header.range(of: #"\[(\w+)\]"#, options: .regularExpression).map {
            String(header[$0].dropFirst().dropLast())
        } ?? "terminal"
        let expectedCause = header.range(of: #"cause=(.+)$"#, options: .regularExpression).map {
            String(header[$0].dropFirst("cause=".count))
        }
        fixtures.append(Fixture(name: name, placeName: placeName, expectedCause: expectedCause, lines: currentLines))
    }
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("### ") {
            finish()
            currentHeader = line
            currentLines = []
        } else {
            currentLines.append(line)
        }
    }
    finish()
    return fixtures.map { fixture in
        var lines = fixture.lines
        while lines.last?.isEmpty == true { lines.removeLast() }
        return Fixture(name: fixture.name, placeName: fixture.placeName, expectedCause: fixture.expectedCause, lines: lines)
    }
}

/// The watcher's decision: a page it never reads never glows.
func decision(for fixture: Fixture, lines: [String]) -> RecognizedError? {
    guard let place = fixture.place else { return nil }
    return ErrorRecognizer.recognize(lines: lines, place: place)
}

func causeMatches(_ recognized: RecognizedError, expected: String) -> Bool {
    if expected.hasPrefix("line ") {
        return recognized.causeLineNumber == Int(expected.dropFirst(5))
    }
    let parts = expected.split(separator: ":")
    guard parts.count == 2, let expectedLine = Int(parts[1]) else { return false }
    return (recognized.causeFileName ?? "").hasSuffix(String(parts[0])) && recognized.causeLineNumber == expectedLine
}

func processCPUSeconds() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
}

func percent(_ part: Int, _ whole: Int) -> String {
    whole == 0 ? "n/a" : String(format: "%.1f%%", 100 * Double(part) / Double(whole))
}

// MARK: - grade

func runGrade(fixturesDirectory: String, setPrefix: String) {
    let shouldGlow = loadFixtures(fixturesDirectory + "/" + setPrefix + "should_glow.txt")
    let shouldNotGlow = loadFixtures(fixturesDirectory + "/" + setPrefix + "should_not_glow.txt")
    print("Fixtures: \(shouldGlow.count) should glow, \(shouldNotGlow.count) should not\n")

    var truePositives = 0
    var causesExpected = 0
    var causesRight = 0
    var positiveFingerprints: [String: String] = [:]
    for fixture in shouldGlow {
        let recognized = decision(for: fixture, lines: fixture.lines)
        if let recognized {
            truePositives += 1
            let message = fixture.lines[recognized.messageLineIndex].trimmingCharacters(in: .whitespaces)
            var causeNote = ""
            if let expected = fixture.expectedCause {
                causesExpected += 1
                if causeMatches(recognized, expected: expected) {
                    causesRight += 1
                } else {
                    causeNote = "   CAUSE WRONG: got \(recognized.causeFileName ?? "none"):\(recognized.causeLineNumber.map(String.init) ?? "-"), wanted \(expected)"
                }
            }
            print("  glow  \(fixture.name): \(recognized.kind.rawValue): \(message.prefix(70))\(causeNote)")
            if let other = positiveFingerprints[recognized.fingerprint] {
                print("        FINGERPRINT SHARED with \(other)")
            }
            positiveFingerprints[recognized.fingerprint] = fixture.name
        } else {
            print("  MISS  \(fixture.name)")
        }
    }

    var falsePositives = 0
    var falsePositivesWithoutTheAppGate = 0
    for fixture in shouldNotGlow {
        if let recognized = decision(for: fixture, lines: fixture.lines) {
            falsePositives += 1
            print("  FALSE GLOW  \(fixture.name): \(recognized.kind.rawValue): \(fixture.lines[recognized.messageLineIndex].prefix(70))")
        }
        // The same text if the page were read anyway, as an editor.
        if fixture.place == nil, ErrorRecognizer.recognize(lines: fixture.lines, place: .editor) != nil {
            falsePositivesWithoutTheAppGate += 1
            print("  (\(fixture.name) would glow if its app were watched; the watcher does not read ordinary web pages)")
        }
    }

    let precision = Double(truePositives) / Double(max(1, truePositives + falsePositives))
    let recall = Double(truePositives) / Double(max(1, shouldGlow.count))
    print("")
    print("Recall:    \(truePositives) of \(shouldGlow.count) (\(percent(truePositives, shouldGlow.count)))")
    print("Precision: \(truePositives) of \(truePositives + falsePositives) (\(String(format: "%.1f%%", precision * 100)))")
    print("False glows on near misses: \(falsePositives) of \(shouldNotGlow.count)")
    print("Near misses that only the app gate stops: \(falsePositivesWithoutTheAppGate)")
    print("Points at the right file and line: \(causesRight) of \(causesExpected)")
    _ = recall

    // Dedupe: the same error read again, with different timings and
    // addresses, must not glow a second time.
    var seen = SeenErrorFingerprints()
    var glowedTwice: [String] = []
    for fixture in shouldGlow {
        guard let first = decision(for: fixture, lines: fixture.lines) else { continue }
        _ = seen.insertIfNew(first.fingerprint)
        let rerunLines = fixture.lines.map { line in
            line.replacingOccurrences(of: #"\d+\.\d+"#, with: "9.87", options: .regularExpression)
                .replacingOccurrences(of: #"0x[0-9a-f]+"#, with: "0xdeadbeef", options: .regularExpression)
        }
        if let again = decision(for: fixture, lines: rerunLines), seen.insertIfNew(again.fingerprint) {
            glowedTwice.append(fixture.name)
        }
    }
    print("Same error re-read with new timings and addresses, glowed again: \(glowedTwice.count)\(glowedTwice.isEmpty ? "" : " " + glowedTwice.joined(separator: ", "))")
    print("Distinct errors sharing a fingerprint: \(shouldGlow.count - positiveFingerprints.count - (shouldGlow.count - truePositives))")

    // The accessibility path reads only what was printed after Return and
    // is on screen now.
    let scrolledBack = ErrorWindowReading.rangeToRead(characterCountAtTrigger: 10_000,
                                                      visibleRange: NSRange(location: 2_000, length: 3_000),
                                                      currentCharacterCount: 10_400)
    let freshOutput = ErrorWindowReading.rangeToRead(characterCountAtTrigger: 10_000,
                                                     visibleRange: NSRange(location: 7_400, length: 3_000),
                                                     currentCharacterCount: 10_400)
    let afterClear = ErrorWindowReading.rangeToRead(characterCountAtTrigger: 10_000,
                                                    visibleRange: NSRange(location: 0, length: 600),
                                                    currentCharacterCount: 600)
    print("Accessibility read range: scrolled back to old output reads \(scrolledBack.length) characters, new output reads \(freshOutput.length) of 400, after clear reads \(afterClear.length) of 600")

    // Cost of the recognizer itself, per check, on the longest fixtures.
    let allLines = (shouldGlow + shouldNotGlow).map(\.lines)
    let started = processCPUSeconds()
    let repetitions = 200
    for _ in 0..<repetitions {
        for lines in allLines { _ = ErrorRecognizer.recognize(lines: lines, place: .terminal) }
    }
    let cpuPerCheck = (processCPUSeconds() - started) / Double(repetitions * allLines.count)
    print(String(format: "Recognizer CPU per check: %.3f ms (average over %d fixtures, %d lines on average)",
                 cpuPerCheck * 1000, allLines.count, allLines.map(\.count).reduce(0, +) / allLines.count))
    let screenful = Array(repeating: shouldGlow[0].lines, count: 8).flatMap { $0 }
    let screenfulStarted = processCPUSeconds()
    for _ in 0..<200 { _ = ErrorRecognizer.recognize(lines: screenful, place: .terminal) }
    print(String(format: "Recognizer CPU on a %d-line window: %.3f ms", screenful.count, (processCPUSeconds() - screenfulStarted) / 200 * 1000))
}

// MARK: - vision

/// Earlier output above the error, so the window is full the way a real
/// one is and recognition has a whole window to read.
let fillerLines = [
    "Last login: Mon Mar  2 09:58:12 on ttys002",
    "% ls -la",
    "total 48",
    "drwxr-xr-x   9 student  staff   288 Mar  2 09:58 .",
    "drwxr-xr-x  14 student  staff   448 Mar  1 18:20 ..",
    "-rw-r--r--   1 student  staff  1204 Mar  2 09:41 README.md",
    "-rw-r--r--   1 student  staff   812 Mar  2 09:55 main.py",
    "drwxr-xr-x   4 student  staff   128 Mar  2 09:12 tests",
    "% git status",
    "On branch main",
    "Your branch is up to date with 'origin/main'.",
    "nothing to commit, working tree clean",
    "% echo $SHELL",
    "/bin/zsh",
    "% which python3 node cargo go",
    "/opt/homebrew/bin/python3",
    "/opt/homebrew/bin/node",
    "/Users/student/.cargo/bin/cargo",
    "/opt/homebrew/bin/go",
    "% date",
    "Mon Mar  2 10:00:01 PST 2026",
    "% cat notes.md",
    "# Study plan",
    "- finish the linked list exercises",
    "- read chapter 4 on recursion",
    "- practice two pointer problems",
    "% pwd",
    "/Users/student/projects/study",
    "% clear",
    "% history | tail -3",
    "  101  git pull",
    "  102  ls",
    "  103  code ."
]

/// A 1200 x 800 point window at Retina scale, the size of a terminal or
/// editor taking most of a laptop screen.
let windowWidthInPixels = 2400
let windowHeightInPixels = 1600

/// The window image, the band of rows the fixture's own lines are in,
/// and the pixel row each of those lines was drawn in, for checking which
/// recognized line a ring would land on.
func renderWindow(lines: [String], darkTerminal: Bool) -> (image: CGImage, errorBand: ClosedRange<Double>, rowOfLine: (Int) -> ClosedRange<Double>?) {
    let fontSize: CGFloat = darkTerminal ? 26 : 28
    let lineHeight = fontSize * 1.3
    let visibleLineCount = Int(CGFloat(windowHeightInPixels - 40) / lineHeight)
    let paddingNeeded = max(0, visibleLineCount - lines.count)
    let padded = Array(fillerLines.prefix(paddingNeeded)) + lines
    let shown = Array(padded.suffix(visibleLineCount))
    let errorStartRow = shown.count - min(lines.count, shown.count)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: windowWidthInPixels, height: windowHeightInPixels, bitsPerComponent: 8,
                            bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(darkTerminal ? CGColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: windowWidthInPixels, height: windowHeightInPixels))
    let font = CTFontCreateWithName((darkTerminal ? "Menlo" : "Helvetica") as CFString, fontSize, nil)
    let textColor = darkTerminal ? CGColor(red: 0.9, green: 0.9, blue: 0.88, alpha: 1) : CGColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 1)
    for (row, line) in shown.enumerated() {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
        let baselineFromTop = 20 + CGFloat(row + 1) * lineHeight - fontSize * 0.3
        context.textPosition = CGPoint(x: 24, y: CGFloat(windowHeightInPixels) - baselineFromTop)
        CTLineDraw(ctLine, context)
    }
    let image = context.makeImage()!
    let bandTop = (20 + Double(errorStartRow) * Double(lineHeight)) / Double(windowHeightInPixels)
    let bandBottom = min(1, (20 + Double(shown.count) * Double(lineHeight)) / Double(windowHeightInPixels))
    let hiddenLineCount = max(0, lines.count - shown.count)
    let rowOfLine: (Int) -> ClosedRange<Double>? = { lineIndex in
        let row = errorStartRow + lineIndex - hiddenLineCount
        guard lineIndex >= hiddenLineCount, row < shown.count else { return nil }
        let top = 20 + Double(row) * Double(lineHeight)
        return top...(top + Double(lineHeight))
    }
    return (image, bandTop...bandBottom, rowOfLine)
}

func scaled(_ image: CGImage, toWidth width: Int) -> CGImage {
    let height = max(1, image.height * width / max(image.width, 1))
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

func savePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func runVision(fixturesDirectory: String, imageDirectory: String) {
    let shouldGlow = loadFixtures(fixturesDirectory + "/should_glow.txt")
    let shouldNotGlow = loadFixtures(fixturesDirectory + "/should_not_glow.txt").filter { $0.place != nil }
    try? FileManager.default.createDirectory(atPath: imageDirectory, withIntermediateDirectories: true)

    struct Measurement { var cpu: [Double] = []; var wall: [Double] = []; var hits = 0; var falseHits = 0 }
    var fullAccurate = Measurement()
    var fullFast = Measurement()
    var bandAccurate = Measurement()
    var thumbnailCPU: [Double] = []
    var missedThroughRecognition: [String] = []
    var ringsChecked = 0
    var ringsRight = 0
    var ringsWrong: [String] = []

    func measure(_ image: CGImage, band: ClosedRange<Double>?, accurate: Bool) -> (lines: [String], cpu: Double, wall: Double) {
        let cpuStart = processCPUSeconds()
        let wallStart = Date()
        let read = ErrorWindowReading.readLines(in: image, rowBand: band, accurate: accurate)
        return (read.map(\.text), processCPUSeconds() - cpuStart, Date().timeIntervalSince(wallStart))
    }

    // One warm-up, so loading the recognition model is not counted as a check.
    let warmUp = renderWindow(lines: ["warm up"], darkTerminal: true)
    _ = ErrorWindowReading.readLines(in: warmUp.image, accurate: true)
    _ = ErrorWindowReading.readLines(in: warmUp.image, accurate: false)

    for (fixtureIndex, fixture) in (shouldGlow + shouldNotGlow).enumerated() {
        let isPositive = fixtureIndex < shouldGlow.count
        let isWebPage = fixture.placeName == "judgeSite"
        let (image, band, rowOfLine) = renderWindow(lines: fixture.lines, darkTerminal: !isWebPage)
        if fixtureIndex < 3 { savePNG(image, to: "\(imageDirectory)/\(fixture.name).png") }

        // The watcher captures its thumbnails 240 pixels wide, so that is
        // the image the thumbnail is made from while waiting for output.
        let smallCapture = scaled(image, toWidth: 240)
        let smallWarmUp = scaled(warmUp.image, toWidth: 240)
        let thumbnailStart = processCPUSeconds()
        let before = ErrorWindowReading.thumbnail(of: smallWarmUp)!
        let after = ErrorWindowReading.thumbnail(of: smallCapture)!
        _ = ErrorWindowReading.changedRows(from: before, to: after)
        thumbnailCPU.append(processCPUSeconds() - thumbnailStart)

        for (accurate, useBand) in [(true, false), (false, false), (true, true)] {
            let result = measure(image, band: useBand ? band : nil, accurate: accurate)
            let glowed = decision(for: fixture, lines: result.lines) != nil
            switch (accurate, useBand) {
            case (true, false):
                fullAccurate.cpu.append(result.cpu); fullAccurate.wall.append(result.wall)
                // The ring: the line the turn note names, matched by its
                // words against the whole window read as the screen index
                // would read it, must be the line drawn in that row.
                if isPositive, let fromText = decision(for: fixture, lines: fixture.lines) {
                    let ringLineIndex = fromText.causeCodeLineIndex ?? fromText.causeLineIndex ?? fromText.messageLineIndex
                    let readWithBounds = ErrorWindowReading.readLines(in: image, accurate: true)
                    var labels: [String: String] = [:]
                    for (labelIndex, line) in readWithBounds.enumerated() { labels["t\(labelIndex + 1)"] = line.text }
                    ringsChecked += 1
                    if let identifier = ErrorWindowReading.bestListedIdentifier(for: fixture.lines[ringLineIndex], among: labels),
                       let labelIndex = Int(identifier.dropFirst()), let row = rowOfLine(ringLineIndex),
                       row.contains(Double(readWithBounds[labelIndex - 1].boundsInImage.midY)) {
                        ringsRight += 1
                    } else {
                        ringsWrong.append(fixture.name)
                    }
                }
                if glowed { isPositive ? (fullAccurate.hits += 1) : (fullAccurate.falseHits += 1) }
                if isPositive && !glowed { missedThroughRecognition.append(fixture.name) }
            case (false, false):
                fullFast.cpu.append(result.cpu); fullFast.wall.append(result.wall)
                if glowed { isPositive ? (fullFast.hits += 1) : (fullFast.falseHits += 1) }
            default:
                bandAccurate.cpu.append(result.cpu); bandAccurate.wall.append(result.wall)
                if glowed { isPositive ? (bandAccurate.hits += 1) : (bandAccurate.falseHits += 1) }
            }
        }
    }

    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    func report(_ title: String, _ measurement: Measurement) {
        print(String(format: "%@: recall %d of %d, false glows %d of %d, CPU median %.0f ms (max %.0f), wall median %.0f ms",
                     title, measurement.hits, shouldGlow.count, measurement.falseHits, shouldNotGlow.count,
                     median(measurement.cpu) * 1000, (measurement.cpu.max() ?? 0) * 1000, median(measurement.wall) * 1000))
    }
    print("Window images: \(windowWidthInPixels) x \(windowHeightInPixels) pixels, the error at the bottom under earlier output\n")
    report("Whole window, accurate recognition", fullAccurate)
    report("Whole window, fast recognition    ", fullFast)
    report("Changed rows only, accurate       ", bandAccurate)
    print(String(format: "Two thumbnails from 240-pixel captures and the change between them: %.3f ms CPU", median(thumbnailCPU) * 1000))
    print("Ring lands on the right line when matched against the whole window's text: \(ringsRight) of \(ringsChecked)\(ringsWrong.isEmpty ? "" : " (wrong or unmatched: " + ringsWrong.joined(separator: ", ") + ")")")
    if !missedThroughRecognition.isEmpty {
        print("Missed through recognition (whole window, accurate): \(missedThroughRecognition.joined(separator: ", "))")
    }
    print("Sample images saved in \(imageDirectory)")
}

@main
enum ErrorOfferTest {
    static func main() {
        let arguments = CommandLine.arguments
        let mode = arguments.count > 1 ? arguments[1] : "grade"
        let fixturesDirectory = arguments.count > 2 ? arguments[2] : "scripts/error_offer/fixtures"
        switch mode {
        case "show":
            // What recognition reads from one fixture's window image.
            let name = arguments.count > 3 ? arguments[3] : ""
            let all = loadFixtures(fixturesDirectory + "/should_glow.txt") + loadFixtures(fixturesDirectory + "/should_not_glow.txt")
            guard let fixture = all.first(where: { $0.name == name }) else { print("no fixture \(name)"); return }
            let (image, _, _) = renderWindow(lines: fixture.lines, darkTerminal: fixture.placeName != "judgeSite")
            for line in ErrorWindowReading.readLines(in: image, accurate: true).suffix(fixture.lines.count + 2) {
                print(line.text)
            }
        case "vision":
            let imageDirectory = (ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "error_offer_images"
            runVision(fixturesDirectory: fixturesDirectory, imageDirectory: imageDirectory)
        default:
            runGrade(fixturesDirectory: fixturesDirectory, setPrefix: mode == "fresh" ? "fresh_" : "")
        }
    }
}
