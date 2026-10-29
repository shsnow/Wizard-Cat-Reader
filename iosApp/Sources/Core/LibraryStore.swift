import Combine
import Foundation
// Array.move(fromOffsets:toOffset:) is declared in SwiftUI, not the standard library.
import SwiftUI

struct LibraryEntry: Codable, Hashable {
    var manga: MangaItem
    var chapters: [ChapterItem]
    var addedAt: Date
    var note: String? = nil
    /// Ids of the user's categories this series belongs to.
    var categories: [String]? = nil
}

struct LibraryCategory: Codable, Hashable, Identifiable {
    var id: String
    var name: String
}

/// One "opened a chapter" event, newest first. The manga snapshot lets History navigate
/// even when the series is no longer in the library.
struct ReadingRecord: Codable, Hashable, Identifiable {
    var manga: MangaItem
    var chapterURL: String
    var chapterName: String
    var date: Date

    var id: String { "\(manga.id)#\(chapterURL)#\(date.timeIntervalSince1970)" }
}

struct BackupImportItem {
    var entry: LibraryEntry
    var progress: MangaProgress
}

struct MangaProgress: Codable, Hashable {
    var readChapters: Set<String> = []
    var lastReadChapter: String?
    var lastReadAt: Date?
    var readingMode: ReadingMode?
    /// Accumulated seconds spent in the reader for this series.
    var readSeconds: Double? = nil
    /// Chapters the user starred to come back to.
    var bookmarkedChapters: Set<String>? = nil
    /// When a series has the same chapter from several groups, keep this one.
    var preferredScanlator: String? = nil
}

