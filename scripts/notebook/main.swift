// Renders a sample notebook offline, so the pages and the PDF can be
// looked at without running Buddy, capturing the screen or drawing on it.
//
// Each fixture lesson is drawn by the real drawing engine in a web view that
// never joins a window, over a made-up screenshot of a code editor. The
// board is read back by the shipped notebook-snapshot.js, the screen crop is
// made by the shipped NotebookScreenCropMaker, pages are written by
// NotebookStore into a sample notebook folder, and NotebookPDFExporter turns
// them into PDFs (A4 and US Letter). Every PDF page, and the Notebook
// window's view of each day, is then rendered to PNG for inspection.
//
// Usage: see README.md beside this file.

import AppKit
import PDFKit
import WebKit

let repositoryFolder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let outputFolder = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : repositoryFolder.appendingPathComponent("build/notebook-sample").path)
let sourceFolder = repositoryFolder.appendingPathComponent("leanring-buddy")

func sourceText(_ relativePath: String) -> String {
    guard let text = try? String(contentsOf: sourceFolder.appendingPathComponent(relativePath), encoding: .utf8) else {
        fatalError("missing \(relativePath); pass the repository folder as the first argument")
    }
    return text
}

// MARK: - Fixtures

struct FixtureLesson {
    let createdAt: Date
    let question: String
    let program: String?
    let proseAnswer: String?
    let targets: [String: [Double]]
    let editorLines: [String]
    let ideas: [NotebookPage.Idea]
}

