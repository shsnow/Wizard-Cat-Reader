import Foundation
import WizardJVMRunner

/// Reads Mihon / Tachiyomi `.tachibk` backups: a gzipped protobuf whose field numbers come from
/// Mihon's `@ProtoNumber` annotations. Only what MokaReader can use is decoded — the library,
/// chapters, read state, history and reading mode; categories, trackers and preferences are
/// ignored without complaint.
enum MihonBackupError: LocalizedError {
    case notABackup
    case noFavorites

    var errorDescription: String? {
        switch self {
            case .notABackup:
                return NSLocalizedString(
                    "El archivo no parece una copia de Mihon o Tachiyomi (.tachibk).",
                    comment: ""
                )
            case .noFavorites:
                return NSLocalizedString(
                    "La copia no contiene series guardadas en la biblioteca.",
                    comment: ""
                )
        }
    }
}

struct MihonBackup {
    struct Chapter {
        var url = ""
        var name = ""
        var scanlator: String?
        var read = false
        var bookmark = false
        var dateUpload: Int64 = 0
        var number: Float?
        var sourceOrder = 0
        var memo: String?
    }

    struct History {
        var url = ""
        var lastRead: Int64 = 0
    }

    /// A library category; `order` is the number BackupManga.categoryOrders points at.
    struct Category {
        var name = ""
        var order: Int64 = 0
    }

    struct Manga {
        var source: Int64 = 0
        var url = ""
        var title = ""
        var artist: String?
        var author: String?
        var summary: String?
        var genres: [String] = []
        var status = 0
        var thumbnailURL: String?
        var dateAdded: Int64 = 0
        var viewer = 0
        var viewerFlags: Int?
        var favorite = true
        var chapters: [Chapter] = []
        var history: [History] = []
        var categoryOrders: [Int64] = []
    }

    var mangas: [Manga] = []
    var sourceNames: [Int64: String] = [:]
    var categories: [Category] = []

    static func decode(_ raw: Data) throws -> MihonBackup {
        var data = raw
        if data.count > 2, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B {
            guard let unzipped = try? TachiJVMCompression.gunzip(data) else {
                throw MihonBackupError.notABackup
            }
            data = unzipped
        }
        var backup = MihonBackup()
        do {
            var reader = ProtobufReader(data)
            while let field = try reader.nextField() {
                switch (field.number, field.value) {
                    case (1, .bytes(let value)):
                        backup.mangas.append(try manga(value))
                    case (2, .bytes(let value)):
                        backup.categories.append(try category(value))
                    case (101, .bytes(let value)):
                        let decoded = try source(value)
                        if decoded.id != 0 { backup.sourceNames[decoded.id] = decoded.name }
                    default:
                        break
                }
            }
        } catch {
            // Truncated or non-protobuf input: not a backup.
            throw MihonBackupError.notABackup
        }
        guard !backup.mangas.isEmpty else { throw MihonBackupError.notABackup }
        return backup
    }

    // MARK: - Messages

    private static func manga(_ data: Data) throws -> Manga {
        var reader = ProtobufReader(data)
        var manga = Manga()
        while let field = try reader.nextField() {
            switch (field.number, field.value) {
                case (1, .varint(let value)): manga.source = Int64(bitPattern: value)
                case (2, .bytes(let value)): manga.url = string(value) ?? ""
                case (3, .bytes(let value)): manga.title = string(value) ?? ""
                case (4, .bytes(let value)): manga.artist = string(value)
                case (5, .bytes(let value)): manga.author = string(value)
                case (6, .bytes(let value)): manga.summary = string(value)
                case (7, .bytes(let value)):
                    if let genre = string(value) { manga.genres.append(genre) }
                case (8, .varint(let value)): manga.status = Int(truncatingIfNeeded: value)
                case (9, .bytes(let value)): manga.thumbnailURL = string(value)
                case (13, .varint(let value)): manga.dateAdded = Int64(bitPattern: value)
                case (14, .varint(let value)): manga.viewer = Int(truncatingIfNeeded: value)
                case (16, .bytes(let value)): manga.chapters.append(try chapter(value))
                // Category references; kotlinx writes repeated varints, but a
                // packed list from another writer decodes the same way.
                case (17, .varint(let value)):
                    manga.categoryOrders.append(Int64(bitPattern: value))
                case (17, .bytes(let value)):
                    manga.categoryOrders.append(contentsOf: packedVarints(value))
                case (100, .varint(let value)): manga.favorite = value != 0
                case (103, .varint(let value)): manga.viewerFlags = Int(truncatingIfNeeded: value)
                case (104, .bytes(let value)): manga.history.append(try history(value))
                default: break
            }
        }
        return manga
    }

