//
//  NotebookWindow.swift
//  leanring-buddy
//
//  The Notebook: a real window (the notch never takes the keyboard) with
//  every kept lesson down the side, grouped by day, and the chosen one as a
//  page of paper beside them. A toolbar holds Replay, Export PDF (this page,
//  this day, a range or everything) and More (Show transcripts in Finder,
//  Keep new lessons, and deleting a page, a day or every note), with a
//  search over titles, questions and what was said.
//
//  The chrome is SwiftUI in the app's dark design system. The page is HTML
//  in a web view, the same HTML family the PDF is printed from, so a page
//  looks the same here as on paper. That web view runs no scripts and loads
//  only the notebook's own files; its buttons are links the window
//  intercepts.
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
        show(dayIdentifier: nil)
    }

    /// Opens on a day when one is given, as the notch's "Yesterday's
    /// lessons" tile does; otherwise on the newest page.
    func show(dayIdentifier: String?) {
        beforeOpening()
        model.store = store
        if let dayIdentifier { model.dayToOpenOnNextLoad = dayIdentifier }
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

    /// Opens on the newest page with this title, as the Map's lesson list does.
    func show(pageTitled lessonTitle: String) {
        model.pageTitleToOpenOnNextLoad = lessonTitle
        show(dayIdentifier: nil)
    }

    /// Out of the way while a lesson is replayed on the real screen, and
    /// back once it is done.
    func stepAsideForReplay() {
        window?.orderOut(nil)
    }

    /// A page was written or changed while the window may be open.
    func notebookDidChange() {
        guard window?.isVisible == true else { return }
        Task { await model.reload() }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Notebook"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 560)
        window.backgroundColor = NSColor(DS.Colors.background)
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        let hostingView = NSHostingView(rootView: NotebookView(model: model))
        // The window's own minSize below sets its limits; SwiftUI resetting
        // them from its content during layout can loop until AppKit throws.
        hostingView.sizingOptions = []
        window.contentView = hostingView
        listenForPageKeys(in: window)
        return window
    }

    private var pageKeyMonitor: Any?

    /// Up and Down move through the pages, Space replays and Delete asks to
    /// delete, while the Notebook is the key window and nothing is being
    /// typed. A local monitor rather than SwiftUI shortcuts, which would
    /// take these keys from the search field too.
    private func listenForPageKeys(in window: NSWindow) {
        pageKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, event.window === window, !(window.firstResponder is NSTextView),
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            switch event.keyCode {
            case 126: self.model.selectNeighbourPage(after: -1)
            case 125: self.model.selectNeighbourPage(after: 1)
            case 49:
                guard let page = self.model.selectedPage, self.model.canReplay(page) else { return event }
                self.model.onReplay(page)
            case 51, 117:
                guard let page = self.model.selectedPage else { return event }
                self.model.pendingDeletion = .page(page)
            default:
                return event
            }
            return nil
        }
    }
}

// MARK: - Model

enum NotebookExportScope: Equatable {
    case page(UUID)
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
    @Published var selectedPageIdentifier: UUID?
    @Published private(set) var hasLoaded = false
    @Published var exportStatus: ExportStatus = .idle
    @Published var isShowingExportSheet = false
    @Published var pendingDeletion: Deletion?
    @Published var searchText = ""
    @Published var isSidebarVisible = true
    @Published var keepsLessons = NotebookRecorder.keepsLessons {
        didSet { NotebookRecorder.keepsLessons = keepsLessons }
    }
    /// The day the next reload opens on, from the notch's start tile.
    var dayToOpenOnNextLoad: String?
    /// The lesson the next reload opens on, from the Map's inspector.
    var pageTitleToOpenOnNextLoad: String?

    var store = NotebookStore(rootFolder: NotebookStore.standardRootFolder)
    weak var window: NSWindow?

    // Set by CompanionManager: what the page's buttons do outside the window.
    /// Whether this page can be drawn again on the screen. Only the last
    /// lesson can: its voice and drawing are kept in memory, older ones are
    /// kept as words and pictures only.
    var canReplay: (NotebookStoredPage) -> Bool = { _ in false }
    var onReplay: (NotebookStoredPage) -> Void = { _ in }
    var onTeachBack: (NotebookStoredPage) -> Void = { _ in }
    var onAskFollowUp: (NotebookStoredPage) -> Void = { _ in }
    var onOpenIdea: (String) -> Void = { _ in }
    var onShowTranscripts: () -> Void = {}

