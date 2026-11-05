//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  The pure logic under Buddy, checked with no model, network, microphone
//  or screen: run with `zsh scripts/test.sh`. The app starts nothing while
//  these run (CompanionAppDelegate.isRunningUnitTests).
//

import CoreGraphics
import Foundation
import Testing
import WebKit
@testable import Buddy

struct PermissionTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }
}

// MARK: - The test run leaves the student's Buddy alone

struct TestIsolationTests {
    @Test func theTestsLogToTheirOwnFile() {
        #expect(CompanionAppDelegate.isRunningUnitTests)
        #expect(TutorDebugLog.fileURL.lastPathComponent.hasSuffix("-unit-tests.log"))
    }
}

// MARK: - Version comparison

struct VersionComparisonTests {
    @Test(arguments: [
        ("1.10", "1.9", true),
        ("1.5", "1.5.0", false),
        ("1.5.0", "1.5", false),
        ("2", "1.99", true),
        ("1.5", "1.5", false),
        ("1.4.9", "1.5", false),
        ("1.6.1", "1.6", true),
        // A pre-release suffix is not a number, so that part counts as
        // zero: "1.5-beta" is read as 1.0 and is never newer than 1.5.
        ("1.5-beta", "1.5", false),
        ("1.6-beta", "1.5", false)
    ])
    func isVersionNewer(candidate: String, current: String, expectedNewer: Bool) {
        #expect(AppUpdater.isVersion(candidate, newerThan: current) == expectedNewer)
    }
}

// MARK: - Program stream cutting

struct ProgramStreamTests {
    @Test func fencedAndUnfencedProgramsAreRecognized() {
        #expect(ProgramStream.looksLikeProgram("```js\nstep(1);") == true)
        #expect(ProgramStream.looksLikeProgram("say(\"hello there\");") == true)
        #expect(ProgramStream.looksLikeProgram("Let me draw this.\nstep(1);\nsay(\"hi\");") == true)
        #expect(ProgramStream.looksLikeProgram("hi") == nil)
        #expect(ProgramStream.looksLikeProgram(String(repeating: "plain words ", count: 60)) == false)
    }

    @Test func aWordEndingInSayIsNotACall() {
        #expect(ProgramStream.closedSayArguments(in: "essay(\"not a sentence\");").isEmpty)
    }

