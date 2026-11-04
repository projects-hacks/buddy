//
//  ConceptIndex.swift
//  leanring-buddy
//
//  The part of learning memory that runs while the student waits: given a
//  question, which of the ideas Buddy has explained before is it about?
//
//  Kept pure (no files, no network, no model) so it can be graded and timed
//  on its own by scripts/learning_memory, and so nothing in it can stall.
//
//  How it decides, and why:
//
//  - Words first. A concept is named by a few technical words ("consistent
//    hashing", "token bucket"), and a question about it nearly always says
//    one of them, or one of its aliases ("2pc"). Each word counts by how
//    rare it is among all remembered names (inverse document frequency), so
//    "tree" in "b-tree" counts for less than "bloom" in "bloom filter".
//    A name counts only when all of it is said: "plus" alone must not find
//    "b plus tree", nor "quick" find "quick sort".
//  - Then cues: the plain-words phrases a student says when they describe
//    an idea instead of naming it ("charged twice" for idempotency keys),
//    and the ways speech recognition mishears its name ("item potent").
//    Claude Haiku writes them when the lesson is filed, after the answer,
//    which is document expansion (doc2query): the expensive understanding
//    happens once at filing time, so the question only pays for a word scan.
//  - Then the explanation's own words. Each concept keeps a one-sentence
//    summary of how it was explained ("servers sit on a hash ring with
//    virtual nodes").
//  - Meaning last, and only as a tie-breaker or for a clear outlier. The
//    sentence model built into macOS rates nearly any two technical
//    sentences as similar, so a raw similarity says little; how far one
//    concept stands above all the others (its z-score) says more.
//
//  The whole index is a few flat arrays scanned in one pass, which for the
//  thousands of concepts a student builds up over years is well under a
//  millisecond. A search structure would only pay for itself past a hundred
//  thousand, which nobody will reach.
//

import Accelerate
import Foundation

/// An idea Buddy has explained, as remembered.
struct RememberedConcept: Codable, Identifiable, Equatable {
    var id: UUID
    /// "consistent hashing", lower case.
    var name: String
    /// Other names for the same idea: "2pc" for two-phase commit.
    var aliases: [String]
    /// What a student says when describing it without its name, and
    /// mishearings of the name. Optional so a store from before cues reads.
    var cues: [String]?
    /// How it was explained most recently, in one sentence. Replaced, not
    /// appended to, each time it is explained again, so it never goes stale
    /// against what the student last heard.
    var summary: String
    /// The example or analogy used last time, so a student who did not
    /// follow it can be given a different one.
    var lastAngle: String?
    var firstExplainedAt: Date
    var lastExplainedAt: Date
    var timesExplained: Int
    /// Times the student said they did not follow an explanation of it.
    var timesLost: Int
    var lastLostAt: Date?
    /// Days until the student is estimated to have a 90% chance of still
    /// remembering it, the FSRS definition of stability. Grows each time it
    /// is explained again after some forgetting, shrinks when they get lost.
    var stabilityDays: Double
    /// The lessons it came up in, newest last, at most a handful.
    var lessonTitles: [String]
}

/// A concept found for a question, with why.
struct ConceptRecollection: Equatable {
    let concept: RememberedConcept
    let score: Double
    /// Estimated chance they still remember it, 0 to 1.
    let retrievability: Double
}

