//
//  ErrorRecognizer.swift
//  leanring-buddy
//
//  Recognizes an error in text read off the screen: a stack trace, a
//  failing test run, a compiler error or a judge's verdict. It runs on the
//  Mac with no model at all, on every check the error watcher makes, so it
//  has to be cheap and, above all, precise. A glow for something that is
//  not an error teaches the student to ignore the glow.
//
//  Precision comes from shape, never from the word "error". Each pattern is
//  the way one tool prints a failure: Python's `File "x.py", line 3` frames
//  under a Traceback, Node's `at fn (file.js:3:9)` frames under a
//  `TypeError:` line, rustc's `error[E0308]:`, clang's `file.c:3:5: error:`.
//  Source code that raises or catches errors never has that shape: `raise
//  ValueError(...)` does not start with `ValueError:`, and a catch block has
//  no frames under it.
//
//  Graded by scripts/error_offer/ on fixtures that should glow and near
//  misses that should not.
//

import Foundation

/// Where the text was read. A verdict such as "Wrong Answer" is an error
/// only on a judge's page, and "Build Failed" only in Xcode's toolbar.
nonisolated enum ErrorReadingPlace: String, Sendable {
    case terminal
    case editor
    case xcode
    case judgeSite
    case browserDeveloperTools
}

/// The family an error belongs to, which is also how it is named to the
/// model in the turn note.
nonisolated enum RecognizedErrorKind: String, Sendable {
    case pythonTraceback = "Python traceback"
    case javaScriptError = "JavaScript error with a stack trace"
    case typeScriptCompilerError = "TypeScript compiler error"
    case javaException = "Java or Kotlin exception"
    case javaCompilerError = "Java or Kotlin compiler error"
    case buildToolFailure = "build failure"
    case swiftCompilerError = "Swift compiler error"
    case swiftRuntimeError = "Swift runtime crash"
    case rustCompilerError = "Rust compiler error"
    case rustPanic = "Rust panic"
    case goPanic = "Go panic"
    case goCompilerError = "Go compiler error"
    case cCompilerError = "C or C++ compiler error"
    case linkerError = "linker error"
    case nativeCrash = "crash"
    case pytestFailure = "failing pytest run"
    case unittestFailure = "failing unittest run"
    case jestFailure = "failing Jest or Vitest run"
    case mochaFailure = "failing Mocha run"
    case junitFailure = "failing JUnit run"
    case xctestFailure = "failing XCTest run"
    case goTestFailure = "failing Go test"
    case cargoTestFailure = "failing cargo test"
    case judgeVerdict = "judge verdict"
}

nonisolated struct RecognizedError: Equatable, Sendable {
    let kind: RecognizedErrorKind
    /// The line that says what went wrong: "TypeError: x is undefined",
    /// "Wrong Answer", "FAILED tests/test_math.py::test_add".
    let messageLineIndex: Int
    /// First and last line of the whole error, frames included.
    let firstLineIndex: Int
    let lastLineIndex: Int
    /// The frame or location line in the student's own code that the
    /// output points to, when it names one.
    let causeLineIndex: Int?
    /// The student's line of code itself, when the output prints it
    /// (Python, Node, rustc, clang, pytest and Jest all do).
    let causeCodeLineIndex: Int?
    let causeFileName: String?
    let causeLineNumber: Int?
    /// Stable across re-reads of the same error, different for a different
    /// one: what the dedupe remembers.
    let fingerprint: String
}

