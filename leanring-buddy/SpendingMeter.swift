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
//  Kept in ~/Library/Application Support/Buddy/spending.json, one small
//  record per day, never sent anywhere.
//

import Combine
import Foundation

/// Published list prices, in dollars per million tokens or per thousand
/// characters. Checked November 2026.
enum APIPrices {
    /// Claude Messages API. Cache writes cost 1.25 times the input price.
    static func claude(model: String, freshInput: Int, cachedInput: Int, cacheWrites: Int, output: Int) -> Double {
        let (input, cacheRead, outputPrice): (Double, Double, Double)
        switch model {
        case let name where name.contains("opus"): (input, cacheRead, outputPrice) = (4, 0.20, 20)
        case let name where name.contains("haiku"): (input, cacheRead, outputPrice) = (0.10, 0.01, 0.50)
        default: (input, cacheRead, outputPrice) = (2, 0.20, 10)
        }
        return (Double(freshInput) * input + Double(cachedInput) * cacheRead
                + Double(cacheWrites) * input * 1.25 + Double(output) * outputPrice) / 1_000_000
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

    enum Service: String, Codable, CaseIterable { case claude, gemini, deepgram }

    struct Day: Codable, Equatable {
        var date: String
        var questions = 0
        var guideSteps = 0
        var dollars = 0.0
        var dollarsByService: [String: Double] = [:]
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
    /// says what it used.
    nonisolated static func record(_ dollars: Double, for service: Service) {
        guard dollars > 0, dollars.isFinite else { return }
        Task { @MainActor in shared.add(dollars, for: service) }
    }

    func countQuestion(isGuideStep: Bool) {
        updateToday { day in
            if isGuideStep { day.guideSteps += 1 } else { day.questions += 1 }
        }
    }

    var today: Day { days.last(where: { $0.date == Self.dayName(Date()) }) ?? Day(date: Self.dayName(Date())) }

    var thisMonthDollars: Double {
        let month = String(Self.dayName(Date()).prefix(7))
        return days.filter { $0.date.hasPrefix(month) }.reduce(0) { $0 + $1.dollars }
    }

    private func add(_ dollars: Double, for service: Service) {
        updateToday { day in
            day.dollars += dollars
            day.dollarsByService[service.rawValue, default: 0] += dollars
        }
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