    /// Newest day first, each day's lessons newest first, as the sidebar
    /// lists them.
    var visibleDays: [NotebookDay] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return days.compactMap { day in
            var filtered = day
            filtered.pages = day.pages.reversed().filter { storedPage in
                guard !query.isEmpty else { return true }
                let page = storedPage.page
                return page.displayTitle.lowercased().contains(query)
                    || page.question.lowercased().contains(query)
                    || page.paragraphs.contains { $0.lowercased().contains(query) }
            }
            return filtered.pages.isEmpty ? nil : filtered
        }
    }

    var visiblePages: [NotebookStoredPage] { visibleDays.flatMap(\.pages) }

    var selectedPage: NotebookStoredPage? {
        visiblePages.first { $0.id == selectedPageIdentifier } ?? visiblePages.first
    }

    var selectedDay: NotebookDay? {
        guard let selectedPage else { return nil }
        return days.first { $0.id == selectedPage.dayIdentifier }
    }

    var newestPage: NotebookStoredPage? {
        days.flatMap(\.pages).max { $0.page.createdAt < $1.page.createdAt }
    }

    var totalSizeInBytes: Int { days.reduce(0) { $0 + $1.sizeInBytes } }
    var totalPageCount: Int { days.reduce(0) { $0 + $1.pages.count } }

    func reload() async {
        days = await store.loadDays()
        hasLoaded = true
        if let pageTitleToOpenOnNextLoad {
            self.pageTitleToOpenOnNextLoad = nil
            searchText = ""
            // The Map names a lesson as the model wrote it; the page shows it as a title.
            let titleToOpen = LessonTitle.displayed(pageTitleToOpenOnNextLoad)
            if let page = visiblePages.first(where: { $0.page.displayTitle == titleToOpen }) {
                selectedPageIdentifier = page.id
                return
            }
        }
        if let dayToOpenOnNextLoad, let day = visibleDays.first(where: { $0.id == dayToOpenOnNextLoad }) {
            // The day reads from its first lesson.
            selectedPageIdentifier = day.pages.last?.id
            self.dayToOpenOnNextLoad = nil
        } else if selectedPageIdentifier == nil || page(withIdentifier: selectedPageIdentifier!) == nil {
            selectedPageIdentifier = visiblePages.first?.id
        }
    }

    func page(withIdentifier identifier: UUID) -> NotebookStoredPage? {
        days.lazy.flatMap(\.pages).first { $0.id == identifier }
    }

    /// Up and Down move through the pages in the order the sidebar shows.
    func selectNeighbourPage(after offset: Int) {
        let pages = visiblePages
        guard !pages.isEmpty else { return }
        let currentIndex = pages.firstIndex { $0.id == selectedPage?.id } ?? 0
        let nextIndex = min(max(0, currentIndex + offset), pages.count - 1)
        selectedPageIdentifier = pages[nextIndex].id
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
        case .page(let pageIdentifier):
            return everyPage.filter { $0.id == pageIdentifier }
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
        let fileDate = pages.count == 1 || NotebookStore.dayIdentifier(for: pages[0].page.createdAt)
            == NotebookStore.dayIdentifier(for: pages[pages.count - 1].page.createdAt)
            ? pages[0].page.createdAt.formatted(.dateTime.day().month(.abbreviated).year())
            : rangeDescription
        savePanel.nameFieldStringValue = "Buddy notebook, \(fileDate).pdf"
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

    fileprivate func export(pages: [NotebookStoredPage], rangeDescription: String, to destinationURL: URL) {
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

#if DEBUG
extension NotebookModel {
    /// QA channel only: the same background export Export PDF starts, to a
    /// given file instead of the save panel, which a script cannot answer.
    func qaExportToday(to destinationURL: URL) {
        let scope = NotebookExportScope.day(NotebookStore.dayIdentifier(for: Date()))
        let pages = pages(in: scope)
        guard !pages.isEmpty else {
            TutorDebugLog.write("🧪 qa: no notebook pages today to export")
            return
        }
        export(pages: pages, rangeDescription: rangeDescription(for: pages, scope: scope), to: destinationURL)
    }
}
#endif

// MARK: - Views

struct NotebookView: View {
    @ObservedObject var model: NotebookModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            NotebookToolbar(model: model, isSearchFocused: $isSearchFocused)
            Rectangle().fill(Color.black.opacity(0.5)).frame(height: 1)
            HStack(spacing: 0) {
                if model.isSidebarVisible {
                    NotebookSidebar(model: model)
                        .frame(width: 270)
                        .transition(.move(edge: .leading))
                    Rectangle().fill(Color.black.opacity(0.4)).frame(width: 1)
                }
                NotebookPageDetail(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DS.Colors.background)
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.22), value: model.isSidebarVisible)
        .background { keyboardShortcuts }
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

    /// The app has no menu bar (it is a menu bar app), so the window's
    /// command keys are handled here: Command F to search, Command P to
    /// export this page, Command W to close. The plain keys (Up, Down,
    /// Space, Delete) are caught by the controller, only while no text
    /// field is typing, so they never eat a space typed into the search.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { isSearchFocused = true }.keyboardShortcut("f", modifiers: .command)
            Button("") {
                if let page = model.selectedPage { model.beginExport(.page(page.id)) }
            }.keyboardShortcut("p", modifiers: .command)
            Button("") { model.window?.performClose(nil) }.keyboardShortcut("w", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
            ? day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
            : day.date.formatted(.dateTime.day().month(.wide).year())
    }

    static func summary(for day: NotebookDay) -> String {
        let lessons = day.pages.count == 1 ? "1 lesson" : "\(day.pages.count) lessons"
        return "\(lessons) · \(NotebookDocumentHTML.sizeText(day.sizeInBytes))"
    }

    /// The sidebar's second line for a lesson: "14:32 · hash map lookup".
    static func meta(for storedPage: NotebookStoredPage) -> String {
        var parts = [NotebookDocumentHTML.lessonTimeText(storedPage.page.createdAt)]
        if let firstIdea = storedPage.page.ideas.first { parts.append(firstIdea.name) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: Toolbar

/// The unified toolbar: 52pt on the first surface, clear of the window's
/// own buttons at the left.
private struct NotebookToolbar: View {
    @ObservedObject var model: NotebookModel
    var isSearchFocused: FocusState<Bool>.Binding

    private var isExporting: Bool {
        if case .exporting = model.exportStatus { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            NotebookToolbarIconButton(systemImage: "sidebar.left", tooltip: model.isSidebarVisible ? "Hide the list" : "Show the list") {
                model.isSidebarVisible.toggle()
            }
            .accessibilityLabel(model.isSidebarVisible ? "Hide the list of lessons" : "Show the list of lessons")
            Text("Notebook")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            exportStatusLabel
            if let page = model.selectedPage {
                let canReplay = model.canReplay(page)
                NotebookToolbarButton(systemImage: "arrow.counterclockwise", title: "Replay", isEnabled: canReplay,
                                      tooltip: canReplay ? "Draw this lesson again on your screen"
                                                         : "Only your last lesson can be replayed") {
                    model.onReplay(page)
                }
            }
            NotebookToolbarMenuButton(systemImage: "square.and.arrow.up", title: "Export PDF", showsChevron: true,
                                      isEnabled: !isExporting && !model.days.isEmpty) {
                [
                    .init(title: "This page", isEnabled: model.selectedPage != nil) {
                        if let page = model.selectedPage { model.beginExport(.page(page.id)) }
                    },
                    .init(title: "This day", isEnabled: model.selectedDay != nil) {
                        if let day = model.selectedDay { model.beginExport(.day(day.id)) }
                    },
                    .init(title: "A range\u{2026}") { model.isShowingExportSheet = true },
                    .init(title: "Everything") { model.beginExport(.everything) },
                ]
            }
            .accessibilityLabel("Export PDF")
            NotebookToolbarMenuButton(systemImage: "ellipsis", title: nil, showsChevron: false, isEnabled: true) {
                [
                    .init(title: "Show transcripts in Finder") { model.onShowTranscripts() },
                    .init(title: "Keep new lessons", isChecked: model.keepsLessons) { model.keepsLessons.toggle() },
                    .separator,
                    .init(title: "Delete page\u{2026}", isEnabled: model.selectedPage != nil) {
                        if let page = model.selectedPage { model.pendingDeletion = .page(page) }
                    },
                    .init(title: "Delete day\u{2026}", isEnabled: model.selectedDay != nil) {
                        if let day = model.selectedDay { model.pendingDeletion = .day(day) }
                    },
                    .init(title: "Delete all notes\u{2026}", isEnabled: !model.days.isEmpty) { model.pendingDeletion = .everything },
                ]
            }
            .accessibilityLabel("More")
            NotebookSearchField(text: $model.searchText, placeholder: "Search lessons", isFocused: isSearchFocused)
                .frame(width: 260)
        }
        // Clear of the window's close, minimise and zoom buttons.
        .padding(.leading, 84)
        .padding(.trailing, 14)
        .frame(height: 52)
        .background(DS.Colors.surface1)
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
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Show in Finder")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.destructiveText)
                .lineLimit(1)
                .frame(maxWidth: 240)
        }
    }
}

/// A toolbar button's face: white 8%, 14% on hover.
private struct NotebookToolbarButtonLabel: View {
    let systemImage: String
    let title: String?
    let showsChevron: Bool
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundStyle(isEnabled ? DS.Colors.textPrimary : DS.Colors.textDisabled)
        .padding(.horizontal, title == nil ? 10 : 12)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(isHovering && isEnabled ? 0.14 : 0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering }
        }
    }
}

/// A toolbar button that opens a native menu. SwiftUI's own Menu drops the
/// toolbar's fill and chevron in its borderless style, so the button is
/// drawn here and the menu is AppKit's, popped under it.
private struct NotebookToolbarMenuButton: View {
    struct Item {
        var title = ""
        var isEnabled = true
        var isChecked = false
        var isSeparator = false
        var action: () -> Void = {}

        init(title: String, isEnabled: Bool = true, isChecked: Bool = false, action: @escaping () -> Void) {
            self.title = title
            self.isEnabled = isEnabled
            self.isChecked = isChecked
            self.action = action
        }

        private init(separator: Void) { isSeparator = true }
        static let separator = Item(separator: ())
    }

    let systemImage: String
    let title: String?
    let showsChevron: Bool
    let isEnabled: Bool
    let items: () -> [Item]

    var body: some View {
        Button(action: popUpMenu) {
            NotebookToolbarButtonLabel(systemImage: systemImage, title: title, showsChevron: showsChevron)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pointerCursor(isEnabled: isEnabled)
    }

    private func popUpMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var targets: [NotebookMenuActionTarget] = []
        for item in items() {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let target = NotebookMenuActionTarget(action: item.action)
            targets.append(target)
            let menuItem = NSMenuItem(title: item.title, action: #selector(NotebookMenuActionTarget.runMenuAction), keyEquivalent: "")
            menuItem.target = target
            menuItem.isEnabled = item.isEnabled
            menuItem.state = item.isChecked ? NSControl.StateValue.on : NSControl.StateValue.off
            menu.addItem(menuItem)
        }
        // The targets live as long as the menu is open; popUp returns after.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        _ = targets
    }
}

/// Carries a closure as a menu item's action.
private final class NotebookMenuActionTarget: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func runMenuAction() { action() }
}

private struct NotebookToolbarButton: View {
    let systemImage: String
    let title: String
    let isEnabled: Bool
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            NotebookToolbarButtonLabel(systemImage: systemImage, title: title, showsChevron: false)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pointerCursor(isEnabled: isEnabled)
        .nativeTooltip(tooltip)
        .accessibilityLabel(title)
        .accessibilityHint(tooltip)
    }
}

