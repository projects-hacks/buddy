//
//  ModelRouter.swift
//  leanring-buddy
//
//  Picks which brain answers a question when the Brain setting is Auto: Claude
//  Sonnet, Claude Opus or Gemini Argon.
//
//  Built the way routers that hold up in production are built, and kept
//  deliberately simple:
//
//  - The decision rests on measurement, not on opinion about the models.
//    RouteTable.json holds, for every kind of question and every brain, a
//    blind-judged quality score, the time to the first spoken word and the
//    cost, all from scripts/route_race. Change the models and the race is
//    rerun; this code does not change.
//  - It routes on probabilities, not on a single guess. A question that is
//    60% teach and 40% normal is weighed as exactly that, so when the sorter
//    is unsure the router leans to the brain whose wrong guess costs least.
//    Learned routers were found to lose more accuracy than nearest-neighbour
//    ones on questions unlike their training (arXiv 2505.12601), so nothing
//    here is trained beyond one fitted temperature.
//  - Differences smaller than the judges' own noise are not differences.
//    Within that margin of the best, the cheaper brain wins, so Opus answers
//    only where it is measurably better, not merely as good.
//  - A brain that fails is benched for a few minutes and the next best one
//    answers, so an outage costs one retry rather than every question. A
//    brain that is merely slow to start is given up on for that answer only.
//

import Foundation

/// A brain Auto can send a question to.
enum RoutedBrain: String, CaseIterable, Codable {
    case sonnet, opus, argon

    var displayName: String {
        switch self {
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        case .argon: return "Argon"
        }
    }
}

/// The measured table the router decides from.
struct RouteTable: Decodable {
    struct Measurement: Decodable {
        /// Blind-judged overall quality, 1 to 10.
        let quality: Double
        /// Median seconds to the first spoken sentence.
        let firstSay: Double
        /// Dollars per answer at list price.
        let cost: Double

        enum CodingKeys: String, CodingKey {
            case quality
            case firstSay = "first_say"
            case cost
        }
    }

    /// How far apart two quality scores must be to count as different.
    let noise: Double
    /// How many seconds of silence before the first word cost one point of
    /// quality. A product decision, stated rather than fitted.
    let secondsPerPoint: Double
    /// Kind name, then brain name, then what was measured.
    let kinds: [String: [String: Measurement]]

    enum CodingKeys: String, CodingKey {
        case noise
        case secondsPerPoint = "seconds_per_point"
        case kinds
    }

    func measurement(kind: QuestionKind, brain: RoutedBrain) -> Measurement? {
        kinds[kind.tableName]?[brain.rawValue]
    }
}

extension QuestionKind {
    /// The kind as RouteTable.json and the scripts name it.
    var tableName: String {
        switch self {
        case .chat: return "chat"
        case .quick: return "quick"
        case .normal: return "normal"
        case .teach: return "teach"
        case .reexplain: return "reexplain"
        case .tradeOff: return "tradeoff"
        }
    }
}

@MainActor
final class ModelRouter {
    struct Choice {
        /// Best first. Later ones are the fallbacks if the first fails.
        let ranking: [RoutedBrain]
        /// One line for the log: every brain's value and why the first won.
        let explanation: String
    }

    private let table: RouteTable?
    private var benchedUntil: [RoutedBrain: Date] = [:]

    /// How many times in a row each brain has been benched without an
    /// answer from it in between.
    private var benchStrikes: [RoutedBrain: Int] = [:]

    /// Long enough to ride out a short outage, short enough that a brain
    /// that recovered is back within a few questions.
    static let benchSeconds: TimeInterval = 300
    /// A brain that fails again as soon as it is back is having a bad day,
    /// not a blip: each such failure doubles its bench up to this. Every
    /// question it is tried on first is paid for twice (its attempt, then
    /// the next brain's) and waited on for its whole patience window.
    static let longestBenchSeconds: TimeInterval = 3600
    /// A failure this long after the last bench ended starts counting again.
    static let strikesForgottenAfterSeconds: TimeInterval = 3600

    /// The clock benching is measured on; the unit tests move it forward.
    var currentDate: () -> Date = { Date() }

