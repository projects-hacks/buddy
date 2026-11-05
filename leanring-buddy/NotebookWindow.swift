//
//  NotebookWindow.swift
//  leanring-buddy
//
//  The Notebook: a real window (the notch never takes the keyboard) with
//  the days down the side and the chosen day's pages scrolling beside them.
//  From here a page, a day or every note can be deleted, new lessons can
//  stop being kept, and a day, a range or everything can be exported to PDF.
//
//  The chrome is SwiftUI in the app's dark design system. The pages are
//  HTML in a web view, the same HTML family the PDF is printed from, so a
//  page looks the same here as on paper. That web view runs no scripts and
//  loads only the notebook's own files; deleting a page is a link the
//  window intercepts.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
final class NotebookWindowController: NSObject, NSWindowDelegate {
    static let shared = NotebookWindowController()

    /// Set by CompanionManager when the notebook is connected.
    var store = NotebookStore(rootFolder: NotebookStore.standardRootFolder)
    /// Puts away what floats above every window (the notch, the drawing).
    var beforeOpening: () -> Void = {}

    let model = NotebookModel()
    private var window: NSWindow?

    func show() {
        beforeOpening()
        model.store = store
        let window = self.window ?? makeWindow()
        let isFirstOpening = self.window == nil
        self.window = window
        model.window = window
        // A menu bar app is never the active app on its own; it has to ask,
        // or the window opens behind everything and cannot take typing.
        NSApp.activate()
        if isFirstOpening { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        Task { await model.reload() }
    }

    /// A page was written or changed while the window may be open.
    func notebookDidChange() {
        guard window?.isVisible == true else { return }
        Task { await model.reload() }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Notebook"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
        window.backgroundColor = NSColor(DS.Colors.background)
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        window.contentView = NSHostingView(rootView: NotebookView(model: model))
        return window
    }
}

// MARK: - Model

enum NotebookExportScope: Equatable {
    case day(String)
    case range(from: Date, through: Date)
    case everything
}

@MainActor
final class NotebookModel: ObservableObject {
    enum ExportStatus: Equatable {
        case idle
        case exporting(lessonCount: Int)
        case finished(URL)
        case failed(String)
    }

    enum Deletion: Identifiable {
        case page(NotebookStoredPage)
        case day(NotebookDay)
        case everything

        var id: String {
            switch self {
            case .page(let storedPage): return "page-\(storedPage.id)"
            case .day(let day): return "day-\(day.id)"
            case .everything: return "everything"
            }
        }
    }

    @Published private(set) var days: [NotebookDay] = []
    @Published var selectedDayIdentifier: String?
    @Published private(set) var hasLoaded = false
    @Published var exportStatus: ExportStatus = .idle
    @Published var isShowingExportSheet = false
    @Published var pendingDeletion: Deletion?
    @Published var keepsLessons = NotebookRecorder.keepsLessons {
        didSet { NotebookRecorder.keepsLessons = keepsLessons }
    }

    var store = NotebookStore(rootFolder: NotebookStore.standardRootFolder)
    weak var window: NSWindow?

    var selectedDay: NotebookDay? {
        days.first { $0.id == selectedDayIdentifier } ?? days.first
    }

    var totalSizeInBytes: Int { days.reduce(0) { $0 + $1.sizeInBytes } }
    var totalPageCount: Int { days.reduce(0) { $0 + $1.pages.count } }

    func reload() async {
        days = await store.loadDays()
        hasLoaded = true
        if selectedDayIdentifier == nil || !days.contains(where: { $0.id == selectedDayIdentifier }) {
            selectedDayIdentifier = days.first?.id
        }
    }

    func page(withIdentifier identifier: UUID) -> NotebookStoredPage? {
        days.lazy.flatMap(\.pages).first { $0.id == identifier }
    }

    func confirmDeletion(_ deletion: Deletion) async {
        switch deletion {
        case .page(let storedPage): await store.deletePage(storedPage)
        case .day(let day): await store.deleteDay(day.id)
        case .everything: await store.deleteEverything()
        }
        await reload()
    }

    // MARK: Export

