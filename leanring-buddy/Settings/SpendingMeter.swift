//
//  SpendingMeter.swift
//  leanring-buddy
//
//  What Buddy has spent on the student's keys, today and this month, shown
//  in Settings so the cost of a question is never a surprise.
//
//  Where the numbers come from. Every reply from Anthropic and Google says
//  how many tokens went in, how many of those came from the prompt cache, and
//  how many came out; Deepgram charges per character spoken, and Buddy knows
//  every character it sends. Each is multiplied by the published price
//  below. It is an estimate in one way only: a provider's bill also counts
//  anything done with the same key outside Buddy, and its rounding is its own.
//
//  Each cost is kept twice over: under the service paid (Claude, Gemini,
//  Deepgram) and under what it was for (answers, voice, hearing the
//  student...), because the bill is per provider but the choice a student
//  can make is per feature.
//
//  Kept in ~/Library/Application Support/Buddy/spending.json, one small
//  record per day, never sent anywhere.
//

import Combine
import Foundation

/// Published list prices, in dollars per million tokens or per thousand
/// characters. Checked November 2026.
enum APIPrices {
    /// Claude Messages API. A cache write kept five minutes costs 1.25 times
    /// the input price; one kept an hour, as Buddy's prompts are, costs twice.
    static func claude(model: String, freshInput: Int, cachedInput: Int, cacheWrites: Int,
                       cacheWritesKeptAnHour: Int = 0, output: Int) -> Double {
        let (input, cacheRead, outputPrice): (Double, Double, Double)
        switch model {
        case let name where name.contains("opus"): (input, cacheRead, outputPrice) = (4, 0.20, 20)
        case let name where name.contains("haiku"): (input, cacheRead, outputPrice) = (0.10, 0.01, 0.50)
        default: (input, cacheRead, outputPrice) = (2, 0.20, 10)
        }
        return (Double(freshInput) * input + Double(cachedInput) * cacheRead
                + Double(cacheWrites) * input * 1.25 + Double(cacheWritesKeptAnHour) * input * 2
                + Double(output) * outputPrice) / 1_000_000
    }

    /// Gemini Argon on Google's API or Vertex: an introductory price until the
    /// end of November 2026, then double. Thinking tokens bill as output.
    /// Other Gemini models (the rare diagram pass) are counted at Argon's
    /// price, which overstates them rather than hiding them.
    static func gemini(promptTokens: Int, cachedTokens: Int, outputTokens: Int, on day: Date = Date()) -> Double {
        let standardPriceFrom = DateComponents(calendar: Calendar(identifier: .gregorian),
                                               year: 2026, month: 12, day: 1).date ?? .distantFuture
        let isIntroductory = day < standardPriceFrom
        let (input, cacheRead, output): (Double, Double, Double) = isIntroductory ? (2, 0.10, 10) : (4, 0.20, 20)
        let freshInput = max(0, promptTokens - cachedTokens)
        return (Double(freshInput) * input + Double(cachedTokens) * cacheRead + Double(outputTokens) * output) / 1_000_000
    }

    /// Deepgram Aura-2, pay as you go.
    static func deepgram(characters: Int) -> Double {
        Double(characters) * 0.030 / 1_000
    }

    /// Reads the usage block of a non-streamed Claude reply.
    static func claude(model: String, usageIn reply: [String: Any]) -> Double {
        let usage = reply["usage"] as? [String: Any] ?? [:]
        return claude(model: model,
                      freshInput: usage["input_tokens"] as? Int ?? 0,
                      cachedInput: usage["cache_read_input_tokens"] as? Int ?? 0,
                      cacheWrites: usage["cache_creation_input_tokens"] as? Int ?? 0,
                      output: usage["output_tokens"] as? Int ?? 0)
    }

    /// Reads a Gemini `usageMetadata` block.
    static func gemini(usageMetadata usage: [String: Any]) -> Double {
        gemini(promptTokens: usage["promptTokenCount"] as? Int ?? 0,
               cachedTokens: usage["cachedContentTokenCount"] as? Int ?? 0,
               outputTokens: (usage["candidatesTokenCount"] as? Int ?? 0) + (usage["thoughtsTokenCount"] as? Int ?? 0))
    }
}

@MainActor
final class SpendingMeter: ObservableObject {
    static let shared = SpendingMeter()

    enum Service: String, Codable, CaseIterable {
        case claude, gemini, deepgram