    init() {
        if let url = Bundle.main.url(forResource: "RouteTable", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let table = try? JSONDecoder().decode(RouteTable.self, from: data) {
            self.table = table
        } else {
            TutorDebugLog.write("⚠️ router: RouteTable.json missing, using the fixed routing")
            self.table = nil
        }
    }

    /// Ranks the allowed brains for a question whose kind is known only as
    /// probabilities.
    ///
    /// Small talk is not in the table: it is a one-sentence reply, so it is
    /// weighed as a quick question. Raced against Sonnet on greetings and
    /// thanks (scripts/route_race/chat_race.py), Haiku was 0.25 to 0.4s
    /// sooner and a twentieth of the price but judged 1.25 and 1.76 points
    /// worse in two runs, well past the noise: it kept re-teaching the last fix when the
    /// student only said thanks. So small talk is answered like the rest.
    func choose(probabilities: [QuestionKind: Double], allowed: Set<RoutedBrain>) -> Choice {
        var weighed = probabilities
        if let chat = weighed.removeValue(forKey: .chat) { weighed[.quick, default: 0] += chat }
        let now = currentDate()
        let healthy = allowed.filter { (benchedUntil[$0] ?? .distantPast) <= now }
        // If every allowed brain is benched, trying one beats not answering.
        let candidates = healthy.isEmpty ? allowed : healthy

        guard let table, !candidates.isEmpty else {
            return fixedChoice(probabilities: weighed, candidates: candidates)
        }

        struct Scored {
            let brain: RoutedBrain
            let value: Double
            let cost: Double
        }
        let scored: [Scored] = candidates.compactMap { brain in
            var value = 0.0
            var cost = 0.0
            for (kind, probability) in weighed where probability > 0 {
                guard let measured = table.measurement(kind: kind, brain: brain) else { return nil }
                value += probability * (measured.quality - measured.firstSay / table.secondsPerPoint)
                cost += probability * measured.cost
            }
            return Scored(brain: brain, value: value, cost: cost)
        }
        guard let best = scored.map(\.value).max() else {
            return fixedChoice(probabilities: weighed, candidates: candidates)
        }

        // Within the noise of the best, cheaper first; then by value.
        let ranked = scored.sorted { left, right in
            let leftClose = left.value >= best - table.noise
            let rightClose = right.value >= best - table.noise
            if leftClose != rightClose { return leftClose }
            if leftClose && left.cost != right.cost { return left.cost < right.cost }
            return left.value > right.value
        }
        let explanation = ranked
            .map { "\($0.brain.rawValue) \(String(format: "%.2f", $0.value)) $\(String(format: "%.3f", $0.cost))" }
            .joined(separator: ", ")
        return Choice(ranking: ranked.map(\.brain), explanation: explanation)
    }

    /// How long to wait for a brain's first words before giving the question
    /// to the next one. The race caught Argon going silent for 20, 27 and once
    /// 138 seconds on questions it usually starts in four, so a median alone
    /// would leave the student waiting on the tail. Twice the brain's usual
    /// time for this kind of question, never under eight seconds, so an
    /// ordinary slow start is not mistaken for a stall.
    func firstWordsDeadline(for brain: RoutedBrain, probabilities: [QuestionKind: Double]) -> TimeInterval {
        guard let table else { return 20 }
        let usual = probabilities.reduce(0.0) { total, entry in
            total + entry.value * (table.measurement(kind: entry.key, brain: brain)?.firstSay ?? 10)
        }
        return min(30, max(8, 2 * usual))
    }

    /// Takes a brain out of the running for a while after it failed, or
    /// said nothing within its patience window.
    func bench(_ brain: RoutedBrain, because reason: String) {
        let now = currentDate()
        if let lastBenchEnded = benchedUntil[brain],
           now.timeIntervalSince(lastBenchEnded) > Self.strikesForgottenAfterSeconds {
            benchStrikes[brain] = nil
        }
        let strikes = (benchStrikes[brain] ?? 0) + 1
        benchStrikes[brain] = strikes
        let seconds = min(Self.longestBenchSeconds, Self.benchSeconds * pow(2, Double(strikes - 1)))
        benchedUntil[brain] = now.addingTimeInterval(seconds)
        TutorDebugLog.write("🪑 router: \(brain.rawValue) benched for \(Int(seconds))s (time \(strikes) in a row), \(reason)")
    }

    /// The brain answered: whatever went wrong before is over.
    func answered(by brain: RoutedBrain) {
        benchStrikes[brain] = nil
    }

    /// Without the table: the fast brain for small questions, the strong one
    /// for the rest, which is what the table said when it was last measured.
    private func fixedChoice(probabilities: [QuestionKind: Double], candidates: Set<RoutedBrain>) -> Choice {
        let likeliest = probabilities.max { $0.value < $1.value }?.key ?? .normal
        let preferred: [RoutedBrain] = (likeliest == .quick || likeliest == .normal)
            ? [.sonnet, .argon, .opus]
            : [.argon, .opus, .sonnet]
        let ranking = preferred.filter(candidates.contains)
        return Choice(ranking: ranking.isEmpty ? [.argon] : ranking, explanation: "fixed routing, no table")
    }
}