    /// Oldest first, which is the order a notebook is read in.
    func pages(in scope: NotebookExportScope) -> [NotebookStoredPage] {
        let everyPage = days.reversed().flatMap(\.pages)
        switch scope {
        case .day(let dayIdentifier):
            return everyPage.filter { $0.dayIdentifier == dayIdentifier }
        case .range(let from, let through):
            let firstDay = NotebookStore.dayIdentifier(for: min(from, through))
            let lastDay = NotebookStore.dayIdentifier(for: max(from, through))
            return everyPage.filter { $0.dayIdentifier >= firstDay && $0.dayIdentifier <= lastDay }
        case .everything:
            return everyPage
        }
    }

    func rangeDescription(for pages: [NotebookStoredPage], scope: NotebookExportScope) -> String {
        guard let first = pages.first?.page.createdAt, let last = pages.last?.page.createdAt else { return "" }
        let isOneDay = NotebookStore.dayIdentifier(for: first) == NotebookStore.dayIdentifier(for: last)
        let span: String
        if isOneDay {
            span = NotebookDocumentHTML.lessonDateText(first)
        } else if Calendar.current.component(.year, from: first) == Calendar.current.component(.year, from: last) {
            span = first.formatted(.dateTime.day().month(.wide)) + " to " + last.formatted(.dateTime.day().month(.wide).year())
        } else {
            span = first.formatted(.dateTime.day().month(.wide).year()) + " to " + last.formatted(.dateTime.day().month(.wide).year())
        }
        if case .everything = scope, !isOneDay { return "All notes, " + span }
        return span
    }

    /// Asks where to save, then exports in the background. The window stays
    /// usable throughout, and a notification says when it is done.
    func beginExport(_ scope: NotebookExportScope) {
        let pages = pages(in: scope)
        guard !pages.isEmpty else { return }
        let rangeDescription = rangeDescription(for: pages, scope: scope)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "Buddy notes, \(rangeDescription).pdf"
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let startExport: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destinationURL = savePanel.url else { return }
            self?.export(pages: pages, rangeDescription: rangeDescription, to: destinationURL)
        }
        if let window {
            savePanel.beginSheetModal(for: window, completionHandler: startExport)
        } else {
            savePanel.begin(completionHandler: startExport)
        }
    }

    private func export(pages: [NotebookStoredPage], rangeDescription: String, to destinationURL: URL) {
        exportStatus = .exporting(lessonCount: pages.count)
        NotebookExportNotifier.shared.prepareForExport()
        let request = NotebookPDFExporter.Request(
            pages: pages, rangeDescription: rangeDescription, destinationURL: destinationURL,
            paperSize: .forCurrentRegion, notebookRootFolder: store.rootFolder)
        Task {
            let exporter = NotebookPDFExporter()
            do {
                let result = try await exporter.export(request)
                exportStatus = .finished(result.url)
                TutorDebugLog.write("📓 notebook: exported \(pages.count) lesson(s), \(result.pageCount) PDF pages")
                NotebookExportNotifier.shared.announceFinishedExport(
                    pdfURL: result.url, lessonCount: pages.count, pageCount: result.pageCount)
            } catch {
                exportStatus = .failed(error.localizedDescription)
                TutorDebugLog.write("⚠️ notebook: export failed: \(error.localizedDescription)")
                NotebookExportNotifier.shared.announceFailedExport(error.localizedDescription)
            }
        }
    }
}

// MARK: - Views

struct NotebookView: View {
    @ObservedObject var model: NotebookModel