        var displayName: String {
            switch self {
            case .claude: return "Claude"
            case .gemini: return "Gemini"
            case .deepgram: return "Deepgram"
            }
        }
    }

    /// What the money was for, so Settings can say which part of Buddy costs
    /// what, not only which provider was paid. The order of the cases is the
    /// order the spending card lists them in.
    enum Purpose: String, Codable, CaseIterable {
        /// The main Claude or Gemini answer, board turns, teach-back's two
        /// calls and guide steps.
        case answers
        /// Deepgram Aura reading answers aloud.
        case voice
        /// Talk-over: the microphone heard while an answer plays.
        case listening
        /// Push-to-talk and teach-back's listening.
        case hearing
        /// Haiku's small calls: sorting the question, memory's recall and
        /// filing, the map's relations, a how-to's ways of asking.
        case helpers
        /// The front app's sound transcribed for a lecture question.
        case lectures

        var displayName: String {
            switch self {
            case .answers: return "Answers"
            case .voice: return "Voice"
            case .listening: return "Listening while it talks"
            case .hearing: return "Hearing you"
            case .helpers: return "Small helpers"
            case .lectures: return "Lectures"
            }
        }
    }

    struct Day: Codable, Equatable {
        var date: String
        var questions = 0
        var guideSteps = 0
        var dollars = 0.0
        var dollarsByService: [String: Double] = [:]
        /// Empty on days saved before purposes were kept; their service
        /// split is still there.
        var dollarsByPurpose: [String: Double] = [:]

        init(date: String) {
            self.date = date
        }

        /// Every field but the date may be missing on disk, so a day written
        /// by an older Buddy, before that field existed, still reads.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = try container.decode(String.self, forKey: .date)
            questions = try container.decodeIfPresent(Int.self, forKey: .questions) ?? 0
            guideSteps = try container.decodeIfPresent(Int.self, forKey: .guideSteps) ?? 0
            dollars = try container.decodeIfPresent(Double.self, forKey: .dollars) ?? 0
            dollarsByService = try container.decodeIfPresent([String: Double].self, forKey: .dollarsByService) ?? [:]
            dollarsByPurpose = try container.decodeIfPresent([String: Double].self, forKey: .dollarsByPurpose) ?? [:]
        }
    }

    /// Days added together: today alone, or every day of a month.
    struct Totals: Equatable {
        var dollars = 0.0
        var dollarsByService: [String: Double] = [:]
        var dollarsByPurpose: [String: Double] = [:]
        var questions = 0
        var guideSteps = 0

        init(adding days: [Day]) {
            for day in days {
                dollars += day.dollars
                questions += day.questions
                guideSteps += day.guideSteps
                for (service, serviceDollars) in day.dollarsByService {
                    dollarsByService[service, default: 0] += serviceDollars
                }
                for (purpose, purposeDollars) in day.dollarsByPurpose {
                    dollarsByPurpose[purpose, default: 0] += purposeDollars
                }
            }
        }

        func dollars(for service: Service) -> Double { dollarsByService[service.rawValue] ?? 0 }
        func dollars(for purpose: Purpose) -> Double { dollarsByPurpose[purpose.rawValue] ?? 0 }
    }

    @Published private(set) var days: [Day] = []

    private let file = AppIdentity.supportFolder.appendingPathComponent("spending.json")
    private var saveTask: Task<Void, Never>?

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Day].self, from: data) {
            days = saved
        }
    }

    /// Callable from any thread: every paid call reports here when its reply
    /// says what it used, and says what the money was for.
    nonisolated static func record(_ dollars: Double, for service: Service, purpose: Purpose) {
        guard dollars > 0, dollars.isFinite else { return }
        Task { @MainActor in shared.add(dollars, for: service, purpose: purpose) }
    }

    func countQuestion(isGuideStep: Bool) {
        updateToday { day in
            if isGuideStep { day.guideSteps += 1 } else { day.questions += 1 }
        }
    }

    var today: Day { days.last(where: { $0.date == Self.dayName(Date()) }) ?? Day(date: Self.dayName(Date())) }

    var thisMonthDollars: Double { thisMonth.dollars }

    var thisMonth: Totals { Self.monthTotals(of: days, month: String(Self.dayName(Date()).prefix(7))) }

    /// Every day of one month ("2026-11") added together.
    static func monthTotals(of days: [Day], month: String) -> Totals {
        Totals(adding: days.filter { $0.date.hasPrefix(month + "-") })
    }

    private func add(_ dollars: Double, for service: Service, purpose: Purpose) {
        updateToday { day in
            Self.add(dollars, for: service, purpose: purpose, to: &day)
        }
    }

    /// One recorded cost added to a day, under both its service and its
    /// purpose, so each split adds up to the day's total.
    static func add(_ dollars: Double, for service: Service, purpose: Purpose, to day: inout Day) {
        day.dollars += dollars
        day.dollarsByService[service.rawValue, default: 0] += dollars
        day.dollarsByPurpose[purpose.rawValue, default: 0] += dollars
    }

    private func updateToday(_ change: (inout Day) -> Void) {
        let name = Self.dayName(Date())
        if let index = days.lastIndex(where: { $0.date == name }) {
            change(&days[index])
        } else {
            var day = Day(date: name)
            change(&day)
            days.append(day)
            // A year and a bit is plenty for "this month", and keeps it tiny.
            if days.count > 400 { days.removeFirst(days.count - 400) }
        }
        scheduleSave()
    }

    /// Written a moment after the last change, so a streaming answer's
    /// several reports become one write. Writes go through one serial queue,
    /// so an older snapshot can never land after a newer one, and each is
    /// atomic (a temporary file renamed over the old), so a crash mid-write
    /// leaves the previous day totals intact rather than half a file.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.days
            let file = self.file
            Self.writeQueue.async { Self.write(snapshot, to: file) }
        }
    }

    /// At quit: the change still waiting out its moment is written before
    /// the app exits, so the last answer of the day is never lost.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = days
        let file = self.file
        Self.writeQueue.sync { Self.write(snapshot, to: file) }
    }

    private static let writeQueue = DispatchQueue(label: "buddy.spending-save", qos: .utility)

    private nonisolated static func write(_ snapshot: [Day], to file: URL) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static func dayName(_ moment: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: moment)
    }

    /// "$0.61", or "under 1¢" for a day that has barely begun.
    static func formatted(_ dollars: Double) -> String {
        if dollars > 0 && dollars < 0.01 { return "under 1¢" }
        return String(format: "$%.2f", dollars)
    }
}

