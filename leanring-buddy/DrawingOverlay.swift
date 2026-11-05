//
//  DrawingOverlay.swift
//  leanring-buddy
//
//  The surface the tutor draws on: a transparent, click-through window over
//  the screen holding the cursor, with a web view running the drawing engine
//  (DrawingEngine/draw-engine.js).
//
//  Why a web view. The tutor answers with a drawing program, and the program
//  is JavaScript: it can loop to draw a row of cells, compute positions from a
//  card's box, and call shapes by name. rough.js and perfect-freehand, the
//  libraries that give the hand-drawn look, are JavaScript too. Rebuilding
//  both in SwiftUI would give a weaker version of the same thing.
//
//  Why it is safe to run code the model wrote. The page loads nothing: its
//  scripts are inlined from the app bundle, its content security policy allows
//  no network, every navigation is refused below, and a content rule list
//  blocks every URL load. The only way out of the page is one message handler,
//  and the app only reads buttons, a lesson title and errors from it.
//

import AppKit
import WebKit

@MainActor
final class DrawingOverlay: NSObject {
    /// What one piece of a program produced.
    struct RunResult {
        var newLineTexts: [String] = []
        var newButtons: [TutorFollowUpButton] = []
        var lessonTitle: String?
        var errors: [String] = []
        var newMarkCount = 0
        /// Every anchor the engine holds so far: the listed items marked,
        /// for MarkFollower to keep the marks on.
        var anchorIds: [String] = []
    }

    private var panel: NSPanel?
    private var webView: WKWebView?

    /// Where the cards are on screen, in AppKit points. The overlay takes the
    /// mouse only while the pointer is over one of these; everywhere else it
    /// stays click-through so the student can keep working underneath.
    private var cardRectsOnScreen: [CGRect] = []
    private var canvasSizeForCurrentAnswer: CGSize = .zero
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var pageIsReady = false
    private var callsWaitingForPage: [() -> Void] = []
    private(set) var screenFrame: CGRect = .zero

