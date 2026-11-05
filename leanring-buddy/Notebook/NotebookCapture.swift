//
//  NotebookCapture.swift
//  leanring-buddy
//
//  What a lesson's drawing becomes on a notebook page.
//
//  Cards are kept as SVG. The engine draws them as SVG already (rough.js
//  shapes and perfect-freehand strokes are paths, words are text), so
//  notebook-snapshot.js copies them out of the drawing board as vectors: a
//  card prints sharp at any size, its words stay text in the PDF, and it is
//  a few tens of kilobytes. A screenshot of the card would be blurry when
//  printed large and several times the size.
//
//  The screen is different: it is the screen the question was asked over,
//  so it can only be an image. Only the part the marks were on is kept,
//  with a margin, as a JPEG with the marks drawn into it. It is cut from the
//  display's own pixels, captured beside the model's screenshot when the
//  question was asked (the screen is never captured again for the
//  notebook). The model's screenshot is only 1280 pixels across, under half
//  a Retina display's pixels, so a crop of it was shown on the page at
//  about one and a half times its size and code in it came out soft. It is
//  still the fallback when the full capture is missing.
//
//  The screenshot is drawn into the crop directly, never through WebKit,
//  so its pixels are copied or scaled down once and never resampled twice.
//  Only the marks are drawn by WebKit (the same renderer as on screen, glow
//  included), on a clear page in a web view that never joins a window, and
//  laid over it.
//

import AppKit
import ImageIO
import WebKit

/// The drawing board as notebook-snapshot.js reported it.
struct NotebookDrawingSnapshot {
    struct Card {
        let svgText: String
        let widthInPixels: Double
        let heightInPixels: Double
        let title: String?
    }

    struct ScreenMarks {
        let svgText: String
        /// The marked part of the screen, in the screenshot's pixels.
        let regionInCanvasPixels: CGRect
    }

    let cards: [Card]
    let screenMarks: ScreenMarks?
    /// Teaching board hook: the whole board, when one was open.
    var board: Card? = nil