    private static func chapter(_ data: Data) throws -> Chapter {
        var reader = ProtobufReader(data)
        var chapter = Chapter()
        while let field = try reader.nextField() {
            switch (field.number, field.value) {
                case (1, .bytes(let value)): chapter.url = string(value) ?? ""
                case (2, .bytes(let value)): chapter.name = string(value) ?? ""
                case (3, .bytes(let value)): chapter.scanlator = string(value)
                case (4, .varint(let value)): chapter.read = value != 0
                case (5, .varint(let value)): chapter.bookmark = value != 0
                case (8, .varint(let value)): chapter.dateUpload = Int64(bitPattern: value)
                case (9, .fixed32(let value)):
                    let number = Float(bitPattern: value)
                    chapter.number = number >= 0 ? number : nil
                case (10, .varint(let value)): chapter.sourceOrder = Int(truncatingIfNeeded: value)
                case (13, .bytes(let value)): chapter.memo = string(value)
                default: break
            }
        }
        return chapter
    }

    private static func history(_ data: Data) throws -> History {
        var reader = ProtobufReader(data)
        var history = History()
        while let field = try reader.nextField() {
            switch (field.number, field.value) {
                case (1, .bytes(let value)): history.url = string(value) ?? ""
                case (2, .varint(let value)): history.lastRead = Int64(bitPattern: value)
                default: break
            }
        }
        return history
    }

    private static func category(_ data: Data) throws -> Category {
        var reader = ProtobufReader(data)
        var category = Category()
        while let field = try reader.nextField() {
            switch (field.number, field.value) {
                case (1, .bytes(let value)): category.name = string(value) ?? ""
                case (2, .varint(let value)): category.order = Int64(bitPattern: value)
                default: break
            }
        }
        return category
    }

    /// Varints packed into one length-delimited field.
    private static func packedVarints(_ data: Data) -> [Int64] {
        var values: [Int64] = []
        var current: UInt64 = 0
        var shift: UInt64 = 0
        for byte in data {
            current |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                values.append(Int64(bitPattern: current))
                current = 0
                shift = 0
            } else {
                shift += 7
                if shift > 63 { return values }
            }
        }
        return values
    }

    private static func source(_ data: Data) throws -> (id: Int64, name: String) {
        var reader = ProtobufReader(data)
        var id: Int64 = 0
        var name = ""
        while let field = try reader.nextField() {
            switch (field.number, field.value) {
                case (1, .bytes(let value)): name = string(value) ?? ""
                case (2, .varint(let value)): id = Int64(bitPattern: value)
                default: break
            }
        }
        return (id, name)
    }

    private static func string(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
    }
}

// MARK: - Import

struct MihonImportSummary {
    var totalFavorites = 0
    var added = 0
    var merged = 0
    var skippedAdult = 0
    var missingSources: [String] = []

    var text: String {
        func local(_ key: String) -> String { NSLocalizedString(key, comment: "") }
        var lines: [String] = []
        let imported = added + merged
        if imported > 0 {
            var line = imported == 1
                ? local("Se importó 1 serie")
                : String(format: local("Se importaron %lld series"), imported)
            if added > 0 && merged > 0 {
                line += String(format: local(" (%lld nuevas, %lld actualizadas)"), added, merged)
            }
            line += local(", con sus capítulos leídos y tu progreso.")
            lines.append(line)
        }
        if skippedAdult > 0 {
            lines.append(
                skippedAdult == 1
                    ? local("1 serie para adultos se omitió.")
                    : String(format: local("%lld series para adultos se omitieron."), skippedAdult)
            )
        }
        if !missingSources.isEmpty {
            var shown = missingSources.prefix(6).joined(separator: ", ")
            if missingSources.count > 6 {
                shown += String(format: local(" y %lld más"), missingSources.count - 6)
            }
            lines.append(
                String(
                    format: local("Para cargar portadas y capítulos nuevos, instala estas extensiones: %@."),
                    shown
                )
            )
        }
        return lines.joined(separator: "\n\n")
    }
}

