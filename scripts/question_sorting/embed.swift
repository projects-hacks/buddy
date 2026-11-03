// Turns sentences into vectors with the two sentence-embedding models built
// into macOS, so the nearest-examples sorter can be tested with nothing
// downloaded and nothing sent off the machine.
//
// stdin: a JSON array of sentences. stdout: JSON with one vector per sentence
// per model, and the milliseconds each sentence took.

import Foundation
import NaturalLanguage

let sentences = try JSONDecoder().decode([String].self, from: FileHandle.standardInput.readDataToEndOfFile())

func milliseconds(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

var output: [String: Any] = [:]

// The transformer one. Its vectors are per token, so they are averaged into
// one per sentence, the usual way to pool a BERT-style encoder.
if let contextual = NLContextualEmbedding(language: .english) {
    if !contextual.hasAvailableAssets {
        let semaphore = DispatchSemaphore(value: 0)
        contextual.requestAssets { _, _ in semaphore.signal() }
        semaphore.wait()
    }
    try contextual.load()
    var vectors: [[Double]] = []
    var timings: [Double] = []
    for sentence in sentences {
        let start = DispatchTime.now()
        let result = try contextual.embeddingResult(for: sentence, language: .english)
        var sum = [Double](repeating: 0, count: contextual.dimension)
        var tokenCount = 0
        result.enumerateTokenVectors(in: sentence.startIndex..<sentence.endIndex) { vector, _ in
            for index in 0..<vector.count { sum[index] += vector[index] }
            tokenCount += 1
            return true
        }
        vectors.append(sum.map { $0 / Double(max(tokenCount, 1)) })
        timings.append(milliseconds(since: start))
    }
    output["contextual"] = ["vectors": vectors, "ms": timings]
}

// The older one, a direct sentence vector.
if let sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english) {
    var vectors: [[Double]] = []
    var timings: [Double] = []
    for sentence in sentences {
        let start = DispatchTime.now()
        vectors.append(sentenceEmbedding.vector(for: sentence) ?? [])
        timings.append(milliseconds(since: start))
    }
    output["sentence"] = ["vectors": vectors, "ms": timings]
}

FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