nonisolated enum ErrorRecognizer {

    /// The error in these lines, top to bottom as they are on screen, or nil.
    /// When several are visible the newest output wins, which in a
    /// terminal is the lowest; a compiler's list of errors is named by its
    /// first, since the rest usually follow from it.
    static func recognize(lines rawLines: [String], place: ErrorReadingPlace) -> RecognizedError? {
        let lines = rawLines.map(normalizedLine)
        var candidates: [Candidate] = []
        candidates += pythonCandidates(lines)
        candidates += javaScriptCandidates(lines)
        candidates += javaCandidates(lines)
        candidates += swiftCandidates(lines, place: place)
        candidates += rustCandidates(lines)
        candidates += goCandidates(lines)
        candidates += cCandidates(lines)
        candidates += testRunnerCandidates(lines)
        if place == .judgeSite {
            candidates += judgeVerdictCandidates(lines)
        }

        // A stack trace logged on purpose at INFO or WARN level is the
        // program handling it, not the student's program failing.
        // Only traces are logged that way; a build tool's own summary at
        // INFO level ("[INFO] BUILD FAILURE") is still the build failing.
        candidates = candidates.filter { candidate in
            let isLoggableTrace = [.pythonTraceback, .javaScriptError, .javaException].contains(candidate.kind)
            return !isLoggableTrace || !isPrecededByLowSeverityLogLine(lines, lineIndex: candidate.firstLineIndex)
        }
        guard let newest = candidates.max(by: { first, second in
            (first.lastLineIndex, first.messageLineIndex) < (second.lastLineIndex, second.messageLineIndex)
        }) else { return nil }

        // In a terminal the error has to be the end of what was printed,
        // give or take a summary and the next prompt. An old error higher
        // up, with other output under it, is history.
        if place == .terminal {
            let nonEmptyLinesAfterError = lines[(newest.lastLineIndex + 1)...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            guard nonEmptyLinesAfterError <= maximumLinesAfterErrorInTerminal else { return nil }
        }

        var chosen = newest
        // A summary ("error: could not compile", "Tests: 1 failed") or a list
        // of compiler errors is named by the first specific error of the
        // same run, which is where the student should start.
        if newest.isSummary || newest.isListItem {
            let runStart = startOfRun(lines, endingAt: newest.messageLineIndex)
            let sameRun = candidates.filter { candidate in
                candidate.family == newest.family && !candidate.isSummary
                    && candidate.messageLineIndex >= runStart && candidate.messageLineIndex <= newest.messageLineIndex
            }
            if let firstSpecific = sameRun.min(by: { $0.messageLineIndex < $1.messageLineIndex }) {
                chosen = firstSpecific
            } else if newest.isSummary, let nearestSpecific = candidates.filter({ candidate in
                !candidate.isSummary && candidate.messageLineIndex >= runStart && candidate.messageLineIndex < newest.messageLineIndex
            }).max(by: { $0.messageLineIndex < $1.messageLineIndex }) {
                // "zsh: trace trap" under "Fatal error: Index out of range":
                // the message above says what the summary only reports.
                chosen = nearestSpecific
            }
            let runRange = runStart...max(newest.lastLineIndex, chosen.lastLineIndex)
            chosen = enriched(chosen, lines: lines, searchRange: runRange, newestLastLineIndex: newest.lastLineIndex)
            // Still nowhere to point: another error of the same run may
            // name the line, as a JUnit failure's exception trace does.
            if chosen.causeLineIndex == nil, let withCause = candidates.filter({ candidate in
                candidate.causeLineIndex != nil && runRange.contains(candidate.messageLineIndex)
            }).min(by: { $0.messageLineIndex < $1.messageLineIndex }) {
                chosen.causeLineIndex = withCause.causeLineIndex
                chosen.causeCodeLineIndex = withCause.causeCodeLineIndex
                chosen.causeFileName = withCause.causeFileName
                chosen.causeLineNumber = withCause.causeLineNumber
            }
        } else {
            chosen = enriched(chosen, lines: lines, searchRange: chosen.firstLineIndex...chosen.lastLineIndex,
                              newestLastLineIndex: chosen.lastLineIndex)
        }

        return RecognizedError(
            kind: chosen.kind,
            messageLineIndex: chosen.messageLineIndex,
            firstLineIndex: chosen.firstLineIndex,
            lastLineIndex: max(chosen.lastLineIndex, newest.lastLineIndex),
            causeLineIndex: chosen.causeLineIndex,
            causeCodeLineIndex: chosen.causeCodeLineIndex,
            causeFileName: chosen.causeFileName,
            causeLineNumber: chosen.causeLineNumber,
            fingerprint: fingerprint(for: chosen, lines: lines))
    }

    /// More output than a summary block and a prompt after the error means
    /// the error was not the last thing that happened.
    static let maximumLinesAfterErrorInTerminal = 15

    // MARK: - Candidates

    /// One error found by one pattern, before the newest is chosen.
    private struct Candidate {
        var kind: RecognizedErrorKind
        /// Errors of one family are one tool's output: a summary is replaced
        /// by the first specific error of its own family only.
        var family: String
        var messageLineIndex: Int
        var firstLineIndex: Int
        var lastLineIndex: Int
        /// "error: could not compile", "Tests: 2 failed": says that it
        /// failed, not what failed.
        var isSummary = false
        /// One of possibly many compiler errors or failing tests.
        var isListItem = false
        var causeLineIndex: Int?
        var causeCodeLineIndex: Int?
        var causeFileName: String?
        var causeLineNumber: Int?
    }

    // MARK: Python

    private static let pythonTracebackHeader = regex(#"^Traceback \(most recent call last\)\s*:?$"#)
    /// Text recognition tends to drop the short word at the start of an
    /// indented line, so "File" is optional; the quoted path followed by
    /// ", line 8" is specific enough on its own.
    private static let pythonFrame = regex(#"^\s*(?:File\s+)?"(.+?)",\s*line\s+(\d+)"#)
    private static let pythonNotebookFrame = regex(#"^\s*Cell\s+In\s*\[[^,]{0,4},\s*line\s+(\d+)"#)
    /// The last line of a traceback: a class name, optionally qualified,
    /// then its message. Not every exception ends in Error (ReadTimeout,
    /// StopIteration), so the name alone is not enough; a frame above it
    /// is what makes it a traceback.
    private static let pythonExceptionLine = regex(#"^((?:[A-Za-z_][A-Za-z0-9_]*\.)*[A-Z][A-Za-z0-9_]*)(?::\s*(.*))?$"#)
    /// The student stopping the program is not a failure.
    private static let pythonExceptionsThatAreNotFailures = ["KeyboardInterrupt", "SystemExit", "GeneratorExit"]

    private static func pythonCandidates(_ lines: [String]) -> [Candidate] {
        var found: [Candidate] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let match = firstMatch(pythonExceptionLine, trimmed) else { continue }
            let exceptionName = group(match, 1, in: trimmed) ?? ""
            if pythonExceptionsThatAreNotFailures.contains(where: { exceptionName.hasSuffix($0) }) || exceptionName.hasSuffix("Warning") { continue }
            // A frame within the lines above: either a traceback, or a
            // SyntaxError, which prints its one frame without a Traceback.
            let searchStart = max(0, index - 8)
            let frameIndices = (searchStart..<index).filter { frameIndex in
                matches(pythonFrame, lines[frameIndex]) || matches(pythonNotebookFrame, lines[frameIndex])
            }
            guard let nearestFrameIndex = frameIndices.last else { continue }
            var firstIndex = nearestFrameIndex
            var scanIndex = nearestFrameIndex
            while scanIndex > 0, index - scanIndex < 80 {
                scanIndex -= 1
                if matches(pythonTracebackHeader, lines[scanIndex].trimmingCharacters(in: .whitespaces)) {
                    firstIndex = scanIndex
                    break
                }
                if matches(pythonFrame, lines[scanIndex]) { firstIndex = scanIndex }
            }
            var candidate = Candidate(kind: .pythonTraceback, family: "python", messageLineIndex: index,
                                      firstLineIndex: firstIndex, lastLineIndex: index)
            // Frames go from the outside in, so the student's own code is
            // the last frame that is not a library's.
            let allFrames = (firstIndex..<index).compactMap { frameIndex -> (Int, String, Int)? in
                let frameLine = lines[frameIndex]
                if let frameMatch = firstMatch(pythonFrame, frameLine) {
                    return (frameIndex, group(frameMatch, 1, in: frameLine) ?? "", Int(group(frameMatch, 2, in: frameLine) ?? "") ?? 0)
                }
                if let notebookMatch = firstMatch(pythonNotebookFrame, frameLine) {
                    return (frameIndex, "notebook cell", Int(group(notebookMatch, 1, in: frameLine) ?? "") ?? 0)
                }
                return nil
            }
            if let causeFrame = allFrames.last(where: { !isLibraryPath($0.1) }) ?? allFrames.last {
                candidate.causeLineIndex = causeFrame.0
                candidate.causeFileName = causeFrame.1
                candidate.causeLineNumber = causeFrame.2
                let codeIndex = causeFrame.0 + 1
                // A notebook prints the cell's lines around it and marks
                // the failing one with an arrow.
                if let arrowIndex = (codeIndex..<index).first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("---->") }) {
                    candidate.causeCodeLineIndex = arrowIndex
                } else if codeIndex < index, looksLikePrintedCode(lines[codeIndex]),
                   !matches(pythonFrame, lines[codeIndex]) {
                    candidate.causeCodeLineIndex = codeIndex
                }
            }
            found.append(candidate)
        }
        return found
    }

    // MARK: JavaScript and TypeScript

    private static let javaScriptMessageLine = regex(#"^(?:Uncaught\s+(?:\(in promise\)\s+)?)?((?:[A-Z][A-Za-z]*)?Error)(?:\s*\[[A-Z0-9_]+\])?:\s*(.+)$"#)
    /// "at fn (file.js:3:9)" or "at file.js:3:9". Recognition sometimes
    /// drops the "at", so the bracketed form is accepted without it.
    private static let javaScriptFrame = regex(#"^\s*(?:at\s+(?:async\s+)?(?:(?:new\s+)?[^\s(]+(?:\s+\[as [^\]]+\])?\s+\()?|(?:async\s+)?(?:new\s+)?[^\s(]+(?:\s+\[as [^\]]+\])?\s+\()((?:file://|https?://|node:)?[^\s()]+?):(\d+):(\d+)\)?$"#)
    /// Firefox's console: "updateScore http://localhost:5173/src/main.js:23",
    /// or "updateScore@http://localhost:5173/src/main.js:23:5".
    private static let firefoxFrame = regex(#"^\s*[\w$.<>/]+(?:\s+|@)((?:https?|file|moz-extension)://[^\s()]+?):(\d+)(?::\d+)?$"#)
    /// Node prints the failing file and line above the message, then the line.
    private static let nodeLocationHeader = regex(#"^((?:file://)?(?:[A-Za-z]:\\|/|\./|\.\./)?[\w@./\\-]+\.(?:m?js|cjs|mts|cts|ts|tsx|jsx)):(\d+)$"#)
    private static let typeScriptCompilerLine = regex(#"^(.+?\.(?:ts|tsx|mts|cts))(?:\((\d+),(\d+)\)|:(\d+):(\d+))\s*(?:-\s*)?error\s+TS\d+:\s*(.+)$"#)

    private static func javaScriptCandidates(_ lines: [String]) -> [Candidate] {
        var found: [Candidate] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = firstMatch(typeScriptCompilerLine, trimmed) {
                var candidate = Candidate(kind: .typeScriptCompilerError, family: "typescript", messageLineIndex: index,
                                          firstLineIndex: index, lastLineIndex: index, isListItem: true)
                candidate.causeLineIndex = index
                candidate.causeFileName = group(match, 1, in: trimmed)
                candidate.causeLineNumber = Int(group(match, 2, in: trimmed) ?? group(match, 4, in: trimmed) ?? "")
                found.append(candidate)
                continue
            }
            guard matches(javaScriptMessageLine, trimmed) else { continue }
            // At least one frame right under the message: a message alone
            // is as likely a sentence in a page or a log.
            // The first frame may sit under a few lines of message (Node's
            // assertion diff); after that, frames come one after another.
            var lastFrameIndex: Int?
            var frames: [(Int, String, Int)] = []
            var scanIndex = index + 1
            while scanIndex < lines.count, scanIndex - (lastFrameIndex ?? index) <= (lastFrameIndex == nil ? 6 : 3) {
                let frameLine = lines[scanIndex]
                if let frameMatch = firstMatch(javaScriptFrame, frameLine) ?? firstMatch(firefoxFrame, frameLine) {
                    lastFrameIndex = scanIndex
                    frames.append((scanIndex, group(frameMatch, 1, in: frameLine) ?? "", Int(group(frameMatch, 2, in: frameLine) ?? "") ?? 0))
                }
                scanIndex += 1
            }
            guard let lastFrameIndex else { continue }
            var candidate = Candidate(kind: .javaScriptError, family: "javascript", messageLineIndex: index,
                                      firstLineIndex: index, lastLineIndex: lastFrameIndex)
            // The header Node prints above the message names the line that threw.
            let headerSearchStart = max(0, index - 6)
            if let headerIndex = (headerSearchStart..<index).last(where: { matches(nodeLocationHeader, lines[$0].trimmingCharacters(in: .whitespaces)) }) {
                let headerLine = lines[headerIndex].trimmingCharacters(in: .whitespaces)
                if let headerMatch = firstMatch(nodeLocationHeader, headerLine), let fileName = group(headerMatch, 1, in: headerLine),
                   !isLibraryPath(fileName) {
                    candidate.firstLineIndex = headerIndex
                    candidate.causeLineIndex = headerIndex
                    candidate.causeFileName = fileName
                    candidate.causeLineNumber = Int(group(headerMatch, 2, in: headerLine) ?? "")
                    if headerIndex + 1 < index, looksLikePrintedCode(lines[headerIndex + 1]) {
                        candidate.causeCodeLineIndex = headerIndex + 1
                    }
                }
            }
            if candidate.causeLineIndex == nil, let userFrame = frames.first(where: { !isLibraryPath($0.1) }) {
                candidate.causeLineIndex = userFrame.0
                candidate.causeFileName = userFrame.1
                candidate.causeLineNumber = userFrame.2
            }
            found.append(candidate)
        }
        return found
    }

    // MARK: Java and Kotlin

    private static let javaThreadException = regex(#"^Exception in thread "[^"]*"\s+((?:[\w$]+\.)*[\w$]+)(?::\s*(.*))?$"#)
    private static let javaQualifiedException = regex(#"^(?:Caused by:\s*)?((?:[a-z_][\w$]*\.)+[A-Z][\w$]*(?:Exception|Error|Throwable|Failure))(?::\s*(.*))?$"#)
    /// "at Main.greet(Main.java:9)". Without its "at", which recognition
    /// sometimes drops, a frame needs a file and line in the brackets, so a
    /// line of source such as `System.out.println(x)` is never one.
    private static let javaFrame = regex(#"^\s*(?:at\s+([\w$.<>/-]+)\(([^)]*)\)|([\w$.<>/-]+)\(([\w$-]+\.(?:java|kt|kts|scala|groovy):\d+)\))$"#)
    private static let javaFrameLocation = regex(#"^([\w$-]+\.(?:java|kt|kts|scala|groovy)):(\d+)$"#)
    private static let javaCompilerLine = regex(#"^(.+?\.(?:java|kt|kts|scala)):(\d+):\s*error:\s*(.+)$"#)
    private static let mavenCompilerLine = regex(#"^\[ERROR\]\s+(.+?\.(?:java|kt|kts|scala)):\[(\d+),(\d+)\]\s*(.+)$"#)
    private static let kotlinCompilerLine = regex(#"^e:\s+(?:file://)?(.+?\.kts?)(?::(\d+):(\d+)|:\s*\((\d+),\s*(\d+)\))\s*:?\s*(.+)$"#)
    private static let buildFailureLine = regex(#"^(?:\[(?:ERROR|INFO)\]\s+)?(?:BUILD FAILURE$|BUILD FAILED(?: in .+)?$|FAILURE: Build failed with an exception\.?$)"#)
    private static let javaLibraryPrefixes = ["java.", "javax.", "jdk.", "sun.", "com.sun.", "kotlin.", "kotlinx.", "org.junit.",
                                               "junit.", "org.gradle.", "org.apache.maven.", "org.opentest4j.", "worker.org.gradle."]

    private static func javaCandidates(_ lines: [String]) -> [Candidate] {
        var found: [Candidate] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if let match = firstMatch(javaCompilerLine, trimmed) ?? firstMatch(mavenCompilerLine, trimmed) {
                var candidate = Candidate(kind: .javaCompilerError, family: "java", messageLineIndex: index,
                                          firstLineIndex: index, lastLineIndex: index, isListItem: true)
                candidate.causeLineIndex = index
                candidate.causeFileName = group(match, 1, in: trimmed)
                candidate.causeLineNumber = Int(group(match, 2, in: trimmed) ?? "")
                if index + 1 < lines.count, looksLikePrintedCode(lines[index + 1]), !lines[index + 1].hasPrefix("[") {
                    candidate.causeCodeLineIndex = index + 1
                }
                found.append(candidate)
                index += 1
                continue
            }
            if let match = firstMatch(kotlinCompilerLine, trimmed) {
                var candidate = Candidate(kind: .javaCompilerError, family: "java", messageLineIndex: index,
                                          firstLineIndex: index, lastLineIndex: index, isListItem: true)
                candidate.causeLineIndex = index
                candidate.causeFileName = group(match, 1, in: trimmed)
                candidate.causeLineNumber = Int(group(match, 2, in: trimmed) ?? group(match, 4, in: trimmed) ?? "")
                found.append(candidate)
                index += 1
                continue
            }
            if matches(buildFailureLine, trimmed) {
                found.append(Candidate(kind: .buildToolFailure, family: "java", messageLineIndex: index,
                                       firstLineIndex: index, lastLineIndex: index, isSummary: true))
                index += 1
                continue
            }
            let isThreadLine = matches(javaThreadException, trimmed)
            guard isThreadLine || matches(javaQualifiedException, trimmed) else {
                index += 1
                continue
            }
            // Frames under it, tabs and "... 12 more" allowed between.
            // An IDE puts a diff ("Expected :5", "Actual :4") between the
            // exception and its first frame, so a few other lines are
            // allowed before the frames start; none after.
            var frameIndices: [Int] = []
            var scanIndex = index + 1
            while scanIndex < lines.count {
                let scanned = lines[scanIndex].trimmingCharacters(in: .whitespaces)
                if matches(javaFrame, scanned) {
                    frameIndices.append(scanIndex)
                } else if frameIndices.isEmpty, scanIndex - index <= 6 {
                    // Still looking for the first frame.
                } else if scanned.hasPrefix("...") && scanned.hasSuffix("more") {
                    // Folded frames.
                } else if scanned.hasPrefix("Caused by:") || scanned.hasPrefix("Suppressed:") {
                    // A chained cause continues the same trace.
                } else {
                    break
                }
                scanIndex += 1
            }
            guard let lastFrameIndex = frameIndices.last else {
                index += 1
                continue
            }
            var candidate = Candidate(kind: .javaException, family: "java", messageLineIndex: index,
                                      firstLineIndex: index, lastLineIndex: lastFrameIndex)
            // The root cause is the last "Caused by:", and its frames
            // are the ones that point at the code that actually broke.
            let causedByIndices = (index...lastFrameIndex).filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("Caused by:") }
            let rootIndex = causedByIndices.last ?? index
            candidate.messageLineIndex = rootIndex
            let framesOfRoot = frameIndices.filter { $0 > rootIndex }
            for frameIndex in framesOfRoot {
                let frameLine = lines[frameIndex].trimmingCharacters(in: .whitespaces)
                guard let frameMatch = firstMatch(javaFrame, frameLine),
                      let method = group(frameMatch, 1, in: frameLine) ?? group(frameMatch, 3, in: frameLine),
                      let location = group(frameMatch, 2, in: frameLine) ?? group(frameMatch, 4, in: frameLine) else { continue }
                let methodWithoutModule = method.split(separator: "/").last.map(String.init) ?? method
                if javaLibraryPrefixes.contains(where: { methodWithoutModule.hasPrefix($0) }) { continue }
                guard let locationMatch = firstMatch(javaFrameLocation, location) else { continue }
                candidate.causeLineIndex = frameIndex
                candidate.causeFileName = group(locationMatch, 1, in: location)
                candidate.causeLineNumber = Int(group(locationMatch, 2, in: location) ?? "")
                break
            }
            found.append(candidate)
            index = lastFrameIndex + 1
        }
        return found
    }

    // MARK: Swift and Xcode

    private static let swiftCompilerLine = regex(#"^(.+?\.(?:swift|swiftinterface)):(\d+):(\d+):\s*error:\s*(.+)$"#)
    private static let xctestErrorLine = regex(#"^(.+?\.swift):(\d+):\s*error:\s*(?:-\[.+?\]|.+?)\s*:\s*(.+)$"#)
    private static let swiftFatalWithLocation = regex(#"^(?:.*?/)?([\w+.-]+\.swift):(\d+):\s*Fatal error(?::\s*(.*))?$"#)
    private static let swiftFatalOldStyle = regex(#"^Fatal error:\s*(.+?)(?::\s*file\s+(.+?\.swift),\s*line\s+(\d+))?$"#)
    private static let xcodeThreadStop = regex(#"^Thread\s+\d+:\s*(?:Fatal error:|EXC_[A-Z_]+|signal SIG[A-Z]+|breakpoint\s+\d)"#)
    /// Xcode's toolbar reads "Weather | Build Failed | Today at 10:42".
    private static let xcodeBuildFailed = regex(#"(?:^|\|\s*)(?:Build Failed|Build failed|Test Failed|Tests Failed)\b"#)
    private static let swiftCommandFailed = regex(#"^(?:error:\s*)?Command \w+ failed with a nonzero exit code$"#)

    private static func swiftCandidates(_ lines: [String], place: ErrorReadingPlace) -> [Candidate] {
        var found: [Candidate] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = firstMatch(swiftCompilerLine, trimmed) {
                var candidate = Candidate(kind: .swiftCompilerError, family: "swift", messageLineIndex: index,
                                          firstLineIndex: index, lastLineIndex: index, isListItem: true)
                candidate.causeLineIndex = index
                candidate.causeFileName = group(match, 1, in: trimmed)
                candidate.causeLineNumber = Int(group(match, 2, in: trimmed) ?? "")
                found.append(candidate)
            } else if let match = firstMatch(xctestErrorLine, trimmed) {
                var candidate = Candidate(kind: .xctestFailure, family: "xctest", messageLineIndex: index,
                                          firstLineIndex: index, lastLineIndex: index, isListItem: true)
                candidate.causeLineIndex = index
                candidate.causeFileName = group(match, 1, in: trimmed)
                candidate.causeLineNumber = Int(group(match, 2, in: trimmed) ?? "")
                found.append(candidate)
            } else if let match = firstMatch(swiftFatalWithLocation, trimmed) {
                var candidate = Candidate(kind: .swiftRuntimeError, family: "swift-runtime", messageLineIndex: index,
                                          firstLineIndex: index, lastLineIndex: index)
                let fileName = group(match, 1, in: trimmed) ?? ""
                if !isLibraryPath(trimmed) {
                    candidate.causeLineIndex = index
                    candidate.causeFileName = fileName
                    candidate.causeLineNumber = Int(group(match, 2, in: trimmed) ?? "")
                }
                found.append(candidate)
            } else if let match = firstMatch(swiftFatalOldStyle, trimmed) {
                var candidate = Candidate(kind: .swiftRuntimeError, family: "swift-runtime", messageLineIndex: index,
                                          firstLineIndex: index, lastLineIndex: index)
                if let fileName = group(match, 2, in: trimmed) {
                    candidate.causeLineIndex = index
                    candidate.causeFileName = fileName
                    candidate.causeLineNumber = Int(group(match, 3, in: trimmed) ?? "")
                }
                found.append(candidate)
            } else if matches(xcodeThreadStop, trimmed) {
                // A breakpoint stops the same way and is not an error.
                guard !trimmed.contains("breakpoint") else { continue }
                found.append(Candidate(kind: .swiftRuntimeError, family: "swift-runtime", messageLineIndex: index,
                                       firstLineIndex: index, lastLineIndex: index))
            } else if place == .xcode, matches(xcodeBuildFailed, trimmed) {
                let isTest = trimmed.contains("Test Failed") || trimmed.contains("Tests Failed")
                found.append(Candidate(kind: isTest ? .xctestFailure : .swiftCompilerError, family: isTest ? "xctest" : "swift",
                                       messageLineIndex: index, firstLineIndex: index, lastLineIndex: index, isSummary: true))
            } else if matches(swiftCommandFailed, trimmed) {
                found.append(Candidate(kind: .swiftCompilerError, family: "swift", messageLineIndex: index,
                                       firstLineIndex: index, lastLineIndex: index, isSummary: true))
            }
        }
        return found
    }

    // MARK: Rust

    private static let rustErrorLine = regex(#"^error(?:\[(E\d{4})\])?:\s*(.+)$"#)
    private static let rustLocationArrow = regex(#"^\s*-->\s*(.+?):(\d+):(\d+)$"#)
    private static let rustGutterCode = regex(#"^\s*(\d+)\s*\|\s?(.*\S.*)$"#)
    private static let rustPanicLine = regex(#"^thread '([^']*)' panicked at (?:'(.*)',\s*)?(.+?):(\d+):(\d+):?$"#)
    private static let cargoTestResultFailed = regex(#"^test result: FAILED\."#)
    private static let cargoFailingTestHeader = regex(#"^---- (\S+) stdout ----$"#)

    private static func rustCandidates(_ lines: [String]) -> [Candidate] {
        var found: [Candidate] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = firstMatch(rustPanicLine, trimmed) {
                var candidate = Candidate(kind: .rustPanic, family: "rust-panic", messageLineIndex: index,
                                          firstLineIndex: index, lastLineIndex: index)
                // Since Rust 1.73 the message is on the next line.
                if group(match, 2, in: trimmed) == nil, index + 1 < lines.count,
                   !lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    candidate.lastLineIndex = index + 1
                }
                let fileName = group(match, 3, in: trimmed) ?? ""
                if !isLibraryPath(fileName) {
                    candidate.causeLineIndex = index
                    candidate.causeFileName = fileName
                    candidate.causeLineNumber = Int(group(match, 4, in: trimmed) ?? "")
                }
                found.append(candidate)
                continue
            }
            if matches(cargoTestResultFailed, trimmed) {
                found.append(Candidate(kind: .cargoTestFailure, family: "rust-panic", messageLineIndex: index,
                                       firstLineIndex: index, lastLineIndex: index, isSummary: true))
                continue
            }
            if matches(cargoFailingTestHeader, trimmed) {
                found.append(Candidate(kind: .cargoTestFailure, family: "rust-panic", messageLineIndex: index,
                                       firstLineIndex: index, lastLineIndex: index, isListItem: true))
                continue
            }
            guard let match = firstMatch(rustErrorLine, trimmed), !trimmed.lowercased().hasPrefix("error: warning") else { continue }
            let hasErrorCode = group(match, 1, in: trimmed) != nil
            let message = group(match, 2, in: trimmed) ?? ""
            if message.hasPrefix("could not compile") || message.hasPrefix("aborting due to") {
                found.append(Candidate(kind: .rustCompilerError, family: "rust", messageLineIndex: index,
                                       firstLineIndex: index, lastLineIndex: index, isSummary: true))
                continue
            }
            // rustc's own errors carry an arrow to the code; plain
            // "error: ..." lines from other tools do not, and are not this.
            let arrowIndex = ((index + 1)..<min(lines.count, index + 4)).first { matches(rustLocationArrow, lines[$0]) }
            guard hasErrorCode || arrowIndex != nil else { continue }
            var candidate = Candidate(kind: .rustCompilerError, family: "rust", messageLineIndex: index,
                                      firstLineIndex: index, lastLineIndex: arrowIndex ?? index, isListItem: true)
            if let arrowIndex, let arrowMatch = firstMatch(rustLocationArrow, lines[arrowIndex]) {
                candidate.causeLineIndex = arrowIndex
                candidate.causeFileName = group(arrowMatch, 1, in: lines[arrowIndex])
                candidate.causeLineNumber = Int(group(arrowMatch, 2, in: lines[arrowIndex]) ?? "")
                if let codeIndex = ((arrowIndex + 1)..<min(lines.count, arrowIndex + 4)).first(where: { matches(rustGutterCode, lines[$0]) }) {
                    candidate.causeCodeLineIndex = codeIndex
                    candidate.lastLineIndex = codeIndex
                }
            }
            found.append(candidate)
        }
        return found
    }

    // MARK: Go

    private static let goPanicLine = regex(#"^panic:\s*(.+)$"#)
    private static let goFatalLine = regex(#"^fatal error:\s*(all goroutines are asleep|concurrent map|out of memory|stack overflow)"#)
    private static let goroutineHeader = regex(#"^goroutine \d+ \["#)
    private static let goFunctionLine = regex(#"^(?:[\w.*()\[\]/-]+\(.*\)|exit status \d+|created by .+)$"#)
    private static let goFrameLocation = regex(#"^\s*(.+?\.go):(\d+)(?:\s+\+0x[0-9a-fA-F]+)?$"#)
    private static let goCompilerLine = regex(#"^((?:\.{1,2}/)?[\w@/.-]+\.go):(\d+):(\d+):\s*(.+)$"#)
    private static let goPackageHeader = regex(#"^# [\w@./-]+$"#)
    private static let goTestFailLine = regex(#"^\s*--- FAIL: (\S+) \("#)
    private static let goTestPackageFail = regex(#"^FAIL\s+\S+\s+[\d.]+s$"#)
    private static let goTestLocation = regex(#"^\s+(\S+_test\.go):(\d+):\s*(.+)$"#)

    private static func goCandidates(_ lines: [String]) -> [Candidate] {
        var found: [Candidate] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if matches(goPanicLine, trimmed) || matches(goFatalLine, trimmed) {
                guard let goroutineIndex = ((index + 1)..<min(lines.count, index + 8)).first(where: {
                    matches(goroutineHeader, lines[$0].trimmingCharacters(in: .whitespaces))
                }) else { continue }
                var candidate = Candidate(kind: .goPanic, family: "go-panic", messageLineIndex: index,
                                          firstLineIndex: index, lastLineIndex: goroutineIndex)
                var scanIndex = goroutineIndex + 1
                while scanIndex < lines.count, scanIndex - candidate.lastLineIndex <= 2 {
                    let frameLine = lines[scanIndex]
                    if let frameMatch = firstMatch(goFrameLocation, frameLine) {
                        candidate.lastLineIndex = scanIndex
                        let fileName = group(frameMatch, 1, in: frameLine) ?? ""
                        if candidate.causeLineIndex == nil, !isLibraryPath(fileName) {
                            candidate.causeLineIndex = scanIndex
                            candidate.causeFileName = fileName
                            candidate.causeLineNumber = Int(group(frameMatch, 2, in: frameLine) ?? "")
                        }
                    } else if matches(goFunctionLine, frameLine.trimmingCharacters(in: .whitespaces)) {
                        candidate.lastLineIndex = scanIndex
                    }
                    scanIndex += 1
                }
                found.append(candidate)
                continue
            }
            if let match = firstMatch(goTestLocation, line) {
                var candidate = Candidate(kind: .goTestFailure, family: "go-test", messageLineIndex: index,
                                          firstLineIndex: index, lastLineIndex: index, isListItem: true)
                // Only inside a failing run: a passing verbose run logs here too.
                let hasFailNearby = ((max(0, index - 3))..<min(lines.count, index + 30)).contains { nearbyIndex in
                    matches(goTestFailLine, lines[nearbyIndex]) || matches(goTestPackageFail, lines[nearbyIndex].trimmingCharacters(in: .whitespaces))
                }
                guard hasFailNearby else { continue }
                candidate.causeLineIndex = index
                candidate.causeFileName = group(match, 1, in: line)
                candidate.causeLineNumber = Int(group(match, 2, in: line) ?? "")
                found.append(candidate)
                continue
            }
            if matches(goTestFailLine, line) {
                found.append(Candidate(kind: .goTestFailure, family: "go-test", messageLineIndex: index,
                                       firstLineIndex: index, lastLineIndex: index, isListItem: true))
                continue
            }
            if matches(goTestPackageFail, trimmed) {
                found.append(Candidate(kind: .goTestFailure, family: "go-test", messageLineIndex: index,
                                       firstLineIndex: index, lastLineIndex: index, isSummary: true))
                continue
            }
            if let match = firstMatch(goCompilerLine, trimmed) {
                // `go build` heads its errors with "# package"; vet and
                // linters print the same shape for style notes.
                let headerSearchStart = max(0, index - 10)
                guard (headerSearchStart..<index).contains(where: { matches(goPackageHeader, lines[$0].trimmingCharacters(in: .whitespaces)) }) else { continue }
                var candidate = Candidate(kind: .goCompilerError, family: "go", messageLineIndex: index,
                                          firstLineIndex: index, lastLineIndex: index, isListItem: true)
                candidate.causeLineIndex = index
                candidate.causeFileName = group(match, 1, in: trimmed)
                candidate.causeLineNumber = Int(group(match, 2, in: trimmed) ?? "")
                found.append(candidate)
            }
        }
        return found
    }

    // MARK: C and C++

    private static let cCompilerLine = regex(#"^(.+?\.(?:c|cc|cpp|cxx|c\+\+|h|hh|hpp|hxx|m|mm|ino|cu)):(\d+):(?:(\d+):)?\s*(?:fatal\s+)?error:\s*(.+)$"#)
    private static let msvcCompilerLine = regex(#"^(.+?\.(?:c|cc|cpp|cxx|h|hpp))\((\d+)(?:,\d+)?\)\s*:\s*(?:fatal\s+)?error\s+C\d+\s*:"#)
    private static let linkerLines = [
        regex(#"^Undefined symbols for architecture \w+:?$"#),
        regex(#"^(?:/usr/bin/)?ld(?:\.lld|64\.lld)?:\s.*(?:undefined reference|symbol\(s\) not found|cannot find|duplicate symbol)"#),
        regex(#"^(?:clang|clang\+\+|gcc|g\+\+|cc|c\+\+|collect2)(?:-\d+)?:\s*error:\s*(?:linker command failed|ld returned)"#),
        regex(#"^.*:\s*undefined reference to [`'].+'$"#)
    ]
    private static let nativeCrashLines = [
        regex(#"^(?:zsh|bash|sh|fish):?\s*(?:\d+\s+)?(?:segmentation fault|bus error|abort|illegal hardware instruction|floating point exception|trace trap)\b"#),
        regex(#"^Segmentation fault(?: \(core dumped\))?$"#),
        regex(#"^(?:Abort trap: 6|Bus error: 10|Illegal instruction: 4|Floating point exception: 8|Trace/BPT trap: 5)$"#),
        regex(#"^==\d+==ERROR: (?:AddressSanitizer|LeakSanitizer|ThreadSanitizer|UndefinedBehaviorSanitizer):"#)
    ]
    private static let makeFailureLine = regex(#"^g?make(?:\[\d+\])?: \*\*\* .*Error \d+"#)
    private static let errorsGeneratedLine = regex(#"^\d+ errors? generated\.$"#)

    private static func cCandidates(_ lines: [String]) -> [Candidate] {
        var found: [Candidate] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = firstMatch(cCompilerLine, trimmed) ?? firstMatch(msvcCompilerLine, trimmed) {
                var candidate = Candidate(kind: .cCompilerError, family: "c", messageLineIndex: index,
                                          firstLineIndex: index, lastLineIndex: index, isListItem: true)
                let fileName = group(match, 1, in: trimmed) ?? ""
                if !isLibraryPath(fileName) {
                    candidate.causeLineIndex = index
                    candidate.causeFileName = fileName
                    candidate.causeLineNumber = Int(group(match, 2, in: trimmed) ?? "")
                    if index + 1 < lines.count, looksLikePrintedCode(lines[index + 1]),
                       firstMatch(cCompilerLine, lines[index + 1].trimmingCharacters(in: .whitespaces)) == nil {
                        candidate.causeCodeLineIndex = index + 1
                        candidate.lastLineIndex = index + 1
                    }
                }
                found.append(candidate)
            } else if linkerLines.contains(where: { matches($0, trimmed) }) {
                found.append(Candidate(kind: .linkerError, family: "c", messageLineIndex: index,
                                       firstLineIndex: index, lastLineIndex: index, isListItem: true))
            } else if nativeCrashLines.contains(where: { matches($0, trimmed) }) {
                // The shell saying the program died. A runtime message just
                // above it ("Fatal error: Index out of range") says why.
                found.append(Candidate(kind: .nativeCrash, family: "crash", messageLineIndex: index,
                                       firstLineIndex: index, lastLineIndex: index, isSummary: true))
            } else if matches(makeFailureLine, trimmed) || matches(errorsGeneratedLine, trimmed) {
                found.append(Candidate(kind: .cCompilerError, family: "c", messageLineIndex: index,
                                       firstLineIndex: index, lastLineIndex: index, isSummary: true))
            }
        }
        return found
    }

    // MARK: Test runners

    private static let pytestFailedLine = regex(#"^FAILED\s+(\S+?\.py)(?:::(\S+))?(?:\s+-\s+(.+))?$"#)
    private static let pytestErrorLine = regex(#"^ERROR\s+(\S+?\.py)(?:::(\S+))?(?:\s+-\s+(.+))?$"#)
    private static let pytestSummaryLine = regex(#"^=+\s.*\b[1-9]\d* (?:failed|errors?)\b.*\bin [\d.]+s\b.*=*$"#)
    private static let pytestLocationLine = regex(#"^(\S+?\.py):(\d+):\s*(?:[A-Za-z_][\w.]*)?$"#)
    private static let pytestCodeMarker = regex(#"^>\s+(\S.*)$"#)
    private static let unittestFailureHeader = regex(#"^(?:FAIL|ERROR): (\w+) \((.+)\)"#)
    private static let unittestSummary = regex(#"^FAILED \((?:failures|errors)=\d+"#)
    private static let jestFailFile = regex(#"^\s*(?:FAIL|❯|×)\s+(\S+?\.(?:test|spec)\.[cm]?[jt]sx?)\b"#)
    private static let jestSummary = regex(#"^\s*(?:Tests|Test Suites|Test Files):?\s+[1-9]\d* failed\b"#)
    private static let jestCodeFrame = regex(#"^\s*>\s*(\d+)\s*\|\s?(.*\S.*)$"#)
    private static let mochaSummary = regex(#"^\s*[1-9]\d* failing$"#)
    private static let junitCounts = regex(#"^(?:\[ERROR\]\s*)?Tests run:\s*\d+,\s*Failures:\s*(\d+),\s*Errors:\s*(\d+)"#)
    private static let gradleTestFailed = regex(#"^(\S+)\s+>\s+(.+?)\s+FAILED$"#)
    private static let mavenFailuresHeader = regex(#"^\[ERROR\]\s+(?:Failures|Errors):\s*$"#)
    private static let mavenFailureLocation = regex(#"^\[ERROR\]\s+(\w+)\.(\w+):(\d+)\s+(.+)$"#)
    private static let junitConsoleFailed = regex(#"^\[\s*[1-9]\d* tests failed\s*\]$"#)
    private static let xctestCaseFailed = regex(#"^Test Case '(.+?)' failed \("#)
    private static let xctestExecutedWithFailures = regex(#"^\s*Executed \d+ tests?, with [1-9]\d* failures?"#)
    private static let swiftTestingFailed = regex(#"^\s*[✘✗xX]\s+Test(?: run with \d+ tests?)?\b.*\b(?:failed|recorded an issue)"#)

    private static func testRunnerCandidates(_ lines: [String]) -> [Candidate] {
        var found: [Candidate] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            func add(_ kind: RecognizedErrorKind, family: String, isSummary: Bool = false, isListItem: Bool = false) {
                found.append(Candidate(kind: kind, family: family, messageLineIndex: index, firstLineIndex: index,
                                       lastLineIndex: index, isSummary: isSummary, isListItem: isListItem))
            }
            if matches(pytestFailedLine, trimmed) || matches(pytestErrorLine, trimmed) {
                add(.pytestFailure, family: "pytest", isListItem: true)
            } else if matches(pytestSummaryLine, trimmed) {
                add(.pytestFailure, family: "pytest", isSummary: true)
            } else if matches(unittestFailureHeader, trimmed) {
                add(.unittestFailure, family: "unittest", isListItem: true)
            } else if matches(unittestSummary, trimmed) {
                add(.unittestFailure, family: "unittest", isSummary: true)
            } else if matches(jestFailFile, line) {
                add(.jestFailure, family: "jest", isListItem: true)
            } else if matches(jestSummary, line) {
                add(.jestFailure, family: "jest", isSummary: true)
            } else if matches(mochaSummary, line) {
                add(.mochaFailure, family: "jest", isSummary: true)
            } else if let match = firstMatch(junitCounts, trimmed),
                      (Int(group(match, 1, in: trimmed) ?? "0") ?? 0) + (Int(group(match, 2, in: trimmed) ?? "0") ?? 0) > 0 {
                add(.junitFailure, family: "java", isSummary: true)
            } else if matches(gradleTestFailed, trimmed) {
                add(.junitFailure, family: "java", isListItem: true)
            } else if matches(mavenFailuresHeader, trimmed) || matches(junitConsoleFailed, trimmed) {
                add(.junitFailure, family: "java", isSummary: true)
            } else if let match = firstMatch(mavenFailureLocation, trimmed) {
                var candidate = Candidate(kind: .junitFailure, family: "java", messageLineIndex: index,
                                          firstLineIndex: index, lastLineIndex: index, isListItem: true)
                candidate.causeLineIndex = index
                candidate.causeFileName = (group(match, 1, in: trimmed) ?? "") + ".java"
                candidate.causeLineNumber = Int(group(match, 3, in: trimmed) ?? "")
                found.append(candidate)
            } else if matches(xctestCaseFailed, trimmed) {
                add(.xctestFailure, family: "xctest", isListItem: true)
            } else if matches(swiftTestingFailed, trimmed), trimmed.contains("recorded an issue") {
                add(.xctestFailure, family: "xctest", isListItem: true)
            } else if matches(xctestExecutedWithFailures, trimmed) || matches(swiftTestingFailed, trimmed) {
                add(.xctestFailure, family: "xctest", isSummary: true)
            }
        }
        return found
    }

    // MARK: Judge verdicts

    private static let verdictLine = regex(#"^(?:Wrong Answer|Runtime Error|Time Limit Exceeded|Memory Limit Exceeded|Output Limit Exceeded|Compile Error|Compilation Error|Compilation error|Presentation Error|Terminated due to timeout|Wrong answer on test \d+|Time limit exceeded on test \d+|Memory limit exceeded on test \d+|Runtime error on test \d+|Idleness limit exceeded on test \d+)\b"#, caseInsensitive: true)
    private static let acceptedLine = regex(#"^Accepted\b"#)
    private static let lineMention = regex(#"\bline\s+(\d+)\b"#, caseInsensitive: true)
    /// What a fresh verdict is shown with. A history of old submissions
    /// shows verdicts with dates and languages instead.
    private static let verdictContextWords = ["input", "output", "expected", "testcase", "test case", "stdout",
                                              "last executed", "compiler message", "compile message", "on test", "passed", "error message",
                                              "your answer", "line "]

    private static func judgeVerdictCandidates(_ lines: [String]) -> [Candidate] {
        let verdictIndices = lines.indices.filter { matches(verdictLine, lines[$0].trimmingCharacters(in: .whitespaces)) }
        let acceptedCount = lines.filter { matches(acceptedLine, $0.trimmingCharacters(in: .whitespaces)) }.count
        // Three verdicts, or verdicts among accepted ones, is a list of
        // past submissions, not the result just returned.
        guard !verdictIndices.isEmpty, verdictIndices.count <= 2, acceptedCount < 2 else { return [] }
        return verdictIndices.compactMap { index in
            let verdict = lines[index].trimmingCharacters(in: .whitespaces).lowercased()
            let nearby = lines[max(0, index - 2)..<min(lines.count, index + 10)].joined(separator: " ").lowercased()
            guard verdict.contains(" on test ") || verdictContextWords.contains(where: { nearby.contains($0) }) else { return nil }
            var candidate = Candidate(kind: .judgeVerdict, family: "judge", messageLineIndex: index,
                                      firstLineIndex: index, lastLineIndex: index)
            // A runtime or compile error on a judge names the line it failed at.
            if let mentionIndex = ((index + 1)..<min(lines.count, index + 10)).first(where: { matches(lineMention, lines[$0]) }),
               let mentionMatch = firstMatch(lineMention, lines[mentionIndex]) {
                candidate.causeLineIndex = mentionIndex
                candidate.causeLineNumber = Int(group(mentionMatch, 1, in: lines[mentionIndex]) ?? "")
                candidate.lastLineIndex = mentionIndex
            }
            return candidate
        }
    }

    // MARK: - Enriching the chosen error

    /// Fills in where the error points when its own line did not say: the
    /// pytest location line, Jest's `> 12 |` code frame, a JUnit frame.
    private static func enriched(_ candidate: Candidate, lines: [String], searchRange: ClosedRange<Int>,
                                 newestLastLineIndex: Int) -> Candidate {
        var result = candidate
        guard searchRange.lowerBound >= 0, searchRange.upperBound < lines.count else { return result }
        if result.causeLineIndex == nil {
            switch result.kind {
            case .pytestFailure:
                if let locationIndex = searchRange.reversed().first(where: { matches(pytestLocationLine, lines[$0].trimmingCharacters(in: .whitespaces)) }),
                   let locationMatch = firstMatch(pytestLocationLine, lines[locationIndex].trimmingCharacters(in: .whitespaces)) {
                    let locationLine = lines[locationIndex].trimmingCharacters(in: .whitespaces)
                    result.causeLineIndex = locationIndex
                    result.causeFileName = group(locationMatch, 1, in: locationLine)
                    result.causeLineNumber = Int(group(locationMatch, 2, in: locationLine) ?? "")
                }
                if let markerIndex = searchRange.reversed().first(where: { matches(pytestCodeMarker, lines[$0]) }) {
                    result.causeCodeLineIndex = markerIndex
                }
            case .jestFailure, .mochaFailure:
                if let frameIndex = searchRange.first(where: { frameIndex in
                    guard let frameMatch = firstMatch(javaScriptFrame, lines[frameIndex]) else { return false }
                    return !isLibraryPath(group(frameMatch, 1, in: lines[frameIndex]) ?? "")
                }), let frameMatch = firstMatch(javaScriptFrame, lines[frameIndex]) {
                    result.causeLineIndex = frameIndex
                    result.causeFileName = group(frameMatch, 1, in: lines[frameIndex])
                    result.causeLineNumber = Int(group(frameMatch, 2, in: lines[frameIndex]) ?? "")
                }
                if let codeIndex = searchRange.first(where: { matches(jestCodeFrame, lines[$0]) }) {
                    result.causeCodeLineIndex = codeIndex
                }
                // The test's own title reads better than the file name.
                if let titleIndex = searchRange.first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("●") }) {
                    result.messageLineIndex = titleIndex
                }
            case .junitFailure, .buildToolFailure:
                if let locationIndex = searchRange.first(where: { matches(mavenFailureLocation, lines[$0].trimmingCharacters(in: .whitespaces)) }),
                   let locationMatch = firstMatch(mavenFailureLocation, lines[locationIndex].trimmingCharacters(in: .whitespaces)) {
                    let locationLine = lines[locationIndex].trimmingCharacters(in: .whitespaces)
                    result.causeLineIndex = locationIndex
                    result.causeFileName = (group(locationMatch, 1, in: locationLine) ?? "") + ".java"
                    result.causeLineNumber = Int(group(locationMatch, 3, in: locationLine) ?? "")
                }
            case .goTestFailure:
                if let locationIndex = searchRange.first(where: { matches(goTestLocation, lines[$0]) }),
                   let locationMatch = firstMatch(goTestLocation, lines[locationIndex]) {
                    result.causeLineIndex = locationIndex
                    result.causeFileName = group(locationMatch, 1, in: lines[locationIndex])
                    result.causeLineNumber = Int(group(locationMatch, 2, in: lines[locationIndex]) ?? "")
                }
            case .cargoTestFailure:
                if let panicIndex = searchRange.first(where: { matches(rustPanicLine, lines[$0].trimmingCharacters(in: .whitespaces)) }),
                   let panicMatch = firstMatch(rustPanicLine, lines[panicIndex].trimmingCharacters(in: .whitespaces)) {
                    let panicLine = lines[panicIndex].trimmingCharacters(in: .whitespaces)
                    result.causeLineIndex = panicIndex
                    result.causeFileName = group(panicMatch, 3, in: panicLine)
                    result.causeLineNumber = Int(group(panicMatch, 4, in: panicLine) ?? "")
                }
            default:
                break
            }
        }
        result.lastLineIndex = max(result.lastLineIndex, newestLastLineIndex)
        return result
    }

    // MARK: - Helpers

    /// Where the output of the command that failed begins: the line after
    /// the last shell prompt above it, or 80 lines up at most.
    private static let shellPromptLine = regex(#"^(?:\([\w.-]+\)\s*)?(?:[\w.@-]+[@:][\w.~/:-]*\s*)?(?:[\w.~/-]+\s+)?(?:git:\([^)]*\)\s*)?[$%❯➜]\s+\S"#)

    private static func startOfRun(_ lines: [String], endingAt endIndex: Int) -> Int {
        var index = endIndex
        while index > 0, endIndex - index < 80 {
            index -= 1
            if matches(shellPromptLine, lines[index]) { return index + 1 }
        }
        return index
    }

    private static let lowSeverityLogLine = regex(#"^(?:\S+\s+){0,3}?\[?(?:INFO|WARN|WARNING|DEBUG|TRACE|NOTICE)\]?(?:\s|:)|^(?:INFO|WARNING|DEBUG):[\w.]*:|^\[(?:info|warn|warning|debug)\]"#)

    private static func isPrecededByLowSeverityLogLine(_ lines: [String], lineIndex: Int) -> Bool {
        guard lineIndex > 0 else { return false }
        return matches(lowSeverityLogLine, lines[lineIndex - 1])
    }

    /// Library code is not the student's: the ring goes on their own frame.
    static func isLibraryPath(_ path: String) -> Bool {
        let markers = ["site-packages", "dist-packages", "/lib/python", "<frozen", "node_modules", "node:internal",
                       "internal/", "/usr/lib/", "/usr/local/lib/", "/usr/include/", "/Library/Developer/",
                       "/Applications/Xcode", "Swift/", "/rustc/", ".cargo/registry", "/library/std/", "/library/core/",
                       "/go/src/", "/pkg/mod/", "runtime/", "<anonymous>", "webpack-internal", "/opt/homebrew/"]
        return markers.contains { path.contains($0) }
    }

    /// A line the tool printed from the student's source, as opposed to
    /// another frame, a caret under it, or a blank.
    private static func looksLikePrintedCode(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return false }
        let caretOnly = trimmed.allSatisfy { "^~ |-".contains($0) }
        return !caretOnly && !trimmed.hasPrefix("at ") && !trimmed.hasPrefix("File ")
    }

    /// Curly quotes and odd spaces from text recognition, made plain, so
    /// the same patterns hold for recognized and accessibility text.
    static func normalizedLine(_ line: String) -> String {
        var normalized = line
        for (curly, straight) in [("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"),
                                  ("\u{00A0}", " "), ("\t", "    ")] {
            normalized = normalized.replacingOccurrences(of: curly, with: straight)
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        // Recognition puts a space after a dot or a colon in code it reads
        // as words: "Grades. java: 17", "Hello. java:5", "Grades. average(".
        for (pattern, template) in recognitionSpacingRepairs {
            normalized = pattern.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized),
                                                          withTemplate: template)
        }
        return normalized
    }

    private static let recognitionSpacingRepairs: [(NSRegularExpression, String)] = [
        (regex(#"(\w)\. ((?:java|kt|kts|py|js|jsx|ts|tsx|mjs|swift|rs|go|c|cc|cpp|h|hpp|m|mm|rb|cs|scala)\b)"#), "$1.$2"),
        (regex(#"(\.(?:java|kt|kts|py|js|jsx|ts|tsx|mjs|swift|rs|go|c|cc|cpp|h|hpp|m|mm|rb|cs|scala)) ?: ?(\d+)"#), "$1:$2"),
        (regex(#"(\w)\. ([a-z_$][\w$]*\()"#), "$1.$2")
    ]

    private static let volatileNumbers = regex(#"0x[0-9a-fA-F]+|\d+\.\d+|\b\d{6,}\b|\b\d{1,2}:\d{2}(?::\d{2})?\b"#)

    /// The message, where it points, and the first line, with addresses,
    /// timings and clock times taken out: running the same broken program
    /// twice gives the same fingerprint, a different error a different one.
    private static func fingerprint(for candidate: Candidate, lines: [String]) -> String {
        var parts = [candidate.kind.rawValue, lines[candidate.messageLineIndex], lines[candidate.firstLineIndex]]
        if let causeLineIndex = candidate.causeLineIndex { parts.append(lines[causeLineIndex]) }
        // "Wrong Answer" is the same words on every problem; the failing
        // input and output under it are what tell two verdicts apart.
        if candidate.kind == .judgeVerdict {
            let followingEnd = min(lines.count, candidate.messageLineIndex + 9)
            parts += lines[(candidate.messageLineIndex + 1)..<followingEnd]
        }
        return parts.map { part in
            let range = NSRange(part.startIndex..., in: part)
            return volatileNumbers.stringByReplacingMatches(in: part, range: range, withTemplate: "#")
                .lowercased()
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }.joined(separator: " | ")
    }

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        // The patterns are constants in this file; a bad one is a
        // programming error caught by the first run of the fixture test.
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        firstMatch(expression, text) != nil
    }

    private static func firstMatch(_ expression: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ match: NSTextCheckingResult, _ number: Int, in text: String) -> String? {
        guard number < match.numberOfRanges, let range = Range(match.range(at: number), in: text) else { return nil }
        return String(text[range])
    }
}

/// The errors already seen this session, by fingerprint, so the same error
/// never glows twice: not after the glow was ignored, not when the same
/// broken program is run again, not when it is scrolled back to.
nonisolated struct SeenErrorFingerprints {
    private var fingerprintsInOrderSeen: [String] = []
    private var fingerprintSet: Set<String> = []
    /// A session of hundreds of distinct errors is not a real one; the
    /// oldest are forgotten so memory stays flat.
    static let maximumRemembered = 500

    /// Records the fingerprint and says whether it was new.
    mutating func insertIfNew(_ fingerprint: String) -> Bool {
        guard fingerprintSet.insert(fingerprint).inserted else { return false }
        fingerprintsInOrderSeen.append(fingerprint)
        if fingerprintsInOrderSeen.count > Self.maximumRemembered {
            fingerprintSet.remove(fingerprintsInOrderSeen.removeFirst())
        }
        return true
    }
}