    var body: some View {
        HStack(spacing: 0) {
            NotebookSidebar(model: model)
                .frame(width: 240)
            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(width: 1)
            NotebookDayDetail(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Colors.background)
        .ignoresSafeArea()
        .sheet(isPresented: $model.isShowingExportSheet) {
            NotebookExportSheet(model: model)
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }),
            presenting: model.pendingDeletion
        ) { deletion in
            Button(deletionButtonTitle(deletion), role: .destructive) {
                Task { await model.confirmDeletion(deletion) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            Text(deletionMessage(deletion))
        }
    }

    private var deletionTitle: String {
        switch model.pendingDeletion {
        case .page(let storedPage): return "Delete \u{201C}\(storedPage.page.displayTitle)\u{201D}?"
        case .day(let day): return "Delete every page from \(NotebookDayNames.name(for: day))?"
        case .everything: return "Delete all notes?"
        case nil: return ""
        }
    }

    private func deletionButtonTitle(_ deletion: NotebookModel.Deletion) -> String {
        switch deletion {
        case .page: return "Delete page"
        case .day: return "Delete day"
        case .everything: return "Delete all notes"
        }
    }

    private func deletionMessage(_ deletion: NotebookModel.Deletion) -> String {
        switch deletion {
        case .page: return "The page, its cards and its screen crop are removed from this Mac."
        case .day(let day): return "\(day.pages.count == 1 ? "1 page" : "\(day.pages.count) pages") and their screen crops are removed from this Mac."
        case .everything: return "Every page, card and screen crop is removed from this Mac. PDFs already exported are not touched, and what Buddy remembers of the ideas stays in its memory."
        }
    }
}

enum NotebookDayNames {
    static func name(for day: NotebookDay) -> String {
        if Calendar.current.isDateInToday(day.date) { return "Today" }
        if Calendar.current.isDateInYesterday(day.date) { return "Yesterday" }
        let sameYear = Calendar.current.component(.year, from: day.date) == Calendar.current.component(.year, from: Date())
        return sameYear
            ? day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            : day.date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func summary(for day: NotebookDay) -> String {
        let lessons = day.pages.count == 1 ? "1 lesson" : "\(day.pages.count) lessons"
        return "\(lessons) · \(NotebookDocumentHTML.sizeText(day.sizeInBytes))"
    }
}

private struct NotebookSidebar: View {
    @ObservedObject var model: NotebookModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Notebook")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(model.totalPageCount == 1 ? "1 lesson kept" : "\(model.totalPageCount) lessons kept")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 18)
            // Clear of the window's close and minimise buttons.
            .padding(.top, 44)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.days) { day in
                        NotebookDayRow(day: day, isSelected: day.id == model.selectedDay?.id) {
                            model.selectedDayIdentifier = day.id
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 10) {
                Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
                Toggle(isOn: $model.keepsLessons) {
                    Text("Keep new lessons")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .pointerCursor()
                .help("Off, finished lessons are no longer written to the notebook. Pages already kept stay until deleted.")
                Text("\(NotebookDocumentHTML.sizeText(model.totalSizeInBytes)) on this Mac, never uploaded")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Colors.textTertiary)
                NotebookCapsuleButton(title: "Delete all notes", systemImage: "trash", kind: .destructive) {
                    model.pendingDeletion = .everything
                }
                .disabled(model.days.isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .background(DS.Colors.surface1)
    }
}

private struct NotebookDayRow: View {
    let day: NotebookDay
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(NotebookDayNames.name(for: day))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                Text(NotebookDayNames.summary(for: day))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(isSelected ? DS.Colors.surface3 : (isHovering ? DS.Colors.surface2 : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in isHovering = hovering }
    }
}

private struct NotebookDayDetail: View {
    @ObservedObject var model: NotebookModel

    var body: some View {
        if let day = model.selectedDay {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(NotebookDocumentHTML.lessonDateText(day.date))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text(NotebookDayNames.summary(for: day))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.Colors.textTertiary)
                    }
                    Spacer(minLength: 12)
                    exportStatusLabel
                    NotebookCapsuleButton(title: "Delete day", systemImage: "trash", kind: .secondary) {
                        model.pendingDeletion = .day(day)
                    }
                    NotebookCapsuleButton(title: "Export PDF\u{2026}", systemImage: "arrow.down.doc", kind: .primary) {
                        model.isShowingExportSheet = true
                    }
                    .disabled(isExporting)
                }
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 14)

                NotebookPagesWebView(
                    html: NotebookDocumentHTML.dayPagesHTML(day: day),
                    rootFolder: model.store.rootFolder,
                    onDeletePage: { pageIdentifier in
                        if let storedPage = model.page(withIdentifier: pageIdentifier) {
                            model.pendingDeletion = .page(storedPage)
                        }
                    }
                )
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "book.pages")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(DS.Colors.textTertiary)
                Text(model.hasLoaded ? "No notes yet" : "")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(model.keepsLessons
                     ? "Each lesson is kept here as a page: what you asked, what was said, the cards drawn and the part of the screen that was marked. Pages stay on this Mac."
                     : "Keeping new lessons is turned off.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isExporting: Bool {
        if case .exporting = model.exportStatus { return true }
        return false
    }

    @ViewBuilder
    private var exportStatusLabel: some View {
        switch model.exportStatus {
        case .idle:
            EmptyView()
        case .exporting(let lessonCount):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(lessonCount == 1 ? "Exporting 1 lesson" : "Exporting \(lessonCount) lessons")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        case .finished(let url):
            Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Show in Finder")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.destructiveText)
                .lineLimit(1)
                .frame(maxWidth: 260)
        }
    }
}

