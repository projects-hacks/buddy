// Reads the text on a screenshot with Apple Vision and prints it the way the
// app lists it to the model: `tN [x, y, w, h] text`, boxes in the image's own
// pixels with the origin at the top left. Lets the race give every model the
// same screen description the app would.
//
// usage: swift screen_listing.swift screenshot.png

import AppKit
import Vision

let path = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: path),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("cannot read \(path)")
}
let width = Double(cgImage.width), height = Double(cgImage.height)

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: cgImage).perform([request])

var lines: [(y: Double, x: Double, text: String)] = []
for observation in request.results ?? [] {
    guard let best = observation.topCandidates(1).first else { continue }
    let box = observation.boundingBox
    let x = (box.minX * width).rounded(), w = (box.width * width).rounded()
    let h = (box.height * height).rounded(), y = ((1 - box.maxY) * height).rounded()
    lines.append((y, x, "[\(Int(x)), \(Int(y)), \(Int(w)), \(Int(h))] \(best.string)"))
}
lines.sort { ($0.y, $0.x) < ($1.y, $1.x) }
for (index, line) in lines.enumerated() {
    print("t\(index + 1) \(line.text)")
}
print("SIZE \(Int(width)) \(Int(height))")
