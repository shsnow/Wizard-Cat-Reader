import Combine
import Foundation
import UIKit

struct DownloadedChapter: Codable, Hashable {
    var mangaId: String
    var mangaTitle: String
    var chapterURL: String
    var chapterName: String
    var folderName: String
    var pageCount: Int
    var bytes: Int64
    var date: Date
}

struct DownloadJob: Identifiable, Hashable, Codable {
    let manga: MangaItem
    let chapter: ChapterItem
    let installed: InstalledExtension

    var id: String { DownloadManager.key(manga: manga, chapter: chapter) }
}

enum DownloadState: Equatable {
    case none
    case queued
    case downloading(Double)
    case downloaded
    case failed(String)
}

/// Saves chapters to disk so they can be read without a connection.
///
/// Downloads run one chapter at a time and keep going after the user leaves the app (on iOS 26
/// with progress in the system UI, earlier only for a short window). The queue is kept on disk:
/// when iOS stops it, it resumes on return or on the next launch.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var downloaded: [String: DownloadedChapter]
    @Published private(set) var queue: [DownloadJob] = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var failures: [String: String] = [:]
    /// Jobs that failed, kept so the Descargas screen can show and retry them.
    @Published private(set) var failedJobs: [DownloadJob] = []

    private var worker: Task<Void, Never>?
    private var currentJob: String?
    /// Keeps the queue running in the background; one per stretch of work, nil when idle.
    private var run: BackgroundRun?
    /// Chapters finished since `run` started, for its progress.
    private var runDone = 0
    /// Set when iOS ends the background time: the current chapter stays queued.
    private var pausedByBackground = false

    private static let indexFile = "downloads.json"
    private static let queueFile = "downloadQueue.json"

    static var root: URL {
        var url = Storage.supportDirectory.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // Downloads can be fetched again; keep them out of the user's iCloud backup.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return url
    }

    private init() {
        downloaded = Storage.load([String: DownloadedChapter].self, from: Self.indexFile) ?? [:]
        // Forget entries whose folder disappeared.
        let missing = downloaded.filter { !FileManager.default.fileExists(atPath: Self.root.appendingPathComponent($0.value.folderName).path) }
        if !missing.isEmpty {
            for key in missing.keys { downloaded[key] = nil }
            save()
        }
    }

    nonisolated static func key(manga: MangaItem, chapter: ChapterItem) -> String {
        "\(manga.id)#\(chapter.url)"
    }

    // MARK: - State

    func state(manga: MangaItem, chapter: ChapterItem) -> DownloadState {
        let key = Self.key(manga: manga, chapter: chapter)
        if downloaded[key] != nil { return .downloaded }
        if let value = progress[key] { return .downloading(value) }
        if queue.contains(where: { $0.id == key }) { return .queued }
        if let message = failures[key] { return .failed(message) }
        return .none
    }

    func isDownloaded(manga: MangaItem, chapter: ChapterItem) -> Bool {
        downloaded[Self.key(manga: manga, chapter: chapter)] != nil
    }

    /// Pages read from disk, or nil when the chapter is not downloaded.
    func localPages(manga: MangaItem, chapter: ChapterItem) -> [PageItem]? {
        guard let record = downloaded[Self.key(manga: manga, chapter: chapter)] else { return nil }
        let folder = Self.root.appendingPathComponent(record.folderName, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        let images = files.filter { $0.pathExtension == "img" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !images.isEmpty else { return nil }
        return images.enumerated().map { offset, url in
            PageItem(index: offset, url: "", imageURL: nil, localURL: url)
        }
    }

    var totalBytes: Int64 {
        downloaded.values.reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Queue

    func enqueue(_ chapters: [ChapterItem], manga: MangaItem, installed: InstalledExtension) {
        guard !manga.isLocal else { return }
        for chapter in chapters {
            let job = DownloadJob(manga: manga, chapter: chapter, installed: installed)
            guard downloaded[job.id] == nil, !queue.contains(where: { $0.id == job.id }) else { continue }
            failures[job.id] = nil
            failedJobs.removeAll { $0.id == job.id }
            queue.append(job)
        }
        saveQueue()
        reportProgress()
        startIfNeeded()
    }

    func retry(_ job: DownloadJob) {
        enqueue([job.chapter], manga: job.manga, installed: job.installed)
    }

    func dismissFailure(_ job: DownloadJob) {
        failedJobs.removeAll { $0.id == job.id }
        failures[job.id] = nil
    }

    func cancel(_ job: DownloadJob) {
        queue.removeAll { $0.id == job.id }
        progress[job.id] = nil
        saveQueue()
        reportProgress()
        if currentJob == job.id {
            worker?.cancel()
        }
    }

    func cancelAll() {
        queue.removeAll()
        progress.removeAll()
        saveQueue()
        worker?.cancel()
    }

    func delete(manga: MangaItem, chapter: ChapterItem) {
        delete(key: Self.key(manga: manga, chapter: chapter))
    }

    func delete(key: String) {
        guard let record = downloaded[key] else { return }
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(record.folderName))
        downloaded[key] = nil
        save()
    }

    func deleteAll(mangaId: String? = nil) {
        for (key, record) in downloaded where mangaId == nil || record.mangaId == mangaId {
            try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(record.folderName))
            downloaded[key] = nil
        }
        save()
    }

    // MARK: - Worker

    /// Picks up downloads iOS stopped in the background, or that were queued when the app
    /// closed. Each job takes the extension as installed now (it may have been updated); jobs
    /// whose extension is gone are dropped.
    func resumeIfInterrupted(extensions: ExtensionManager) {
        guard worker == nil else { return }
        let stored = queue.isEmpty
            ? (Storage.load([DownloadJob].self, from: Self.queueFile) ?? [])
            : queue
        var seen: Set<String> = []
        queue = stored.compactMap { job in
            guard downloaded[job.id] == nil, seen.insert(job.id).inserted,
                  let installed = extensions.extensionFor(sourceId: job.manga.sourceId)
            else { return nil }
            return DownloadJob(manga: job.manga, chapter: job.chapter, installed: installed)
        }
        saveQueue()
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        pausedByBackground = false
        if run == nil {
            runDone = 0
            run = BackgroundRun(
                kind: "downloads",
                title: NSLocalizedString("Descargando capítulos", comment: ""),
                subtitle: progressText(done: 0, of: queue.count),
                total: queue.count * 100
            ) { [weak self] in
                self?.pauseForBackground()
            }
        }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let job = queue.first, !pausedByBackground {
            currentJob = job.id
            progress[job.id] = 0
            reportProgress()
            do {
                try await download(job)
                failures[job.id] = nil
            } catch let error where error is CancellationError || Task.isCancelled {
                // Cancelled by the user (URLSession reports it as URLError.cancelled; the job was
                // already removed from the queue) or paused by iOS (the job stays queued).
            } catch {
                failures[job.id] = error.localizedDescription
                failedJobs.removeAll { $0.id == job.id }
                failedJobs.append(job)
            }
            progress[job.id] = nil
            currentJob = nil
            if pausedByBackground { break }
            if queue.contains(where: { $0.id == job.id }) {
                queue.removeAll { $0.id == job.id }
                runDone += 1
            }
            saveQueue()
            reportProgress()
            if Task.isCancelled {
                // A single cancel stops only the current job; keep going if others remain.
                worker = nil
                if !queue.isEmpty { startIfNeeded() } else { finishRun() }
                return
            }
        }
        worker = nil
        if pausedByBackground {
            // Stopped by iOS, but the user may already be back: carry on right away.
            if UIApplication.shared.applicationState == .active { startIfNeeded() }
        } else {
            finishRun()
        }
    }

    /// iOS is ending the background time: stop now, keep the queue for later.
    private func pauseForBackground() {
        pausedByBackground = true
        // The background run has already ended on its side.
        run = nil
        worker?.cancel()
        Storage.flush()
    }

    private func finishRun() {
        run?.finish(success: true)
        run = nil
        runDone = 0
    }

    /// Progress in hundredths of a chapter, so the system bar moves within long chapters too.
    private func reportProgress() {
        guard let run else { return }
        let total = runDone + queue.count
        let partial = currentJob.flatMap { progress[$0] } ?? 0
        let done = runDone + (currentJob == nil ? 0 : 1)
        run.update(
            completed: runDone * 100 + Int(partial * 100),
            total: total * 100,
            subtitle: progressText(done: min(done, total), of: total)
        )
    }

    private func progressText(done: Int, of total: Int) -> String {
        String(format: NSLocalizedString("%lld de %lld capítulos", comment: ""), done, total)
    }

    private func download(_ job: DownloadJob) async throws {
        let pages = try await JVMEngine.shared.pages(
            of: job.chapter, manga: job.manga, installed: job.installed, priority: .background
        )
        guard !pages.isEmpty else { throw EngineError.host("El capítulo no tiene páginas.") }

        let folderName = String(ImagePipeline.hash(job.id).prefix(24))
        let final = Self.root.appendingPathComponent(folderName, isDirectory: true)
        let partial = Self.root.appendingPathComponent(folderName + ".partial", isDirectory: true)
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)

        var bytes: Int64 = 0
        var completed = 0
        // A few pages at a time: the image downloads overlap, while the extension engine still
        // serializes its own part of each request.
        let batchSize = AppSettings.shared.downloadBatch
        do {
            for start in stride(from: 0, to: pages.count, by: batchSize) {
                try Task.checkCancellation()
                let batch = Array(pages[start..<min(start + batchSize, pages.count)])
                let results = try await withThrowingTaskGroup(of: (Int, Data).self, returning: [(Int, Data)].self) { group in
                    for (offset, page) in batch.enumerated() {
                        let position = start + offset
                        group.addTask {
                            let data = try await ImagePipeline.shared.pageData(
                                page, sourceId: job.manga.sourceId, installed: job.installed,
                                priority: .background
                            )
                            return (position, data)
                        }
                    }
                    var collected: [(Int, Data)] = []
                    for try await item in group { collected.append(item) }
                    return collected
                }
                for (position, data) in results {
                    let file = partial.appendingPathComponent(String(format: "%04d.img", position))
                    try data.write(to: file, options: .atomic)
                    bytes += Int64(data.count)
                }
                completed += results.count
                progress[job.id] = Double(completed) / Double(pages.count)
                reportProgress()
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }

        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: partial, to: final)
        downloaded[job.id] = DownloadedChapter(
            mangaId: job.manga.id,
            mangaTitle: job.manga.title,
            chapterURL: job.chapter.url,
            chapterName: job.chapter.name,
            folderName: folderName,
            pageCount: pages.count,
            bytes: bytes,
            date: Date()
        )
        save()
    }

    private func save() {
        Storage.save(downloaded, to: Self.indexFile)
    }

    private func saveQueue() {
        Storage.save(queue, to: Self.queueFile)
    }
}

extension Int64 {
    var byteText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // "0 KB" instead of the spelled-out "Zero KB".
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: self)
    }
}