enum ConceptText {
    /// Words that say nothing about which idea a question is about.
    private static let stopwords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "for", "to", "and", "or", "with", "by", "at", "from", "as", "into",
        "is", "are", "was", "were", "be", "been", "it", "its", "this", "that", "these", "those", "there", "here",
        "i", "me", "my", "you", "your", "we", "our", "they", "them", "he", "she",
        "what", "whats", "why", "how", "when", "where", "which", "who", "does", "do", "did", "doing", "done",
        "can", "could", "should", "would", "will", "shall", "might", "must", "may",
        "explain", "explained", "work", "works", "working", "use", "used", "using", "mean", "means",
        "difference", "between", "vs", "versus", "like", "so", "just", "really", "again", "wait", "okay", "ok",
        "get", "got", "make", "makes", "made", "thing", "things", "stuff", "about", "help", "need", "want",
        "tell", "show", "give", "please", "hey", "buddy", "um", "uh", "yeah", "right", "actually", "basically",
        "not", "no", "yes", "if", "then", "than", "but", "also", "too", "very", "some", "any", "all", "one",
        "good", "bad", "better", "best", "way", "ways", "go", "goes", "going", "happen", "happens", "happening",
        "understand", "follow", "know", "think", "see", "look", "looking", "say", "said", "kind", "sort",
        "problem", "question", "code", "here's", "part", "case", "cases", "new", "same", "other", "each"
    ]

    /// Lower case, punctuation and hyphens to spaces, plurals folded, and
    /// stopwords dropped, so "Prefix-Sums" and "prefix sum" agree.
    static func tokens(_ text: String) -> [String] {
        let lowered = text.lowercased()
        var cleaned = ""
        cleaned.reserveCapacity(lowered.count)
        for character in lowered {
            if character.isLetter || character.isNumber {
                cleaned.append(character)
            } else if character == "'" || character == "\u{2019}" {
                continue
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(separator: " ").compactMap { word in
            let folded = singular(String(word))
            // Single letters stay ("b" in "b-tree"); "a" and "i" are stopwords.
            guard !folded.isEmpty, !stopwords.contains(folded) else { return nil }
            return folded
        }
    }

    /// The name as it is compared for duplicates.
    static func normalisedName(_ name: String) -> String {
        tokens(name).joined(separator: " ")
    }

    /// Plurals folded, then a light stem, the same on both sides, so
    /// "charged", "charging" and "charge" all meet at "charg". Crude next to
    /// Porter's stemmer, and enough: it only has to make the two sides agree.
    private static func singular(_ word: String) -> String {
        guard word.count > 3, word.allSatisfy(\.isLetter) else { return word }
        var stem = word
        if stem.hasSuffix("ies") {
            stem = String(stem.dropLast(3)) + "y"
        } else if stem.hasSuffix("sses") || stem.hasSuffix("xes") || stem.hasSuffix("ches") || stem.hasSuffix("shes") {
            stem = String(stem.dropLast(2))
        } else if stem.hasSuffix("s"), !stem.hasSuffix("ss"), !stem.hasSuffix("us"), !stem.hasSuffix("is") {
            stem = String(stem.dropLast())
        }
        if stem.count > 5, stem.hasSuffix("ing") {
            stem = String(stem.dropLast(3))
        } else if stem.count > 4, stem.hasSuffix("ed") {
            stem = String(stem.dropLast(2))
        }
        if stem.count > 4, stem.hasSuffix("e") { stem = String(stem.dropLast()) }
        return stem
    }
}

/// The FSRS-5 forgetting curve: the chance of still recalling something
/// `elapsedDays` after it was last learned, given its stability. Power law
/// rather than exponential because a mix of memories of different strength
/// forgets that way (expertium.github.io/Algorithm.html).
enum ForgettingCurve {
    static let decay = -0.5
    static let factor = 19.0 / 81.0

    static func retrievability(elapsedDays: Double, stabilityDays: Double) -> Double {
        guard stabilityDays > 0 else { return 0 }
        return pow(1 + factor * max(0, elapsedDays) / stabilityDays, decay)
    }

    /// A first explanation is held for about two days.
    static let initialStabilityDays = 2.0

    /// Explained again: the less was left, the more the memory is
    /// strengthened, which is why spaced repetition spaces things out.
    static func stabilityAfterReexplaining(_ stabilityDays: Double, retrievabilityAtTheTime: Double) -> Double {
        min(365, stabilityDays * (1.3 + 2.2 * (1 - retrievabilityAtTheTime)))
    }

    /// The student said they did not follow: whatever was there was weak.
    static func stabilityAfterGettingLost(_ stabilityDays: Double) -> Double {
        max(1, stabilityDays * 0.5)
    }
}

struct ConceptIndex {
    /// Weights and cut-offs, chosen on the dev half of
    /// scripts/learning_memory/recall_test.json and scored once on its test half.
    struct Tuning {
        /// The whole name said in the question.
        var fullNameWeight = 1.0
        /// Part of the name said: evidence, never enough alone.
        var partialNameWeight = 0.3
        /// The whole name on screen but not in the question.
        var screenNameWeight = 0.4
        /// How much of the question the concept's words (name, aliases,
        /// cues, summary) account for.
        var coverageWeight = 1.0
        /// Fewer shared words than this and coverage counts for nothing: one
        /// shared word ("tree", "queue") is how unrelated questions slip in.
        var minimumSharedWords = 2
        var meaningWeight = 0.0
        var meaningOutlierZ = 99.0
        var acceptAbove = 0.6
        var ignoresEverydayAliases = false

        /// Used alone, with no Haiku to choose: only a name or alias said in
        /// full counts, and a one-word alias only when it looks like a term
        /// of art ("2pc", "bfs"), never an everyday word ("index", "quick").
        static let namesOnly = Tuning(partialNameWeight: 0, screenNameWeight: 0, coverageWeight: 0,
                                      acceptAbove: 0.9, ignoresEverydayAliases: true)

        /// The shortlist: one shared rare word is enough to be considered.
        static let shortlist = Tuning(partialNameWeight: 0.35, screenNameWeight: 0.4, coverageWeight: 1.0,
                                      minimumSharedWords: 1, meaningWeight: 0.08, acceptAbove: 0.12)
    }

    private(set) var concepts: [RememberedConcept] = []
    var tuning = Tuning()

    // Parallel to `concepts`.
    private var nameTokens: [[String]] = []
    private var aliasTokens: [[[String]]] = []
    /// Every word that belongs to the concept: name, aliases, cues, summary.
    private var vocabularyTokens: [Set<String>] = []
    /// Unit vectors, one row per concept, `dimension` floats each. A row of
    /// zeros means the concept has not been embedded yet.
    private var vectorMatrix: [Float] = []
    /// Whether each row holds a real vector, so the scan never copies rows.
    private var isEmbedded: [Bool] = []
    private(set) var dimension = 0

    private var nameWordRarity: [String: Double] = [:]
    private var vocabularyWordRarity: [String: Double] = [:]

    init(dimension: Int = 0) {
        self.dimension = dimension
    }

    var count: Int { concepts.count }

    func index(of id: UUID) -> Int? {
        concepts.firstIndex { $0.id == id }
    }

    /// Adds or replaces a concept and its vector, then refreshes the word
    /// statistics. Called after an answer, never while one is awaited.
    mutating func upsert(_ concept: RememberedConcept, vector: [Float]?) {
        if dimension == 0, let vector { dimension = vector.count }
        let row = vector.flatMap { $0.count == dimension ? $0 : nil } ?? [Float](repeating: 0, count: dimension)
        if let existing = index(of: concept.id) {
            concepts[existing] = concept
            if vector != nil, dimension > 0 {
                vectorMatrix.replaceSubrange(existing * dimension..<(existing + 1) * dimension, with: row)
                isEmbedded[existing] = true
            }
            nameTokens[existing] = ConceptText.tokens(concept.name)
            aliasTokens[existing] = concept.aliases.map(ConceptText.tokens)
            vocabularyTokens[existing] = Self.vocabulary(of: concept)
        } else {
            concepts.append(concept)
            vectorMatrix.append(contentsOf: row)
            isEmbedded.append(vector?.count == dimension && dimension > 0)
            nameTokens.append(ConceptText.tokens(concept.name))
            aliasTokens.append(concept.aliases.map(ConceptText.tokens))
            vocabularyTokens.append(Self.vocabulary(of: concept))
        }
        refreshRarity()
    }

    mutating func remove(id: UUID) {
        guard let position = index(of: id) else { return }
        concepts.remove(at: position)
        nameTokens.remove(at: position)
        aliasTokens.remove(at: position)
        vocabularyTokens.remove(at: position)
        isEmbedded.remove(at: position)
        if dimension > 0 {
            vectorMatrix.removeSubrange(position * dimension..<(position + 1) * dimension)
        }
        refreshRarity()
    }

    func vector(at position: Int) -> [Float]? {
        guard dimension > 0, isEmbedded[position] else { return nil }
        return Array(vectorMatrix[position * dimension..<(position + 1) * dimension])
    }

    private mutating func refreshRarity() {
        nameWordRarity = Self.rarity(of: nameTokens.map { Set($0) } + aliasTokens.flatMap { $0.map { Set($0) } })
        vocabularyWordRarity = Self.rarity(of: vocabularyTokens)
    }

    private static func vocabulary(of concept: RememberedConcept) -> Set<String> {
        var words = Set(ConceptText.tokens(concept.name))
        for text in concept.aliases + (concept.cues ?? []) + [concept.summary] {
            words.formUnion(ConceptText.tokens(text))
        }
        return words
    }

    private static func rarity(of documents: [Set<String>]) -> [String: Double] {
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for word in document { documentFrequency[word, default: 0] += 1 }
        }
        let total = Double(max(1, documents.count))
        return documentFrequency.mapValues { log(1 + total / Double($0)) }
    }

    /// A broad shortlist for Claude Haiku to choose from: anything sharing a
    /// rare word or a name with the question, best first. Tuned to miss as
    /// little as possible, not to be right; the choosing happens after.
    func candidates(questionText: String, contextText: String, questionVector: [Float]?, limit: Int = 12) -> [RememberedConcept] {
        var broad = self
        broad.tuning = Tuning.shortlist
        return broad.recall(questionText: questionText, contextText: contextText,
                            questionVector: questionVector, limit: limit).map(\.concept)
    }

    /// The concepts a question is about, best first.
    ///
    /// - questionText: what the student said.
    /// - contextText: the window title and the screen's text, weaker evidence
    ///   than the question, since a screen shows many things at once.
    /// - questionVector: the question's unit vector from the same sentence
    ///   model the concepts were embedded with, or nil.
    func recall(
        questionText: String,
        contextText: String,
        questionVector: [Float]?,
        limit: Int = 3,
        now: Date = Date()
    ) -> [ConceptRecollection] {
        guard !concepts.isEmpty else { return [] }
        let questionWords = Set(ConceptText.tokens(questionText))
        let contextWords = Set(ConceptText.tokens(contextText))
        // A word no concept uses is as rare as a word can be: a question full
        // of them ("photosynthesis") is about something else.
        let unseenRarity = log(1 + Double(max(1, concepts.count)))
        let questionRarities = questionWords.map { (word: $0, rarity: vocabularyWordRarity[$0] ?? unseenRarity) }
        let questionTotalRarity = questionRarities.reduce(0.0) { $0 + $1.rarity }

        let meaningZ = meaningZScores(questionVector)

        var scored: [(position: Int, score: Double)] = []
        for position in concepts.indices {
            let nameScore = max(
                nameMatch(nameTokens[position], questionWords: questionWords, contextWords: contextWords),
                aliasTokens[position]
                    .filter { !tuning.ignoresEverydayAliases || $0.count > 1 || Self.looksLikeTermOfArt($0.first ?? "") }
                    .map { nameMatch($0, questionWords: questionWords, contextWords: contextWords) }
                    .max() ?? 0
            )

            var coverageScore = 0.0
            if questionTotalRarity > 0 {
                var covered = 0.0
                var shared = 0
                for entry in questionRarities where vocabularyTokens[position].contains(entry.word) {
                    covered += entry.rarity
                    shared += 1
                }
                if shared >= tuning.minimumSharedWords { coverageScore = covered / questionTotalRarity }
            }

            let z = meaningZ.map { $0[position] } ?? 0
            let score = max(nameScore, tuning.coverageWeight * coverageScore)
                + tuning.meaningWeight * max(0, z - 1)
            let isMeaningOutlier = z >= tuning.meaningOutlierZ
            if score >= tuning.acceptAbove || isMeaningOutlier {
                scored.append((position, score))
            }
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { entry in
                let concept = concepts[entry.position]
                let elapsedDays = now.timeIntervalSince(concept.lastExplainedAt) / 86_400
                return ConceptRecollection(
                    concept: concept,
                    score: entry.score,
                    retrievability: ForgettingCurve.retrievability(
                        elapsedDays: elapsedDays, stabilityDays: concept.stabilityDays)
                )
            }
    }

    /// The nearest concepts by meaning alone, for offering the extractor a
    /// short list of existing names to match a new explanation against.
    func nearestByMeaning(to vector: [Float], limit: Int) -> [RememberedConcept] {
        guard let similarities = similarities(to: vector) else { return [] }
        return similarities.enumerated()
            .sorted { $0.element > $1.element }
            .prefix(limit)
            .map { concepts[$0.offset] }
    }

    /// "2pc", "bfs", "lru": short, or carrying a digit. An everyday word used
    /// as an alias ("index", "queue") says too little on its own.
    private static func looksLikeTermOfArt(_ word: String) -> Bool {
        word.contains(where: \.isNumber) || (word.count <= 4 && !["tree", "heap", "sort", "key", "log", "list", "map", "set", "cache"].contains(word))
    }

    /// The whole name said scores in full; the whole name only on screen
    /// scores less; part of the name scores a little, by how rare the said
    /// words are.
    private func nameMatch(_ tokens: [String], questionWords: Set<String>, contextWords: Set<String>) -> Double {
        let words = Set(tokens)
        guard !words.isEmpty else { return 0 }
        if words.isSubset(of: questionWords) { return tuning.fullNameWeight }
        if words.isSubset(of: questionWords.union(contextWords)) { return tuning.screenNameWeight }
        var total = 0.0
        var matched = 0.0
        for word in words {
            let rarity = nameWordRarity[word] ?? 1
            total += rarity
            if questionWords.contains(word) { matched += rarity }
        }
        return total > 0 ? tuning.partialNameWeight * matched / total : 0
    }

    private func similarities(to vector: [Float]) -> [Float]? {
        guard dimension > 0, vector.count == dimension, !concepts.isEmpty else { return nil }
        var result = [Float](repeating: 0, count: concepts.count)
        // One matrix-vector product over every concept.
        vectorMatrix.withUnsafeBufferPointer { matrix in
            vector.withUnsafeBufferPointer { query in
                result.withUnsafeMutableBufferPointer { output in
                    cblas_sgemv(CblasRowMajor, CblasNoTrans,
                                Int32(concepts.count), Int32(dimension),
                                1, matrix.baseAddress, Int32(dimension),
                                query.baseAddress, 1, 0, output.baseAddress, 1)
                }
            }
        }
        return result
    }

    /// How far each concept's similarity stands above the rest, in standard
    /// deviations. Needs enough concepts for a spread to mean anything.
    private func meaningZScores(_ questionVector: [Float]?) -> [Double]? {
        guard let questionVector, concepts.count >= 12, let similarities = similarities(to: questionVector) else {
            return nil
        }
        let embedded = similarities.indices.filter { isEmbedded[$0] }.map { Double(similarities[$0]) }
        guard embedded.count >= 12 else { return nil }
        let mean = embedded.reduce(0, +) / Double(embedded.count)
        let variance = embedded.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(embedded.count)
        let deviation = max(1e-6, sqrt(variance))
        return similarities.map { (Double($0) - mean) / deviation }
    }
}
