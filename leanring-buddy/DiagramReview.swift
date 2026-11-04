//
//  DiagramReview.swift
//  leanring-buddy
//
//  When the student is drawing their own design (a system design in
//  Excalidraw, a flow in draw.io, boxes in Freeform), Buddy talks it through
//  the way a peer at the whiteboard would, and draws on their diagram rather
//  than beside it: rings and arrows on their own boxes, and anything it
//  proposes drawn dashed, in a different colour, next to where it would go,
//  so a suggestion reads as a suggestion and never as a correction.
//
//  Why it is its own mode. Interview practice tools that look at a board do
//  it inside their own web whiteboard and end with a score. Buddy works on
//  whatever tool is already open, and never scores: the student should come
//  away with a better design and the reason it is better, not a grade.
//
//  Their boxes' labels are in the screen index like any other text, so the
//  tutor can point at "Redis" by id, exactly.
//

import Foundation

enum DiagramReview {
    /// Apps and sites where people draw diagrams, by what their window or
    /// app name contains.
    private static let drawingTools: [(match: String, name: String)] = [
        ("excalidraw", "Excalidraw"), ("tldraw", "tldraw"), ("draw.io", "draw.io"), ("diagrams.net", "draw.io"),
        ("miro", "Miro"), ("figjam", "FigJam"), ("freeform", "Freeform"), ("whimsical", "Whimsical"),
        ("lucidchart", "Lucidchart"), ("eraser", "Eraser"), ("mermaid", "Mermaid"), ("whiteboard", "a whiteboard"),
        ("omnigraffle", "OmniGraffle"), ("google drawings", "Google Drawings"), ("visio", "Visio"),
        ("mural", "Mural"), ("canva", "Canva")
    ]

    /// Things a student says about a drawing of their own, in any app.
    private static let ownDrawingPhrases = [
        "my design", "my diagram", "my architecture", "my drawing", "my sketch", "my system", "what i drew",
        "i drew", "i've drawn", "ive drawn", "i have drawn", "review my", "look at my", "check my design",
        "my whiteboard", "this design of mine", "my boxes", "my flow"
    ]

    /// The tool, when the student is working on a drawing of their own.
    static func detect(frontAppName: String?, windowTitle: String?, transcript: String) -> String? {
        let title = (windowTitle ?? "").lowercased()
        let app = (frontAppName ?? "").lowercased()
        for tool in drawingTools where title.contains(tool.match) || app.contains(tool.match) {
            return tool.name
        }
        let said = transcript.lowercased()
        if ownDrawingPhrases.contains(where: { said.contains($0) }) {
            return frontAppName ?? "their drawing"
        }
        return nil
    }

    static func instruction(tool: String) -> String {
        """
        THEY ARE DRAWING THEIR OWN DESIGN, in \(tool). be the peer at the whiteboard beside them, not an examiner: no score, no verdict on the whole design, no "good job". if they are asking about \(tool) itself (how to draw an arrow), ignore this and just answer.
        - their diagram is the canvas. the labels of their boxes are in SCREEN TEXT: point at their own components by id with ring, point and connect, or by coordinates for unlabelled shapes and arrows.
        - lead with the one thing that matters most for what they asked: the missing piece, the bottleneck, the single point of failure, the request path that cannot work. one point per beat, each marked on their diagram.
        - to propose something they have not drawn, draw it beside their diagram, in empty space next to where it would go: suggest(x, y, w, h, "cache"), then connect(...) it to their boxes with {tone: "purple"}. dashed and purple reads as a proposal, not a correction. at most two proposals.
        - keep their diagram readable: at most four marks on it besides the proposals, labels of one to three words, and only on the arrows that matter. never draw across the text in their boxes, never put a label on a box, and leave their own title alone.
        - no card, unless they need a picture of something that cannot go on their canvas.
        - if you talked about this diagram earlier in the conversation, start from what they changed since.
        - end with one button asking the next question a design reviewer would ask about it, for example button("what if redis goes down?", {ask: "what happens in my design if redis goes down?"}).
        """
    }
}