/// The lines of Spent today's breakdown card and the sentence a screen
/// reader hears for it, worked out once from today's and this month's
/// totals so the card and its spoken label can never disagree.
struct SpendingBreakdown: Equatable {
    struct Line: Equatable {
        let name: String
        let today: Double
        let thisMonth: Double
    }

    static let whereTheNumbersComeFrom =
        "From published prices; your provider's bill is exact and also counts anything else using the same key."

    /// A row per service, leaving out one with nothing today or this month.
    let serviceLines: [Line]
    /// A row per purpose with spending, in `SpendingMeter.Purpose` order.
    let purposeLines: [Line]
    let questionsToday: Int
    let guideStepsToday: Int

    init(today: SpendingMeter.Totals, thisMonth: SpendingMeter.Totals) {
        serviceLines = SpendingMeter.Service.allCases
            .map { Line(name: $0.displayName, today: today.dollars(for: $0), thisMonth: thisMonth.dollars(for: $0)) }
            .filter { $0.today > 0 || $0.thisMonth > 0 }
        purposeLines = SpendingMeter.Purpose.allCases
            .map { Line(name: $0.displayName, today: today.dollars(for: $0), thisMonth: thisMonth.dollars(for: $0)) }
            .filter { $0.today > 0 || $0.thisMonth > 0 }
        questionsToday = today.questions
        guideStepsToday = today.guideSteps
    }

    /// "3 questions and 1 guide step today"; guide steps are left out on a
    /// day with none, as most days have.
    var countsSentence: String {
        var sentence = questionsToday == 1 ? "1 question" : "\(questionsToday) questions"
        if guideStepsToday > 0 {
            sentence += " and " + (guideStepsToday == 1 ? "1 guide step" : "\(guideStepsToday) guide steps")
        }
        return sentence + " today"
    }

    /// Every line of the card in reading order, for VoiceOver.
    var spokenDescription: String {
        func spoken(_ line: Line) -> String {
            "\(line.name), \(SpendingMeter.formatted(line.today)) today, \(SpendingMeter.formatted(line.thisMonth)) this month."
        }
        let lines = (serviceLines + purposeLines).map(spoken)
        return (lines + [countsSentence + ".", Self.whereTheNumbersComeFrom]).joined(separator: " ")
    }
}
