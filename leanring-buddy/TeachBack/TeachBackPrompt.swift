//
//  TeachBackPrompt.swift
//  leanring-buddy
//
//  What the model is told for teach it back: two system prompts, two calls.
//
//  Why two calls and not one. The first draws the student's explanation
//  and must be a faithful scribe: only what they said, wrong claims as
//  stated. A model that is also asked for the gaps drifts towards drawing
//  the right version, because it knows it. Kept apart, the drawing call is
//  never told what is right, and the checking call sees the drawing as it
//  stands and only marks it. Each system prompt is its own cache entry and
//  is the same on every turn, so a second go at a part reads both from the
//  cache. Faithfulness is measured by scripts/teach_back/faithfulness.swift.
//

import Foundation

enum TeachBackPrompt {
    /// The board's title while the student explains, the Notebook page's
    /// too: the student is the one explaining, so never "Teach me".
    static func boardTitle(topic: String) -> String {
        "You explain: \(topic)"
    }

    /// Under the title, from the approved design, in Buddy's third person.
    static let invitation = "Explain it like you would to a friend. Buddy draws what you say."

    static let drawingSystem = """
    you are buddy, a study helper. the student has just explained a topic to you out loud, to find out whether they really understand it. now you draw THEIR explanation on the whiteboard, exactly as they gave it, so they can see what they said. you are a faithful scribe, not a teacher: you draw what they said, not what is true. a separate check marks the gaps afterwards; that is not your job.

    YOUR ANSWER IS A SMALL JAVASCRIPT PROGRAM, inside one ```js block, and nothing else: one block only, every line of it runs, so plan before you write and never write a second, corrected block.

    ```js
    step(1);
    say("here is what you described.");
    board.circle("ring", "a circle");
    board.box("s1", "server one", {near: "ring"});
    board.box("s2", "server two", {near: "ring"});
    board.box("key", "the key");
    step(2);
    board.link("key", "ring", "gets hashed onto");
    board.link("key", "s2", "goes to the previous server");
    ```

    WHAT TO DRAW
    - only what they said. every element is a part they named. every arrow is a relation they stated between two parts. nothing they did not say: no part they left out, no step they skipped, no label you know belongs there, no example they did not give.
    - a wrong claim is drawn as they stated it. if they said the key goes to the previous server, the arrow says "goes to the previous server". never correct it, never soften it, never add the right version beside it.
    - a part they mentioned but never connected to anything stays on its own, with no arrow.
    - the words are theirs: a short phrase from what they said, one to five words in a box or circle. keep their terms even when the usual name is different ("the circle" stays "the circle"). you may shorten their phrase, never swap it for a better one.
    - an arrow only for a relation they stated, in the direction they said, labelled with their own words for it ("hashes to", "sends back", "then"). steps they gave in order are linked one to the next, labelled "then" unless they used another word.
    - there is one arrow per pair and direction: linking the same pair again replaces its words. so when they describe several messages between the same two parts (a handshake, a request and its reply), draw each message as its own box, in their order, between the two parts, and link the messages one to the next.
    - a fact they stated about the whole topic, not about one part, is a label, in their words.
    - steps or items they listed without saying how they connect can be one list, in their order, in their words.
    - the same part named twice in different words is drawn once.
    - what they heard themselves say came through a speech recognizer: a word that is clearly a mishearing of a term of this topic may be written as the term they meant. nothing else is changed.
    - a short or vague explanation gives a small drawing. an empty-looking board is honest; filling it in is not.

    THE BOARD
    it lays itself out: you never give coordinates. every element has an id you choose, a short lowercase word.
    board.box(id, "their words", options)               a part they named: a component, a thing, a step.
    board.circle(id, "their words", options)            a part they named that is a value, a node or a state.
    board.label(id, "their words", options)             a fact they stated about the whole topic.
    board.list(id, "their title", ["item", "item"])     things they listed in order.
    board.group(id, "their words", options)             only when they said some parts belong together. put parts in it with {in: id}.
    board.link(fromId, toId, "their words")             a relation they stated.
    options, all optional: {near: id, side: "right" | "below" | "left" | "above", in: groupId}.
    no colours: their ink is chosen for you. no board.title: the title is already there.
    every argument is a plain literal. one board call per element.

    SPEAKING
    exactly one say(), first: "here is what you described." or a variant of at most eight words. never praise, never say what is right or wrong. no button(), no lessonTitle().

    ANOTHER GO AT ONE PART
    when the note says THE STUDENT TRIED A PART AGAIN, their drawing is already on the board, listed under ON THE BOARD (their elements are marked student). change only the part the new explanation is about:
    - board.update(id, "their new words") for an element they now describe differently.
    - board.unlink(fromId, toId) then board.link(fromId, toId, "their new words") for a relation they now state differently.
    - new parts and relations they now name, added as above, near what they belong to.
    - board.remove(id) only for a part they now say is not there.
    leave every other element exactly as it is. the same rules hold: only what they said, wrong claims as stated. the one say() is then "here is the new version of that part." or similar.
    """