private struct NotebookToolbarIconButton: View {
    let systemImage: String
    let tooltip: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isHovering ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering }
        }
        .nativeTooltip(tooltip)
    }
}

/// The search field both windows use: a magnifier, the text, a clear button.
struct NotebookSearchField: View {
    @Binding var text: String
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.textPrimary)
                .focused(isFocused)
                .onExitCommand { text = "" }
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .nativeTooltip("Clear the search")
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(isFocused.wrappedValue ? DS.Colors.accentText.opacity(0.6) : Color.clear, lineWidth: 1))
    }
}

// MARK: Sidebar

private struct NotebookSidebar: View {
    @ObservedObject var model: NotebookModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.hasLoaded && model.visibleDays.isEmpty {
                    Text(model.searchText.isEmpty ? "No lessons yet." : "No lesson matches \u{201C}\(model.searchText)\u{201D}.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 16)
                }
                ForEach(model.visibleDays) { day in
                    Text(NotebookDayNames.name(for: day))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 16)
                        .padding(.bottom, 6)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(day.pages) { storedPage in
                        NotebookLessonRow(storedPage: storedPage, dayName: NotebookDayNames.name(for: day),
                                          isSelected: storedPage.id == model.selectedPage?.id) {
                            model.selectedPageIdentifier = storedPage.id
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
        .background(DS.Colors.surface1.opacity(0.6))
    }
}

private struct NotebookLessonRow: View {
    let storedPage: NotebookStoredPage
    let dayName: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "book.closed")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(isSelected ? DS.Colors.accentText : DS.Colors.textTertiary)
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(storedPage.page.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(NotebookDayNames.meta(for: storedPage))
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? DS.Colors.accentText.opacity(0.18) : (isHovering ? DS.Notch.rowHover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovering = hovering }
        }
        .accessibilityLabel("\(storedPage.page.displayTitle), \(dayName.lowercased()) \(NotebookDayNames.meta(for: storedPage))")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: Page

private struct NotebookPageDetail: View {
    @ObservedObject var model: NotebookModel

    var body: some View {
        if let storedPage = model.selectedPage, let day = model.days.first(where: { $0.id == storedPage.dayIdentifier }) {
            let pagesOfTheDay = day.pages
            let pageNumber = (pagesOfTheDay.firstIndex { $0.id == storedPage.id } ?? 0) + 1
            NotebookPagesWebView(
                html: NotebookDocumentHTML.windowPageHTML(
                    storedPage: storedPage, pageNumber: pageNumber, pageCount: pagesOfTheDay.count,
                    dayName: NotebookDayNames.name(for: day).lowercased(),
                    canReplay: model.canReplay(storedPage)),
                rootFolder: model.store.rootFolder,
                onAction: { action in handle(action, on: storedPage) }
            )
            .accessibilityLabel("Page, \(storedPage.page.displayTitle)")
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
                     : "Keeping new lessons is turned off. Turn it on in More.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func handle(_ action: NotebookPageAction, on storedPage: NotebookStoredPage) {
        switch action {
        case .teachBack: model.onTeachBack(storedPage)
        case .askFollowUp: model.onAskFollowUp(storedPage)
        case .openIdea(let name): model.onOpenIdea(name)
        case .deletePage: model.pendingDeletion = .page(storedPage)
        }
    }
}

private struct NotebookExportSheet: View {
    @ObservedObject var model: NotebookModel
    private enum Choice: Hashable { case day, range, everything }
    @State private var choice: Choice = .range
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
                Button("Cancel") { model.isShowingExportSheet = false }
                    .buttonStyle(DSTextButtonStyle(fontSize: 13))
                    .keyboardShortcut(.cancelAction)
                Button("Export\u{2026}") {
                    let chosenScope = scope
                    model.isShowingExportSheet = false
                    // The save panel opens as the window's sheet, so it
                    // waits for this sheet to have gone.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        model.beginExport(chosenScope)
                    }
                }
                .buttonStyle(DSPrimaryButtonStyle(isFullWidth: false))
                .disabled(pageCount == 0)
                .keyboardShortcut(.defaultAction)
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

/// What a page's buttons ask the window to do.
enum NotebookPageAction {
    case teachBack, askFollowUp, deletePage
    case openIdea(String)
}

/// One page, as HTML. No scripts, no network, only the notebook's own
/// files; its buttons are links the window acts on.
private struct NotebookPagesWebView: NSViewRepresentable {
    let html: String
    let rootFolder: URL
    let onAction: (NotebookPageAction) -> Void

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
        context.coordinator.onAction = onAction
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: URL(string: "\(NotebookDocumentHTML.fileScheme)://notes/"))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        var onAction: (NotebookPageAction) -> Void = { _ in }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
            if url.scheme == NotebookDocumentHTML.actionScheme {
                switch url.host {
                case "teach-back": onAction(.teachBack)
                case "follow-up": onAction(.askFollowUp)
                case "delete-page": onAction(.deletePage)
                case "open-idea":
                    let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "name" }?.value
                    if let name, !name.isEmpty { onAction(.openIdea(name)) }
                default: break
                }
                return decisionHandler(.cancel)
            }
            // The page itself, loaded from a string. Nothing else is followed.
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}
