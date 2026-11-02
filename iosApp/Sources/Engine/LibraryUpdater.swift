import Combine
import Foundation
import UIKit

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
    /// Set when iOS, not the user, stopped the update: what was left resumes on return.
    private var stoppedByBackground = false
    private static let pendingKey = "updaterPendingIDs"

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
        stoppedByBackground = false
        completed = 0
        newChapters = 0
        total = entries.count
        var discovered: Set<String> = []
        // Until the run ends, the entries not yet checked are on disk: if iOS ends the app
        // mid-update, the next launch picks up from there.
        var pending = entries.map(\.manga.id)
        UserDefaults.standard.set(pending, forKey: Self.pendingKey)

        // Keeps going when the user leaves the app (on iOS 26 with progress in the system UI).
        let background = BackgroundRun(
            title: NSLocalizedString("Actualizando biblioteca", comment: ""),
            subtitle: progressText(done: 0, of: entries.count),
            total: entries.count
        ) { [weak self] in
            self?.stoppedByBackground = true
            self?.cancelRequested = true
        }

        for entry in entries {
            if Task.isCancelled || cancelRequested { break }
            defer {
                completed += 1
                pending.removeFirst()
                UserDefaults.standard.set(pending, forKey: Self.pendingKey)
                background.update(
                    completed: completed, subtitle: progressText(done: completed, of: total)
                )
            }
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
        background.finish(success: !cancelRequested)
        if !stoppedByBackground {
            // Finished, or cancelled on purpose: nothing to resume.
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        }
        lastFinished = Date()
        UserDefaults.standard.set(lastFinished, forKey: "updaterLastFinished")
        // Stopped in the background but the user is already back: carry on right away.
        if stoppedByBackground && UIApplication.shared.applicationState == .active {
            resumeIfInterrupted(library: library, extensions: extensions)
        }
    }

    /// Picks up an update that iOS stopped in the background (or that was running when the
    /// app was closed), with only the series still unchecked.
    func resumeIfInterrupted(library: LibraryStore, extensions: ExtensionManager) {
        guard !isRefreshing,
              let stored = UserDefaults.standard.array(forKey: Self.pendingKey) as? [String]
        else { return }
        // Series removed from the library since then have nothing left to check.
        let inLibrary = Set(library.sortedEntries.map(\.manga.id))
        let ids = Set(stored).intersection(inLibrary)
        guard !ids.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            return
        }
        refreshAll(library: library, extensions: extensions, only: ids)
    }

    private func progressText(done: Int, of total: Int) -> String {
        String(format: NSLocalizedString("%lld de %lld series", comment: ""), done, total)
    }

    func cancel() {
        cancelRequested = true
        stoppedByBackground = false
        task?.cancel()
    }
}