    @Test func sayArgumentsReadEscapesAndApostrophes() {
        let code = #"""
        say("it's the \"middle\" one");
        say('single quoted');
        say(`a backtick sentence`);
        """#
        #expect(ProgramStream.closedSayArguments(in: code) == [
            "it's the \"middle\" one", "single quoted", "a backtick sentence"
        ])
    }

    @Test func anUnterminatedSayIsNotSpokenYet() {
        #expect(ProgramStream.closedSayArguments(in: "say(\"half a sente") == [])
    }

    @Test func piecesAreCutAtSayAndStepLinesAndTheRestArrivesOnce() {
        var stream = ProgramStream()
        let firstPart = "step(1);\nsay(\"one.\");\ncircle(\"t1\");\n"
        let firstUpdate = stream.feed(accumulatedText: firstPart)
        #expect(firstUpdate.newSentences == ["one."])
        #expect(firstUpdate.newPieces == ["step(1);\n"])

        let secondPart = firstPart + "say(\"two.\");\nbox(\"t2\");"
        let secondUpdate = stream.feed(accumulatedText: secondPart)
        #expect(secondUpdate.newSentences == ["two."])
        #expect(secondUpdate.newPieces == ["say(\"one.\");\ncircle(\"t1\");\n"])

        // Feeding the same text again adds nothing.
        let repeated = stream.feed(accumulatedText: secondPart)
        #expect(repeated.newSentences.isEmpty)
        #expect(repeated.newPieces.isEmpty)

        let finished = stream.finish(fullText: secondPart)
        #expect(finished.newSentences.isEmpty)
        #expect(finished.newPieces == ["say(\"two.\");\nbox(\"t2\");"])
        #expect(stream.finish(fullText: secondPart).newPieces.isEmpty)
    }

    @Test func talkBeforeAnUnfencedProgramIsNotCode() {
        let text = "Here is the picture.\nstep(1);\nsay(\"hi.\");"
        #expect(ProgramStream.code(in: text) == "step(1);\nsay(\"hi.\");")
    }

    @Test func fenceLinesAreDropped() {
        #expect(ProgramStream.code(in: "```js\nsay(\"a.\");\n```") == "say(\"a.\");")
    }
}

// MARK: - Speech hints

struct SpeechHintTests {
    @Test func shortLabelsAndTermsAreKeptAndNoiseIsDropped() {
        let hints = TalkSessionCoordinator.speechHints(
            screenLabels: ["Wallet DB", "O(n)", "S3 bucket", "12:40", "id 83749201", "the gRPC client retries"],
            recentAnswerPrograms: [],
            recentlyLearnedConceptNames: [])
        #expect(hints.contains("Wallet DB"))
        #expect(hints.contains("O(n)"))
        #expect(hints.contains("S3 bucket"))
        #expect(hints.contains("gRPC"))
        #expect(!hints.contains("12:40"))
        #expect(!hints.contains("id 83749201"))
    }

    /// Pinned as it is: a two-character name with one letter ("S3", "v2")
    /// is dropped on its own, though the comment in `speechHints` names
    /// them as kept. Within a longer label ("S3 bucket") it is heard.
    @Test func aTwoCharacterNameOnItsOwnIsDropped() {
        let hints = TalkSessionCoordinator.speechHints(
            screenLabels: ["S3", "v2"], recentAnswerPrograms: [], recentlyLearnedConceptNames: [])
        #expect(hints.isEmpty)
    }

    @Test func duplicatesAreDroppedWhateverTheirCase() {
        let hints = TalkSessionCoordinator.speechHints(
            screenLabels: ["Kafka"], recentAnswerPrograms: [], recentlyLearnedConceptNames: ["kafka", "Consistent hashing"])
        #expect(hints.filter { $0.lowercased() == "kafka" }.count == 1)
        #expect(hints.contains("Consistent hashing"))
    }

    @Test func spokenSentencesAndColoursInProgramsAreNotHints() {
        let program = "say(\"The Load Balancer spreads requests.\");\nbox(\"Load Balancer\", {color: \"#FF0000\"});"
        let hints = TalkSessionCoordinator.speechHints(
            screenLabels: [], recentAnswerPrograms: [program], recentlyLearnedConceptNames: [])
        #expect(hints == ["Load Balancer"])
    }

    @Test func eachSourceIsCappedAndTheScreenTakesWhatIsLeft() {
        let screenLabels = (1...80).map { "Screen Label \(String(UnicodeScalar(65 + $0 % 26)!))\(String(UnicodeScalar(65 + $0 / 26)!))" }
        let concepts = (1...30).map { "idea \(String(UnicodeScalar(97 + $0 % 26)!))\(String(UnicodeScalar(97 + $0 / 26)!))" }
        let hints = TalkSessionCoordinator.speechHints(
            screenLabels: screenLabels, recentAnswerPrograms: [], recentlyLearnedConceptNames: concepts)
        #expect(hints.count <= 100)
        #expect(hints.filter { $0.hasPrefix("idea") }.count == 15)
    }
}

// MARK: - History shortening

struct HistoryShorteningTests {
    private func program(_ number: Int) -> String {
        "step(1);\nsay(\"sentence \(number).\");\nbox(\"t1\");"
    }

    @Test func theEleventhWholeAnswerShortensTheSixOldest() {
        var history: [(userTranscript: String, assistantResponse: String)] = []
        for number in 1...11 {
            history = ConversationHistory.history(history, remembering: "question \(number)", answer: program(number))
        }
        let shortened = history.filter { $0.assistantResponse.hasPrefix(ConversationHistory.spokenOnlyMarker) }
        #expect(history.count == 11)
        #expect(shortened.count == ConversationHistory.historyTrimBatch)
        #expect(history[0].assistantResponse == ConversationHistory.spokenOnlyMarker + " sentence 1.")
        #expect(history[10].assistantResponse == program(11))
    }

    @Test func pastFortyTheOldestSixAreDropped() {
        var history: [(userTranscript: String, assistantResponse: String)] = []
        for number in 1...41 {
            history = ConversationHistory.history(history, remembering: "question \(number)", answer: program(number))
        }
        #expect(history.count == 41 - ConversationHistory.historyTrimBatch)
        #expect(history.first?.userTranscript == "question 7")
        // Every answer already shortened stays as it was.
        #expect(history.allSatisfy { !$0.assistantResponse.hasPrefix(ConversationHistory.spokenOnlyMarker + " " + ConversationHistory.spokenOnlyMarker) })
    }

    @Test func spokenPartOfAProgramAndOfProse() {
        #expect(ConversationHistory.spokenPart(of: "say(\"one.\");\nsay(\"the \\\"two\\\".\");")
                == ConversationHistory.spokenOnlyMarker + " one. the \"two\".")
        let prose = String(repeating: "word ", count: 400)
        #expect(ConversationHistory.spokenPart(of: prose) == ConversationHistory.spokenOnlyMarker + " " + String(prose.prefix(800)))
    }
}

// MARK: - Filing a lesson under a known idea

struct FilingMatchTests {
    private func known(_ name: String, aliases: [String]) -> RememberedConcept {
        RememberedConcept(id: UUID(), name: name, aliases: aliases, cues: nil, summary: "", lastAngle: nil,
                          firstExplainedAt: Date(), lastExplainedAt: Date(), timesExplained: 1, timesLost: 0,
                          lastLostAt: nil, stabilityDays: 2, lessonTitles: [])
    }

    @Test func theLiveMisreadIdIsRefused() {
        let division = known("division by zero", aliases: ["zerodivisionerror", "divide by zero", "zero division"])
        #expect(!FilingMatchCheck.namesAgree(extractedName: "off by one error",
                                             extractedAliases: ["off by one", "fencepost error", "index out of bounds"],
                                             known: division))
    }

    @Test func theSameIdeaUnderItsOwnOrARelatedNameIsKept() {
        let offByOne = known("off by one error", aliases: ["off-by-one", "index out of range", "fencepost error"])
        #expect(FilingMatchCheck.namesAgree(extractedName: "off-by-one error", extractedAliases: [], known: offByOne))
        #expect(FilingMatchCheck.namesAgree(extractedName: "off-by-one bounds", extractedAliases: [], known: offByOne))
        let hashing = known("consistent hashing", aliases: ["hash ring"])
        #expect(FilingMatchCheck.namesAgree(extractedName: "adding nodes to hash ring", extractedAliases: [], known: hashing))
        #expect(FilingMatchCheck.namesAgree(extractedName: "node addition",
                                            extractedAliases: ["consistent hashing node addition"], known: hashing))
        #expect(FilingMatchCheck.namesAgree(extractedName: "binary heap", extractedAliases: [], known: known("heap", aliases: [])))
    }

    @Test func sharedAliasesOrOneEverydayWordAreNotEnough() {
        let arrayBounds = known("array index out of bounds", aliases: ["index out of range", "indexerror"])
        #expect(!FilingMatchCheck.namesAgree(extractedName: "off by one error", extractedAliases: ["index out of range"],
                                             known: arrayBounds))
        let indexing = known("database indexing", aliases: ["index"])
        #expect(!FilingMatchCheck.namesAgree(extractedName: "array index", extractedAliases: [], known: indexing))
        #expect(!FilingMatchCheck.namesAgree(extractedName: "linear scan", extractedAliases: ["search"],
                                             known: known("binary search", aliases: [])))
    }
}

// MARK: - Spending arithmetic

struct SpendingArithmeticTests {
    @Test func claudeRatesAndCacheWrites() {
        #expect(abs(APIPrices.claude(model: "claude-sonnet-5-5", freshInput: 1_000_000, cachedInput: 0, cacheWrites: 0, output: 0) - 2) < 1e-9)
        #expect(abs(APIPrices.claude(model: "claude-opus-5-5", freshInput: 0, cachedInput: 0, cacheWrites: 0, output: 1_000_000) - 20) < 1e-9)
        #expect(abs(APIPrices.claude(model: "claude-haiku-5", freshInput: 0, cachedInput: 1_000_000, cacheWrites: 0, output: 0) - 0.01) < 1e-9)
        // A cache write costs 1.25 times the input price, or twice when kept an hour.
        #expect(abs(APIPrices.claude(model: "claude-sonnet-5-5", freshInput: 0, cachedInput: 0, cacheWrites: 1_000_000, output: 0) - 2.5) < 1e-9)
        #expect(abs(APIPrices.claude(model: "claude-sonnet-5-5", freshInput: 0, cachedInput: 0, cacheWrites: 0,
                                     cacheWritesKeptAnHour: 1_000_000, output: 0) - 4) < 1e-9)
    }

    @Test func geminiIntroductoryPriceThenDouble() {
        let november = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 30).date!
        let december = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 12, day: 1).date!
        let before = APIPrices.gemini(promptTokens: 1_000_000, cachedTokens: 0, outputTokens: 1_000_000, on: november)
        let after = APIPrices.gemini(promptTokens: 1_000_000, cachedTokens: 0, outputTokens: 1_000_000, on: december)
        #expect(abs(before - 12) < 1e-9)
        #expect(abs(after - 24) < 1e-9)
        // Cached tokens are taken out of the prompt's fresh input.
        #expect(abs(APIPrices.gemini(promptTokens: 1_000_000, cachedTokens: 1_000_000, outputTokens: 0, on: november) - 0.10) < 1e-9)
    }

    @Test func thinkingTokensBillAsOutput() {
        let withThinking = APIPrices.gemini(usageMetadata: ["candidatesTokenCount": 100, "thoughtsTokenCount": 900])
        let withoutThinking = APIPrices.gemini(usageMetadata: ["candidatesTokenCount": 1_000])
        #expect(abs(withThinking - withoutThinking) < 1e-12)
    }

    @Test func deepgramPerCharacter() {
        #expect(abs(APIPrices.deepgram(characters: 1_000) - 0.030) < 1e-12)
    }
}

// MARK: - Spending by service and purpose

struct SpendingBreakdownTests {
    /// A day as Buddy 1.6 wrote it: services but no purposes.
    private let dayWithoutPurposes = """
    {"date":"2026-11-03","questions":4,"guideSteps":1,"dollars":0.30,"dollarsByService":{"claude":0.25,"deepgram":0.05}}
    """
    /// Older still: no guide steps and no service split.
    private let dayWithOnlyTotals = """
    {"date":"2026-11-02","questions":2,"dollars":0.10}
    """

    @Test func oldDaysStillDecodeWithTheirServiceSplit() throws {
        let days = try JSONDecoder().decode([SpendingMeter.Day].self,
                                            from: Data("[\(dayWithoutPurposes),\(dayWithOnlyTotals)]".utf8))
        #expect(days.count == 2)
        #expect(days[0].questions == 4 && days[0].guideSteps == 1)
        #expect(days[0].dollarsByService == ["claude": 0.25, "deepgram": 0.05])
        #expect(days[0].dollarsByPurpose.isEmpty)
        #expect(days[1].guideSteps == 0 && days[1].dollarsByService.isEmpty)
        #expect(abs(days[1].dollars - 0.10) < 1e-12)
    }

    @Test func aDayRoundTripsWithItsPurposes() throws {
        var day = SpendingMeter.Day(date: "2026-11-05")
        SpendingMeter.add(0.20, for: .claude, purpose: .answers, to: &day)
        SpendingMeter.add(0.01, for: .deepgram, purpose: .listening, to: &day)
        let decoded = try JSONDecoder().decode(SpendingMeter.Day.self, from: JSONEncoder().encode(day))
        #expect(decoded == day)
        #expect(decoded.dollarsByPurpose == ["answers": 0.20, "listening": 0.01])
    }

    @Test func eachCostCountsUnderItsServiceAndItsPurpose() {
        var day = SpendingMeter.Day(date: "2026-11-05")
        SpendingMeter.add(0.40, for: .claude, purpose: .answers, to: &day)
        SpendingMeter.add(0.02, for: .claude, purpose: .helpers, to: &day)
        SpendingMeter.add(0.05, for: .deepgram, purpose: .voice, to: &day)
        SpendingMeter.add(0.01, for: .deepgram, purpose: .hearing, to: &day)
        #expect(abs(day.dollars - 0.48) < 1e-12)
        #expect(abs((day.dollarsByService["claude"] ?? 0) - 0.42) < 1e-12)
        #expect(abs((day.dollarsByService["deepgram"] ?? 0) - 0.06) < 1e-12)
        #expect(abs(day.dollarsByPurpose.values.reduce(0, +) - day.dollars) < 1e-12)
    }

    @Test func monthTotalsAddOnlyThatMonthsDays() throws {
        let oldDay = try JSONDecoder().decode(SpendingMeter.Day.self, from: Data(dayWithoutPurposes.utf8))
        var today = SpendingMeter.Day(date: "2026-11-05")
        today.questions = 3
        SpendingMeter.add(0.10, for: .gemini, purpose: .answers, to: &today)
        SpendingMeter.add(0.02, for: .deepgram, purpose: .lectures, to: &today)
        var lastMonth = SpendingMeter.Day(date: "2026-10-31")
        SpendingMeter.add(5, for: .claude, purpose: .answers, to: &lastMonth)
        // A day named like the month but in another year is not this month.
        var anotherYear = SpendingMeter.Day(date: "2025-11-05")
        SpendingMeter.add(7, for: .claude, purpose: .answers, to: &anotherYear)

        let month = SpendingMeter.monthTotals(of: [anotherYear, lastMonth, oldDay, today], month: "2026-11")
        #expect(abs(month.dollars - 0.42) < 1e-12)
        #expect(month.questions == 7 && month.guideSteps == 1)
        #expect(abs(month.dollars(for: .claude) - 0.25) < 1e-12)
        #expect(abs(month.dollars(for: .gemini) - 0.10) < 1e-12)
        #expect(abs(month.dollars(for: .deepgram) - 0.07) < 1e-12)
        // The old day has no purposes, so only today's are sorted.
        #expect(abs(month.dollars(for: .answers) - 0.10) < 1e-12)
        #expect(abs(month.dollars(for: .lectures) - 0.02) < 1e-12)
        #expect(month.dollars(for: .voice) == 0)
    }

    @Test func theCardLeavesOutWhatHadNoSpending() {
        var today = SpendingMeter.Day(date: "2026-11-05")
        today.questions = 1
        SpendingMeter.add(0.30, for: .claude, purpose: .answers, to: &today)
        var earlier = SpendingMeter.Day(date: "2026-11-01")
        SpendingMeter.add(0.04, for: .deepgram, purpose: .voice, to: &earlier)
        let breakdown = SpendingBreakdown(today: SpendingMeter.Totals(adding: [today]),
                                          thisMonth: SpendingMeter.Totals(adding: [earlier, today]))
        #expect(breakdown.serviceLines.map(\.name) == ["Claude", "Deepgram"])
        #expect(breakdown.purposeLines.map(\.name) == ["Answers", "Voice"])
        #expect(breakdown.purposeLines[1].today == 0 && breakdown.purposeLines[1].thisMonth == 0.04)
        #expect(breakdown.countsSentence == "1 question today")
        #expect(breakdown.spokenDescription.hasPrefix("Claude, $0.30 today, $0.30 this month."))
        #expect(breakdown.spokenDescription.hasSuffix(SpendingBreakdown.whereTheNumbersComeFrom))
    }

    @Test func countsNameGuideStepsOnlyWhenThereAreSome() {
        var today = SpendingMeter.Day(date: "2026-11-05")
        today.questions = 12
        today.guideSteps = 3
        let breakdown = SpendingBreakdown(today: SpendingMeter.Totals(adding: [today]),
                                          thisMonth: SpendingMeter.Totals(adding: [today]))
        #expect(breakdown.countsSentence == "12 questions and 3 guide steps today")
        #expect(breakdown.serviceLines.isEmpty && breakdown.purposeLines.isEmpty)
    }
}

// MARK: - Key error reading

struct KeyErrorReadingTests {
    @Test func rejectedKeysAreKeyProblems() {
        #expect(APIKeyChecker.problem(in: ClaudeError.httpStatus(401, "invalid x-api-key"))?.service == .anthropic)
        #expect(APIKeyChecker.problem(in: ClaudeError.httpStatus(400, "Your credit balance is too low"))?.service == .anthropic)
        #expect(APIKeyChecker.problem(in: GeminiError.httpStatus(403, "permission denied"))?.service == .gemini)
        #expect(APIKeyChecker.problem(in: GeminiError.httpStatus(429, "Quota exceeded: RESOURCE_EXHAUSTED"))?.service == .gemini)
    }

    @Test func busyAndNetworkFailuresAreNotKeyProblems() {
        #expect(APIKeyChecker.problem(in: ClaudeError.httpStatus(529, "overloaded")) == nil)
        #expect(APIKeyChecker.problem(in: GeminiError.httpStatus(429, "slow down")) == nil)
        #expect(APIKeyChecker.problem(in: URLError(.notConnectedToInternet)) == nil)
    }

    @Test(arguments: [401, 402, 403])
    func aRefusedDeepgramKeyIsReported(status: Int) {
        #expect(APIKeyChecker.problem(in: DeepgramError.httpStatus(status))?.service == .deepgram)
    }

    @Test func aMissingDeepgramKeyOrAServerErrorIsNot() {
        #expect(APIKeyChecker.problem(in: DeepgramError.missingKey) == nil)
        #expect(APIKeyChecker.problem(in: DeepgramError.httpStatus(500)) == nil)
    }

    @Test func interpretSaysWhatIsWrong() {
        #expect(APIKeyChecker.interpret(status: 402, body: "", service: .deepgram)
                == .rejected("The key is fine, but the Deepgram account is out of credit."))
        if case .worksWithNote = APIKeyChecker.interpret(status: 429, body: "", service: .anthropic) {} else {
            Issue.record("a rate limit is not a rejected key")
        }
        if case .couldNotCheck = APIKeyChecker.interpret(status: 529, body: "", service: .anthropic) {} else {
            Issue.record("an overloaded server is not a rejected key")
        }
    }
}

// MARK: - Failure kinds in the answer pipeline

struct AnswerFailureKindTests {
    @Test func cancellationInEveryForm() {
        #expect(CompanionManager.isCancellation(CancellationError()))
        #expect(CompanionManager.isCancellation(URLError(.cancelled)))
        #expect(CompanionManager.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        #expect(!CompanionManager.isCancellation(URLError(.timedOut)))
        #expect(!CompanionManager.isCancellation(ClaudeError.httpStatus(500, "")))
    }

    @Test func lostConnections() {
        #expect(CompanionManager.isLostConnection(URLError(.networkConnectionLost)))
        #expect(CompanionManager.isLostConnection(URLError(.timedOut)))
        #expect(CompanionManager.isLostConnection(CompanionManager.AnswerStreamStalled()))
        #expect(!CompanionManager.isLostConnection(URLError(.cancelled)))
        #expect(!CompanionManager.isLostConnection(ClaudeError.httpStatus(401, "")))
    }

    @Test func busyRefusals() {
        #expect(CompanionManager.isBusyRefusal(ClaudeError.httpStatus(429, "")))
        #expect(CompanionManager.isBusyRefusal(ClaudeError.httpStatus(529, "")))
        #expect(CompanionManager.isBusyRefusal(ClaudeError.streamError("Overloaded")))
        #expect(CompanionManager.isBusyRefusal(GeminiError.httpStatus(503, "")))
        #expect(!CompanionManager.isBusyRefusal(ClaudeError.httpStatus(401, "")))
        #expect(!CompanionManager.isBusyRefusal(URLError(.timedOut)))
    }
}

// MARK: - Routing and benching

struct RoutingTests {
    @Test func aBenchedBrainIsSkippedForFiveMinutesThenBack() {
        let router = ModelRouter()
        var now = Date(timeIntervalSince1970: 1_000_000)
        router.currentDate = { now }
        let allowed: Set<RoutedBrain> = [.sonnet, .opus, .argon]
        let probabilities: [QuestionKind: Double] = [.normal: 1]
        let first = router.choose(probabilities: probabilities, allowed: allowed).ranking[0]

        router.bench(first, because: "a test")
        #expect(!router.choose(probabilities: probabilities, allowed: allowed).ranking.contains(first))

        now = now.addingTimeInterval(ModelRouter.benchSeconds - 1)
        #expect(!router.choose(probabilities: probabilities, allowed: allowed).ranking.contains(first))

        now = now.addingTimeInterval(2)
        #expect(router.choose(probabilities: probabilities, allowed: allowed).ranking[0] == first)
    }

    @Test func aBrainThatKeepsFailingIsBenchedLongerUntilItAnswers() {
        let router = ModelRouter()
        var now = Date(timeIntervalSince1970: 1_000_000)
        router.currentDate = { now }
        let allowed: Set<RoutedBrain> = [.sonnet, .opus, .argon]
        func isBenched() -> Bool { !router.choose(probabilities: [.teach: 1], allowed: allowed).ranking.contains(.argon) }

        router.bench(.argon, because: "a test")
        now = now.addingTimeInterval(ModelRouter.benchSeconds + 1)
        #expect(!isBenched())
        // Fails again as soon as it is back: twice as long this time.
        router.bench(.argon, because: "a test")
        now = now.addingTimeInterval(ModelRouter.benchSeconds + 1)
        #expect(isBenched())
        now = now.addingTimeInterval(ModelRouter.benchSeconds)
        #expect(!isBenched())
        // An answer clears the record, so the next failure is a short bench.
        router.answered(by: .argon)
        router.bench(.argon, because: "a test")
        now = now.addingTimeInterval(ModelRouter.benchSeconds + 1)
        #expect(!isBenched())
        // Never past an hour however many times in a row.
        for _ in 0..<10 { router.bench(.argon, because: "a test") }
        now = now.addingTimeInterval(ModelRouter.longestBenchSeconds + 1)
        #expect(!isBenched())
    }

    @Test func everyBrainBenchedStillAnswers() {
        let router = ModelRouter()
        router.currentDate = { Date(timeIntervalSince1970: 1_000_000) }
        for brain in RoutedBrain.allCases { router.bench(brain, because: "a test") }
        #expect(!router.choose(probabilities: [.quick: 1], allowed: Set(RoutedBrain.allCases)).ranking.isEmpty)
    }

    @Test func onlyAllowedBrainsAreRanked() {
        let ranking = ModelRouter().choose(probabilities: [.teach: 1], allowed: [.argon]).ranking
        #expect(ranking == [.argon])
    }

    @Test func tiesWithinTheNoiseGoToTheCheaperBrain() {
        // From RouteTable.json: on a quick question Sonnet is within the
        // judges' noise of the best once its speed is counted, and cheaper
        // than Opus, so Opus never comes first.
        let ranking = ModelRouter().choose(probabilities: [.quick: 1], allowed: [.sonnet, .opus]).ranking
        #expect(ranking.first == .sonnet)
    }

    @Test func firstWordsDeadlineStaysInItsBounds() {
        let router = ModelRouter()
        for brain in RoutedBrain.allCases {
            for kind in [QuestionKind.quick, .normal, .teach, .reexplain, .tradeOff] {
                let deadline = router.firstWordsDeadline(for: brain, probabilities: [kind: 1])
                #expect(deadline >= 8 && deadline <= 30)
            }
        }
    }
}

// MARK: - Utterance joining

struct UtteranceJoiningTests {
    @Test func aRevisionReplacesTheCurrentUtterance() {
        var utterances = SpokenUtterances()
        utterances.update(with: "what is", utteranceEnded: false)
        utterances.update(with: "what is a hash", utteranceEnded: false)
        #expect(utterances.fullText == "what is a hash")
    }

    @Test func anEndedUtteranceIsKeptAndTheNextFollowsIt() {
        var utterances = SpokenUtterances()
        utterances.update(with: "what is a hash table", utteranceEnded: true)
        utterances.update(with: "and why", utteranceEnded: false)
        #expect(utterances.fullText == "what is a hash table and why")
    }

    @Test func aShorterTextStartingDifferentlyIsANewUtterance() {
        var utterances = SpokenUtterances()
        utterances.update(with: "what is a hash table", utteranceEnded: false)
        utterances.update(with: "why", utteranceEnded: false)
        #expect(utterances.fullText == "what is a hash table why")
    }
}

// MARK: - Talk-over hearing

struct TalkOverHearingTests {
    private let recentlySpoken = [
        "high starts one slot past the end, and that is the whole bug.",
        "take three buckets, three, seven and nine, and search for twenty.",
        "the cache absorbs most reads, so the database only sees misses."
    ]

    private func meaning(_ heard: String, loud: Bool = true) -> TalkOverHearing.Meaning {
        TalkOverHearing.meaning(ofUtterance: heard, recentlySpoken: recentlySpoken, wasLoudEnough: loud)
    }

    @Test func controlsAreRead() {
        #expect(meaning("hold on") == .hold)
        #expect(meaning("okay, go on please") == .resume)
        #expect(meaning("slow down") == .slower)
        #expect(meaning("go back") == .repeatPreviousSentence)
        #expect(meaning("Say that again.") == .replayAnswer)
    }

    @Test func aQuestionCutsIn() {
        if case .question = meaning("wait, why?") {} else { Issue.record("\"wait, why?\" should be a question") }
    }

    @Test func echoesQuietVoicesAndOtherPeopleAreIgnored() {
        func isIgnored(_ meaning: TalkOverHearing.Meaning) -> Bool {
            if case .ignore = meaning { return true }
            return false
        }
        #expect(isIgnored(meaning("the cache absorbs most reads so the database only sees misses")))
        #expect(isIgnored(meaning("wait, why?", loud: false)))
        #expect(isIgnored(meaning("yeah I'll call you back later")))
    }
}

// MARK: - Error recognition

struct ErrorRecognitionTests {
    @Test func aPythonTracebackIsRecognizedWithItsCause() throws {
        let lines = """
        maya@MacBook-Air stats % python3 average.py
        Traceback (most recent call last):
          File "/Users/maya/stats/average.py", line 8, in <module>
            print(average([]))
          File "/Users/maya/stats/average.py", line 4, in average
            return sum(values) / len(values)
        ZeroDivisionError: division by zero
        maya@MacBook-Air stats %
        """.components(separatedBy: "\n")
        let recognized = try #require(ErrorRecognizer.recognize(lines: lines, place: .terminal))
        #expect(recognized.causeFileName?.hasSuffix("/average.py") == true)
        #expect(recognized.causeLineNumber == 4)
        #expect(lines[recognized.messageLineIndex].hasPrefix("ZeroDivisionError"))
    }

    @Test func sourceThatRaisesAndCatchesIsNotAnError() {
        let lines = """
        def load(path):
            try:
                return open(path).read()
            except FileNotFoundError as error:
                raise ValueError("missing file") from error
        """.components(separatedBy: "\n")
        #expect(ErrorRecognizer.recognize(lines: lines, place: .editor) == nil)
    }

    @Test func theSameErrorReadAgainKeepsItsFingerprint() throws {
        let lines = [
            "$ node app.js",
            "/Users/sam/app.js:3",
            "    console.log(user.name);",
            "                     ^",
            "TypeError: Cannot read properties of undefined (reading 'name')",
            "    at Object.<anonymous> (/Users/sam/app.js:3:22)",
            "    at node:internal/main/run_main_module:28:49"
        ]
        let first = try #require(ErrorRecognizer.recognize(lines: lines, place: .terminal))
        let again = try #require(ErrorRecognizer.recognize(lines: ["$ clear"] + lines, place: .terminal))
        #expect(first.fingerprint == again.fingerprint)
    }
}

// MARK: - Push to talk

struct PushToTalkTests {
    @Test func theShortcutIsHeldOnlyWithBothModifiers() {
        let controlAndOption = CGEventFlags([.maskControl, .maskAlternate]).rawValue
        #expect(BuddyPushToTalkShortcut.isShortcutHeld(modifierFlagsRawValue: controlAndOption, isSpaceKeyDown: false))
        #expect(!BuddyPushToTalkShortcut.isShortcutHeld(modifierFlagsRawValue: CGEventFlags.maskControl.rawValue, isSpaceKeyDown: false))
        #expect(!BuddyPushToTalkShortcut.isShortcutHeld(modifierFlagsRawValue: 0, isSpaceKeyDown: false))
    }

    @Test func pressAndReleaseTransitions() {
        let controlAndOption = CGEventFlags([.maskControl, .maskAlternate]).rawValue
        #expect(BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged, keyCode: 0, modifierFlagsRawValue: controlAndOption, wasShortcutPreviouslyPressed: false) == .pressed)
        #expect(BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged, keyCode: 0, modifierFlagsRawValue: controlAndOption, wasShortcutPreviouslyPressed: true) == .none)
        #expect(BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged, keyCode: 0, modifierFlagsRawValue: CGEventFlags.maskControl.rawValue, wasShortcutPreviouslyPressed: true) == .released)
        #expect(BuddyPushToTalkShortcut.shortcutTransition(
            for: .keyDown, keyCode: 17, modifierFlagsRawValue: controlAndOption, wasShortcutPreviouslyPressed: false) == .none)
    }
}

// MARK: - Board layout invariants

struct BoardLayoutTests {
    private static let turns = [
        """
        step(1);
        say("consistent hashing decides which server keeps each key.");
        board.title("consistent hashing");
        board.group("ring", "the hash ring, 0 to 99");
        board.circle("a", "A at 10", {in: "ring"});
        board.circle("b", "B at 45", {in: "ring"});
        board.circle("c", "C at 80", {in: "ring"});
        board.box("key", "user42 hashes to 30");
        board.link("key", "b", "walks clockwise");
        board.table("owns", "who owns what", [["range", "server"], ["81 to 10", "A"], ["11 to 45", "B"], ["46 to 80", "C"]], {near: "ring", side: "below"});
        board.note("tip", "only one neighbour's keys move");
        """,
        """
        say("when b leaves, only its keys move.");
        board.update("b", "B left");
        board.unlink("key", "b");
        board.link("key", "c", "now lands on C");
        board.list("leave", "a server leaves", ["its keys go to the next server", "every other key stays put"]);
        board.box("client", "client");
        board.box("hash", "hash function");
        board.link("client", "hash", "key");
        board.label("why", "clockwise is the rule");
        """
    ]

    private func boardAfterTurns() -> (board: TeachingBoard, layout: BoardLayout) {
        let surface = BoardSurface(canvasWidth: 1512, canvasHeight: 982)
        let board = TeachingBoard(layout: surface.layout)
        for turn in Self.turns {
            board.beginTurn()
            _ = BoardProgramTranslator.translate(turn, on: board)
        }
        return (board, surface.layout)
    }

    @Test func everyCallPlacesAnElement() {
        let (board, _) = boardAfterTurns()
        let identifiers = Set(board.state.elements.map(\.identifier))
        for identifier in ["ring", "a", "b", "c", "key", "owns", "tip", "leave", "client", "hash", "why"] {
            #expect(identifiers.contains(identifier), "\(identifier) was not placed")
        }
    }

    @Test func elementsNeverOverlapUnlessOneHoldsTheOther() {
        let (board, _) = boardAfterTurns()
        let elements = board.state.elements
        for (firstIndex, first) in elements.enumerated() {
            for second in elements[(firstIndex + 1)...] {
                let related = first.groupIdentifier == second.identifier || second.groupIdentifier == first.identifier
                guard !related else { continue }
                #expect(!first.frame.intersects(second.frame), "\(first.identifier) overlaps \(second.identifier)")
            }
        }
    }

    @Test func membersSitInsideTheirGroup() {
        let (board, _) = boardAfterTurns()
        let elementsByIdentifier = Dictionary(uniqueKeysWithValues: board.state.elements.map { ($0.identifier, $0) })
        for member in board.state.elements {
            guard let groupIdentifier = member.groupIdentifier, let group = elementsByIdentifier[groupIdentifier] else { continue }
            #expect(group.frame.contains(member.frame), "\(member.identifier) is outside \(groupIdentifier)")
        }
    }

    @Test func elementsStayOnTheBoard() {
        let (board, layout) = boardAfterTurns()
        for element in board.state.elements {
            #expect(element.frame.minX >= 0 && element.frame.minY >= 0, "\(element.identifier) starts off the board")
            #expect(element.frame.maxX <= layout.widestBoardWidth + 0.5, "\(element.identifier) runs past the board's width")
        }
    }

    @Test func anIdentifierUsedTwiceUpdatesInsteadOfRedrawing() {
        let (board, _) = boardAfterTurns()
        #expect(board.state.elements.filter { $0.identifier == "b" }.count == 1)
        #expect(board.state.elements.first { $0.identifier == "b" }?.text == "B left")
    }

    /// The live TCP board (scripts/board/live_tcp): a table right of a group
    /// at the board's right edge, a label asked to sit below it and a second
    /// below that. Both once sat on one row below and left of the table.
    @Test func labelsAskedToSitBelowATableStackUnderIt() {
        let surface = BoardSurface(canvasWidth: 1512, canvasHeight: 982)
        let board = TeachingBoard(layout: surface.layout)
        board.beginTurn()
        _ = BoardProgramTranslator.translate("""
            board.title("how tcp works");
            board.box("client", "client", {tone: "sky"});
            board.box("server", "server", {tone: "mint", near: "client", side: "right"});
            board.note("loss", "network can lose or shuffle packets", {tone: "coral", near: "client", side: "below"});
            board.group("hs", "the three way handshake", {near: "loss", side: "below"});
            board.box("syn", "1. SYN, seq 100", {in: "hs", tone: "sky"});
            board.box("synack", "2. SYN-ACK, seq 300, ack 101", {in: "hs", tone: "mint"});
            board.box("ack", "3. ACK, ack 301", {in: "hs", tone: "sky"});
            board.table("segs", "data segments", [["seq", "bytes"], ["101", "100 bytes"], ["201", "100 bytes"], ["301", "100 bytes"]], {near: "hs", side: "right"});
            board.label("ackrule", "ack = next byte I expect", {near: "segs", side: "below", tone: "mint"});
            board.label("retry", "no ack in time? resend", {near: "ackrule", side: "below", tone: "butter"});
            """, on: board)
        guard let table = board.state.element("segs")?.frame, let ackRule = board.state.element("ackrule")?.frame,
              let retry = board.state.element("retry")?.frame else {
            Issue.record("an element was not placed")
            return
        }
        func sitsUnder(_ upper: BoardRect, _ lower: BoardRect) -> Bool {
            lower.minY >= upper.maxY && lower.minY - upper.maxY <= BoardLayout.gapBetweenElements + 1
                && lower.minX < upper.maxX && lower.maxX > upper.minX
        }
        #expect(sitsUnder(table, ackRule), "ackrule \(ackRule) is not under segs \(table)")
        #expect(sitsUnder(ackRule, retry), "retry \(retry) is not under ackrule \(ackRule)")
    }
}

// MARK: - The drawing engine

struct DrawingEngineTests {
    /// Runs the real engine in the host app's bundle, in a page that is
    /// never shown. A loop that never ends is stopped at the piece's time
    /// limit, and the next piece draws on a page built again.
    @Test(.timeLimit(.minutes(1)))
    func aLoopThatNeverEndsIsStoppedInThePageAndTheNextPieceRuns() async {
        let overlay = DrawingOverlay()
        overlay.beginAnswer(canvasSize: CGSize(width: 800, height: 600), targets: [:], screenInkHex: "#3380FF")

        let working = await overlay.run(programPiece: "say(\"first sentence.\");")
        #expect(working.newLineTexts == ["first sentence."])

        for stuckPiece in ["while (true) {}", "for (;;) { var x = 1; }", "var n = 0; do { n += 0; } while (n < 1);"] {
            let startedAt = Date()
            let stuck = await overlay.run(programPiece: stuckPiece)
            #expect(Date().timeIntervalSince(startedAt) < 3, "\(stuckPiece) was not stopped in the page")
            #expect(stuck.errors.contains { $0.contains("ran longer") }, "\(stuckPiece) gave \(stuck.errors)")
        }

        let afterwards = await overlay.run(programPiece: "say(\"still drawing.\");")
        #expect(afterwards.errors.isEmpty)
        #expect(afterwards.newLineTexts == ["still drawing."])
    }

    /// Work no loop check reaches (ten billion calls made by the built-in
    /// `forEach`, with no `for` or `while` in the program) is given up on by
    /// the app, the page is built again, and the next piece draws on it.
    @Test(.timeLimit(.minutes(1)))
    func aPieceTheLoopCheckCannotStopIsAbandonedAndThePageRebuilt() async {
        let overlay = DrawingOverlay()
        overlay.beginAnswer(canvasSize: CGSize(width: 800, height: 600), targets: [:], screenInkHex: "#3380FF")

        let startedAt = Date()
        let stuck = await overlay.run(programPiece: """
        var outer = Array.from({length: 100000});
        outer.forEach(function () { Array.from({length: 100000}).forEach(function () {}); });
        """)
        #expect(Date().timeIntervalSince(startedAt) < 8)
        #expect(stuck.errors.contains { $0.contains("ran longer") })

        let afterwards = await overlay.run(programPiece: "say(\"on a new page.\");")
        #expect(afterwards.errors.isEmpty)
        #expect(afterwards.newLineTexts == ["on a new page."])
    }

    /// What DrawingOverlay ends a stuck page's process with; without it the
    /// process would spin a core until Buddy quits.
    @Test func webKitCanStillEndAStuckPagesProcess() {
        #expect(WKWebView().responds(to: NSSelectorFromString("_killWebContentProcess")))
    }

    @Test func wordsInStringsAndCommentsAreNotTreatedAsLoops() async {
        let overlay = DrawingOverlay()
        overlay.beginAnswer(canvasSize: CGSize(width: 800, height: 600), targets: [:], screenInkHex: "#3380FF")
        let result = await overlay.run(programPiece: """
        // while (true) in a comment
        var total = 0;
        for (var i = 0; i < 3; i++) { total += i; }
        for (var item of [1, 2]) { total += item; }
        say("for a while (it is fine) the total is " + total + ".");
        """)
        #expect(result.errors.isEmpty)
        #expect(result.newLineTexts == ["for a while (it is fine) the total is 6."])
    }
}

@MainActor
struct MarkPacingTests {
    /// A sentence of tags alone asks for all its marks with Int.max. After
    /// words were already spoken in the answer, adding the two used to trap.
    @Test func aSentenceOfOnlyTagsAfterSpokenWordsDoesNotOverflow() {
        let markCoordinator = MarkCoordinator()
        let spokenSentence = markCoordinator.marksFollowingSpeech(
            of: ParsedTeacherResponse(spokenText: "the loop starts at zero.", directives: []))
        spokenSentence.reached(10)
        spokenSentence.finished()
        let sentenceOfOnlyTags = markCoordinator.marksFollowingSpeech(
            of: ParsedTeacherResponse(spokenText: "", directives: []))
        sentenceOfOnlyTags.reached(Int.max)
        sentenceOfOnlyTags.finished()
        #expect(markCoordinator.boardRevealFraction <= 1.0)
    }
}

@MainActor
struct ErrorGlowWindowTests {
    /// Live, Buddy quit with AppKit's "more Update Constraints passes than
    /// views" the moment an error offer showed: the halo follows the notch
    /// four times a second while the notch widens for the offer's words.
    @Test func theHaloFollowsAGrowingNotchWithoutALayoutLoop() async throws {
        let glow = ErrorGlowWindows()
        var width: CGFloat = 180
        var notchIsOpen = false
        glow.show(shapeSize: { CGSize(width: width, height: 32) }, isNotchOpen: { notchIsOpen })
        for step in 0..<24 {
            width = step.isMultiple(of: 2) ? 180 + CGFloat(step) * 6 : 420
            if step == 12 { notchIsOpen = true }
            if step == 16 { notchIsOpen = false }
            try await Task.sleep(nanoseconds: 125_000_000)
        }
        glow.hide()
        try await Task.sleep(nanoseconds: 800_000_000)
    }
}
