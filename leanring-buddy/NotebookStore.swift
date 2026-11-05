//
//  NotebookStore.swift
//  leanring-buddy
//
//  The notebook on disk: every finished lesson kept as a page, one folder
//  per day, in ~/Library/Application Support/Buddy/Notebook.
//
//      Notebook/
//        2026-11-05/
//          143012-1f9a3c2e/
//            page.json      what was asked, said and learned
//            card-1.svg     each card drawn, as vectors
//            screen.jpg     the marked part of the screen, marks drawn in
//
//  page.json is written last, so a page whose writing was interrupted has no
//  page.json, is never shown, and is swept away the next time the notebook
//  is read. Nothing here leaves the Mac; the PDF export is the only way out,
//  and only to where the student saves it.
//
//  Plain files rather than a database, so the student can see exactly what
//  is kept (the Notebook window shows each page's size) and delete it with
//  confidence: a deleted page is a deleted folder.
//

import Foundation

/// One lesson as a notebook page.
nonisolated struct NotebookPage: Codable, Equatable, Identifiable {
    struct Card: Codable, Equatable {
        var fileName: String
        /// The card's size in the screenshot's pixels, for its proportions.
        var widthInPixels: Double
        var heightInPixels: Double
        var title: String?
    }

    struct ScreenCrop: Codable, Equatable {
        var fileName: String
        var widthInPixels: Int
        var heightInPixels: Int
    }

    /// An idea the lesson covered, as learning memory filed it.
    struct Idea: Codable, Equatable {
        var name: String
        var summary: String
        /// Days until the student is estimated to have a 90% chance of still
        /// remembering it (FSRS stability), when the page was written.
        var stabilityDays: Double
        /// When the forgetting curve says it is worth looking at again.
        var reviewAround: Date
    }

    var id: UUID
    var createdAt: Date
    var lessonTitle: String?
    var question: String
    /// What was said, one paragraph per beat of the lesson.
    var paragraphs: [String]
    var cards: [Card]
    var screenCrop: ScreenCrop?
    var ideas: [Idea]
    var answeredBy: String?
    var formatVersion: Int = 1

    /// The lesson's own name when it gave one, the question otherwise.
    var displayTitle: String {
        if let lessonTitle, !lessonTitle.trimmingCharacters(in: .whitespaces).isEmpty { return lessonTitle }
        // Speech recognition hears questions in lower case; a title starts
        // with a capital.
        return question.prefix(1).uppercased() + question.dropFirst()
    }

    /// The earliest of the ideas' review dates: by then the first of them is
    /// starting to fade.
    var reviewAgainAround: Date? {
        ideas.map(\.reviewAround).min()
    }
}

/// A page as found on disk.
nonisolated struct NotebookStoredPage: Identifiable, Equatable {
    let page: NotebookPage
    let folder: URL
    let sizeInBytes: Int
    let dayIdentifier: String

    var id: UUID { page.id }

    func fileURL(_ fileName: String) -> URL { folder.appendingPathComponent(fileName) }

    /// Where a file of this page sits relative to the notebook folder, which
    /// is how the notebook's pages refer to it.
    func relativePath(of fileName: String) -> String {
        "\(dayIdentifier)/\(folder.lastPathComponent)/\(fileName)"
    }
}

/// One day of the notebook.
nonisolated struct NotebookDay: Identifiable, Equatable {
    /// "2026-11-05", which is also the folder's name.
    let id: String
    let date: Date
    /// Oldest first, the order they were learned in.
    var pages: [NotebookStoredPage]

    var sizeInBytes: Int { pages.reduce(0) { $0 + $1.sizeInBytes } }
}