@MainActor
enum MihonBackupImporter {
    /// Puts the backup's favorites into the library. Existing entries merge: read chapters are
    /// combined, the furthest history wins, and a reading mode already chosen here is kept.
    static func restore(
        _ backup: MihonBackup,
        into library: LibraryStore,
        extensions: ExtensionManager
    ) throws -> MihonImportSummary {
        var summary = MihonImportSummary()
        let installedSources = Set(extensions.allSources.map(\.id))
        var missing: Set<String> = []
        var items: [BackupImportItem] = []

        // The backup's categories, created here on first use and matched by name,
        // so re-importing never duplicates them.
        let categoryNames = Dictionary(
            backup.categories.map { ($0.order, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        var categoryIds: [Int64: String] = [:]
        func resolveCategories(_ orders: [Int64]) -> [String]? {
            var resolved: [String] = []
            for order in orders {
                let id: String?
                if let known = categoryIds[order] {
                    id = known
                } else if let name = categoryNames[order],
                          let category = library.addCategory(named: name) {
                    categoryIds[order] = category.id
                    id = category.id
                } else {
                    id = nil
                }
                if let id, !resolved.contains(id) { resolved.append(id) }
            }
            return resolved.isEmpty ? nil : resolved
        }

        // Mihon's on-device "local source" is sourceId 0: its files live on the Android
        // device, so importing those entries here would only produce dead series.
        for manga in backup.mangas where manga.favorite && manga.source != 0 {
            summary.totalFavorites += 1
            let item = MangaItem(
                sourceId: manga.source,
                url: manga.url,
                title: manga.title,
                thumbnailURL: manga.thumbnailURL,
                author: manga.author,
                artist: manga.artist,
                summary: manga.summary,
                genre: manga.genres.isEmpty ? nil : manga.genres.joined(separator: ", "),
                status: manga.status
            )
            guard !item.url.isEmpty, !item.title.isEmpty else { continue }
            guard ContentFilter.isAllowed(item) else {
                summary.skippedAdult += 1
                continue
            }
            if !installedSources.contains(manga.source) {
                let name = backup.sourceNames[manga.source] ?? ""
                missing.insert(name.isEmpty ? "fuente \(manga.source)" : name)
            }

            // Mihon stores chapters with sourceOrder 0 = newest; MokaReader lists newest first.
            let ordered = manga.chapters.sorted { $0.sourceOrder < $1.sourceOrder }
            let chapters = ordered.map {
                ChapterItem(
                    url: $0.url,
                    name: $0.name,
                    number: $0.number,
                    scanlator: $0.scanlator,
                    dateUpload: $0.dateUpload,
                    memo: $0.memo
                )
            }

            var progress = MangaProgress()
            progress.readChapters = Set(ordered.lazy.filter(\.read).map(\.url))
            let bookmarked = Set(ordered.lazy.filter(\.bookmark).map(\.url))
            progress.bookmarkedChapters = bookmarked.isEmpty ? nil : bookmarked
            if let last = manga.history.max(by: { $0.lastRead < $1.lastRead }), last.lastRead > 0 {
                progress.lastReadChapter = last.url
                progress.lastReadAt = Date(timeIntervalSince1970: TimeInterval(last.lastRead) / 1000)
            }
            progress.readingMode = readingMode(manga.viewerFlags ?? manga.viewer)

            let addedAt = manga.dateAdded > 0
                ? Date(timeIntervalSince1970: TimeInterval(manga.dateAdded) / 1000)
                : Date()
            items.append(
                BackupImportItem(
                    entry: LibraryEntry(
                        manga: item,
                        chapters: chapters,
                        addedAt: addedAt,
                        categories: resolveCategories(manga.categoryOrders)
                    ),
                    progress: progress
                )
            )
        }

        guard !items.isEmpty || summary.skippedAdult > 0 else {
            throw MihonBackupError.noFavorites
        }
        let result = library.applyImport(items)
        summary.added = result.added
        summary.merged = result.merged
        summary.missingSources = missing.sorted()
        return summary
    }

    /// Mihon's per-manga viewer values. In Mihon, `viewerFlags` also carries the orientation
    /// (bits 3 and up); only the low three bits are the reading mode. Old Tachiyomi backups put
    /// the bare mode (0–5) in `viewer`, which the mask leaves unchanged.
    private static func readingMode(_ viewer: Int) -> ReadingMode? {
        guard viewer > 0 else { return nil }
        switch viewer & 0x7 {
            case 1: return .leftToRight
            case 2: return .rightToLeft
            case 3, 4, 5: return .webtoon
            default: return nil
        }
    }
}
