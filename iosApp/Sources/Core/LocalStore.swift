import Foundation
import UIKit
import ZIPFoundation

/// The pseudo-source of comics imported on the device.
enum LocalSource {
    static let sourceId: Int64 = -9_000

    /// Stands in for an installed extension, so the library, the continue row and the
    /// reader treat local series like any other. The engine is never called with it:
    /// every local read is intercepted before reaching the JVM.
    static let installedExtension = InstalledExtension(
        id: "local",
        name: "En este iPhone",
        versionName: "1.0",
        versionCode: 1,
        iconURL: nil,
        jarFileName: "",
        nsfw: false,
        repositoryURL: nil,
        sources: []
    )
}

/// Comics imported as CBZ/ZIP archives: one folder per series under Documents/Comics,
/// one archive per chapter. Chapters are listed from disk and pages extracted to a
/// cache on demand, so local reading works with the extension engine off.
///
/// Identifiers are relative ("local:/<series>/<file>") because the app container's
/// absolute path changes across reinstalls and restores.
@MainActor
final class LocalStore {
    static let shared = LocalStore()
    private init() {}

    nonisolated static var root: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Comics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private nonisolated static var pagesCache: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalPages", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated static let archiveExtensions: Set<String> = ["cbz", "zip"]
    private nonisolated static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "avif", "jxl",
    ]

    enum LocalError: LocalizedError {
        case notAnArchive(String)
        case noImages(String)
        case nothingImported

        var errorDescription: String? {
            switch self {
                case .notAnArchive(let name):
                    return String(
                        format: NSLocalizedString("%@ no es un archivo CBZ/ZIP válido.", comment: ""),
                        name
                    )
                case .noImages(let name):
                    return String(
                        format: NSLocalizedString("%@ no contiene imágenes.", comment: ""),
                        name
                    )
                case .nothingImported:
                    return NSLocalizedString("No se pudo importar ningún archivo.", comment: "")
            }
        }
    }

    // MARK: - Identifiers

    nonisolated static func mangaItem(folderName: String) -> MangaItem {
        MangaItem(
            sourceId: LocalSource.sourceId,
            url: "local:/\(folderName)",
            title: folderName,
            thumbnailURL: "local-cover:/\(folderName)",
            author: nil,
            artist: nil,
            summary: nil,
            genre: nil,
            status: 0
        )
    }

    nonisolated static func folderName(of manga: MangaItem) -> String? {
        guard manga.isLocal, manga.url.hasPrefix("local:/") else { return nil }
        return String(manga.url.dropFirst("local:/".count))
    }

    nonisolated static func seriesURL(of manga: MangaItem) -> URL? {
        folderName(of: manga).map { root.appendingPathComponent($0, isDirectory: true) }
    }

    private nonisolated static func archiveURL(of chapter: ChapterItem) -> URL? {
        guard chapter.url.hasPrefix("local:/") else { return nil }
        let relative = String(chapter.url.dropFirst("local:/".count))
        guard let separator = relative.lastIndex(of: "/") else { return nil }
        let folder = String(relative[..<separator])
        let file = String(relative[relative.index(after: separator)...])
        guard !folder.isEmpty, !file.isEmpty else { return nil }
        return root
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(file)
    }

    // MARK: - Chapters

    /// The series' archives as chapters, newest (highest number) first, the same
    /// convention sources use.
    nonisolated static func chapters(for manga: MangaItem) -> [ChapterItem] {
        guard let folderName = folderName(of: manga), let folder = seriesURL(of: manga) else {
            return []
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let archives = files
            .filter { archiveExtensions.contains($0.pathExtension.lowercased()) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
        let items = archives.enumerated().map { offset, url -> ChapterItem in
            let name = url.deletingPathExtension().lastPathComponent
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return ChapterItem(
                url: "local:/\(folderName)/\(url.lastPathComponent)",
                name: name,
                number: chapterNumber(in: name) ?? Float(offset + 1),
                scanlator: nil,
                dateUpload: Int64((modified?.timeIntervalSince1970 ?? 0) * 1000),
                memo: nil
            )
        }
        return items.reversed()
    }

    /// The first number in the file name ("Tomo 2 Cap 12.5" → 2 would mislead, but
    /// most collections put the chapter number first; files without one keep disk order).
    private nonisolated static func chapterNumber(in name: String) -> Float? {
        var current = ""
        for character in name {
            if character.isWholeNumber {
                current.append(character)
            } else if character == "." || character == ",", !current.isEmpty,
                      !current.contains(".") {
                current.append(".")
            } else if !current.isEmpty {
                break
            }
        }
        let trimmed = current.hasSuffix(".") ? String(current.dropLast()) : current
        return Float(trimmed)
    }

    // MARK: - Pages

    /// Lists and extracts the chapter's images into the page cache. Blocking I/O and
    /// decompression: call it off the main actor.
    nonisolated static func pages(for chapter: ChapterItem) throws -> [PageItem] {
        guard let archiveURL = archiveURL(of: chapter) else {
            throw LocalError.notAnArchive(chapter.name)
        }
        let cacheDirectory = pagesCache.appendingPathComponent(
            ImagePipeline.hash(chapter.url), isDirectory: true
        )
        let marker = cacheDirectory.appendingPathComponent("complete")

        // A finished extraction is reused: the marker holds the page count, so a cache
        // iOS purged halfway (some .img gone, marker kept) is re-extracted instead of
        // coming back silently shorter.
        if let markerText = try? String(contentsOf: marker, encoding: .utf8),
           let expected = Int(markerText.trimmingCharacters(in: .whitespacesAndNewlines)),
           expected > 0,
           let cached = try? FileManager.default.contentsOfDirectory(
               at: cacheDirectory, includingPropertiesForKeys: nil
           ) {
            let images = cached
                .filter { $0.pathExtension == "img" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if images.count == expected {
                return images.enumerated().map { offset, url in
                    PageItem(index: offset, url: chapter.url, imageURL: nil, localURL: url)
                }
            }
        }

        guard let archive = try? Archive(url: archiveURL, accessMode: .read) else {
            throw LocalError.notAnArchive(archiveURL.lastPathComponent)
        }
        let entries = archive
            .filter { entry in
                guard entry.type == .file else { return false }
                let path = entry.path
                let name = (path as NSString).lastPathComponent
                guard !path.hasPrefix("__MACOSX"), !name.hasPrefix(".") else { return false }
                return imageExtensions.contains((name as NSString).pathExtension.lowercased())
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !entries.isEmpty else {
            throw LocalError.noImages(archiveURL.lastPathComponent)
        }

        try? FileManager.default.removeItem(at: cacheDirectory)
        try FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true
        )
        var pages: [PageItem] = []
        for (index, entry) in entries.enumerated() {
            let file = cacheDirectory.appendingPathComponent(String(format: "%04d.img", index))
            _ = try archive.extract(entry, to: file)
            pages.append(PageItem(index: index, url: chapter.url, imageURL: nil, localURL: file))
        }
        FileManager.default.createFile(atPath: marker.path, contents: Data("\(pages.count)".utf8))
        return pages
    }

    // MARK: - Covers

    nonisolated static func coverData(for manga: MangaItem) -> Data? {
        guard let folder = seriesURL(of: manga) else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent("cover.jpg"))
    }

    /// Writes cover.jpg from the first page of the first chapter, if missing.
    nonisolated static func ensureCover(for manga: MangaItem) {
        guard let folder = seriesURL(of: manga) else { return }
        let coverURL = folder.appendingPathComponent("cover.jpg")
        guard !FileManager.default.fileExists(atPath: coverURL.path) else { return }
        guard
            let first = chapters(for: manga).last,
            let firstPage = (try? pages(for: first))?.first,
            let localURL = firstPage.localURL,
            let data = try? Data(contentsOf: localURL),
            let image = ImagePipeline.decode(data, maxWidth: 600),
            let jpeg = image.jpegData(compressionQuality: 0.82)
        else { return }
        try? jpeg.write(to: coverURL, options: .atomic)
    }

    // MARK: - Import

    /// Copies the picked archives into the series folder and returns the series.
    /// Files that are not readable ZIPs with images are skipped; importing into an
    /// existing series adds the files as new chapters. Blocking I/O (copies, ZIP
    /// validation and the cover extraction): call it off the main actor.
    nonisolated static func importArchives(_ urls: [URL], seriesTitle: String) throws -> MangaItem {
        let title = Self.sanitizedTitle(seriesTitle)
        let folder = Self.root.appendingPathComponent(title, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var imported = 0
        var firstProblem: Error?
        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            var destination = folder.appendingPathComponent(source.lastPathComponent)
            var counter = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                let base = source.deletingPathExtension().lastPathComponent
                destination = folder.appendingPathComponent(
                    "\(base) (\(counter)).\(source.pathExtension)"
                )
                counter += 1
            }
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                try Self.validateArchive(at: destination)
                imported += 1
            } catch {
                try? FileManager.default.removeItem(at: destination)
                if firstProblem == nil { firstProblem = error }
            }
        }
        guard imported > 0 else {
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: folder)
            }
            throw firstProblem ?? LocalError.nothingImported
        }
        let manga = Self.mangaItem(folderName: title)
        Self.ensureCover(for: manga)
        return manga
    }

    private nonisolated static func validateArchive(at url: URL) throws {
        guard let archive = try? Archive(url: url, accessMode: .read) else {
            throw LocalError.notAnArchive(url.lastPathComponent)
        }
        let hasImage = archive.contains { entry in
            let name = (entry.path as NSString).lastPathComponent
            return entry.type == .file &&
                !entry.path.hasPrefix("__MACOSX") &&
                !name.hasPrefix(".") &&
                imageExtensions.contains((name as NSString).pathExtension.lowercased())
        }
        guard hasImage else { throw LocalError.noImages(url.lastPathComponent) }
    }

    private nonisolated static func sanitizedTitle(_ value: String) -> String {
        let cleaned = value
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Serie local" : cleaned
    }

    /// A readable series name guessed from a file name: extension and trailing
    /// chapter counters removed.
    nonisolated static func suggestedTitle(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        for marker in [" cap ", " cap.", " capitulo ", " capítulo ", " ch ", " ch.", " chapter ", " vol ", " vol.", " #", " - "] {
            if let range = name.range(of: marker, options: [.caseInsensitive]) {
                name = String(name[..<range.lowerBound])
            }
        }
        while let last = name.last, last.isWholeNumber || last == " " || last == "-" || last == "_" {
            name.removeLast()
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? url.deletingPathExtension().lastPathComponent : trimmed
    }

    // MARK: - Removal

    nonisolated static func deleteSeriesFiles(for manga: MangaItem) {
        guard let folder = seriesURL(of: manga) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Bundled sample

    private static let sampleSeededKey = "localSampleSeeded"
    private static let sampleTitle = "Guía de Wizard Cat"

    /// The guide comic's library identity, to tell whether it is still there.
    nonisolated static var sampleManga: MangaItem { mangaItem(folderName: sampleTitle) }

    /// Puts the guide comic back after the user removed it (Ajustes → Acerca de).
    func restoreSample(library: LibraryStore) {
        UserDefaults.standard.set(false, forKey: Self.sampleSeededKey)
        seedSampleIfNeeded(library: library)
    }

    /// On first launch the bundled guide comic joins the library, so the app has
    /// readable content out of the box. Removing it is final: it is not re-seeded
    /// on its own, only through `restoreSample`.
    func seedSampleIfNeeded(library: LibraryStore) {
        let defaults = UserDefaults.standard
        let key = Self.sampleSeededKey
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        guard let bundled = Bundle.main.url(forResource: "guia-wizard-cat", withExtension: "cbz")
        else { return }
        Task {
            // The copy and the cover extraction are blocking I/O: off the main actor.
            let seeded = await Task.detached { () -> (MangaItem, [ChapterItem])? in
                let title = Self.sampleTitle
                let folder = Self.root.appendingPathComponent(title, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(
                        at: folder, withIntermediateDirectories: true
                    )
                    let destination = folder.appendingPathComponent("Guía de Wizard Cat 1.cbz")
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.copyItem(at: bundled, to: destination)
                    }
                    let manga = Self.mangaItem(folderName: title)
                    Self.ensureCover(for: manga)
                    return (manga, Self.chapters(for: manga))
                } catch {
                    // The sample is a nicety; a failed copy never blocks startup.
                    return nil
                }
            }.value
            guard let (manga, chapters) = seeded, !library.contains(manga) else { return }
            library.add(manga, chapters: chapters)
        }
    }
}