nonisolated final class NotebookStore: @unchecked Sendable {
    static let pageFileName = "page.json"

    /// ~/Library/Application Support/Buddy/Notebook.
    @MainActor static var standardRootFolder: URL {
        AppIdentity.supportFolder.appendingPathComponent("Notebook", isDirectory: true)
    }

    let rootFolder: URL
    private let fileManager = FileManager.default
    /// Writes and deletes happen one at a time, off the main thread, so a
    /// page being written is never half deleted.
    private let fileQueue = DispatchQueue(label: "buddy.notebook.files")

    init(rootFolder: URL) {
        self.rootFolder = rootFolder
    }

    // MARK: - Names

    static func dayIdentifier(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func date(fromDayIdentifier dayIdentifier: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dayIdentifier)
    }

    private static func pageFolderName(for page: NotebookPage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HHmmss"
        let shortIdentifier = page.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "\(formatter.string(from: page.createdAt))-\(shortIdentifier)"
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Writing

    /// Writes a page with its cards and screen crop, and returns the page as
    /// stored. Off the main thread.
    func write(page: NotebookPage, cardSVGTexts: [String], screenCropJPEGData: Data?) async throws -> NotebookStoredPage {
        try await onFileQueue {
            let dayIdentifier = Self.dayIdentifier(for: page.createdAt)
            let dayFolder = self.rootFolder.appendingPathComponent(dayIdentifier, isDirectory: true)
            let pageFolder = dayFolder.appendingPathComponent(Self.pageFolderName(for: page), isDirectory: true)
            try self.fileManager.createDirectory(at: pageFolder, withIntermediateDirectories: true)
            for (cardIndex, card) in page.cards.enumerated() where cardIndex < cardSVGTexts.count {
                try Data(cardSVGTexts[cardIndex].utf8).write(to: pageFolder.appendingPathComponent(card.fileName), options: .atomic)
            }
            if let screenCrop = page.screenCrop, let screenCropJPEGData {
                try screenCropJPEGData.write(to: pageFolder.appendingPathComponent(screenCrop.fileName), options: .atomic)
            }
            // Last: its presence is what makes the folder a page.
            try Self.jsonEncoder.encode(page).write(to: pageFolder.appendingPathComponent(Self.pageFileName), options: .atomic)
            return NotebookStoredPage(page: page, folder: pageFolder,
                                      sizeInBytes: self.sizeOfFolder(pageFolder), dayIdentifier: dayIdentifier)
        }
    }

    /// Adds the ideas learning memory filed for a page once it was written.
    /// Filing runs alongside the lesson and often finishes after it.
    func updateIdeas(_ ideas: [NotebookPage.Idea], ofPageIn pageFolder: URL) async {
        try? await onFileQueue {
            let pageFile = pageFolder.appendingPathComponent(Self.pageFileName)
            guard let data = try? Data(contentsOf: pageFile),
                  var page = try? Self.jsonDecoder.decode(NotebookPage.self, from: data) else { return }
            page.ideas = ideas
            try Self.jsonEncoder.encode(page).write(to: pageFile, options: .atomic)
        }
    }

    // MARK: - Reading

    /// Every day with at least one page, newest day first, pages oldest
    /// first within a day. Folders left by an interrupted write are removed.
    func loadDays() async -> [NotebookDay] {
        (try? await onFileQueue { self.readDaysFromDisk() }) ?? []
    }

    private func readDaysFromDisk() -> [NotebookDay] {
        guard let dayFolders = try? fileManager.contentsOfDirectory(
            at: rootFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var days: [NotebookDay] = []
        for dayFolder in dayFolders {
            let dayIdentifier = dayFolder.lastPathComponent
            guard let dayDate = Self.date(fromDayIdentifier: dayIdentifier) else { continue }
            let pageFolders = (try? fileManager.contentsOfDirectory(
                at: dayFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            var pages: [NotebookStoredPage] = []
            for pageFolder in pageFolders {
                let pageFile = pageFolder.appendingPathComponent(Self.pageFileName)
                guard let data = try? Data(contentsOf: pageFile),
                      let page = try? Self.jsonDecoder.decode(NotebookPage.self, from: data) else {
                    // No page.json: a write that never finished. Only swept
                    // once it is clearly not one in progress right now.
                    if let modified = try? pageFolder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       Date().timeIntervalSince(modified) > 600 {
                        try? fileManager.removeItem(at: pageFolder)
                    }
                    continue
                }
                pages.append(NotebookStoredPage(page: page, folder: pageFolder,
                                                sizeInBytes: sizeOfFolder(pageFolder), dayIdentifier: dayIdentifier))
            }
            guard !pages.isEmpty else {
                if pageFolders.isEmpty { try? fileManager.removeItem(at: dayFolder) }
                continue
            }
            pages.sort { $0.page.createdAt < $1.page.createdAt }
            days.append(NotebookDay(id: dayIdentifier, date: dayDate, pages: pages))
        }
        return days.sorted { $0.id > $1.id }
    }

    private func sizeOfFolder(_ folder: URL) -> Int {
        let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: - Deleting

    func deletePage(_ storedPage: NotebookStoredPage) async {
        try? await onFileQueue {
            try? self.fileManager.removeItem(at: storedPage.folder)
            let dayFolder = storedPage.folder.deletingLastPathComponent()
            let remaining = (try? self.fileManager.contentsOfDirectory(atPath: dayFolder.path))?
                .filter { !$0.hasPrefix(".") } ?? []
            if remaining.isEmpty { try? self.fileManager.removeItem(at: dayFolder) }
        }
    }

    func deleteDay(_ dayIdentifier: String) async {
        guard Self.date(fromDayIdentifier: dayIdentifier) != nil else { return }
        try? await onFileQueue {
            try? self.fileManager.removeItem(at: self.rootFolder.appendingPathComponent(dayIdentifier, isDirectory: true))
        }
    }

    /// The whole notebook folder, every day and page in it.
    func deleteEverything() async {
        try? await onFileQueue {
            try? self.fileManager.removeItem(at: self.rootFolder)
        }
    }

    // MARK: -

    private func onFileQueue<Value>(_ work: @escaping () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            fileQueue.async {
                continuation.resume(with: Swift.Result<Value, Error>(catching: work))
            }
        }
    }
}