    /// The script that reads the board, bundled beside the drawing engine.
    static var snapshotScript: String? {
        guard let url = Bundle.main.url(forResource: "notebook-snapshot", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func parse(json: String) -> NotebookDrawingSnapshot? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let cards: [Card] = (object["cards"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let svgText = entry["svg"] as? String,
                  let width = (entry["width"] as? NSNumber)?.doubleValue,
                  let height = (entry["height"] as? NSNumber)?.doubleValue,
                  width > 0, height > 0 else { return nil }
            let title = (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Card(svgText: svgText, widthInPixels: width, heightInPixels: height, title: title)
        }
        var screenMarks: ScreenMarks?
        if let marks = object["marks"] as? [String: Any],
           let svgText = marks["svg"] as? String,
           let region = marks["region"] as? [NSNumber], region.count == 4 {
            screenMarks = ScreenMarks(
                svgText: svgText,
                regionInCanvasPixels: CGRect(x: region[0].doubleValue, y: region[1].doubleValue,
                                             width: region[2].doubleValue, height: region[3].doubleValue)
            )
        }
        var board: Card?
        if let boardEntry = object["board"] as? [String: Any], let svgText = boardEntry["svg"] as? String,
           let width = (boardEntry["width"] as? NSNumber)?.doubleValue,
           let height = (boardEntry["height"] as? NSNumber)?.doubleValue, width > 0, height > 0 {
            board = Card(svgText: svgText, widthInPixels: width, heightInPixels: height, title: nil)
        }
        return NotebookDrawingSnapshot(cards: cards, screenMarks: screenMarks, board: board)
    }
}

/// Cuts the marked region out of the screen the question was asked over and
/// draws the marks into it.
@MainActor
final class NotebookScreenCropMaker: NSObject {
    /// The window shows the crop at most about 410 points wide and the PDF
    /// about 280, so 1600 pixels keeps two pixels to a point on a Retina
    /// display even for a tall crop. The smallest region the marks get (520
    /// by 300 of the model's pixels, about 1230 by 710 of a MacBook's) stays
    /// at the display's own pixels.
    static let longestSideInPixels = 1600
    static let jpegCompressionFactor = 0.8

    struct Crop {
        let jpegData: Data
        let widthInPixels: Int
        let heightInPixels: Int
    }

    private var webView: WKWebView?
    private var pageLoadContinuation: CheckedContinuation<Void, Never>?

    /// `fullResolutionScreenshot` is the display at its own pixels, captured
    /// with the model's screenshot. Without it the crop is cut from
    /// `screenshotJPEGData`, the model's screenshot, as before.
    func makeCrop(screenshotJPEGData: Data, fullResolutionScreenshot: CGImage?, canvasSize: CGSize,
                  screenMarks: NotebookDrawingSnapshot.ScreenMarks) async -> Crop? {
        guard canvasSize.width > 0,
              let screenshot = fullResolutionScreenshot ?? Self.decodedImage(fromJPEGData: screenshotJPEGData)
        else { return nil }

        // The marks are placed in the canvas's pixels (the model's
        // screenshot); the full capture is the same screen at more pixels.
        let pixelsPerCanvasPixel = Double(screenshot.width) / canvasSize.width
        let region = screenMarks.regionInCanvasPixels
        let cropRectangle = CGRect(
            x: region.minX * pixelsPerCanvasPixel, y: region.minY * pixelsPerCanvasPixel,
            width: region.width * pixelsPerCanvasPixel, height: region.height * pixelsPerCanvasPixel
        ).integral.intersection(CGRect(x: 0, y: 0, width: screenshot.width, height: screenshot.height))
        guard cropRectangle.width >= 8, cropRectangle.height >= 8,
              let croppedScreenshot = screenshot.cropping(to: cropRectangle) else { return nil }

        let downscale = min(1, Double(Self.longestSideInPixels) / max(cropRectangle.width, cropRectangle.height))
        let outputWidth = max(1, Int((cropRectangle.width * downscale).rounded()))
        let outputHeight = max(1, Int((cropRectangle.height * downscale).rounded()))

        // Drawn in the screenshot's own colour space, so the page shows the
        // colours the screen did.
        let screenshotColorSpace = croppedScreenshot.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        guard let colorSpace = screenshotColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let outputRectangle = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        context.interpolationQuality = .high
        context.draw(croppedScreenshot, in: outputRectangle)

        guard let marksImage = await renderMarks(svgText: screenMarks.svgText,
                                                 widthInPixels: outputWidth, heightInPixels: outputHeight)
        else { return nil }
        context.draw(marksImage, in: outputRectangle)

        guard let croppedImageWithMarks = context.makeImage(),
              let jpegData = NSBitmapImageRep(cgImage: croppedImageWithMarks).representation(
                using: .jpeg, properties: [.compressionFactor: Self.jpegCompressionFactor])
        else { return nil }
        return Crop(jpegData: jpegData, widthInPixels: outputWidth, heightInPixels: outputHeight)
    }

    private static func decodedImage(fromJPEGData jpegData: Data) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }

    /// The marks alone, on a page that is clear wherever nothing is drawn.
    /// The page is laid out one CSS pixel to each pixel of the crop and the
    /// snapshot comes back at the screen's scale, so on a Retina Mac the
    /// marks are drawn at twice the crop's pixels and scaled down onto it,
    /// which smooths their edges.
    private func renderMarks(svgText: String, widthInPixels: Int, heightInPixels: Int) async -> CGImage? {
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}
        img{position:absolute;left:0;top:0;width:\(widthInPixels)px;height:\(heightInPixels)px}</style></head>
        <body><img src="data:image/svg+xml;base64,\(Data(svgText.utf8).base64EncodedString())"></body></html>
        """

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // The marks are shown as an image, which runs nothing; the page
        // itself needs no scripts either.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: widthInPixels, height: heightInPixels), configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        self.webView = webView
        defer { self.webView = nil }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pageLoadContinuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        // Decoding the image can trail the load event by a frame.
        try? await Task.sleep(nanoseconds: 150_000_000)

        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.rect = CGRect(x: 0, y: 0, width: widthInPixels, height: heightInPixels)
        guard let renderedImage = try? await webView.takeSnapshot(configuration: snapshotConfiguration) else { return nil }
        return renderedImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

extension NotebookScreenCropMaker: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoadContinuation?.resume()
        pageLoadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageLoadContinuation?.resume()
        pageLoadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageLoadContinuation?.resume()
        pageLoadContinuation = nil
    }

    /// A page whose process died reports neither a finish nor a failure.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageLoadContinuation?.resume()
        pageLoadContinuation = nil
    }
}