/// The user's library and reading progress. Progress is kept for every manga opened, not only
/// those in the library, so reading something before saving it does not lose your place.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var entries: [String: LibraryEntry]
    @Published private(set) var progress: [String: MangaProgress]
    @Published private(set) var history: [ReadingRecord]
    @Published private(set) var categories: [LibraryCategory]

    private static let libraryFile = "library.json"
    private static let progressFile = "progress.json"
    private static let historyFile = "history.json"
    private static let categoriesFile = "categories.json"
    private static let pagesFile = "pages.json"

    /// The page each unfinished chapter was left on, keyed "mangaId#chapterURL". Not
    /// @Published on purpose: it changes on every page turn, and nothing on screen shows it,
    /// so publishing it would redraw the reader (and the library) at every page.
    private var pagePositions: [String: Int]
    private static let historyLimit = 300

    private init() {
        entries = Storage.load([String: LibraryEntry].self, from: Self.libraryFile) ?? [:]
        progress = Storage.load([String: MangaProgress].self, from: Self.progressFile) ?? [:]
        history = Storage.load([ReadingRecord].self, from: Self.historyFile) ?? []
        categories = Storage.load([LibraryCategory].self, from: Self.categoriesFile) ?? []
        pagePositions = Storage.load([String: Int].self, from: Self.pagesFile) ?? [:]
    }

    // MARK: - Page within a chapter

    private static func pageKey(_ chapterURL: String, in manga: MangaItem) -> String {
        "\(manga.id)#\(chapterURL)"
    }

    /// The page to reopen the chapter on: where it was left, unless it was finished.
    func resumePage(for chapter: ChapterItem, in manga: MangaItem) -> Int {
        guard !isRead(chapter, in: manga) else { return 0 }
        return pagePositions[Self.pageKey(chapter.url, in: manga)] ?? 0
    }

    /// Raw saved page, for backups (Mihon's lastPageRead).
    func savedPage(chapterURL: String, in manga: MangaItem) -> Int? {
        pagePositions[Self.pageKey(chapterURL, in: manga)]
    }

    /// Remembers the page the reader is on; page 0 forgets it.
    func setPage(_ page: Int, chapter: ChapterItem, in manga: MangaItem) {
        setPage(page, chapterURL: chapter.url, in: manga)
    }

    func setPage(_ page: Int, chapterURL: String, in manga: MangaItem) {
        let key = Self.pageKey(chapterURL, in: manga)
        // A finished chapter reopens from the start; its page is not worth keeping.
        let finished = progress[manga.id]?.readChapters.contains(chapterURL) ?? false
        let value = page > 0 && !finished ? page : nil
        guard pagePositions[key] != value else { return }
        pagePositions[key] = value
        Storage.save(pagePositions, to: Self.pagesFile)
    }

    /// A finished chapter reopens from the start.
    private func forgetPages(_ chapterURLs: [String], in manga: MangaItem) {
        var changed = false
        for url in chapterURLs where pagePositions.removeValue(forKey: Self.pageKey(url, in: manga)) != nil {
            changed = true
        }
        if changed { Storage.save(pagePositions, to: Self.pagesFile) }
    }

    var sortedEntries: [LibraryEntry] {
        entries.values.sorted {
            let left = progress[$0.manga.id]?.lastReadAt ?? $0.addedAt
            let right = progress[$1.manga.id]?.lastReadAt ?? $1.addedAt
            return left > right
        }
    }

    func contains(_ manga: MangaItem) -> Bool {
        entries[manga.id] != nil
    }

    func entry(for manga: MangaItem) -> LibraryEntry? {
        entries[manga.id]
    }

    func add(_ manga: MangaItem, chapters: [ChapterItem]) {
        entries[manga.id] = LibraryEntry(manga: manga, chapters: chapters, addedAt: Date())
        saveLibrary()
    }

    func remove(_ manga: MangaItem) {
        if manga.isLocal { LocalStore.deleteSeriesFiles(for: manga) }
        entries[manga.id] = nil
        saveLibrary()
    }

    /// Keeps a library entry's details and chapter list current after a refresh.
    func refresh(_ manga: MangaItem, chapters: [ChapterItem]) {
        guard var entry = entries[manga.id] else { return }
        entry.manga = manga
        if !chapters.isEmpty {
            reconcileProgress(for: manga, from: entry.chapters, to: chapters)
            entry.chapters = chapters
        }
        entries[manga.id] = entry
        saveLibrary()
    }

    /// Progress is keyed by chapter URL, and some sources rotate their URLs: without
    /// this, a refresh would silently mark everything unread. Marks whose URL vanished
    /// migrate to the new chapter with the same number (preferring the same scanlator),
    /// or failing that the same name — the same reconciliation Mihon performs.
    private func reconcileProgress(
        for manga: MangaItem,
        from old: [ChapterItem],
        to new: [ChapterItem]
    ) {
        guard var value = progress[manga.id], !old.isEmpty else { return }
        let newUrls = Set(new.map(\.url))
        var tracked = value.readChapters
        tracked.formUnion(value.bookmarkedChapters ?? [])
        if let last = value.lastReadChapter { tracked.insert(last) }
        let lost = tracked.subtracting(newUrls)
        guard !lost.isEmpty else { return }

        let oldByUrl = Dictionary(old.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        func replacement(for chapter: ChapterItem) -> ChapterItem? {
            if let number = chapter.number, number >= 0 {
                let candidates = new.filter { $0.number == number }
                if let exact = candidates.first(where: { $0.scanlator == chapter.scanlator }) {
                    return exact
                }
                if let first = candidates.first { return first }
            }
            return new.first { $0.name == chapter.name }
        }

        var changed = false
        for url in lost {
            guard let oldChapter = oldByUrl[url], let target = replacement(for: oldChapter) else {
                continue
            }
            if value.readChapters.remove(url) != nil {
                value.readChapters.insert(target.url)
                changed = true
            }
            if value.bookmarkedChapters?.remove(url) != nil {
                value.bookmarkedChapters?.insert(target.url)
                changed = true
            }
            if value.lastReadChapter == url {
                value.lastReadChapter = target.url
                changed = true
            }
        }
        if changed {
            progress[manga.id] = value
            saveProgress()
        }
    }

    func unreadCount(for entry: LibraryEntry) -> Int {
        let read = progress[entry.manga.id]?.readChapters ?? []
        return effectiveChapters(of: entry).filter { !read.contains($0.url) }.count
    }

    func isRead(_ chapter: ChapterItem, in manga: MangaItem) -> Bool {
        progress[manga.id]?.readChapters.contains(chapter.url) ?? false
    }

    func lastRead(in manga: MangaItem) -> String? {
        progress[manga.id]?.lastReadChapter
    }

    func setRead(_ read: Bool, chapter: ChapterItem, in manga: MangaItem) {
        var value = progress[manga.id] ?? MangaProgress()
        if read {
            value.readChapters.insert(chapter.url)
            forgetPages([chapter.url], in: manga)
        } else {
            value.readChapters.remove(chapter.url)
        }
        progress[manga.id] = value
        saveProgress()
    }

    func markOpened(_ chapter: ChapterItem, in manga: MangaItem) {
        var value = progress[manga.id] ?? MangaProgress()
        value.lastReadChapter = chapter.url
        value.lastReadAt = Date()
        progress[manga.id] = value
        saveProgress()

        // Reopening the same chapter refreshes its entry instead of stacking duplicates.
        if let first = history.first, first.manga.id == manga.id, first.chapterURL == chapter.url {
            history[0].date = Date()
        } else {
            history.insert(
                ReadingRecord(manga: manga, chapterURL: chapter.url, chapterName: chapter.name, date: Date()),
                at: 0
            )
            if history.count > Self.historyLimit {
                history.removeLast(history.count - Self.historyLimit)
            }
        }
        Storage.save(history, to: Self.historyFile)
    }

    func clearHistory() {
        history = []
        Storage.save(history, to: Self.historyFile)
    }

    func deleteHistoryRecord(_ record: ReadingRecord) {
        history.removeAll { $0.id == record.id }
        Storage.save(history, to: Self.historyFile)
    }

    // MARK: - Reading time

    func addReadingTime(_ seconds: TimeInterval, to manga: MangaItem) {
        guard seconds >= 5 else { return }
        if UserDefaults.standard.object(forKey: "readingSince") == nil {
            UserDefaults.standard.set(Date(), forKey: "readingSince")
        }
        var value = progress[manga.id] ?? MangaProgress()
        value.readSeconds = (value.readSeconds ?? 0) + seconds
        progress[manga.id] = value
        saveProgress()
    }

    /// When reading-time tracking started on this device.
    var readingSince: Date? {
        UserDefaults.standard.object(forKey: "readingSince") as? Date
    }

    var totalReadSeconds: Double {
        progress.values.reduce(0) { $0 + ($1.readSeconds ?? 0) }
    }

    /// Series ranked by time read, most first. Series no longer in the library are looked up
    /// in the history snapshots so their title and cover still show.
    var readingRanking: [(manga: MangaItem, seconds: Double)] {
        let snapshots = Dictionary(history.map { ($0.manga.id, $0.manga) }) { first, _ in first }
        return progress
            .compactMap { id, value -> (manga: MangaItem, seconds: Double)? in
                guard let seconds = value.readSeconds, seconds >= 60 else { return nil }
                guard let manga = entries[id]?.manga ?? snapshots[id] else { return nil }
                return (manga: manga, seconds: seconds)
            }
            .sorted { $0.seconds > $1.seconds }
    }

    static func timeText(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes) m" }
        return "\(minutes / 60) h \(minutes % 60) m"
    }

    /// "1 h 37 m" for the series, or nil under a minute.
    func readingTimeText(for manga: MangaItem) -> String? {
        let seconds = progress[manga.id]?.readSeconds ?? 0
        guard seconds >= 60 else { return nil }
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes) m" }
        return "\(minutes / 60) h \(minutes % 60) m"
    }

    func note(for manga: MangaItem) -> String {
        entries[manga.id]?.note ?? ""
    }

    func setNote(_ note: String, for manga: MangaItem) {
        guard var entry = entries[manga.id] else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.note = trimmed.isEmpty ? nil : trimmed
        entries[manga.id] = entry
        saveLibrary()
    }

    /// A library entry's chapters stamped with their series, for the Novedades list.
    var latestUploads: [(manga: MangaItem, chapter: ChapterItem)] {
        entries.values
            .flatMap { entry in entry.chapters.map { (manga: entry.manga, chapter: $0) } }
            .filter { $0.1.dateUpload > 0 }
            .sorted { $0.1.dateUpload > $1.1.dateUpload }
            .prefix(150)
            .map { $0 }
    }

    /// The chapter "Continuar" should open: the last one opened if unfinished, otherwise the next.
    func continueChapter(in entry: LibraryEntry) -> ChapterItem? {
        let ordered = Array(effectiveChapters(of: entry).reversed())
        guard !ordered.isEmpty else { return nil }
        if let last = progress[entry.manga.id]?.lastReadChapter,
           let index = ordered.firstIndex(where: { $0.url == last }) {
            if !isRead(ordered[index], in: entry.manga) { return ordered[index] }
            // The first unread chapter after the last one opened, skipping any read out of order.
            if let next = ordered[(index + 1)...].first(where: { !isRead($0, in: entry.manga) }) {
                return next
            }
            return ordered[index]
        }
        return ordered.first { !isRead($0, in: entry.manga) } ?? ordered.first
    }

    /// Moves an entry to the same series on another source. Read chapters, favorites and the
    /// last-read position carry over matched by chapter number; the note, categories and
    /// reading time move as they are. Downloads of the old source are left on disk.
    func migrate(from old: MangaItem, to new: MangaItem, chapters newChapters: [ChapterItem]) {
        guard old.id != new.id, let oldEntry = entries[old.id] else { return }
        let oldProgress = progress[old.id]

        func numbers(of urls: Set<String>) -> Set<Float> {
            // -1 is Tachiyomi's "no number" sentinel; it must not match across sources.
            Set(
                oldEntry.chapters
                    .filter { urls.contains($0.url) }
                    .compactMap(\.number)
                    .filter { $0 >= 0 }
            )
        }
        func urls(matching numbers: Set<Float>) -> Set<String> {
            Set(newChapters.filter { $0.number.map(numbers.contains) == true }.map(\.url))
        }

        var moved = MangaProgress()
        moved.readChapters = urls(matching: numbers(of: oldProgress?.readChapters ?? []))
        if let bookmarked = oldProgress?.bookmarkedChapters, !bookmarked.isEmpty {
            let mapped = urls(matching: numbers(of: bookmarked))
            moved.bookmarkedChapters = mapped.isEmpty ? nil : mapped
        }
        moved.readSeconds = oldProgress?.readSeconds
        moved.readingMode = oldProgress?.readingMode
        moved.lastReadAt = oldProgress?.lastReadAt
        if let lastURL = oldProgress?.lastReadChapter,
           let number = oldEntry.chapters.first(where: { $0.url == lastURL })?.number,
           number >= 0,
           let match = newChapters.first(where: { $0.number == number }) {
            moved.lastReadChapter = match.url
        }

        entries[new.id] = LibraryEntry(
            manga: new,
            chapters: newChapters,
            addedAt: oldEntry.addedAt,
            note: oldEntry.note,
            categories: oldEntry.categories
        )
        progress[new.id] = moved
        entries[old.id] = nil
        progress[old.id] = nil
        saveLibrary()
        saveProgress()
    }

    // MARK: - Scanlator preference

    func preferredScanlator(for manga: MangaItem) -> String? {
        progress[manga.id]?.preferredScanlator
    }

    func setPreferredScanlator(_ scanlator: String?, for manga: MangaItem) {
        var value = progress[manga.id] ?? MangaProgress()
        value.preferredScanlator = scanlator
        progress[manga.id] = value
        saveProgress()
    }

    /// Drops duplicate chapters from other groups when the preferred one covers that number.
    /// Chapters without a number, and numbers the preferred group never released, stay.
    static func applyScanlatorPreference(
        _ chapters: [ChapterItem],
        preferred: String?
    ) -> [ChapterItem] {
        guard let preferred, !preferred.isEmpty else { return chapters }
        // Sources without numbering report -1 (Tachiyomi's sentinel); those never collide.
        let covered = Set(
            chapters
                .filter { $0.scanlator == preferred }
                .compactMap(\.number)
                .filter { $0 >= 0 }
        )
        guard !covered.isEmpty else { return chapters }
        return chapters.filter { chapter in
            guard let number = chapter.number, number >= 0, covered.contains(number) else {
                return true
            }
            return chapter.scanlator == preferred
        }
    }

    /// The entry's chapters as the detail view shows them, with the scanlator preference applied.
    func effectiveChapters(of entry: LibraryEntry) -> [ChapterItem] {
        Self.applyScanlatorPreference(
            entry.chapters,
            preferred: progress[entry.manga.id]?.preferredScanlator
        )
    }

    // MARK: - Custom covers

    /// Bumped whenever a custom cover changes, so the cover views reload.
    @Published private(set) var coverVersion = 0

    static var customCoversDirectory: URL {
        let url = Storage.supportDirectory.appendingPathComponent(
            "CustomCovers", isDirectory: true
        )
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func customCoverURL(for manga: MangaItem) -> URL? {
        let url = Self.customCoversDirectory
            .appendingPathComponent(ImagePipeline.hash(manga.id) + ".jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func setCustomCover(_ data: Data, for manga: MangaItem) {
        let url = Self.customCoversDirectory
            .appendingPathComponent(ImagePipeline.hash(manga.id) + ".jpg")
        try? data.write(to: url, options: .atomic)
        coverVersion += 1
    }

    func removeCustomCover(for manga: MangaItem) {
        guard let url = customCoverURL(for: manga) else { return }
        try? FileManager.default.removeItem(at: url)
        coverVersion += 1
    }

    func readingMode(for manga: MangaItem, fallback: ReadingMode) -> ReadingMode {
        if let stored = progress[manga.id]?.readingMode { return stored }
        return manga.looksLikeWebtoon ? .webtoon : fallback
    }

    func setReadingMode(_ mode: ReadingMode, for manga: MangaItem) {
        var value = progress[manga.id] ?? MangaProgress()
        value.readingMode = mode
        progress[manga.id] = value
        saveProgress()
    }

    // MARK: - Categories

    @discardableResult
    func addCategory(named name: String) -> LibraryCategory? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = categories.first(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return existing
        }
        let category = LibraryCategory(id: UUID().uuidString, name: trimmed)
        categories.append(category)
        saveCategories()
        return category
    }

    func renameCategory(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[index].name = trimmed
        saveCategories()
    }

    func deleteCategory(_ id: String) {
        categories.removeAll { $0.id == id }
        saveCategories()
        for (key, entry) in entries where entry.categories?.contains(id) == true {
            var updated = entry
            updated.categories?.removeAll { $0 == id }
            entries[key] = updated
        }
        saveLibrary()
    }

    func moveCategories(from offsets: IndexSet, to destination: Int) {
        categories.move(fromOffsets: offsets, toOffset: destination)
        saveCategories()
    }

    func isInCategory(_ entryId: String, _ categoryId: String) -> Bool {
        entries[entryId]?.categories?.contains(categoryId) ?? false
    }

    /// Replaces the categories of one series (the category picker's answer).
    func setCategories(_ ids: [String], for manga: MangaItem) {
        guard var entry = entries[manga.id] else { return }
        entry.categories = ids.isEmpty ? nil : ids
        entries[manga.id] = entry
        saveLibrary()
    }

    /// Adds the category to every given entry; if all of them already have it, removes it instead.
    func toggleCategory(_ categoryId: String, forEntries ids: [String]) {
        let present = ids.filter { isInCategory($0, categoryId) }
        let adding = present.count != ids.count
        for id in ids {
            guard var entry = entries[id] else { continue }
            var set = entry.categories ?? []
            set.removeAll { $0 == categoryId }
            if adding { set.append(categoryId) }
            entry.categories = set.isEmpty ? nil : set
            entries[id] = entry
        }
        saveLibrary()
    }

    // MARK: - Bulk actions

    /// Marks every chapter of the given entries read or unread, saving once.
    func bulkSetRead(_ read: Bool, entryIds: [String]) {
        for id in entryIds {
            guard let entry = entries[id] else { continue }
            var value = progress[id] ?? MangaProgress()
            if read {
                value.readChapters.formUnion(entry.chapters.map(\.url))
            } else {
                value.readChapters = []
            }
            progress[id] = value
        }
        saveProgress()
    }

    func isBookmarked(_ chapter: ChapterItem, in manga: MangaItem) -> Bool {
        progress[manga.id]?.bookmarkedChapters?.contains(chapter.url) ?? false
    }

    /// Adds the bookmark to every given chapter; if all already have it, removes it instead.
    func toggleBookmark(chapterURLs: [String], in manga: MangaItem) {
        var value = progress[manga.id] ?? MangaProgress()
        var set = value.bookmarkedChapters ?? []
        let adding = !chapterURLs.allSatisfy(set.contains)
        if adding {
            set.formUnion(chapterURLs)
        } else {
            set.subtract(chapterURLs)
        }
        value.bookmarkedChapters = set.isEmpty ? nil : set
        progress[manga.id] = value
        saveProgress()
    }

    /// Marks the given chapters of one series, saving once.
    func setRead(_ read: Bool, chapterURLs: [String], in manga: MangaItem) {
        var value = progress[manga.id] ?? MangaProgress()
        if read {
            value.readChapters.formUnion(chapterURLs)
            forgetPages(chapterURLs, in: manga)
        } else {
            value.readChapters.subtract(chapterURLs)
        }
        progress[manga.id] = value
        saveProgress()
    }

    func removeEntries(ids: [String]) {
        for id in ids {
            if let manga = entries[id]?.manga, manga.isLocal {
                LocalStore.deleteSeriesFiles(for: manga)
            }
            entries[id] = nil
        }
        saveLibrary()
    }

    private func saveCategories() {
        Storage.save(categories, to: Self.categoriesFile)
    }

    /// Merges a Mihon backup in one pass: existing read chapters are kept, the furthest
    /// history wins, and a reading mode already chosen in MokaReader is not overwritten.
    func applyImport(_ items: [BackupImportItem]) -> (added: Int, merged: Int) {
        var added = 0
        var merged = 0
        for item in items {
            let id = item.entry.manga.id
            if var existing = entries[id] {
                // What is already here was fetched live and is at least as current as the
                // backup, which may be months old: keep it, and only fill in a chapter list
                // that is missing entirely. Replacing a fresher list would drop chapters
                // added since the backup was taken.
                if existing.chapters.isEmpty { existing.chapters = item.entry.chapters }
                // Categories union: the backup's assignments join the local ones.
                if let incoming = item.entry.categories, !incoming.isEmpty {
                    var combined = existing.categories ?? []
                    for categoryId in incoming where !combined.contains(categoryId) {
                        combined.append(categoryId)
                    }
                    existing.categories = combined
                }
                entries[id] = existing
                merged += 1
            } else {
                entries[id] = item.entry
                added += 1
            }
            var current = progress[id] ?? MangaProgress()
            current.readChapters.formUnion(item.progress.readChapters)
            if let at = item.progress.lastReadAt, at > (current.lastReadAt ?? .distantPast) {
                current.lastReadAt = at
                current.lastReadChapter = item.progress.lastReadChapter ?? current.lastReadChapter
            }
            if current.readingMode == nil { current.readingMode = item.progress.readingMode }
            if let bookmarks = item.progress.bookmarkedChapters, !bookmarks.isEmpty {
                var set = current.bookmarkedChapters ?? []
                set.formUnion(bookmarks)
                current.bookmarkedChapters = set
            }
            progress[id] = current
        }
        saveLibrary()
        saveProgress()
        return (added, merged)
    }

    private func saveLibrary() {
        Storage.save(entries, to: Self.libraryFile)
    }

    private func saveProgress() {
        Storage.save(progress, to: Self.progressFile)
    }
}