func date(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

func idea(_ name: String, _ summary: String, stabilityDays: Double, explainedAt: Date) -> NotebookPage.Idea {
    NotebookPage.Idea(name: name, summary: summary, stabilityDays: stabilityDays,
                      reviewAround: explainedAt.addingTimeInterval(stabilityDays * 86_400))
}

// Screen targets sit on the made-up editor's lines: line n is at y = 60 + 34n.
func lineTarget(_ line: Int, x: Double = 96, width: Double) -> [Double] { [x, 60 + Double(line) * 34, width, 28] }

let binarySearchLines = [
    "def binary_search(items, target):",
    "    low, high = 0, len(items) - 1",
    "    while low <= high:",
    "        middle = (low + high) // 2",
    "        if items[middle] == target:",
    "            return middle",
    "        if items[middle] < target:",
    "            low = middle + 1",
    "        else:",
    "            high = middle - 1",
    "    return -1",
]

let hashingLines = [
    "class HashRing:",
    "    def __init__(self, nodes, replicas=100):",
    "        self.ring = SortedDict()",
    "        for node in nodes:",
    "            for replica in range(replicas):",
    "                key = hash(f\"{node}:{replica}\")",
    "                self.ring[key] = node",
    "",
    "    def node_for(self, item):",
    "        key = hash(item)",
    "        index = self.ring.bisect_left(key) % len(self.ring)",
    "        return self.ring.peekitem(index)[1]",
]

let tableLines = [
    "def longest_common_subsequence(a, b):",
    "    table = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]",
    "    for i in range(1, len(a) + 1):",
    "        for j in range(1, len(b) + 1):",
    "            if a[i - 1] == b[j - 1]:",
    "                table[i][j] = table[i - 1][j - 1] + 1",
    "            else:",
    "                table[i][j] = max(table[i - 1][j], table[i][j - 1])",
    "    return table[len(a)][len(b)]",
]

let fixtures: [FixtureLesson] = [
    FixtureLesson(
        createdAt: date("2026-11-03 10:14"),
        question: "why does binary search only need log n steps",
        program: #"""
        lessonTitle("Binary search halves the range");
        step(1);
        say("Each comparison throws away half of what is left, so a million items take about twenty looks.");
        ring("L3");
        const card = paper(820, 120, 560, 470, {title: "Halving", heading: "Binary search", subtitle: "keep the half that can hold the target"});
        const values = [2, 5, 8, 12, 16, 23, 38, 56];
        for (const position of range(8)) rect(card.x + position * 62, card.y + 20, 56, 48, {label: String(values[position]), fill: position === 3 ? "butter" : undefined});
        step(2);
        say("Here the middle is twelve, and the target is bigger, so everything on the left is gone in one step.");
        arrow([[card.x + 3 * 62 + 28, card.y + 140], [card.x + 3 * 62 + 28, card.y + 76]], {label: "middle"});
        rect(card.x, card.y + 170, 4 * 62 - 6, 48, {fill: "grey", fillAlpha: 0.18, dashed: true});
        text(card.x + 4, card.y + 250, "discarded", {size: 16, tone: "grey"});
        underline("L4");
        step(3);
        say("Halving twenty times gets from a million to one, which is why the cost grows with the logarithm.");
        text(card.x, card.y + 300, "1,000,000 -> 500,000 -> ... -> 1", {size: 20});
        text(card.x, card.y + 336, "about 20 halvings = log2(n)", {size: 20, tone: "blue"});
        """#,
        proseAnswer: nil,
        targets: ["L3": lineTarget(2, width: 260), "L4": lineTarget(3, x: 128, width: 380)],
        editorLines: binarySearchLines,
        ideas: [
            idea("binary search", "Each comparison discards half of the remaining range.", stabilityDays: 2, explainedAt: date("2026-11-03 10:14")),
            idea("logarithmic time", "Halving n down to one takes log2(n) steps.", stabilityDays: 5.4, explainedAt: date("2026-11-03 10:14")),
        ]
    ),
    FixtureLesson(
        createdAt: date("2026-11-03 11:02"),
        question: "what are the replicas for in this hash ring",
        program: #"""
        lessonTitle("virtual nodes in consistent hashing");
        step(1);
        say("Each server is placed on the ring a hundred times, so keys spread evenly instead of piling onto one server.");
        highlight("R2");
        const card = paper(780, 130, 600, 520, {title: "Hash ring", heading: "Virtual nodes", subtitle: "one server, many points on the ring"});
        circle(card.x + 200, card.y + 190, 150, {tone: "grey"});
        const colours = ["blue", "coral", "green"];
        for (const index of range(9)) {
          const angle = index / 9 * 2 * PI;
          circle(card.x + 200 + 150 * cos(angle), card.y + 190 + 150 * sin(angle), 12, {fill: colours[index % 3], tone: colours[index % 3]});
        }
        step(2);
        say("When a server leaves, only the keys next to its points move, and they move to many different servers.");
        sticky(card.x + 380, card.y + 60, "a server leaving moves only its neighbours", "butter");
        underline("R6");
        """#,
        proseAnswer: nil,
        targets: ["R2": lineTarget(1, x: 128, width: 520), "R6": lineTarget(5, x: 224, width: 470)],
        editorLines: hashingLines,
        ideas: [
            idea("consistent hashing", "Keys and servers share one ring; a key belongs to the next server clockwise.", stabilityDays: 7.9, explainedAt: date("2026-11-03 11:02")),
            idea("virtual nodes", "Each server appears many times on the ring so load spreads evenly.", stabilityDays: 2, explainedAt: date("2026-11-03 11:02")),
        ]
    ),
    FixtureLesson(
        createdAt: date("2026-11-04 09:30"),
        question: "is a hash table lookup really constant time",
        program: nil,
        proseAnswer: "On average, yes. The key is hashed straight to a bucket, so the work does not grow with the number of items. It can be slower when many keys land in the same bucket, but a good hash function and resizing keep that rare. When the table grows it is rebuilt, which costs linear time once, and spread over all the inserts that is still constant on average. So constant time is a promise about the average case, not about every single lookup.",
        targets: [:],
        editorLines: [],
        ideas: [
            idea("hash table", "A key is hashed to a bucket, so lookups do not scan the items.", stabilityDays: 12.5, explainedAt: date("2026-11-04 09:30")),
            idea("amortised cost", "An occasional expensive resize averaged over many cheap inserts.", stabilityDays: 2, explainedAt: date("2026-11-04 09:30")),
        ]
    ),
    FixtureLesson(
        createdAt: date("2026-11-04 15:45"),
        question: "walk me through how this table gets filled in",
        program: #"""
        lessonTitle("Filling the longest common subsequence table");
        step(1);
        say("Every cell answers a smaller question: how long a common subsequence the first i letters of one word share with the first j of the other.");
        say("The table has one extra row and column of zeros, because an empty prefix shares nothing.");
        spotlight("T2");
        const card = paper(640, 110, 740, 760, {title: "LCS table", heading: "ABCBDAB against BDCABA", subtitle: "fill row by row, left to right"});
        const columnLetters = "BDCABA", rowLetters = "ABCBDAB";
        for (const j of range(6)) text(card.x + 90 + j * 52 + 18, card.y + 18, columnLetters[j], {size: 20, bold: true});
        for (const i of range(7)) text(card.x + 30, card.y + 76 + i * 52, rowLetters[i], {size: 20, bold: true});
        const values = [[0,0,0,1,1,1],[1,1,1,1,2,2],[1,1,2,2,2,2],[1,1,2,2,3,3],[1,2,2,2,3,3],[1,2,2,3,3,4],[1,2,2,3,4,4]];
        for (const i of range(7)) for (const j of range(6)) rect(card.x + 90 + j * 52, card.y + 40 + i * 52, 48, 46, {label: String(values[i][j]), fill: values[i][j] === 4 ? "mint" : undefined});
        step(2);
        say("When the letters match, the cell is one more than the cell diagonally up and to the left.");
        say("That is the line that adds one: both words lose their last letter and the answer grows by it.");
        say("The diagonal arrows in the table show every place this happened.");
        frame("T6");
        arrow([[card.x + 90 + 2 * 52 + 10, card.y + 40 + 1 * 52 + 10], [card.x + 90 + 2 * 52 + 30, card.y + 40 + 2 * 52 + 20]], {tone: "green"});
        step(3);
        say("When they do not match, the cell takes the larger of the cell above and the cell to the left.");
        say("Dropping a letter from either word can only keep or lose matches, never add one, so the best of the two is the answer.");
        say("This is why the table only ever looks up, left, or up and left, never ahead.");
        say("Filling it row by row means the cells it needs are always already filled.");
        underline("T8");
        step(4);
        say("The bottom right cell holds the answer for the whole words, which is four here.");
        say("Walking back from that cell along the matches spells out one longest subsequence, such as BCBA.");
        say("The table has one cell for every pair of prefixes, so the time and the memory both grow with the product of the lengths.");
        text(card.x + 90, card.y + 440, "answer: 4 (BCBA)", {size: 22, tone: "green", bold: true});
        text(card.x + 90, card.y + 480, "time and memory: O(n * m)", {size: 20});
        text(card.x + 90, card.y + 520, "only the previous row is needed for the length", {size: 18, tone: "grey"});
        text(card.x + 90, card.y + 560, "so memory can drop to O(m)", {size: 18, tone: "grey"});
        step(5);
        say("If only the length is needed, two rows are enough, because each row is built from the one above it.");
        say("Keeping the whole table is only worth it when the subsequence itself has to be read back out.");
        say("That trade between memory and being able to reconstruct the answer comes up in almost every table like this one.");
        step(6);
        say("A good way to check the idea is to fill the first two rows by hand and compare them with the table.");
        say("If the numbers agree, the rule for matches and mismatches has landed.");
        """#,
        proseAnswer: nil,
        targets: ["T2": lineTarget(1, x: 128, width: 600), "T6": lineTarget(5, x: 192, width: 520), "T8": lineTarget(7, x: 192, width: 700)],
        editorLines: tableLines,
        ideas: [
            idea("dynamic programming", "Build answers to small subproblems first and reuse them.", stabilityDays: 3.1, explainedAt: date("2026-11-04 15:45")),
            idea("longest common subsequence", "A cell is one more than its diagonal on a match, else the larger neighbour.", stabilityDays: 2, explainedAt: date("2026-11-04 15:45")),
            idea("space optimisation", "Only the previous row is needed when the length alone is wanted.", stabilityDays: 2, explainedAt: date("2026-11-04 15:45")),
        ]
    ),
]

// MARK: - A made-up screenshot

/// A dark code editor with the lines given on a 1440x900 point display, so
/// screen marks land on readable code the way they do on a real screen.
/// At one pixel a point it is the model's screenshot, the canvas; at two it
/// is the display's own pixels, which the crop is cut from.
func editorScreenshot(lines: [String], pixelsPerPoint: Int) -> CGImage {
    let width = 1440, height = 900
    let context = CGContext(data: nil, width: width * pixelsPerPoint, height: height * pixelsPerPoint,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height * pixelsPerPoint))
    context.scaleBy(x: CGFloat(pixelsPerPoint), y: -CGFloat(pixelsPerPoint))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.2, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: 36).fill()
    ("editor.py  -  Visual Studio Code" as NSString).draw(at: NSPoint(x: 600, y: 9), withAttributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(white: 0.7, alpha: 1)])
    let codeAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 19, weight: .regular),
        .foregroundColor: NSColor(calibratedRed: 0.86, green: 0.88, blue: 0.92, alpha: 1)]
    let numberAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
        .foregroundColor: NSColor(white: 0.42, alpha: 1)]
    for (lineIndex, line) in lines.enumerated() {
        let top = 60 + Double(lineIndex) * 34
        ("\(lineIndex + 1)" as NSString).draw(at: NSPoint(x: 36, y: top + 4), withAttributes: numberAttributes)
        (line as NSString).draw(at: NSPoint(x: 96, y: top + 2), withAttributes: codeAttributes)
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

func editorScreenshotJPEG(lines: [String]) -> Data {
    NSBitmapImageRep(cgImage: editorScreenshot(lines: lines, pixelsPerPoint: 1))
        .representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
}

// MARK: - Running the engine without a window

@MainActor
final class HeadlessDrawingBoard: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var loaded: CheckedContinuation<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func load() async {
        let scripts = ["draw-vendor-rough", "draw-vendor-freehand", "draw-engine"]
            .map { "<script>\n\(sourceText("Drawing/DrawingEngine/\($0).js"))\n</script>" }
            .joined(separator: "\n")
        let html = sourceText("Drawing/DrawingEngine/draw-page.html").replacingOccurrences(of: "<!--SCRIPTS-->", with: scripts)
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    /// Draws a program the way a lesson does (setup, run), without playing
    /// it: the snapshot writes every reveal out finished either way.
    func draw(program: String, targets: [String: [Double]]) async -> NotebookDrawingSnapshot? {
        let options: [String: Any] = ["canvasWidth": 1440, "canvasHeight": 900, "targets": targets,
                                      "targetLabels": [String: String](), "screenInk": "#3380FF", "unitsPerPoint": 1]
        let optionsJSON = String(data: try! JSONSerialization.data(withJSONObject: options), encoding: .utf8)!
        _ = try? await webView.evaluateJavaScript("BuddyEngine.clearAll(); BuddyEngine.setup(\(optionsJSON));")
        let result = try? await webView.callAsyncJavaScript("return JSON.stringify(BuddyEngine.run(code));",
                                                            arguments: ["code": program], contentWorld: .page)
        print("   engine: \(result as? String ?? "no result")".prefix(220))
        guard let snapshotJSON = try? await webView.evaluateJavaScript(
            sourceText("Notebook/notebook-snapshot.js"), in: nil, contentWorld: .defaultClient) as? String else { return nil }
        return NotebookDrawingSnapshot.parse(json: snapshotJSON)
    }
}

/// Shows a day's newest page the way the Notebook window does, and snapshots it.
@MainActor
final class DayViewRenderer: NSObject, WKNavigationDelegate {
    private var loaded: CheckedContinuation<Void, Never>?

    func render(day: NotebookDay, rootFolder: URL, to file: URL) async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(NotebookFileSchemeHandler(rootFolder: rootFolder), forURLScheme: NotebookDocumentHTML.fileScheme)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 860, height: 3600), configuration: configuration)
        webView.navigationDelegate = self
        await withCheckedContinuation { continuation in
            loaded = continuation
            let pageHTML = day.pages.last.map { newestPage in
                NotebookDocumentHTML.windowPageHTML(storedPage: newestPage, pageNumber: day.pages.count,
                                                    pageCount: day.pages.count, dayName: "today", canReplay: false)
            } ?? "<!doctype html><html><body></body></html>"
            webView.loadHTMLString(pageHTML, baseURL: URL(string: "\(NotebookDocumentHTML.fileScheme)://notes/"))
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        let contentHeight = (try? await webView.evaluateJavaScript("document.documentElement.scrollHeight") as? NSNumber)?.doubleValue
        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.rect = CGRect(x: 0, y: 0, width: 860, height: min(3600, contentHeight ?? 3600))
        if let image = try? await webView.takeSnapshot(configuration: snapshotConfiguration),
           let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: file)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }
}

/// Every page of a PDF as a PNG, at twice its size in points.
func renderPDFPages(_ pdfURL: URL, to folder: URL, prefix: String) -> [URL] {
    guard let document = PDFDocument(url: pdfURL) else { return [] }
    var written: [URL] = []
    for pageIndex in 0..<document.pageCount {
        guard let page = document.page(at: pageIndex) else { continue }
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        let file = folder.appendingPathComponent(String(format: "%@-page-%02d.png", prefix, pageIndex + 1))
        if let image = context.makeImage(),
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: file)
            written.append(file)
        }
    }
    return written
}

// MARK: - Checks

var failedCheckCount = 0

func check(_ name: String, _ passed: Bool) {
    print("   \(passed ? "pass" : "FAIL"): \(name)")
    if !passed { failedCheckCount += 1 }
}

/// What the sample pages cannot show by looking at them: the snapshot
/// cleaning, the text parsing, and deleting.
@MainActor
func runChecks(board: HeadlessDrawingBoard, sampleStore: NotebookStore) async {
    print("checks:")

    // A program is model-written code and could put anything into a card.
    let hostileProgram = #"""
    say("A card with things in it that are not drawings.");
    const card = paper(700, 140, 400, 300, {title: "Card"});
    const svgNamespace = "http://www.w3.org/2000/svg";
    const content = document.querySelector("#card-layer g.card").children[1].firstElementChild;
    const script = document.createElementNS(svgNamespace, "script"); script.textContent = "alert(1)"; content.appendChild(script);
    const outside = document.createElementNS(svgNamespace, "image"); outside.setAttribute("href", "https://example.com/track.png"); content.appendChild(outside);
    const foreign = document.createElementNS(svgNamespace, "foreignObject"); content.appendChild(foreign);
    const handler = document.createElementNS(svgNamespace, "rect"); handler.setAttribute("onclick", "alert(2)"); handler.setAttribute("width", 10); handler.setAttribute("height", 10); handler.setAttribute("x", 720); handler.setAttribute("y", 200); content.appendChild(handler);
    const link = document.createElementNS(svgNamespace, "a"); link.setAttribute("href", "https://example.com"); content.appendChild(link);
    rect(card.x, card.y, 80, 40, {label: "kept"});
    """#
    let hostileSnapshot = await board.draw(program: hostileProgram, targets: [:])
    let hostileSVG = hostileSnapshot?.cards.first?.svgText ?? ""
    check("a card is exported", !hostileSVG.isEmpty)
    check("scripts are removed", !hostileSVG.contains("<script"))
    check("external images are removed", !hostileSVG.contains("example.com"))
    check("foreign objects are removed", !hostileSVG.contains("foreignObject"))
    check("event attributes are removed", !hostileSVG.contains("onclick"))
    check("the drawing itself is kept", hostileSVG.contains("kept"))
    check("no screen marks means no crop", hostileSnapshot?.screenMarks == nil)

    // Unplayed reveals are written out finished.
    let unplayedSVG = (await board.draw(program: #"say("x"); const card = paper(700, 140, 400, 300, {}); text(card.x, card.y + 40, "written words");"#, targets: [:]))?.cards.first?.svgText ?? ""
    check("words are not left behind their writing clip", !unplayedSVG.contains("write-clip"))
    check("nothing is left hidden", !unplayedSVG.contains("visibility"))

    let paragraphs = NotebookText.paragraphs(inProgram: #"step(1); say("She said \"no\" twice."); say("Then left."); step(2); say("It’s fine.");"#)
    check("one paragraph per beat", paragraphs.count == 2)
    check("escaped quotes are unescaped", paragraphs.first == "She said \"no\" twice. Then left.")
    check("unicode escapes are unescaped", paragraphs.last == "It\u{2019}s fine.")
    check("without beats, three sentences a paragraph",
          NotebookText.paragraphs(inProgram: #"say("One."); say("Two."); say("Three."); say("Four.");"#).count == 2)

    // Titles read as titles: the first letter a capital, nothing else changed.
    check("a lower case name gets a capital", LessonTitle.displayed("what return does") == "What return does")
    check("the rest of a name is kept as given",
          LessonTitle.displayed("binary search over TCP logs") == "Binary search over TCP logs")
    check("a name starting with an acronym is unchanged", LessonTitle.displayed("TCP handshake") == "TCP handshake")
    check("a name like iPhone is left as written", LessonTitle.displayed("iPhone backups") == "iPhone backups")
    check("a short question is the whole title",
          LessonTitle.fromQuestion("what does len do in one sentence?") == "What does len do in one sentence?")
    let longQuestion = "give me a quick recap of binary search in about thirty seconds, with a different example from last time"
    let longQuestionTitle = LessonTitle.fromQuestion(longQuestion)
    let longQuestionTitleWords = String(longQuestionTitle.dropLast())
    let wordAfterTheCut = longQuestion.dropFirst(longQuestionTitleWords.count).first
    check("a long question is shortened with an ellipsis",
          longQuestionTitle.hasSuffix("\u{2026}") && longQuestionTitle.count <= LessonTitle.longestQuestionTitleInCharacters)
    check("a long question is cut between words",
          longQuestion.lowercased().hasPrefix(longQuestionTitleWords.lowercased())
              && (wordAfterTheCut == " " || wordAfterTheCut == ","))
    func samplePage(lessonTitle: String?, question: String) -> NotebookStoredPage {
        let page = NotebookPage(id: UUID(), createdAt: date("2026-11-05 12:18"), lessonTitle: lessonTitle, question: question,
                                paragraphs: ["Said."], cards: [], screenCrop: nil, ideas: [], answeredBy: nil)
        return NotebookStoredPage(page: page, folder: URL(fileURLWithPath: "/tmp/2026-11-05/121800-sample"),
                                  sizeInBytes: 0, dayIdentifier: "2026-11-05")
    }
    let namedPage = samplePage(lessonTitle: "why high starts at length minus one", question: "why does this crash when I search for 10?")
    let unnamedPage = samplePage(lessonTitle: nil, question: "Why does high")
    let questionlessPage = samplePage(lessonTitle: "what while does", question: "")
    func windowHTML(_ storedPage: NotebookStoredPage) -> String {
        NotebookDocumentHTML.windowPageHTML(storedPage: storedPage, pageNumber: 1, pageCount: 1, dayName: "today", canReplay: false)
    }
    let printHTML = NotebookDocumentHTML.printDocumentHTML(pages: [namedPage, unnamedPage], rangeDescription: "today",
                                                           paperSize: .a4, generatedAt: Date())
    check("a page's title is capitalized in the window", windowHTML(namedPage).contains("<h1>Why high starts at length minus one</h1>"))
    check("a page's title is capitalized in the PDF",
          printHTML.contains("1. Why high starts at length minus one</span>")
              && printHTML.contains("<h2 class=\"lesson-title\">Why high starts at length minus one</h2>"))
    check("a named page says what was asked", windowHTML(namedPage).contains("You asked: \u{201C}why does this crash when I search for 10?\u{201D}"))
    check("a page without a name says what was asked too", windowHTML(unnamedPage).contains("You asked: \u{201C}Why does high\u{201D}")
              && printHTML.contains("<span class=\"question-label\">You asked</span> \u{201C}Why does high\u{201D}"))
    check("a page kept without a question has no question line", !windowHTML(questionlessPage).contains("You asked"))

    check("US Letter in the United States", NotebookPaperSize.forRegion("US") == .usLetter)
    check("A4 in the United Kingdom", NotebookPaperSize.forRegion("GB") == .a4)
    check("A4 with no region", NotebookPaperSize.forRegion(nil) == .a4)

    // Deleting, on a copy of the sample notebook.
    let copyFolder = sampleStore.rootFolder.deletingLastPathComponent().appendingPathComponent("Notebook-delete-check")
    try? FileManager.default.removeItem(at: copyFolder)
    try? FileManager.default.copyItem(at: sampleStore.rootFolder, to: copyFolder)
    let copyStore = NotebookStore(rootFolder: copyFolder)
    var days = await copyStore.loadDays()
    let pagesBefore = days.reduce(0) { $0 + $1.pages.count }
    if let firstPage = days.first?.pages.first {
        await copyStore.updateIdeas([], ofPageIn: firstPage.folder)
        days = await copyStore.loadDays()
        check("ideas can be updated after writing", days.first?.pages.first?.page.ideas.isEmpty == true)
        await copyStore.deletePage(firstPage)
    }
    days = await copyStore.loadDays()
    check("a page is deleted", days.reduce(0) { $0 + $1.pages.count } == pagesBefore - 1)
    if let lastDay = days.last {
        await copyStore.deleteDay(lastDay.id)
        check("a day is deleted", !FileManager.default.fileExists(atPath: copyFolder.appendingPathComponent(lastDay.id).path))
    }
    // A folder left by a write that never finished is not a page.
    let unfinished = copyFolder.appendingPathComponent("2026-11-04/120000-unfinished")
    try? FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
    try? Data("<svg/>".utf8).write(to: unfinished.appendingPathComponent("card-1.svg"))
    days = await copyStore.loadDays()
    check("an unfinished page is not shown", !days.flatMap(\.pages).contains { $0.folder.lastPathComponent == "120000-unfinished" })
    await copyStore.deleteEverything()
    check("delete all notes removes the folder", !FileManager.default.fileExists(atPath: copyFolder.path))
    print("checks: \(failedCheckCount == 0 ? "all passed" : "\(failedCheckCount) failed")")
}

// MARK: - The run

@MainActor
func run() async {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: outputFolder)
    let notebookFolder = outputFolder.appendingPathComponent("Notebook")
    let imagesFolder = outputFolder.appendingPathComponent("png")
    try? fileManager.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
    let store = NotebookStore(rootFolder: notebookFolder)

    let board = HeadlessDrawingBoard()
    await board.load()
    let cropMaker = NotebookScreenCropMaker()

    for fixture in fixtures {
        print("lesson: \(fixture.question)")
        var cards: [NotebookPage.Card] = []
        var cardTexts: [String] = []
        var crop: NotebookScreenCropMaker.Crop?
        var lessonTitle: String?
        var paragraphs: [String]
        if let program = fixture.program {
            paragraphs = NotebookText.paragraphs(inProgram: program)
            if let titleMatch = program.range(of: #"lessonTitle\("([^"]*)"\)"#, options: .regularExpression) {
                lessonTitle = String(program[titleMatch]).replacingOccurrences(of: "lessonTitle(\"", with: "").replacingOccurrences(of: "\")", with: "")
            }
            if let snapshot = await board.draw(program: program, targets: fixture.targets) {
                for (cardIndex, card) in snapshot.cards.enumerated() {
                    cards.append(NotebookPage.Card(fileName: "card-\(cardIndex + 1).svg", widthInPixels: card.widthInPixels,
                                                   heightInPixels: card.heightInPixels, title: card.title))
                    cardTexts.append(card.svgText)
                }
                if let marks = snapshot.screenMarks {
                    crop = await cropMaker.makeCrop(screenshotJPEGData: editorScreenshotJPEG(lines: fixture.editorLines),
                                                    fullResolutionScreenshot: editorScreenshot(lines: fixture.editorLines, pixelsPerPoint: 2),
                                                    canvasSize: CGSize(width: 1440, height: 900), screenMarks: marks)
                    let displayPixelsAcross = min(Double(NotebookScreenCropMaker.longestSideInPixels),
                                                  2 * max(marks.regionInCanvasPixels.width, marks.regionInCanvasPixels.height))
                    check("the crop is cut from the display's own pixels",
                          Double(max(crop?.widthInPixels ?? 0, crop?.heightInPixels ?? 0)) >= displayPixelsAcross - 2)
                }
            }
        } else {
            paragraphs = NotebookText.paragraphs(inProse: fixture.proseAnswer ?? "")
        }
        let page = NotebookPage(
            id: UUID(), createdAt: fixture.createdAt, lessonTitle: lessonTitle, question: fixture.question,
            paragraphs: paragraphs, cards: cards,
            screenCrop: crop.map { NotebookPage.ScreenCrop(fileName: "screen.jpg", widthInPixels: $0.widthInPixels, heightInPixels: $0.heightInPixels) },
            ideas: fixture.ideas, answeredBy: "Sonnet")
        do {
            let stored = try await store.write(page: page, cardSVGTexts: cardTexts, screenCropJPEGData: crop?.jpegData)
            let cardBytes = cardTexts.map { $0.utf8.count }
            print("   page: \(stored.sizeInBytes) bytes (cards \(cardBytes), screen \(crop?.jpegData.count ?? 0), \(crop.map { "\($0.widthInPixels)x\($0.heightInPixels)" } ?? "none"))")
        } catch {
            print("   write failed: \(error)")
        }
    }

    let days = await store.loadDays()
    let allPages = days.reversed().flatMap(\.pages)
    print("notebook: \(days.count) days, \(allPages.count) pages, \(days.reduce(0) { $0 + $1.sizeInBytes }) bytes")

    for day in days {
        let file = imagesFolder.appendingPathComponent("window-\(day.id).png")
        await DayViewRenderer().render(day: day, rootFolder: notebookFolder, to: file)
        print("window view: \(file.path)")
    }

    await runChecks(board: board, sampleStore: store)

    let exporter = NotebookPDFExporter()
    let exports: [(name: String, pages: [NotebookStoredPage], range: String, paper: NotebookPaperSize)] = [
        ("all-a4", allPages, "3 to 4 November 2026", .a4),
        ("day-letter", days.first?.pages ?? [], NotebookDocumentHTML.lessonDateText(days.first?.date ?? Date()), .usLetter),
    ]
    for export in exports {
        let pdfURL = outputFolder.appendingPathComponent("\(export.name).pdf")
        do {
            let result = try await exporter.export(NotebookPDFExporter.Request(
                pages: export.pages, rangeDescription: export.range, destinationURL: pdfURL,
                paperSize: export.paper, notebookRootFolder: notebookFolder))
            let mediaBox = PDFDocument(url: pdfURL)?.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
            print("pdf: \(pdfURL.path), \(result.pageCount) pages, page size \(mediaBox.width)x\(mediaBox.height) pt")
            for image in renderPDFPages(pdfURL, to: imagesFolder, prefix: export.name) { print("   \(image.path)") }
        } catch {
            print("pdf failed: \(error.localizedDescription)")
        }
    }
    exit(0)
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
Task { @MainActor in await run() }
application.run()
