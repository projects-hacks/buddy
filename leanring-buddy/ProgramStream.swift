//
//  ProgramStream.swift
//  leanring-buddy
//
//  Splits a drawing program into speakable sentences and runnable pieces
//  while it is still streaming in.
//
//  Two different moments matter, and they are not the same moment:
//
//  - A sentence can be spoken as soon as its `say("...")` closes. Waiting for
//    the marks after it would add seconds of silence to every answer, and the
//    first sentence is what the student is waiting for.
//  - A piece of code can only run once it is whole. Pieces are cut at the
//    start of each `say(` or `step(` line, so every piece starts with its own
//    sentence and an error in one piece cannot shift the sentence count of the
//    next. The engine numbers sentences in the order it runs them, and this
//    numbers them in the order they arrive; cutting at sentence starts is what
//    keeps the two in step.
//

import Foundation

struct ProgramStream {
    /// What became ready since the last feed.
    struct Update {
        var newSentences: [String] = []
        var newPieces: [String] = []
    }

    private(set) var sentenceCount = 0
    private var piecesDeliveredUpToOffset = 0
    private var latestCode = ""

    /// Whether streamed text is a drawing program rather than plain prose.
    /// Decided from its first characters, so it is known almost immediately.
    static func looksLikeProgram(_ streamedText: String) -> Bool? {
        let start = streamedText.drop { $0.isWhitespace }
        guard start.count >= 5 else { return nil }
        return start.hasPrefix("```") || start.hasPrefix("step(") || start.hasPrefix("say(")
    }

    /// Takes the whole text streamed so far and returns what is newly ready.
    mutating func feed(accumulatedText: String) -> Update {
        latestCode = Self.code(in: accumulatedText)
        var update = Update()

        let sentences = Self.closedSayArguments(in: latestCode)
        if sentences.count > sentenceCount {
            update.newSentences = Array(sentences[sentenceCount...])
            sentenceCount = sentences.count
        }

        // A piece is whole once the next boundary line has begun.
        let boundaries = Self.boundaryOffsets(in: latestCode)
        if let lastBoundary = boundaries.last(where: { $0 > piecesDeliveredUpToOffset }) {
            let piece = Self.substring(latestCode, from: piecesDeliveredUpToOffset, to: lastBoundary)
            if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                update.newPieces.append(piece)
            }
            piecesDeliveredUpToOffset = lastBoundary
        }
        return update
    }

    /// Everything not yet delivered, once the stream has ended.
    mutating func finish(fullText: String) -> Update {
        var update = feed(accumulatedText: fullText)
        let rest = Self.substring(latestCode, from: piecesDeliveredUpToOffset, to: latestCode.count)
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            update.newPieces.append(rest)
        }
        piecesDeliveredUpToOffset = latestCode.count
        return update
    }

    // MARK: - Reading the text

    /// The program's code: everything inside ``` fences, or the whole text when
    /// the model wrote none. Fence lines themselves are dropped, and an open
    /// fence still streaming counts as code.
    static func code(in text: String) -> String {
        guard text.contains("```") else { return text }
        var codeLines: [Substring] = []
        var insideFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            if insideFence { codeLines.append(line) }
        }
        return codeLines.joined(separator: "\n")
    }

    /// Character offsets where a line starting with `say(` or `step(` begins.
    private static func boundaryOffsets(in code: String) -> [Int] {
        var offsets: [Int] = []
        var offset = 0
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if offset > 0, trimmed.hasPrefix("say(") || trimmed.hasPrefix("step(") {
                offsets.append(offset)
            }
            offset += line.count + 1
        }
        return offsets
    }

    /// The string argument of every `say(...)` whose closing quote has arrived,
    /// in order. Reads JavaScript string literals properly, so a sentence with
    /// an apostrophe or an escaped quote is not cut short.
    static func closedSayArguments(in code: String) -> [String] {
        let characters = Array(code)
        var results: [String] = []
        var index = 0
        let marker = Array("say(")
        while index + marker.count < characters.count {
            // Only a call, not the end of an identifier like `essay(`.
            let isCall = Array(characters[index..<(index + marker.count)]) == marker
                && (index == 0 || !(characters[index - 1].isLetter || characters[index - 1].isNumber || characters[index - 1] == "_" || characters[index - 1] == "."))
            guard isCall else { index += 1; continue }

            var cursor = index + marker.count
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count, ["\"", "'", "`"].contains(characters[cursor]) else {
                index += 1; continue
            }
            let quote = characters[cursor]
            cursor += 1
            var sentence = ""
            var closed = false
            while cursor < characters.count {
                let character = characters[cursor]
                if character == "\\", cursor + 1 < characters.count {
                    let escaped = characters[cursor + 1]
                    switch escaped {
                    case "n": sentence.append(" ")
                    case "t": sentence.append(" ")
                    default: sentence.append(escaped)
                    }
                    cursor += 2
                    continue
                }
                if character == quote { closed = true; break }
                sentence.append(character)
                cursor += 1
            }
            guard closed else { break }   // still streaming
            results.append(sentence.trimmingCharacters(in: .whitespaces))
            index = cursor + 1
        }
        return results
    }

    private static func substring(_ text: String, from start: Int, to end: Int) -> String {
        guard start < end, start < text.count else { return "" }
        let startIndex = text.index(text.startIndex, offsetBy: start)
        let endIndex = text.index(text.startIndex, offsetBy: min(end, text.count))
        return String(text[startIndex..<endIndex])
    }
}
