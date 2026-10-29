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

struct DownloadJob: Identifiable, Hashable {
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
/// Downloads run one chapter at a time while the app is open; iOS grants a short extra window
/// when the app goes to the background, and the queue resumes from where it stopped.
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
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private static let indexFile = "downloads.json"

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
        if currentJob == job.id {
            worker?.cancel()
        }
    }

    func cancelAll() {
        queue.removeAll()
        progress.removeAll()
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

    private func startIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        beginBackgroundWindow()
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let job = queue.first {
            currentJob = job.id
            progress[job.id] = 0
            do {
                try await download(job)
                failures[job.id] = nil
            } catch let error where error is CancellationError || Task.isCancelled {
                // Cancelled by the user (URLSession reports it as URLError.cancelled); the job was
                // already removed from the queue.
            } catch {
                failures[job.id] = error.localizedDescription
                failedJobs.removeAll { $0.id == job.id }
                failedJobs.append(job)
            }
            progress[job.id] = nil
            queue.removeAll { $0.id == job.id }
            currentJob = nil
            if Task.isCancelled {
                // A single cancel stops only the current job; keep going if others remain.
                worker = nil
                if !queue.isEmpty { startIfNeeded() } else { endBackgroundWindow() }
                return
            }
        }
        worker = nil
        endBackgroundWindow()
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

    private func beginBackgroundWindow() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MokaReader downloads") {
            Task { @MainActor in DownloadManager.shared.endBackgroundWindow() }
        }
    }

    private func endBackgroundWindow() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
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
