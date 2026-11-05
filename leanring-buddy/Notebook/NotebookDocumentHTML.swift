//
//  NotebookDocumentHTML.swift
//  leanring-buddy
//
//  The notebook's pages as HTML, twice over: for the Notebook window (one
//  lesson as a page of paper on the window's dark background) and for the PDF
//  (cover, contents, one lesson per printed page, laid out for A4 or US
//  Letter). Both are rendered by WebKit, which is what draws the cards in
//  the first place, so a card looks the same in the notebook, in the PDF
//  and on screen.
//
//  Cards are shown with <img src="...svg">, never inlined. An SVG shown as an
//  image cannot run scripts or load anything, which matters because the
//  program that drew it was written by a model. The pages load their files
//  through NotebookFileSchemeHandler, which serves only the notebook folder.
//

import Foundation
import WebKit

enum NotebookDocumentHTML {
    static let fileScheme = "buddy-notebook"
    static let actionScheme = "buddy-notebook-action"

    static func fileURLString(for storedPage: NotebookStoredPage, fileName: String) -> String {
        let path = storedPage.relativePath(of: fileName)
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        return "\(fileScheme)://notes/\(path)"
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - Words

    static func lessonDateText(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    static func lessonTimeText(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    static func reviewDateText(_ date: Date, comparedWith now: Date = Date()) -> String {
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.weekday(.wide).day().month(.wide))
            : date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - Shared pieces

    /// A lesson's content blocks, in the order a page reads: title, date and
    /// question; the cards large; the screen smaller; what was said; the
    /// ideas; when to look again. Each block is one unit the PDF's layout
    /// keeps whole on a printed page.
    /// `screenAfterWords` puts the screen crop after what was said, which
    /// is how the PDF lays it out: the words then fill the space under the
    /// card instead of the crop being pushed to a page of its own.
    private static func lessonBlocks(_ storedPage: NotebookStoredPage, lessonNumber: Int?, screenAfterWords: Bool) -> String {
        let page = storedPage.page
        var html = ""
        var kicker = lessonDateText(page.createdAt) + " · " + lessonTimeText(page.createdAt)
        if let lessonNumber { kicker = "Lesson \(lessonNumber) · " + kicker }
        html += """
        <div class="block lesson-header">
          <div class="kicker">\(escaped(kicker))</div>
          <h2 class="lesson-title">\(escaped(page.displayTitle))</h2>
          \(page.lessonTitle != nil ? "<div class=\"question\"><span class=\"question-label\">You asked</span> \u{201C}\(escaped(page.question))\u{201D}</div>" : "")
        </div>

        """
        for card in page.cards {
            let source = fileURLString(for: storedPage, fileName: card.fileName)
            html += """
            <figure class="block card"><img src="\(source)" width="\(Int(card.widthInPixels))" height="\(Int(card.heightInPixels))" alt="\(escaped(card.title ?? "Card"))"></figure>

            """
        }
        var screenHTML = ""
        if let screenCrop = page.screenCrop {
            let source = fileURLString(for: storedPage, fileName: screenCrop.fileName)
            screenHTML = """
            <figure class="block screen"><img src="\(source)" width="\(screenCrop.widthInPixels)" height="\(screenCrop.heightInPixels)" alt="Marked part of the screen"><figcaption>Marked on your screen</figcaption></figure>

            """
        }
        if !screenAfterWords { html += screenHTML }
        if !page.paragraphs.isEmpty {
            html += "<h3 class=\"block section-heading\" data-keep-with-next=\"1\">What Buddy said</h3>\n"
            for paragraph in page.paragraphs {
                // One span per sentence, so a long paragraph can continue on
                // the next printed page between sentences.
                let sentences = NotebookText.sentences(in: paragraph)
                    .map { "<span class=\"sentence\">\(escaped($0)) </span>" }.joined()
                html += "<p class=\"block said\">\(sentences)</p>\n"
            }
        }
        if screenAfterWords { html += screenHTML }
        if !page.ideas.isEmpty {
            let labels = page.ideas.map { idea in
                "<span class=\"idea\" title=\"\(escaped(idea.summary))\">\(escaped(idea.name))</span>"
            }.joined(separator: " ")
            html += "<div class=\"block ideas\"><span class=\"ideas-label\">Ideas</span> \(labels)</div>\n"
        }
        if let reviewAgainAround = page.reviewAgainAround {
            html += "<div class=\"block review\">Review again around <strong>\(escaped(reviewDateText(reviewAgainAround)))</strong></div>\n"
        }
        return html
    }

    /// Typography and blocks common to the window and the PDF.
    private static let sharedStyles = """
    * { box-sizing: border-box; }
    body { margin: 0; -webkit-font-smoothing: antialiased; }
    .kicker { font: 600 10.5px/1.3 -apple-system, "Helvetica Neue", sans-serif; letter-spacing: 0.06em; text-transform: uppercase; color: #7A7F87; }
    .lesson-title { font: 700 23px/1.22 -apple-system, "Helvetica Neue", sans-serif; color: #1F2127; margin: 6px 0 8px; letter-spacing: -0.01em; }
    .question { font: italic 400 12.5px/1.5 ui-serif, "New York", Georgia, serif; color: #565B63; border-left: 2.5px solid #D9D2BF; padding: 1px 0 1px 10px; margin-bottom: 4px; }
    .question-label { font: 600 9.5px/1 -apple-system, sans-serif; font-style: normal; letter-spacing: 0.06em; text-transform: uppercase; color: #9A9585; margin-right: 4px; }
    figure { margin: 0; }
    figure.card img { display: block; width: 100%; height: auto; border-radius: 12px; border: 1px solid #E4DECF; background: #FBF7EE; }
    figure.screen img { display: block; width: 100%; height: auto; border-radius: 8px; border: 1px solid #D8DADF; }
    figure.screen figcaption { font: 500 10px/1.3 -apple-system, sans-serif; color: #8A8F96; margin-top: 5px; }
    .section-heading { font: 700 10.5px/1.2 -apple-system, sans-serif; letter-spacing: 0.07em; text-transform: uppercase; color: #8C8676; margin: 0; }
    p.said { font: 400 13px/1.62 ui-serif, "New York", Georgia, serif; color: #24262C; margin: 0; }
    .ideas { font: 500 10.5px/1.9 -apple-system, sans-serif; color: #5F6470; }
    .ideas-label { font-weight: 700; letter-spacing: 0.07em; text-transform: uppercase; color: #8C8676; margin-right: 4px; font-size: 10px; }
    .idea { display: inline-block; padding: 1px 9px; border-radius: 999px; background: #E9EEF9; color: #2F4C8C; margin: 0 2px 2px 0; line-height: 1.7; }
    .review { font: 500 11.5px/1.4 -apple-system, sans-serif; color: #3D5A99; background: #F1F4FB; border-radius: 8px; padding: 7px 11px; }
    .review strong { font-weight: 700; }
    """

    // MARK: - Notebook window

    /// One lesson as a page of paper for the Notebook window: the eyebrow,
    /// the title, the ideas it taught (each opens the Map), the question,
    /// the drawing on a lighter panel, what was said, and the page's own
    /// buttons. No scripts: every button is a link the window intercepts.
    static func windowPageHTML(storedPage: NotebookStoredPage, pageNumber: Int, pageCount: Int,
                               dayName: String, canReplay: Bool) -> String {
        let page = storedPage.page
        let eyebrow = page.createdAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            + " \u{00B7} " + lessonTimeText(page.createdAt)

        var ideasHTML = ""
        if !page.ideas.isEmpty {
            let chips = page.ideas.map { idea -> String in
                let name = idea.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                return "<a class=\"idea-chip\" href=\"\(actionScheme)://open-idea?name=\(name)\" title=\"\(escaped(idea.summary))\">\(linkGlyph)\(escaped(idea.name))</a>"
            }.joined(separator: " ")
            ideasHTML = "<div class=\"ideas-row\">\(chips)</div>"
        }

        var drawingHTML = ""
        if !page.cards.isEmpty || page.screenCrop != nil {
            var figures = ""
            for card in page.cards {
                let source = fileURLString(for: storedPage, fileName: card.fileName)
                figures += "<img class=\"card\" src=\"\(source)\" width=\"\(Int(card.widthInPixels))\" height=\"\(Int(card.heightInPixels))\" alt=\"\(escaped(card.title ?? "Card"))\">"
            }
            if let screenCrop = page.screenCrop {
                let source = fileURLString(for: storedPage, fileName: screenCrop.fileName)
                figures += "<img class=\"screen\" src=\"\(source)\" width=\"\(screenCrop.widthInPixels)\" height=\"\(screenCrop.heightInPixels)\" alt=\"Marked part of the screen\">"
            }
            let caption = canReplay
                ? "The drawing from this lesson. Replay draws it again on your screen."
                : "The drawing from this lesson."
            drawingHTML = """
            <div class="drawing">\(figures)<div class="drawing-caption">\(pencilGlyph)\(caption)</div></div>
            """
        }

        let paragraphsHTML = page.paragraphs.map { "<p class=\"said\">\(escaped($0))</p>" }.joined()
        var reviewHTML = ""
        if let reviewAgainAround = page.reviewAgainAround {
            reviewHTML = "<div class=\"review\">Review again around <strong>\(escaped(reviewDateText(reviewAgainAround)))</strong></div>"
        }

        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(fileScheme):; style-src 'unsafe-inline'">
        <style>
        * { box-sizing: border-box; }
        html { background: #101211; }
        body { margin: 0; padding: 44px 32px 56px; -webkit-font-smoothing: antialiased; font-family: -apple-system, sans-serif; }
        .page { width: 700px; max-width: 100%; margin: 0 auto; background-color: #F7F2E3;
                background-image: radial-gradient(rgba(0,0,0,0.09) 0.9px, transparent 1.1px); background-size: 16px 16px;
                border-radius: 6px; padding: 34px 40px 30px; box-shadow: 0 18px 48px rgba(0,0,0,0.45); color: #2B2D33; }
        .eyebrow { font: 700 11px/1.3 -apple-system, sans-serif; letter-spacing: 0.1em; text-transform: uppercase; color: rgba(0,0,0,0.56); }
        h1 { font: 700 26px/1.2 ui-rounded, -apple-system, sans-serif; margin: 10px 0 12px; letter-spacing: -0.01em; color: #2B2D33; }
        .ideas-row { margin-bottom: 8px; }
        a.idea-chip { display: inline-flex; align-items: center; gap: 6px; font: 600 12.5px/1 -apple-system, sans-serif; color: #5C459E;
                      background: rgba(220,209,247,0.9); padding: 7px 12px; border-radius: 999px; text-decoration: none; margin: 0 4px 4px 0; cursor: pointer; }
        a.idea-chip:hover { background: rgba(205,190,245,1); }
        .question { font: 500 13px/1.45 -apple-system, sans-serif; color: #5E626B; margin: 4px 0 16px; }
        .drawing { background: rgba(255,255,255,0.55); border: 1px solid rgba(0,0,0,0.06); border-radius: 12px; padding: 16px 16px 12px; margin: 0 0 20px; }
        .drawing img { display: block; max-width: 100%; height: auto; margin: 0 auto 10px; }
        .drawing img.card { max-height: 520px; width: auto; }
        .drawing img.screen { max-width: 70%; border-radius: 8px; border: 1px solid #D8DADF; }
        .drawing-caption { display: flex; align-items: center; gap: 7px; font: 500 11.5px/1.3 -apple-system, sans-serif; color: rgba(0,0,0,0.56); }
        p.said { font: 400 14px/21px -apple-system, sans-serif; color: #2B2D33; margin: 0 0 14px; }
        .review { font: 500 12px/1.4 -apple-system, sans-serif; color: #3D5A99; margin: 4px 0 0; }
        .footer { display: flex; align-items: center; gap: 10px; margin-top: 22px; }
        .footer .spacer { flex: 1; }
        a.gel { display: inline-flex; align-items: center; gap: 7px; font: 600 13.5px/1 -apple-system, sans-serif; color: #2B2D33;
                background: rgba(255,255,255,0.55); border: 1px solid rgba(0,0,0,0.1); padding: 10px 16px; border-radius: 999px; text-decoration: none; cursor: pointer; }
        a.gel:hover { background: rgba(255,255,255,0.78); }
        .page-count { font: 500 12px/1 -apple-system, sans-serif; color: rgba(0,0,0,0.56); }
        svg.glyph { width: 13px; height: 13px; flex: none; }
        </style></head>
        <body>
        <article class="page">
          <div class="eyebrow">\(escaped(eyebrow))</div>
          <h1>\(escaped(page.displayTitle))</h1>
          \(ideasHTML)
          \(page.lessonTitle != nil ? "<div class=\"question\">You asked: \u{201C}\(escaped(page.question))\u{201D}</div>" : "")
          \(drawingHTML)
          \(paragraphsHTML)
          \(reviewHTML)
          <div class="footer">
            <a class="gel" href="\(actionScheme)://teach-back/\(page.id.uuidString)">\(teachBackGlyph)Teach it back</a>
            <a class="gel" href="\(actionScheme)://follow-up/\(page.id.uuidString)">\(followUpGlyph)Ask a follow-up</a>
            <span class="spacer"></span>
            <span class="page-count">Page \(pageNumber) of \(pageCount) \(escaped(dayName))</span>
          </div>
        </article>
        </body></html>
        """
    }

    // Small line glyphs drawn inline, since the page loads nothing else.
    private static let linkGlyph = """
    <svg class="glyph" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M6.5 9.5l3-3M7 4.5l1-1a2.8 2.8 0 014 4l-1 1M9 11.5l-1 1a2.8 2.8 0 01-4-4l1-1"/></svg>
    """
    private static let pencilGlyph = """
    <svg class="glyph" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10.5 2.5l3 3L6 13H3v-3z"/></svg>
    """
    private static let teachBackGlyph = """
    <svg class="glyph" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><circle cx="6" cy="5" r="2.5"/><path d="M1.5 13.5c.6-2.6 2.3-4 4.5-4s3.9 1.4 4.5 4M11.5 4.5c1 .8 1 2.7 0 3.5M13.3 3c1.9 1.6 1.9 4.9 0 6.5"/></svg>
    """
    private static let followUpGlyph = """
    <svg class="glyph" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3v5.5a2 2 0 002 2h8M10 7.5l3 3-3 3"/></svg>
    """

    // MARK: - PDF

    /// The whole export as one HTML document. A short script lays it out
    /// into fixed-size sheets once it has loaded (see `paginationScript`),
    /// then the exporter prints each sheet as one PDF page.
    static func printDocumentHTML(
        pages: [NotebookStoredPage],
        rangeDescription: String,
        paperSize: NotebookPaperSize,
        generatedAt: Date
    ) -> String {
        var source = ""
        let lessonCountText = pages.count == 1 ? "1 lesson" : "\(pages.count) lessons"
        let dayCount = Set(pages.map(\.dayIdentifier)).count
        let dayCountText = dayCount == 1 ? "1 day" : "\(dayCount) days"

        source += """
        <section class="cover-source">
          <div class="cover-brand">Buddy</div>
          <h1 class="cover-title">Notebook</h1>
          <svg class="cover-stroke" viewBox="0 0 300 18" width="300" height="18"><path d="M3 12 C 60 4, 120 15, 180 8 S 270 6, 297 9" fill="none" stroke="#3A6FD8" stroke-width="3.2" stroke-linecap="round"/></svg>
          <div class="cover-range">\(escaped(rangeDescription))</div>
          <div class="cover-count">\(lessonCountText) over \(dayCountText)</div>
          <div class="cover-footnote">Made on \(escaped(lessonDateText(generatedAt))) from the lessons kept on this Mac.</div>
        </section>

        """

        source += "<section class=\"contents-source\">\n<h2 class=\"block contents-title\">Contents</h2>\n"
        var lastDayIdentifier: String?
        for (lessonIndex, storedPage) in pages.enumerated() {
            if storedPage.dayIdentifier != lastDayIdentifier {
                lastDayIdentifier = storedPage.dayIdentifier
                source += "<div class=\"block contents-day\" data-keep-with-next=\"1\">\(escaped(lessonDateText(storedPage.page.createdAt)))</div>\n"
            }
            source += """
            <div class="block contents-row"><span class="contents-time">\(escaped(lessonTimeText(storedPage.page.createdAt)))</span><span class="contents-name">\(lessonIndex + 1). \(escaped(storedPage.page.displayTitle))</span><span class="contents-leader"></span><span class="contents-page" data-lesson="\(lessonIndex)">000</span></div>

            """
        }
        source += "</section>\n"

        for (lessonIndex, storedPage) in pages.enumerated() {
            source += """
            <section class="lesson-source" data-lesson="\(lessonIndex)" data-running-head="\(escaped(storedPage.page.displayTitle)), continued">
            \(lessonBlocks(storedPage, lessonNumber: lessonIndex + 1, screenAfterWords: true))
            </section>

            """
        }

        let margins = paperSize.marginsInPoints
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(fileScheme):; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
        <style>
        \(sharedStyles)
        html, body { background: #FFFFFF; }
        #source { display: none; }
        .sheet { position: relative; width: \(paperSize.widthInPoints)px; height: \(paperSize.heightInPoints)px; overflow: hidden; background: #FFFFFF;
                 padding: \(margins.top)px \(margins.side)px \(margins.bottom)px; }
        .sheet-body { height: 100%; overflow: hidden; display: flow-root; }
        .sheet-body > .block { margin: 0 0 14px; }
        .sheet-body > p.said { margin-bottom: 8px; }
        .sheet-body > .section-heading { margin: 18px 0 7px; }
        .sheet-body > figure.card { margin-bottom: 18px; }
        .sheet-body > figure.card img { width: auto; height: auto; max-width: 100%; max-height: 430px; }
        .sheet-body > figure.screen { width: 58%; margin-bottom: 16px; }
        .sheet-footer { position: absolute; left: \(margins.side)px; right: \(margins.side)px; bottom: 26px; display: flex; justify-content: space-between;
                        font: 500 8.5px/1 -apple-system, sans-serif; color: #9A9EA5; letter-spacing: 0.02em; border-top: 0.5px solid #E3E4E7; padding-top: 8px; }
        .running-head { font: 600 9px/1.2 -apple-system, sans-serif; color: #A0A4AA; letter-spacing: 0.06em; text-transform: uppercase; margin-bottom: 14px; }
        .sheet.cover .sheet-footer { display: none; }
        .sheet.cover .sheet-body { display: flex; flex-direction: column; justify-content: center; padding-bottom: 80px; }
        .cover-brand { font: 700 12px/1 -apple-system, sans-serif; letter-spacing: 0.22em; text-transform: uppercase; color: #3A6FD8; }
        .cover-title { font: 800 54px/1.05 -apple-system, sans-serif; color: #1C1E23; margin: 14px 0 6px; letter-spacing: -0.025em; }
        .cover-stroke { display: block; margin: 0 0 26px -2px; }
        .cover-range { font: 500 19px/1.35 ui-serif, "New York", Georgia, serif; color: #2B2E35; }
        .cover-count { font: 500 13px/1.4 -apple-system, sans-serif; color: #6B7078; margin-top: 8px; }
        .cover-footnote { position: absolute; left: \(margins.side)px; bottom: 40px; font: 400 10px/1.4 -apple-system, sans-serif; color: #A0A4AA; }
        .contents-title { font: 800 26px/1.1 -apple-system, sans-serif; color: #1C1E23; margin: 0 0 18px !important; letter-spacing: -0.015em; }
        .contents-day { font: 700 10px/1.2 -apple-system, sans-serif; letter-spacing: 0.07em; text-transform: uppercase; color: #8C8676; margin: 14px 0 6px !important; }
        .contents-row { display: flex; align-items: baseline; gap: 8px; font: 400 12px/1.5 ui-serif, "New York", Georgia, serif; color: #24262C; margin: 0 0 3px !important; }
        .contents-time { font: 500 10px/1 -apple-system, sans-serif; color: #9A9EA5; width: 54px; flex: none; white-space: nowrap; font-variant-numeric: tabular-nums; }
        .contents-name { flex: 0 1 auto; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 78%; }
        .contents-leader { flex: 1 1 auto; border-bottom: 1px dotted #C9CBD0; transform: translateY(-3px); min-width: 16px; }
        .contents-page { flex: none; font: 600 10.5px/1 -apple-system, sans-serif; color: #4A4E56; font-variant-numeric: tabular-nums; }
        </style></head>
        <body>
        <div id="source">
        \(source)
        </div>
        <div id="sheets"></div>
        <script>
        window.notebookFooterTitle = \(javaScriptStringLiteral("Buddy notebook · " + rangeDescription));
        \(paginationScript)
        </script>
        </body></html>
        """
    }

    private static func javaScriptStringLiteral(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        // ["..."] to "...", and nothing in it can close the script element.
        return String(array.dropFirst().dropLast()).replacingOccurrences(of: "</", with: "<\\/")
    }

    /// Lays the document out into sheets the size of the paper. Every lesson
    /// starts a sheet; blocks are placed in order and a block that does not
    /// fit moves whole to the next sheet, so a card is never cut in half. A
    /// card taller than a whole sheet is scaled down to fit one. Paragraphs
    /// are the exception: they continue on the next sheet between sentences,
    /// so a long answer does not leave half a page empty. A heading never
    /// ends a sheet without what it heads.
    private static let paginationScript = """
    window.layOutNotebook = async function () {
      await Promise.all([...document.images].map(image => image.decode ? image.decode().catch(() => {}) : Promise.resolve()));
      const sheets = document.getElementById('sheets');
      const source = document.getElementById('source');
      const allSheets = [];

      function newSheet(kind, runningHead) {
        const sheet = document.createElement('div');
        sheet.className = 'sheet ' + kind;
        const body = document.createElement('div');
        body.className = 'sheet-body';
        sheet.appendChild(body);
        let headCount = 0;
        if (runningHead) {
          const head = document.createElement('div');
          head.className = 'running-head';
          head.textContent = runningHead;
          body.appendChild(head);
          headCount = 1;
        }
        const footer = document.createElement('div');
        footer.className = 'sheet-footer';
        sheet.appendChild(footer);
        sheets.appendChild(sheet);
        allSheets.push(sheet);
        return { sheet, body, headCount };
      }

      const overflows = body => body.scrollHeight > body.clientHeight + 0.5;
      const blocksOn = current => current.body.children.length - current.headCount;

      function shrinkFigureToFit(block, body) {
        const image = block.querySelector('img');
        if (!image) return;
        const excess = body.scrollHeight - body.clientHeight;
        const height = image.getBoundingClientRect().height;
        const fittedHeight = Math.max(60, height - excess - 2);
        image.style.height = fittedHeight + 'px';
        image.style.width = 'auto';
        image.style.maxWidth = '100%';
        block.style.width = 'auto';
      }

      // Moves trailing sentences of a paragraph that does not fit into a new
      // paragraph, returned for the next sheet. Null if it all fits.
      function splitParagraph(block, body) {
        const rest = block.cloneNode(false);
        while (overflows(body) && block.children.length > 1) {
          rest.insertBefore(block.lastElementChild, rest.firstChild);
        }
        if (overflows(body)) {
          while (rest.firstChild) block.appendChild(rest.firstChild);
          return 'whole';
        }
        return rest.children.length ? rest : null;
      }

      function place(block, state, kind, runningHead) {
        state.current.body.appendChild(block);
        if (!overflows(state.current.body)) {
          // A heading at the very bottom would be cut off from its text.
          const roomLeft = state.current.body.getBoundingClientRect().bottom - block.getBoundingClientRect().bottom;
          if (block.dataset.keepWithNext && roomLeft < 90 && blocksOn(state.current) > 1) {
            block.remove();
            state.current = newSheet(kind, runningHead);
            state.current.body.appendChild(block);
          }
          return;
        }
        if (block.classList.contains('said') && block.children.length > 1) {
          const rest = splitParagraph(block, state.current.body);
          if (rest && rest !== 'whole') {
            state.current = newSheet(kind, runningHead);
            place(rest, state, kind, runningHead);
            return;
          }
        }
        if (blocksOn(state.current) > 1) {
          block.remove();
          // Its heading goes with it.
          const previous = state.current.body.lastElementChild;
          const carried = previous && previous.dataset && previous.dataset.keepWithNext ? previous : null;
          if (carried) carried.remove();
          state.current = newSheet(kind, runningHead);
          if (carried) state.current.body.appendChild(carried);
          state.current.body.appendChild(block);
        }
        if (overflows(state.current.body)) shrinkFigureToFit(block, state.current.body);
      }

      const cover = newSheet('cover');
      cover.body.appendChild(source.querySelector('.cover-source'));

      const contentsState = { current: newSheet('contents') };
      for (const block of [...source.querySelectorAll('.contents-source > .block')]) {
        place(block, contentsState, 'contents', 'Contents, continued');
      }

      const firstSheetOfLesson = {};
      for (const lesson of [...source.querySelectorAll('.lesson-source')]) {
        const state = { current: newSheet('lesson') };
        firstSheetOfLesson[lesson.dataset.lesson] = allSheets.length;
        for (const block of [...lesson.children]) {
          place(block, state, 'lesson', lesson.dataset.runningHead);
        }
      }

      for (const number of [...document.querySelectorAll('.contents-page')]) {
        number.textContent = String(firstSheetOfLesson[number.dataset.lesson] || '');
      }
      const total = allSheets.length;
      allSheets.forEach((sheet, index) => {
        const footer = sheet.querySelector('.sheet-footer');
        const title = document.createElement('span');
        title.textContent = window.notebookFooterTitle;
        const number = document.createElement('span');
        number.textContent = 'Page ' + (index + 1) + ' of ' + total;
        footer.appendChild(title);
        footer.appendChild(number);
      });
      return total;
    };
    """
}

/// The paper the PDF is laid out for: US Letter where it is the standard
/// size, A4 everywhere else.
struct NotebookPaperSize: Equatable {
    let name: String
    let widthInPoints: Double
    let heightInPoints: Double

    static let a4 = NotebookPaperSize(name: "A4", widthInPoints: 595.28, heightInPoints: 841.89)
    static let usLetter = NotebookPaperSize(name: "US Letter", widthInPoints: 612, heightInPoints: 792)

    /// The countries that print on US Letter rather than A4.
    private static let usLetterRegions: Set<String> = [
        "US", "CA", "MX", "PH", "CL", "CO", "VE", "CR", "GT", "PA", "DO", "PR", "SV", "NI", "HN", "BO", "BZ"
    ]

    static func forRegion(_ regionCode: String?) -> NotebookPaperSize {
        guard let regionCode else { return .a4 }
        return usLetterRegions.contains(regionCode.uppercased()) ? .usLetter : .a4
    }

    static var forCurrentRegion: NotebookPaperSize {
        forRegion(Locale.current.region?.identifier)
    }

    var marginsInPoints: (top: Double, side: Double, bottom: Double) { (52, 50, 62) }
}

/// Serves the notebook's own files to its pages, and nothing else: a path
/// that leaves the notebook folder is refused.
final class NotebookFileSchemeHandler: NSObject, WKURLSchemeHandler {
    private let rootFolder: URL

    init(rootFolder: URL) {
        self.rootFolder = rootFolder.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let relativePath = url.path.removingPercentEncoding ?? url.path
        let fileURL = rootFolder.appendingPathComponent(relativePath).standardizedFileURL
        guard fileURL.path.hasPrefix(rootFolder.path + "/"),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mimeType: String
        switch fileURL.pathExtension.lowercased() {
        case "svg": mimeType = "image/svg+xml"
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "png": mimeType = "image/png"
        default: mimeType = "application/octet-stream"
        }
        let response = URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/// Sentences and paragraphs, for the pages.
enum NotebookText {
    /// Every say("...") in a drawing program as paragraphs, one per beat
    /// (`step(n)`), so the page reads the way the lesson was paced. Without
    /// beats, every three sentences make a paragraph.
    static func paragraphs(inProgram program: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"\bstep\s*\(|\bsay\(\s*"((?:[^"\\]|\\.)*)"\s*\)"#) else { return [] }
        let range = NSRange(program.startIndex..., in: program)
        var paragraphs: [[String]] = []
        var current: [String] = []
        var sawStep = false
        for match in expression.matches(in: program, range: range) {
            if let sentenceRange = Range(match.range(at: 1), in: program) {
                let sentence = unescapedJavaScriptString(String(program[sentenceRange]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { current.append(sentence) }
            } else {
                sawStep = true
                if !current.isEmpty { paragraphs.append(current) }
                current = []
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        if !sawStep { return groupedInThrees(paragraphs.flatMap { $0 }) }
        return paragraphs.map { $0.joined(separator: " ") }
    }

    /// Prose answers: every three sentences make a paragraph.
    static func paragraphs(inProse text: String) -> [String] {
        groupedInThrees(sentences(in: text))
    }

    static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        return sentences.isEmpty && !text.isEmpty ? [text] : sentences
    }

    private static func groupedInThrees(_ sentences: [String]) -> [String] {
        stride(from: 0, to: sentences.count, by: 3).map { start in
            sentences[start..<min(start + 3, sentences.count)].joined(separator: " ")
        }
    }

    /// The text of a JavaScript string literal's body: \" \' \\ \n and \u
    /// escapes, which is how a sentence with quotes in it arrives.
    static func unescapedJavaScriptString(_ body: String) -> String {
        var result = ""
        var characters = body.makeIterator()
        while let character = characters.next() {
            guard character == "\\", let escapedCharacter = characters.next() else {
                result.append(character)
                continue
            }
            switch escapedCharacter {
            case "n": result.append(" ")
            case "t": result.append(" ")
            case "u":
                var hexDigits = ""
                for _ in 0..<4 { if let digit = characters.next() { hexDigits.append(digit) } }
                if let value = UInt32(hexDigits, radix: 16), let scalar = Unicode.Scalar(value) {
                    result.append(Character(scalar))
                }
            default: result.append(escapedCharacter)
            }
        }
        return result
    }
}
