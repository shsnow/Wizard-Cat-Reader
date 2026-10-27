import Combine
import Foundation

/// Refreshes every library entry against its source, one at a time — the extension engine is
/// serial anyway — and remembers which chapters are new so the Novedades list can flag them.
@MainActor
final class LibraryUpdater: ObservableObject {
    static let shared = LibraryUpdater()

    @Published private(set) var isRefreshing = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var newChapters = 0
    @Published private(set) var lastFinished: Date?
    /// URLs of the chapters the latest update discovered.
    @Published private(set) var lastNewURLs: Set<String> = []

    private var task: Task<Void, Never>?
    private var cancelRequested = false

    private init() {
        // The "Nuevo" labels and the last-update summary survive app restarts.
        lastFinished = UserDefaults.standard.object(forKey: "updaterLastFinished") as? Date
        if let stored = UserDefaults.standard.array(forKey: "updaterLastNewURLs") as? [String] {
            lastNewURLs = Set(stored)
        }
    }

    /// Fire-and-forget, for the toolbar button and the library's pull-to-refresh.
    /// `only` limits the update to those entry ids (one category); nil updates everything.
    func refreshAll(
        library: LibraryStore,
        extensions: ExtensionManager,
        only ids: Set<String>? = nil
    ) {
        guard !isRefreshing else { return }
        task = Task { [weak self] in
            await self?.refresh(library: library, extensions: extensions, only: ids)
            self?.task = nil
        }
    }

    /// Awaits until the whole update finishes, for pull-to-refresh.
    func refresh(
        library: LibraryStore,
        extensions: ExtensionManager,
        only ids: Set<String>? = nil
    ) async {
        guard !isRefreshing else { return }
        var entries = library.sortedEntries
        if let ids { entries = entries.filter { ids.contains($0.manga.id) } }
        guard !entries.isEmpty else { return }
        isRefreshing = true
        cancelRequested = false
        completed = 0
        newChapters = 0
        total = entries.count
        var discovered: Set<String> = []

        for entry in entries {
            if Task.isCancelled || cancelRequested { break }
            defer { completed += 1 }
            // Imported series have no site to check.
            if entry.manga.isLocal { continue }
            guard let installed = extensions.extensionFor(sourceId: entry.manga.sourceId) else {
                continue
            }
            do {
                // Background lane: the update must not hold up whatever is on screen.
                let result = try await JVMEngine.shared.details(
                    of: entry.manga, installed: installed, priority: .background
                )
                // The entry's URL is its identity: a source that rotated its slug must
                // not detach the series, its progress, or its download records.
                var freshManga = result.manga
                freshManga.url = entry.manga.url
                let known = Set(entry.chapters.map(\.url))
                // A rotated URL is not a new chapter: a known chapter number keeps it
                // out of the badge and of the automatic download.
                let knownNumbers = Set(entry.chapters.compactMap(\.number).filter { $0 >= 0 })
                let fresh = result.chapters.filter { chapter in
                    guard !known.contains(chapter.url) else { return false }
                    if let number = chapter.number, number >= 0 {
                        return !knownNumbers.contains(number)
                    }
                    return true
                }
                newChapters += fresh.count
                discovered.formUnion(fresh.map(\.url))
                // Optional auto-download, oldest first so the queue follows reading order.
                // An entry with no chapter list yet is skipped: there "new" would mean the
                // whole series.
                if AppSettings.shared.autoDownloadUpdates, !known.isEmpty, !fresh.isEmpty {
                    // Don't auto-download duplicates the scanlator preference hides.
                    let visible = Set(
                        LibraryStore.applyScanlatorPreference(
                            result.chapters,
                            preferred: library.preferredScanlator(for: entry.manga)
                        ).map(\.url)
                    )
                    let wanted = fresh.filter { visible.contains($0.url) }
                    if !wanted.isEmpty {
                        DownloadManager.shared.enqueue(
                            Array(wanted.reversed()), manga: freshManga, installed: installed
                        )
                    }
                }
                library.refresh(freshManga, chapters: result.chapters)
            } catch {
                // A source that is down should not stop the rest of the update.
                continue
            }
        }
        if !discovered.isEmpty {
            // A category update adds its finds to the "Nuevo" labels of the last full one.
            if ids != nil {
                lastNewURLs.formUnion(discovered)
            } else {
                lastNewURLs = discovered
            }
            UserDefaults.standard.set(Array(discovered), forKey: "updaterLastNewURLs")
        }
        isRefreshing = false
        lastFinished = Date()
        UserDefaults.standard.set(lastFinished, forKey: "updaterLastFinished")
    }

    func cancel() {
        cancelRequested = true
        task?.cancel()
    }
}
