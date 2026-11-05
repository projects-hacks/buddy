//
//  MarkCoordinator.swift
//  leanring-buddy
//
//  What the prose path has drawn on the screen: the marks, the spotlight,
//  the scratch board and how much of it is revealed, and where the cursor
//  buddy should fly to point. Turns each directive into a mark at an exact
//  rectangle, paces marks to the words that carry them, moves them with a
//  trackpad scroll and clears them. The cursor overlay reads this state
//  through CompanionManager, which forwards every change.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class MarkCoordinator: ObservableObject {
    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?

    /// Marks currently drawn on screen.
    @Published private(set) var activeAnnotations: [TeacherAnnotation] = []

    /// Regions kept lit while the rest of the screen dims. Empty means no spotlight.
    @Published private(set) var spotlightRectsInGlobalPoints: [CGRect] = []

    /// How much of the answer has been spoken, 0 to 1.
    ///
    /// The board is drawn up to this point. Screen marks already fire from
    /// per-word callbacks, but the diagram arrives as one shape from the
    /// second pass, so without this it would appear complete in an instant
    /// while the explanation is still in its first sentence.
    @Published private(set) var boardRevealFraction: Double = 0

    /// The scratch board the tutor draws on while explaining. Built up as it
    /// speaks, so the picture assembles in the order it is described.
    @Published private(set) var whiteboard = TutorWhiteboard()

    /// The display the current answer is marking up.
    var displayFrameForCurrentAnswer: CGRect = .zero

    /// Characters spoken so far across every segment of this answer.
    private var charactersSpokenInAnswer = 0

    /// Length of the whole answer, known once the stream completes.
    private var totalCharactersInAnswer = 0

    /// Clears the board and marks once the answer has had time to be read.
    private var markDismissalTask: Task<Void, Never>?

    /// The screen index of the current answer, which marks resolve against.
    var currentScreenIndex: () -> ScreenIndex = { ScreenIndex() }
    /// Whether the cursor overlay is up, for the log line of each mark.
    var isOverlayVisible: () -> Bool = { false }
    /// A clear-all directive, or the dismissal after an answer: everything
    /// drawn goes, the drawing program's marks as well.
    var onClearEverything: () -> Void = {}

    /// Whether any mark or spotlight sits over screen content.
    var hasScreenMarks: Bool { !activeAnnotations.isEmpty || !spotlightRectsInGlobalPoints.isEmpty }

    /// A new answer starts revealing from nothing.
    func resetRevealForNewAnswer() {
        charactersSpokenInAnswer = 0
        totalCharactersInAnswer = 0
        boardRevealFraction = 0
    }

    /// The stream finished: the answer's spoken length is known.
    func noteSpokenLength(ofWholeAnswer spokenCharacterCount: Int) {
        totalCharactersInAnswer = max(totalCharactersInAnswer, spokenCharacterCount)
    }

    /// The whole board shown at once, for the calibration picture.
    func revealWholeBoard() {
        boardRevealFraction = 1
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
    }

    // MARK: - Drawing on screen

    /// Turns one directive into a mark, resolving its target to an exact rectangle.
    ///
    /// `spokenContext` is the sentence the mark was attached to. It is only
    /// consulted when an id fails to resolve, as the recovery path described
    /// on `ScreenIndex.bestTextMatch(forSpokenPhrase:)`.
    func apply(directive: TeacherDirective, spokenContext: String = "") {
        let displayFrame = displayFrameForCurrentAnswer
        let screenIndex = currentScreenIndex()

        /// Converts a display-local rectangle into global AppKit points.
        func globalRect(for target: ScreenTarget) -> CGRect {
            CGRect(
                x: target.boundsInDisplayPoints.origin.x + displayFrame.origin.x,
                y: target.boundsInDisplayPoints.origin.y + displayFrame.origin.y,
                width: target.boundsInDisplayPoints.width,
                height: target.boundsInDisplayPoints.height
            )
        }

        func resolve(_ identifier: String) -> CGRect? {
            if let target = screenIndex.target(forIdentifier: identifier) {
                return globalRect(for: target)
            }

            // The id missed. The words around it are usually still honest
            // about what the model meant, so try to recover from those before
            // dropping the mark.
            let leadingPhrase = phraseLeadingUpTo(
                characterOffset: directive.characterOffsetInSpokenText,
                in: spokenContext
            )

            if let recoveredTarget = screenIndex.bestTextMatch(forSpokenPhrase: leadingPhrase) {
                TutorDebugLog.write("↩️ Recovered bad id \(identifier) as \(recoveredTarget.id) via \"\(recoveredTarget.displayedText)\"")
                return globalRect(for: recoveredTarget)
            }

            TutorDebugLog.write("⚠️ unknown target \(identifier), nothing nearby matched")
            return nil
        }

        switch directive.action {
        case .clearAll:
            onClearEverything()

        // MARK: Board
        //
        // Each of these appends to the board, and appending is the reveal:
        // because directives fire from speech word boundaries, an element
        // lands exactly as it is described rather than the finished picture
        // appearing at once.

        case .beginBoard(let title):
            withAnimation(.easeOut(duration: 0.3)) {
                whiteboard = TutorWhiteboard(title: title)
            }

        case .addBoardColumn(let label, let content):
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                whiteboard.columns.append(
                    TutorWhiteboard.Column(label: label, content: content)
                )
            }

        case .addBoardBase(let label):
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                whiteboard.baseLabel = label
            }

        case .addBoardCells(let values):
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                whiteboard.cells = values
                // Pointers refer to positions in the old row, so they are
                // dropped rather than left pointing somewhere arbitrary.
                whiteboard.pointers = []
            }

        case .addBoardPointer(let position, let name):
            guard let cellIndex = position.resolve(inCellCount: whiteboard.cells.count) else {
                TutorDebugLog.write("⚠️ pointer \(name) could not be placed; row has \(whiteboard.cells.count) cell(s)")
                return
            }
            withAnimation(.easeOut(duration: 0.22)) {
                // One name per position: re-stating `mid` moves it rather than
                // stacking a second label under the same cell. This is what
                // makes a walkthrough animate, since each restatement of `lo`
                // slides the marker along instead of littering the row.
                whiteboard.pointers.removeAll { pointer in pointer.name == name }
                whiteboard.pointers.append(
                    TutorWhiteboard.Pointer(cellIndex: cellIndex, name: name)
                )
            }

        case .addBoardNode(let identifier, let column, let row, let widthInColumns, let label, let tint):
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                // Restating a node moves it rather than stacking a duplicate,
                // which is what lets a diagram be corrected mid-explanation.
                whiteboard.nodes.removeAll { existing in existing.id == identifier }
                whiteboard.nodes.append(
                    TutorWhiteboard.Node(
                        id: identifier,
                        column: column,
                        row: row,
                        widthInColumns: widthInColumns,
                        label: label,
                        tint: TutorWhiteboard.Node.Tint(name: tint)
                    )
                )
            }

        case .addBoardEdge(let fromIdentifier, let toIdentifier, let label):
            // Both ends must exist, or the arrow has nothing to attach to and
            // would be drawn from the origin.
            let knownIdentifiers = Set(whiteboard.nodes.map(\.id))
            guard knownIdentifiers.contains(fromIdentifier),
                  knownIdentifiers.contains(toIdentifier) else {
                TutorDebugLog.write("⚠️ edge \(fromIdentifier)->\(toIdentifier) references a node that was never drawn")
                return
            }
            withAnimation(.easeOut(duration: 0.3)) {
                whiteboard.edges.append(
                    TutorWhiteboard.Edge(
                        fromIdentifier: fromIdentifier,
                        toIdentifier: toIdentifier,
                        label: label
                    )
                )
            }

        case .drawDiagram(let shape):
            let expanded = shape.expand()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                whiteboard.nodes = expanded.nodes
                whiteboard.edges = expanded.edges
            }
            TutorDebugLog.write("📐 drew \(expanded.nodes.count) boxes, \(expanded.edges.count) arrows")

        case .addBoardNote(let text):
            withAnimation(.easeOut(duration: 0.25)) {
                whiteboard.caption = text
            }

        case .point(let identifier):
            guard let rect = resolve(identifier) else { return }
            detectedElementScreenLocation = CGPoint(x: rect.midX, y: rect.midY)
            detectedElementDisplayFrame = displayFrame

        case .pointAtCoordinate(let x, let y, _, _):
            // Coordinates arrive in the screenshot's top-left space; the
            // overlay works in AppKit's bottom-left space.
            let flippedY = displayFrame.height - y
            detectedElementScreenLocation = CGPoint(
                x: x + displayFrame.origin.x,
                y: flippedY + displayFrame.origin.y
            )
            detectedElementDisplayFrame = displayFrame

        case .circle(let identifier):
            appendAnnotation(style: .circle, identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .box(let identifier):
            appendAnnotation(style: .box, identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .underline(let identifier):
            appendAnnotation(style: .underline, identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .highlight(let identifier):
            appendAnnotation(style: .highlight, identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .strikethrough(let identifier):
            appendAnnotation(style: .strikethrough, identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .step(let identifier, let stepNumber):
            appendAnnotation(style: .step(number: stepNumber), identifier: identifier, resolve: resolve, displayFrame: displayFrame)
        case .callout(let identifier, let text):
            appendAnnotation(style: .callout(text: text), identifier: identifier, resolve: resolve, displayFrame: displayFrame)

        case .arrow(let fromIdentifier, let toIdentifier):
            guard let fromRect = resolve(fromIdentifier),
                  let toRect = resolve(toIdentifier) else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                activeAnnotations.append(
                    TeacherAnnotation(
                        style: .arrow(destinationRectInGlobalPoints: toRect),
                        rectInGlobalPoints: fromRect,
                        displayFrame: displayFrame
                    )
                )
            }

        case .spotlight(let identifiers):
            // Capped in code, not just asked for in the prompt. The model
            // spotlighted sixteen targets on its first real run, which lights
            // most of the screen and hides nothing, defeating the one mark
            // whose whole value is removing distraction.
            let litRects = identifiers.prefix(3).compactMap(resolve)
            guard !litRects.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                spotlightRectsInGlobalPoints = litRects
            }
        }
    }

    /// Returns the words just before a mark, which is where the model names
    /// the thing it is marking.
    ///
    /// Looks backwards rather than around the offset because the natural
    /// phrasing is "the load balancer [POINT:t12]": the noun precedes the tag.
    /// A short lookahead is still included for the occasional inversion.
    private func phraseLeadingUpTo(characterOffset: Int, in text: String) -> String {
        guard !text.isEmpty else { return "" }

        let charactersBefore = 70
        let charactersAfter = 25

        let clampedOffset = max(0, min(characterOffset, text.count))
        let lowerBound = max(0, clampedOffset - charactersBefore)
        let upperBound = min(text.count, clampedOffset + charactersAfter)
        guard lowerBound < upperBound else { return "" }

        let startIndex = text.index(text.startIndex, offsetBy: lowerBound)
        let endIndex = text.index(text.startIndex, offsetBy: upperBound)
        return String(text[startIndex..<endIndex])
    }

    private func appendAnnotation(
        style: TeacherAnnotation.Style,
        identifier: String,
        resolve: (String) -> CGRect?,
        displayFrame: CGRect
    ) {
        guard let rect = resolve(identifier) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            activeAnnotations.append(
                TeacherAnnotation(
                    style: style,
                    rectInGlobalPoints: rect,
                    displayFrame: displayFrame
                )
            )
        }
        TutorDebugLog.write("🖊️ \(identifier) -> rect (\(Int(rect.minX)),\(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height)) on display \(Int(displayFrame.width))x\(Int(displayFrame.height)) at \(Int(displayFrame.origin.x)),\(Int(displayFrame.origin.y)), total now \(activeAnnotations.count), overlayVisible=\(isOverlayVisible())")
    }

    // MARK: - Pacing marks to speech

    /// One sentence's marks, drawn as the words carrying them are said, and
    /// the board revealed as far as the answer has been spoken.
    func marksFollowingSpeech(of segment: ParsedTeacherResponse) -> ProseSpeechQueue.SegmentMarks {
        var undispatchedDirectives = segment.directives
        let charactersBeforeThisSegment = charactersSpokenInAnswer

        // Until the stream finishes the total is unknown, so it is estimated
        // from what has been queued. Otherwise the first segment would divide
        // by nothing and the board would appear complete immediately.
        if totalCharactersInAnswer == 0 {
            totalCharactersInAnswer = max(1, charactersBeforeThisSegment + segment.spokenText.count * 3)
        }

        func drawMarksReached(upToCharacterOffset offset: Int) {
            let spokenOverall = charactersBeforeThisSegment + offset
            charactersSpokenInAnswer = max(charactersSpokenInAnswer, spokenOverall)
            let fraction = Double(charactersSpokenInAnswer) / Double(max(1, totalCharactersInAnswer))
            // Monotonic: a diagram must never un-draw itself mid-sentence.
            if fraction > boardRevealFraction {
                withAnimation(.easeOut(duration: 0.35)) {
                    boardRevealFraction = min(1.0, fraction)
                }
            }

            while let next = undispatchedDirectives.first,
                  Self.offsetWhereMarkedPhraseBegins(
                    tagOffset: next.characterOffsetInSpokenText,
                    spokenText: segment.spokenText
                  ) <= offset {
                undispatchedDirectives.removeFirst()
                apply(directive: next, spokenContext: segment.spokenText)
            }
        }

        return ProseSpeechQueue.SegmentMarks(
            reached: { offset in drawMarksReached(upToCharacterOffset: offset) },
            finished: { [self] in
                drawMarksReached(upToCharacterOffset: segment.spokenText.count)
                charactersSpokenInAnswer = charactersBeforeThisSegment + segment.spokenText.count
            }
        )
    }

    /// Where the words a mark belongs to start, so the mark appears as they
    /// are spoken rather than after.
    ///
    /// The model writes a tag after the phrase it marks: "the real separation
    /// is between workers and a shared storage layer like s3 [UNDERLINE:t44]".
    /// Fired at the tag, that underline landed ten seconds into the sentence,
    /// after the student had finished hearing about the thing it underlines.
    /// Backed up to the start of the clause, it appears as the phrase begins.
    /// Capped at about four seconds of speech, so a long clause does not mark
    /// its subject before it has been named at all.
    static func offsetWhereMarkedPhraseBegins(tagOffset: Int, spokenText: String) -> Int {
        let characters = Array(spokenText)
        let clampedTagOffset = min(max(tagOffset, 0), characters.count)
        let longestLeadInCharacters = 60
        let clauseBoundaries: Set<Character> = [".", ",", ";", ":", "!", "?"]

        var phraseStart = clampedTagOffset
        // Step over any boundary sitting right at the tag, so "s3 [TAG]." backs
        // into its own clause rather than stopping at its own full stop.
        while phraseStart > 0, characters[phraseStart - 1] == " " {
            phraseStart -= 1
        }
        while phraseStart > 0,
              clampedTagOffset - phraseStart < longestLeadInCharacters,
              !clauseBoundaries.contains(characters[phraseStart - 1]) {
            phraseStart -= 1
        }
        // The cap can stop mid-word. Finish the word, so the count is in words.
        while phraseStart > 0, characters[phraseStart - 1].isLetter || characters[phraseStart - 1].isNumber {
            phraseStart -= 1
        }
        return phraseStart
    }

    // MARK: - Lifetime

    /// Takes the board and marks down a while after the answer finishes.
    ///
    /// They previously stayed until the next question, so a board left behind
    /// covered the screen indefinitely. The delay is generous on purpose: the
    /// diagram is the part worth looking at after the talking stops, and
    /// asking again clears it immediately anyway.
    func scheduleDismissal() {
        markDismissalTask?.cancel()
        markDismissalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.onClearEverything()
        }
    }

    func cancelDismissal() {
        markDismissalTask?.cancel()
        markDismissalTask = nil
    }

    /// Moves screen marks with the content as a trackpad scrolls it.
    /// Positive deltas move content down the screen, which is downward in
    /// AppKit's bottom-left coordinates.
    func shiftScreenMarks(byVerticalDelta verticalDelta: CGFloat) {
        activeAnnotations = activeAnnotations.map { annotation in
            annotation.shiftedVertically(by: -verticalDelta)
        }
        spotlightRectsInGlobalPoints = spotlightRectsInGlobalPoints.map { rect in
            rect.offsetBy(dx: 0, dy: -verticalDelta)
        }
    }

    /// Removes marks drawn over screen content, keeping the board.
    func clearScreenMarks() {
        guard hasScreenMarks else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            activeAnnotations.removeAll()
            spotlightRectsInGlobalPoints.removeAll()
        }
    }

    /// Wipes every mark and takes down the board. Whether anything was drawn.
    func clearEverythingDrawn() -> Bool {
        let hasNothingToClear = activeAnnotations.isEmpty
            && spotlightRectsInGlobalPoints.isEmpty
            && !whiteboard.hasContent
        guard !hasNothingToClear else { return false }

        withAnimation(.easeOut(duration: 0.25)) {
            activeAnnotations.removeAll()
            spotlightRectsInGlobalPoints.removeAll()
            whiteboard = TutorWhiteboard()
        }
        return true
    }
}