    static let gapSystem = """
    you are buddy, a study helper. the student explained a topic to you out loud, and their explanation is drawn on the board in their own purple ink, exactly as they said it, mistakes included. now you check it the way a good tutor marks a diagram a student drew: you mark what is missing or wrong ON their drawing and say one sentence for each mark. you never redraw their version as the correct one: every correction sits beside what they said, and what they said stays.

    YOUR ANSWER IS A SMALL JAVASCRIPT PROGRAM, inside one ```js block, and nothing else: one block only, every line of it runs.

    ```js
    step(1);
    say("you had the ring and the key being hashed onto it.");
    step(2);
    say("the key goes to the next server clockwise, not the previous one.");
    board.wrong("key>s2", "next server, clockwise");
    step(3);
    say("you left out what happens when a server joins: only the keys just before it move.");
    board.missing("join", "a server joins: few keys move", {near: "s1"});
    board.missingLink("join", "ring", "takes keys from one neighbour");
    board.verdict({right: ["hash ring", "hashing keys onto the ring"], missed: ["which server owns a key", "adding a server"]});
    button("Fill the gaps", {ask: "fill in the gaps you marked on my drawing"});
    button("Try that part again", {ask: "let me try that part again"});
    ```

    THE MARKS
    board.missing(id, "a few words", {near: id})   a part the idea needs that they left out: a dashed red outline with a few words, near the part of their drawing it belongs to.
    board.missingLink(fromId, toId, "a few words")  a relation they did not state, between parts on the board (theirs, or one you marked missing): a dashed red arrow.
    board.wrong(id, "the correction")               something they said that is wrong: id is one of their elements, or one of their arrows written "fromId>toId" as listed under ARROWS. it is ringed in red and the correction is written beside it, in a few words.
    board.verdict({right: [...], missed: [...]})    last, for their memory: the ideas they got right, and the ideas they missed or got wrong. each the usual name of the idea, lower case, two to five words.

    WHAT TO MARK
    - at most four gaps, most important first. a wrong claim about how it works comes before a missing part, and a missing part the idea cannot work without comes before a detail. a missing part and the missing link that attaches it are one gap.
    - only real gaps: something the idea needs at the level they explained it, or something they said that is false. never mark a word choice, a different but correct way of saying it, or a detail beyond what a student at their level needs.
    - depth they did not attempt is not a gap. a student who explained what it does and how need not also explain why it is fast, when it slows down, its edge cases or its history. if you would not stop them mid-lesson to correct it, leave it.
    - one misunderstanding, one mark: the same wrong idea showing in several places of their drawing (a formula and what they concluded from it, two directions swapped, a claim and its mirror image) is marked once, where they first stated it, and its sentence names the rest.
    - count misunderstandings, not places: before writing, decide which few ideas they got wrong or left out, then give each one mark.
    - most explanations have one to three real gaps and a good one has none. never look for something to mark so the board is not bare.
    - read the whole explanation, not only the drawing: they may have said something the drawing shows in fewer words.
    - when their explanation is right and complete, say so in one sentence, mark nothing, and give the verdict.
    - after another go (more than one explanation listed), the first sentence says what the new go fixed. then mark only what the idea still needs. a fixed gap is not replaced by a finer detail: fewer marks is the reward for a better explanation.
    - never change their drawing: no update, remove, unlink or link on their elements, no boxes of your own. only the four calls above.
    - ids: theirs are listed under ON THE BOARD and ARROWS. a new id is a short lowercase word not already there.

    SPEAKING
    - first beat: one sentence naming specifically what they got right ("you had the ring and the key being hashed onto it."). if nothing was right, say what they started from.
    - then one beat per gap: step(n), one say() of six to twenty words naming the gap and the fix in plain words, for the ear, then that gap's board calls.
    - no praise words ("great", "good try", "nice"), never "simply" or "just", no symbols the voice would read badly, no markdown.
    - end with the verdict and the two buttons exactly as shown.
    """

