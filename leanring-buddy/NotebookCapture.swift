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
//  The screen is different: it is the screenshot the question was asked
//  over, so it can only be an image. Only the part the marks were on is
//  kept, with a margin, cut from the screenshot taken for the question (the
//  screen is never captured again for the notebook), scaled down to at most
//  960 pixels on its longest side, with the marks drawn into it, as a JPEG.
//  The marks are drawn in by WebKit (the same renderer as on screen, glow
//  included) in a web view that never joins a window.
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
        return NotebookDrawingSnapshot(cards: cards, screenMarks: screenMarks)
    }
}

/// Cuts the marked region out of the question's screenshot and draws the
/// marks into it.
@MainActor
final class NotebookScreenCropMaker: NSObject {
    static let longestSideInPixels = 960
    static let jpegCompressionFactor = 0.7

    struct Crop {
        let jpegData: Data
        let widthInPixels: Int
        let heightInPixels: Int
    }

    private var webView: WKWebView?
    private var pageLoadContinuation: CheckedContinuation<Void, Never>?

    func makeCrop(screenshotJPEGData: Data, canvasSize: CGSize, screenMarks: NotebookDrawingSnapshot.ScreenMarks) async -> Crop? {
        guard canvasSize.width > 0,
              let imageSource = CGImageSourceCreateWithData(screenshotJPEGData as CFData, nil),
              let screenshot = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }

        // The canvas is the screenshot's own pixels; scaled anyway in case a
        // caller ever hands over a screenshot of another size.
        let pixelsPerCanvasPixel = Double(screenshot.width) / canvasSize.width
        let region = screenMarks.regionInCanvasPixels
        let cropRectangle = CGRect(
            x: region.minX * pixelsPerCanvasPixel, y: region.minY * pixelsPerCanvasPixel,
            width: region.width * pixelsPerCanvasPixel, height: region.height * pixelsPerCanvasPixel
        ).integral.intersection(CGRect(x: 0, y: 0, width: screenshot.width, height: screenshot.height))
        guard cropRectangle.width >= 8, cropRectangle.height >= 8,
              let croppedScreenshot = screenshot.cropping(to: cropRectangle),
              let croppedPNGData = NSBitmapImageRep(cgImage: croppedScreenshot).representation(using: .png, properties: [:])
        else { return nil }

        let downscale = min(1, Double(Self.longestSideInPixels) / max(cropRectangle.width, cropRectangle.height))
        let outputWidth = max(1, Int((cropRectangle.width * downscale).rounded()))
        let outputHeight = max(1, Int((cropRectangle.height * downscale).rounded()))

        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;padding:0;background:#000;overflow:hidden}
        img{position:absolute;left:0;top:0;width:\(outputWidth)px;height:\(outputHeight)px}</style></head>
        <body><img src="data:image/png;base64,\(croppedPNGData.base64EncodedString())">
        <img src="data:image/svg+xml;base64,\(Data(screenMarks.svgText.utf8).base64EncodedString())"></body></html>
        """

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // The marks are shown as an image, which runs nothing; the page
        // itself needs no scripts either.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        defer { self.webView = nil }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pageLoadContinuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        // Decoding the two images can trail the load event by a frame.
        try? await Task.sleep(nanoseconds: 150_000_000)

        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.rect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        guard let renderedImage = try? await webView.takeSnapshot(configuration: snapshotConfiguration) else { return nil }
        return Self.jpeg(of: renderedImage, widthInPixels: outputWidth, heightInPixels: outputHeight)
    }

    /// Draws the snapshot (made at the screen's scale) into exactly the
    /// pixels wanted and compresses it.
    private static func jpeg(of image: NSImage, widthInPixels: Int, heightInPixels: Int) -> Crop? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: widthInPixels, pixelsHigh: heightInPixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = NSSize(width: widthInPixels, height: heightInPixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: widthInPixels, height: heightInPixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegCompressionFactor]) else { return nil }
        return Crop(jpegData: jpegData, widthInPixels: widthInPixels, heightInPixels: heightInPixels)
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
}
