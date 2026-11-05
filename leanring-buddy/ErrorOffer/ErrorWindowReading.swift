//
//  ErrorWindowReading.swift
//  leanring-buddy
//
//  The parts of the error watcher that work on an image and nothing else:
//  the small grey thumbnail that says whether a window changed and where,
//  and text recognition on the part that changed. Kept apart from the
//  watcher, which needs the window server and the accessibility tree, so
//  scripts/error_offer/ can time and grade exactly this code on saved images.
//

import CoreGraphics
import Foundation
import Vision

/// One line of text read from a window image, with where it was.
nonisolated struct ReadTextLine: Sendable {
    let text: String
    /// In the image's pixels, origin at the top left.
    let boundsInImage: CGRect
}

nonisolated enum ErrorWindowReading {

    // MARK: Thumbnails

    /// The grid a window is reduced to. A new line of output in a terminal
    /// changes a row of cells; a blinking caret changes one.
    static let thumbnailWidth = 96
    static let thumbnailHeight = 60
    /// A cell counts as changed past this much brightness, so compression
    /// noise and anti-aliasing do not.
    static let cellChangeThreshold = 26
    /// A caret, a spinner or the pointer is a few cells; output is more.
    static let changedCellsForNewOutput = 6

    static func thumbnail(of image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: thumbnailWidth * thumbnailHeight)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: thumbnailWidth, height: thumbnailHeight,
                bitsPerComponent: 8, bytesPerRow: thumbnailWidth,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: thumbnailWidth, height: thumbnailHeight))
            return true
        }
        return drew ? pixels : nil
    }

    /// How many cells changed between two thumbnails, and the band of rows
    /// they are in, as fractions of the window with the origin at the top.
    /// Whole rows are returned because output is read line by line: a
    /// changed word in the middle of a line still needs the whole line.
    static func changedRows(from before: [UInt8], to after: [UInt8]) -> (changedCells: Int, rowBand: ClosedRange<Double>?) {
        guard before.count == after.count, before.count == thumbnailWidth * thumbnailHeight else { return (0, nil) }
        var changedCells = 0
        var topRow = thumbnailHeight
        var bottomRow = -1
        for row in 0..<thumbnailHeight {
            for column in 0..<thumbnailWidth {
                let cellIndex = row * thumbnailWidth + column
                if abs(Int(before[cellIndex]) - Int(after[cellIndex])) > cellChangeThreshold {
                    changedCells += 1
                    // Core Graphics drew the thumbnail with row 0 at the
                    // bottom of the window, so the row is flipped here.
                    let rowFromTop = thumbnailHeight - 1 - row
                    topRow = min(topRow, rowFromTop)
                    bottomRow = max(bottomRow, rowFromTop)
                }
            }
        }
        guard bottomRow >= topRow else { return (changedCells, nil) }
        let band = (Double(topRow) / Double(thumbnailHeight))...(Double(bottomRow + 1) / Double(thumbnailHeight))
        return (changedCells, band)
    }

    // MARK: Text recognition

    /// The text of the image, or of a band of its rows, line by line from
    /// top to bottom. `rowBand` is a fraction of the height with the origin
    /// at the top; it is widened a little so a line cut by the band's edge
    /// is still read whole.
    static func readLines(in image: CGImage, rowBand: ClosedRange<Double>? = nil, accurate: Bool = true) -> [ReadTextLine] {
        let imageHeight = Double(image.height)
        var imageToRead = image
        var offsetFromTop = 0.0
        if let rowBand {
            let lineAllowance = 0.03
            let top = max(0, rowBand.lowerBound - lineAllowance)
            let bottom = min(1, rowBand.upperBound + lineAllowance)
            let cropRect = CGRect(x: 0, y: (top * imageHeight).rounded(.down),
                                  width: Double(image.width), height: ((bottom - top) * imageHeight).rounded(.up))
            if let cropped = image.cropping(to: cropRect) {
                imageToRead = cropped
                offsetFromTop = cropRect.minY
            }
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        // Code and file paths are not words; correction turns `nums[i]`
        // into something else and `File "app.py"` into prose.
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: imageToRead, options: [:]).perform([request])
        } catch {
            return []
        }
        let readWidth = Double(imageToRead.width)
        let readHeight = Double(imageToRead.height)
        let fragments: [ReadTextLine] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            let bounds = CGRect(x: box.minX * readWidth,
                                y: (1 - box.maxY) * readHeight + offsetFromTop,
                                width: box.width * readWidth,
                                height: box.height * readHeight)
            return ReadTextLine(text: candidate.string, boundsInImage: bounds)
        }
        return joinedIntoRows(fragments)
    }

    /// Recognition splits a line where it has a wide gap, as in Jest's
    /// "Tests:       1 failed". Pieces at the same height are joined back
    /// in reading order, unless the gap between them is so wide that they
    /// are two panes side by side.
    static func joinedIntoRows(_ fragments: [ReadTextLine]) -> [ReadTextLine] {
        let sortedByTop = fragments.sorted { $0.boundsInImage.midY < $1.boundsInImage.midY }
        var rows: [[ReadTextLine]] = []
        for fragment in sortedByTop {
            if let lastRow = rows.last, let anchor = lastRow.first,
               abs(anchor.boundsInImage.midY - fragment.boundsInImage.midY) < anchor.boundsInImage.height * 0.5 {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        var joined: [ReadTextLine] = []
        for row in rows {
            let leftToRight = row.sorted { $0.boundsInImage.minX < $1.boundsInImage.minX }
            var current = leftToRight[0]
            for fragment in leftToRight.dropFirst() {
                let characterWidth = current.boundsInImage.width / Double(max(current.text.count, 1))
                let gap = fragment.boundsInImage.minX - current.boundsInImage.maxX
                if gap < characterWidth * 12 {
                    current = ReadTextLine(text: current.text + " " + fragment.text,
                                           boundsInImage: current.boundsInImage.union(fragment.boundsInImage))
                } else {
                    joined.append(current)
                    current = fragment
                }
            }
            joined.append(current)
        }
        return joined
    }

    // MARK: Matching a line to the screen index

    /// The id of the listed screen text that is the same line as one read
    /// from the window. Recognition on the whole screen may join or split
    /// lines differently from the window read, so lines are compared by
    /// their words: most of the line's words, or nearly all of a listed
    /// fragment's when it shares at least three. A short label such as the
    /// tab title "main.py" never stands in for the frame that names it.
    static func bestListedIdentifier(for lineText: String, among listedLabels: [String: String]) -> String? {
        let lineWords = words(in: lineText)
        guard lineWords.count >= 2 else { return nil }
        var best: (identifier: String, shared: Int, coverage: Double)?
        for (identifier, label) in listedLabels.sorted(by: { $0.key < $1.key }) {
            let labelWords = words(in: label)
            guard !labelWords.isEmpty else { continue }
            let shared = lineWords.intersection(labelWords).count
            let coverageOfLine = Double(shared) / Double(lineWords.count)
            let coverageOfLabel = Double(shared) / Double(labelWords.count)
            guard shared >= 2, coverageOfLine >= 0.6 || (coverageOfLabel >= 0.8 && shared >= 3) else { continue }
            // Between two lines sharing as many words, the closer copy wins.
            let coverage = coverageOfLine + coverageOfLabel
            if best == nil || shared > best!.shared || (shared == best!.shared && coverage > best!.coverage) {
                best = (identifier, shared, coverage)
            }
        }
        return best?.identifier
    }

    private static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init).filter { $0.count >= 2 })
    }

    // MARK: Accessibility text

    /// The characters of a terminal's accessibility text to read: what it
    /// printed after the trigger that is on screen now. Output from before
    /// Return went down is history, and so is anything scrolled out of
    /// view. When the text got shorter (the screen was cleared), all that
    /// is visible counts. Counts are in UTF-16 units, as the accessibility
    /// API gives them.
    static func rangeToRead(characterCountAtTrigger: Int, visibleRange: NSRange, currentCharacterCount: Int) -> NSRange {
        let visibleEnd = min(NSMaxRange(visibleRange), currentCharacterCount)
        let wasCleared = currentCharacterCount < characterCountAtTrigger
        let start = wasCleared ? visibleRange.location : max(characterCountAtTrigger, visibleRange.location)
        guard visibleEnd > start else { return NSRange(location: visibleEnd, length: 0) }
        return NSRange(location: start, length: visibleEnd - start)
    }
}