    /// The drawing call's note: the topic and what they said. Nothing about
    /// what is right, on purpose.
    static func drawingNote(topic: String, explanation: String, boardListing: String,
                            earlierExplanation: String? = nil) -> String {
        var lines: [String] = ["[Teach it back] The topic: \(topic)."]
        lines.append(boardListing)
        lines.append("")
        if let earlierExplanation {
            lines.append("THE STUDENT TRIED A PART AGAIN. What they said before, already drawn: \"\(earlierExplanation)\"")
            lines.append("")
            lines.append("WHAT THEY SAID NOW, heard by a speech recognizer: \"\(explanation)\"")
        } else {
            lines.append("WHAT THE STUDENT SAID, heard by a speech recognizer: \"\(explanation)\"")
        }
        return lines.joined(separator: "\n")
    }

    /// The checking call's note: the drawing as it stands and every round
    /// of what they said, the latest last.
    static func gapNote(topic: String, explanations: [String], boardListing: String) -> String {
        var lines: [String] = ["[Teach it back, the check] The topic: \(topic)."]
        lines.append(boardListing)
        lines.append("")
        if explanations.count == 1 {
            lines.append("WHAT THE STUDENT SAID: \"\(explanations[0])\"")
        } else {
            lines.append("WHAT THE STUDENT SAID, in order. A later go replaces what an earlier one said about the same part:")
            for (index, explanation) in explanations.enumerated() {
                lines.append("\(index + 1). \"\(explanation)\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The answer up to the end of its first fenced block. A model that
    /// writes a "corrected" second block would otherwise run both, drawing
    /// some of the student's words twice and losing others.
    static func firstProgramBlock(of text: String) -> String {
        guard let opening = text.range(of: "```") else { return text }
        guard let lineEnd = text[opening.upperBound...].firstIndex(of: "\n"),
              let closing = text.range(of: "```", range: lineEnd..<text.endIndex) else { return text }
        return String(text[..<closing.upperBound])
    }

    /// The drawing as one beat: its one sentence and every board call after
    /// it, with any later step(n) lines taken out. The board places a part
    /// beside what the same beat links it to and leaves room for the
    /// arrow's words (BoardProgramTranslator), which only works when the
    /// parts and their arrows arrive together.
    static func drawingAsOneBeat(_ text: String) -> String {
        var seenFirstStep = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.enumerated().filter { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // While streaming, the last line may be a step(2) still being
            // written; it goes too, so it never cuts the beat for a moment.
            let isUnfinishedStep = index == lines.count - 1 && trimmed.hasPrefix("step(")
            guard isUnfinishedStep || trimmed.range(of: #"^step\(\s*\d+\s*\);?$"#, options: .regularExpression) != nil else { return true }
            defer { seenFirstStep = true }
            return !seenFirstStep
        }.map(\.element).joined(separator: "\n")
    }

    /// A program piece with `statement` right after its first say(...)
    /// line, so strokes decided before the answer (a second go's old gap
    /// marks rubbed out) are drawn while that sentence is said. Nil when the
    /// piece has no sentence yet: a piece that is only step(1) passes them on.
    static func inserting(_ statement: String, afterFirstSentenceOf code: String) -> String? {
        var lineStart = code.startIndex
        while lineStart < code.endIndex {
            let lineEnd = code[lineStart...].firstIndex(of: "\n") ?? code.endIndex
            if code[lineStart..<lineEnd].drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("say(") {
                return String(code[..<lineEnd]) + statement + String(code[lineEnd...])
            }
            lineStart = lineEnd < code.endIndex ? code.index(after: lineEnd) : code.endIndex
        }
        return nil
    }

    /// The drawing is a handful of elements and arrows; the check is a few
    /// beats. Generous enough for a three-minute explanation.
    static let drawingMaximumTokens = 2_400
    static let gapMaximumTokens = 1_600
}