    /// Brings the overlay up over `screen`, sized to it, with the page loaded.
    func show(on screen: NSScreen) {
        if panel == nil { buildPanel() }
        guard let panel else { return }
        if panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: true)
        }
        screenFrame = screen.frame
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Engine calls

    /// Prepares the page for a new answer drawn over a screenshot of
    /// `canvasSize` pixels. `targets` maps listing ids to boxes in the same
    /// pixels, so the program can mark a line by id.
    /// `screenMarksHidden` is for a replay over a screen that has changed:
    /// its cards are drawn, its marks on the screen's content are not.
    func beginAnswer(canvasSize: CGSize, targets: [String: [Double]], targetLabels: [String: String] = [:], screenInkHex: String,
                     screenMarksHidden: Bool = false) {
        canvasSizeForCurrentAnswer = canvasSize
        let unitsPerPoint = screenFrame.width > 0 ? canvasSize.width / screenFrame.width : 1
        let options: [String: Any] = [
            "canvasWidth": canvasSize.width,
            "canvasHeight": canvasSize.height,
            "targets": targets,
            "targetLabels": targetLabels,
            "screenInk": screenInkHex,
            "unitsPerPoint": unitsPerPoint,
            "screenMarksHidden": screenMarksHidden
        ]
        callEngine("setup", argumentsJSON: Self.json(options))
    }

    /// Runs one piece of the program and reports the sentences, buttons and
    /// errors it produced.
    func run(programPiece: String) async -> RunResult {
        await whenPageReady()
        guard let webView else { return RunResult() }
        do {
            let value = try await webView.callAsyncJavaScript(
                "return JSON.stringify(BuddyEngine.run(code));",
                arguments: ["code": programPiece],
                contentWorld: .page
            )
            guard let jsonText = value as? String,
                  let data = jsonText.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return RunResult()
            }
            var result = RunResult()
            result.newLineTexts = (object["newLines"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            result.newButtons = (object["newButtons"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let title = entry["title"] as? String else { return nil }
                return TutorFollowUpButton(
                    title: title,
                    question: entry["ask"] as? String,
                    textToCopy: entry["copy"] as? String
                )
            }
            result.lessonTitle = object["lessonTitle"] as? String
            result.errors = object["newErrors"] as? [String] ?? []
            result.newMarkCount = object["newMarks"] as? Int ?? 0
            result.anchorIds = object["anchors"] as? [String] ?? []
            return result
        } catch {
            return RunResult(errors: [error.localizedDescription])
        }
    }

    func playLine(_ lineIndex: Int, seconds: TimeInterval) {
        callEngine("playLine", argumentsJSON: "\(lineIndex), \(seconds)")
    }

    func updateLineDuration(_ lineIndex: Int, seconds: TimeInterval) {
        callEngine("updateLineDuration", argumentsJSON: "\(lineIndex), \(seconds)")
    }

    func finishLine(_ lineIndex: Int) {
        callEngine("finishLine", argumentsJSON: "\(lineIndex)")
    }

    func finishAll() {
        callEngine("finishAll", argumentsJSON: "")
    }

    func clearAll() {
        callEngine("clearAll", argumentsJSON: "")
    }

    /// Clears what marks the screen and keeps the cards, for when the content
    /// under the marks changed.
    func clearScreenMarks() {
        callEngine("clearScreenMarks", argumentsJSON: "")
    }

    /// Moves the screen marks with scrolled content. `points` is in screen
    /// points, positive meaning content moved down.
    func scrollScreenMarks(byPoints points: CGFloat) {
        guard screenFrame.height > 0 else { return }
        callEngine("scrollScreenMarks", argumentsJSON: "\(points)")
    }

    /// Moves the anchors of marked items to where those items are now.
    func placeAnchors(_ placements: [AnchorPlacement], animate: Bool) {
        let list = placements.map { placement -> [String: Any] in
            ["id": placement.id, "dx": placement.dx, "dy": placement.dy, "visible": placement.visible]
        }
        callEngine("placeAnchors", argumentsJSON: "\(Self.json(list)), \(animate)")
    }

    // MARK: - Page

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSScreen.main?.frame ?? .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above ordinary windows and menus, like the rest of the overlay, but
        // never taking a click: the student keeps working underneath.
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(WeakMessageHandler(owner: self), name: "clicky")

        let webView = FirstClickWebView(frame: panel.contentView?.bounds ?? .zero, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        panel.contentView = webView

        self.panel = panel
        self.webView = webView
        watchMouseOverCards()

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "clicky-drawing-no-network",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^(https?|wss?|file|ftp|blob):"},"action":{"type":"block"}}]"#
        ) { [weak self] ruleList, _ in
            Task { @MainActor in
                guard let self, let webView = self.webView else { return }
                if let ruleList {
                    webView.configuration.userContentController.add(ruleList)
                }
                webView.loadHTMLString(Self.pageHTML(), baseURL: nil)
            }
        }
    }

    /// The page with every script inlined, so it needs nothing from anywhere.
    private static func pageHTML() -> String {
        func bundled(_ name: String, _ fileExtension: String) -> String {
            guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                TutorDebugLog.write("⚠️ drawing engine file missing: \(name).\(fileExtension)")
                return ""
            }
            return text
        }
        let scripts = ["draw-vendor-rough", "draw-vendor-freehand", "draw-engine"]
            .map { "<script>\n\(bundled($0, "js"))\n</script>" }
            .joined(separator: "\n")
        return bundled("draw-page", "html").replacingOccurrences(of: "<!--SCRIPTS-->", with: scripts)
    }

    private func whenPageReady() async {
        if pageIsReady { return }
        await withCheckedContinuation { continuation in
            callsWaitingForPage.append { continuation.resume() }
        }
    }

    private func callEngine(_ function: String, argumentsJSON: String) {
        let call: () -> Void = { [weak self] in
            guard let webView = self?.webView else { return }
            webView.evaluateJavaScript("BuddyEngine.\(function)(\(argumentsJSON));") { _, error in
                if let error {
                    TutorDebugLog.write("⚠️ engine \(function) failed: \(error.localizedDescription)")
                }
            }
        }
        if pageIsReady { call() } else { callsWaitingForPage.append(call) }
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// The page reports where its cards are whenever one appears, grows,
    /// moves or closes.
    fileprivate func cardsDidChange(canvasRects: [[Double]]) {
        guard canvasSizeForCurrentAnswer.width > 0, screenFrame.width > 0 else { return }
        let pointsPerCanvasPixel = screenFrame.width / canvasSizeForCurrentAnswer.width
        cardRectsOnScreen = canvasRects.compactMap { rect in
            guard rect.count == 4 else { return nil }
            // Canvas is top-left origin; AppKit screen points are bottom-left.
            return CGRect(
                x: screenFrame.minX + rect[0] * pointsPerCanvasPixel,
                y: screenFrame.maxY - (rect[1] + rect[3]) * pointsPerCanvasPixel,
                width: rect[2] * pointsPerCanvasPixel,
                height: rect[3] * pointsPerCanvasPixel
            )
        }
        updateMousePassThrough()
    }

    private func watchMouseOverCards() {
        // Global for when the pointer is over other apps, local for when the
        // overlay itself has the mouse.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.updateMousePassThrough() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateMousePassThrough()
            return event
        }
    }

    private func updateMousePassThrough() {
        guard let panel else { return }
        let pointer = NSEvent.mouseLocation
        let isOverCard = cardRectsOnScreen.contains { $0.contains(pointer) }
        // While a card is being dragged the pointer can outrun it; keep the
        // mouse until the button is let go.
        let isDragging = NSEvent.pressedMouseButtons & 1 != 0 && !panel.ignoresMouseEvents
        let shouldPassThrough = !(isOverCard || isDragging)
        if panel.ignoresMouseEvents != shouldPassThrough {
            panel.ignoresMouseEvents = shouldPassThrough
        }
    }

    fileprivate func pageDidFinishLoading() {
        pageIsReady = true
        let waiting = callsWaitingForPage
        callsWaitingForPage.removeAll()
        waiting.forEach { $0() }
        TutorDebugLog.write("🖌️ drawing engine loaded")
    }
}

extension DrawingOverlay: WKNavigationDelegate {
    // The page is loaded once from a string. Anything else is the program
    // trying to go somewhere, and it is refused.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let isInitialLoad = navigationAction.request.url?.absoluteString == "about:blank"
        decisionHandler(isInitialLoad && !pageIsReady ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageDidFinishLoading()
    }
}

/// The page reports where its cards are, so the overlay knows where to take
/// the mouse. Nothing else it posts is acted on.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: DrawingOverlay?
    init(owner: DrawingOverlay) { self.owner = owner }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              body["type"] as? String == "cards",
              let rects = body["rects"] as? [[Double]] else { return }
        MainActor.assumeIsolated { owner?.cardsDidChange(canvasRects: rects) }
    }
}

/// Takes the first click even though the overlay never becomes the key
/// window, so a card's close button or title bar responds to one click
/// instead of the first click only focusing the window.
private final class FirstClickWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