private struct NotebookExportSheet: View {
    @ObservedObject var model: NotebookModel
    private enum Choice: Hashable { case day, range, everything }
    @State private var choice: Choice = .day
    @State private var rangeStart = Date()
    @State private var rangeEnd = Date()

    private var scope: NotebookExportScope {
        switch choice {
        case .day: return .day(model.selectedDay?.id ?? "")
        case .range: return .range(from: rangeStart, through: rangeEnd)
        case .everything: return .everything
        }
    }

    private var earliestDay: Date { model.days.last?.date ?? Date() }
    private var latestDay: Date { model.days.first?.date ?? Date() }

    var body: some View {
        let pageCount = model.pages(in: scope).count
        VStack(alignment: .leading, spacing: 16) {
            Text("Export to PDF")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DS.Colors.textPrimary)
            Picker("", selection: $choice) {
                Text("This day").tag(Choice.day)
                Text("A range").tag(Choice.range)
                Text("Everything").tag(Choice.everything)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .pointerCursor()

            if choice == .range {
                HStack(spacing: 14) {
                    DatePicker("From", selection: $rangeStart, in: earliestDay...latestDay, displayedComponents: .date)
                    DatePicker("To", selection: $rangeEnd, in: earliestDay...latestDay, displayedComponents: .date)
                }
                .datePickerStyle(.field)
                .font(.system(size: 12.5))
                .foregroundStyle(DS.Colors.textSecondary)
            }

            Text("\(pageCount == 1 ? "1 lesson" : "\(pageCount) lessons"), one to a page, on \(NotebookPaperSize.forCurrentRegion.name) paper. It is made in the background; a notification says when it is ready.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()
                NotebookCapsuleButton(title: "Cancel", systemImage: nil, kind: .secondary) {
                    model.isShowingExportSheet = false
                }
                NotebookCapsuleButton(title: "Export\u{2026}", systemImage: "arrow.down.doc", kind: .primary) {
                    let chosenScope = scope
                    model.isShowingExportSheet = false
                    // The save panel opens as the window's sheet, so it
                    // waits for this sheet to have gone.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        model.beginExport(chosenScope)
                    }
                }
                .disabled(pageCount == 0)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(DS.Colors.surface1)
        .onAppear {
            rangeStart = earliestDay
            rangeEnd = latestDay
        }
    }
}

/// The notebook's buttons: compact capsules in the design system's colours,
/// with the pointer and a hover change so they read as clickable.
private struct NotebookCapsuleButton: View {
    enum Kind { case primary, secondary, destructive }

    let title: String
    let systemImage: String?
    let kind: Kind
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Capsule().fill(background))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled: isEnabled)
        .onHover { hovering in isHovering = hovering }
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovering)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return DS.Colors.textOnAccent
        case .secondary: return DS.Colors.textPrimary
        case .destructive: return isHovering && isEnabled ? .white : DS.Colors.destructiveText
        }
    }

    private var background: Color {
        let hovering = isHovering && isEnabled
        switch kind {
        case .primary: return hovering ? DS.Colors.accentHover : DS.Colors.accent
        case .secondary: return hovering ? DS.Colors.surface3 : DS.Colors.surface2
        case .destructive: return hovering ? DS.Colors.destructive : DS.Colors.destructive.opacity(0.12)
        }
    }
}

/// A day's pages, as HTML. No scripts, no network, only the notebook's own
/// files; the only link it acts on is a page's Delete.
private struct NotebookPagesWebView: NSViewRepresentable {
    let html: String
    let rootFolder: URL
    let onDeletePage: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(NotebookFileSchemeHandler(rootFolder: rootFolder),
                                          forURLScheme: NotebookDocumentHTML.fileScheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onDeletePage = onDeletePage
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: URL(string: "\(NotebookDocumentHTML.fileScheme)://notes/"))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        var onDeletePage: (UUID) -> Void = { _ in }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
            if url.scheme == NotebookDocumentHTML.actionScheme {
                if url.host == "delete-page", let pageIdentifier = UUID(uuidString: url.lastPathComponent) {
                    onDeletePage(pageIdentifier)
                }
                return decisionHandler(.cancel)
            }
            // The page itself, loaded from a string. Nothing else is followed.
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}
