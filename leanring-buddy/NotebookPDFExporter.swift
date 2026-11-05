//
//  NotebookPDFExporter.swift
//  leanring-buddy
//
//  Turns notebook pages into a PDF: a cover with the range and number of
//  lessons, a contents page, then one lesson per page with page numbers, on
//  A4 or US Letter as the student's region prints.
//
//  Why an HTML page printed by WebKit rather than drawing with PDFKit or
//  Core Graphics. The cards are SVG drawn by WebKit in the first place; any
//  other renderer would need its own SVG support and would draw them a
//  little differently (fonts, rough.js fills, masks). WebKit's createPDF
//  keeps text as text and paths as paths, so the cards stay sharp at any
//  zoom and the words can be searched and copied. HTML also gives real
//  typography (wrapping, sentence-by-sentence page breaks, leaders in the
//  contents) for free.
//
//  createPDF on its own makes one tall page, so the document is laid out
//  into fixed sheets the size of the paper first (by a short script in the
//  page, see NotebookDocumentHTML), and each sheet is printed as its own PDF
//  page. That is also what keeps a card whole: the layout moves it to the
//  next sheet, or scales it to fit a sheet, instead of a print engine
//  cutting it wherever the page happens to end.
//
//  Everything here is asynchronous. The layout and printing happen in
//  WebKit's own process; combining the pages and writing the file run off
//  the main thread. Nothing waits on it.
//

import AppKit
import PDFKit
import WebKit

@MainActor
final class NotebookPDFExporter: NSObject {
    struct Request {
        /// Oldest first, the order they are printed in.
        let pages: [NotebookStoredPage]
        /// "Thursday 5 November 2026", or a range, shown on the cover.
        let rangeDescription: String
        let destinationURL: URL
        let paperSize: NotebookPaperSize
        let notebookRootFolder: URL
    }

    nonisolated enum ExportError: LocalizedError {
        case nothingToExport
        case pageDidNotLoad
        case layoutFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .nothingToExport: return "There are no lessons in that range."
            case .pageDidNotLoad: return "The notes could not be laid out."
            case .layoutFailed: return "The notes could not be laid out into pages."
            case .writeFailed: return "The PDF could not be saved there."
            }
        }
    }

    private var webView: WKWebView?
    private var pageLoadContinuation: CheckedContinuation<Void, Error>?

    /// Lays out and writes the PDF. Returns where it was written and how
    /// many pages it has.
    func export(_ request: Request) async throws -> (url: URL, pageCount: Int) {
        guard !request.pages.isEmpty else { throw ExportError.nothingToExport }
        let paperSize = request.paperSize
        let html = NotebookDocumentHTML.printDocumentHTML(
            pages: request.pages,
            rangeDescription: request.rangeDescription,
            paperSize: paperSize,
            generatedAt: Date()
        )

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(NotebookFileSchemeHandler(rootFolder: request.notebookRootFolder),
                                          forURLScheme: NotebookDocumentHTML.fileScheme)
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: paperSize.widthInPoints, height: paperSize.heightInPoints),
            configuration: configuration
        )
        webView.navigationDelegate = self
        self.webView = webView
        defer { self.webView = nil }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pageLoadContinuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "\(NotebookDocumentHTML.fileScheme)://notes/"))
        }

        let sheetCountValue = try await webView.callAsyncJavaScript(
            "return await window.layOutNotebook();", arguments: [:], in: nil, contentWorld: .page)
        let sheetCount = (sheetCountValue as? NSNumber)?.intValue ?? 0
        guard sheetCount > 0 else { throw ExportError.layoutFailed }

        var sheetPDFs: [Data] = []
        for sheetIndex in 0..<sheetCount {
            let pdfConfiguration = WKPDFConfiguration()
            pdfConfiguration.rect = CGRect(
                x: 0,
                y: Double(sheetIndex) * paperSize.heightInPoints,
                width: paperSize.widthInPoints,
                height: paperSize.heightInPoints
            )
            sheetPDFs.append(try await webView.pdf(configuration: pdfConfiguration))
        }

        let destinationURL = request.destinationURL
        let documentTitle = "Buddy notebook, " + request.rangeDescription
        let pageCount = try await Task.detached(priority: .utility) {
            try Self.combine(sheetPDFs: sheetPDFs, documentTitle: documentTitle, destinationURL: destinationURL)
        }.value
        return (destinationURL, pageCount)
    }

    /// One PDF out of the one-page PDFs, written atomically so a reader
    /// never opens a half-written file.
    nonisolated private static func combine(sheetPDFs: [Data], documentTitle: String, destinationURL: URL) throws -> Int {
        let combinedDocument = PDFDocument()
        for sheetPDF in sheetPDFs {
            guard let sheetDocument = PDFDocument(data: sheetPDF), let page = sheetDocument.page(at: 0) else { continue }
            combinedDocument.insert(page, at: combinedDocument.pageCount)
        }
        combinedDocument.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: documentTitle,
            PDFDocumentAttribute.creatorAttribute: "Buddy"
        ]
        guard let data = combinedDocument.dataRepresentation() else { throw ExportError.writeFailed }
        do {
            try data.write(to: destinationURL, options: .atomic)
        } catch {
            throw ExportError.writeFailed
        }
        return combinedDocument.pageCount
    }
}

extension NotebookPDFExporter: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoadContinuation?.resume()
        pageLoadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageLoadContinuation?.resume(throwing: ExportError.pageDidNotLoad)
        pageLoadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageLoadContinuation?.resume(throwing: ExportError.pageDidNotLoad)
        pageLoadContinuation = nil
    }

    /// The document is loaded once from a string; it has no links to follow.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }
}
