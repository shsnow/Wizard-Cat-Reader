import Foundation
import WizardJVMRunner

/// Minimal protobuf wire-format writer, the counterpart of ProtobufReader.
private struct ProtobufWriter {
    var data = Data()

    mutating func varint(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }

    private mutating func tag(_ field: UInt64, wire: UInt64) {
        varint(field << 3 | wire)
    }

    mutating func field(_ number: UInt64, varint value: UInt64) {
        tag(number, wire: 0)
        varint(value)
    }

    mutating func field(_ number: UInt64, bool value: Bool) {
        field(number, varint: value ? 1 : 0)
    }

    mutating func field(_ number: UInt64, int64 value: Int64) {
        field(number, varint: UInt64(bitPattern: value))
    }

    mutating func field(_ number: UInt64, float value: Float) {
        tag(number, wire: 5)
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    mutating func field(_ number: UInt64, bytes value: Data) {
        tag(number, wire: 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    mutating func field(_ number: UInt64, string value: String) {
        field(number, bytes: Data(value.utf8))
    }

    mutating func message(_ number: UInt64, _ build: (inout ProtobufWriter) -> Void) {
        var inner = ProtobufWriter()
        build(&inner)
        field(number, bytes: inner.data)
    }
}

/// Writes the library as a Mihon-compatible `.tachibk`: the same `@ProtoNumber` fields the
/// decoder reads, so a MokaReader backup restores in Mihon and its forks.
@MainActor
enum MihonBackupExport {
    static func make(library: LibraryStore, extensions: ExtensionManager) throws -> Data {
        let entries = library.sortedEntries
        var writer = ProtobufWriter()
        var sourceIds: Set<Int64> = []

        // Categories travel with the backup: each one's position is the "order"
        // that BackupManga.categories (field 17) points at, the same way Mihon does.
        var categoryOrder: [String: Int] = [:]
        for (index, category) in library.categories.enumerated() {
            categoryOrder[category.id] = index
            writer.message(2) { backupCategory in
                backupCategory.field(1, string: category.name)
                backupCategory.field(2, varint: UInt64(index))
            }
        }

        for entry in entries {
            let manga = entry.manga
            // Imported series live as files on this device; Mihon could not restore them.
            if manga.isLocal { continue }
            let progress = library.progress[manga.id]
            sourceIds.insert(manga.sourceId)

            writer.message(1) { backupManga in
                backupManga.field(1, int64: manga.sourceId)
                backupManga.field(2, string: manga.url)
                backupManga.field(3, string: manga.title)
                if let artist = manga.artist, !artist.isEmpty { backupManga.field(4, string: artist) }
                if let author = manga.author, !author.isEmpty { backupManga.field(5, string: author) }
                if let summary = manga.summary, !summary.isEmpty { backupManga.field(6, string: summary) }
                for genre in manga.genres { backupManga.field(7, string: genre) }
                backupManga.field(8, varint: UInt64(max(manga.status, 0)))
                if let thumbnail = manga.thumbnailURL, !thumbnail.isEmpty {
                    backupManga.field(9, string: thumbnail)
                }
                backupManga.field(13, int64: Int64(entry.addedAt.timeIntervalSince1970 * 1000))
                for categoryId in entry.categories ?? [] {
                    if let order = categoryOrder[categoryId] {
                        backupManga.field(17, varint: UInt64(order))
                    }
                }

                // Chapters are stored newest first; sourceOrder 0 = newest, as Mihon expects.
                for (index, chapter) in entry.chapters.enumerated() {
                    backupManga.message(16) { backupChapter in
                        backupChapter.field(1, string: chapter.url)
                        backupChapter.field(2, string: chapter.name)
                        if let scanlator = chapter.scanlator, !scanlator.isEmpty {
                            backupChapter.field(3, string: scanlator)
                        }
                        if progress?.readChapters.contains(chapter.url) == true {
                            backupChapter.field(4, bool: true)
                        }
                        if progress?.bookmarkedChapters?.contains(chapter.url) == true {
                            backupChapter.field(5, bool: true)
                        }
                        if let page = library.savedPage(chapterURL: chapter.url, in: manga), page > 0 {
                            backupChapter.field(6, int64: Int64(page))
                        }
                        if chapter.dateUpload > 0 {
                            backupChapter.field(8, int64: chapter.dateUpload)
                        }
                        backupChapter.field(9, float: chapter.number ?? -1)
                        backupChapter.field(10, varint: UInt64(index))
                    }
                }

                backupManga.field(100, bool: true)
                if let mode = progress?.readingMode {
                    backupManga.field(103, varint: Self.viewerFlags(mode))
                }
                if let lastChapter = progress?.lastReadChapter, let lastAt = progress?.lastReadAt {
                    backupManga.message(104) { history in
                        history.field(1, string: lastChapter)
                        history.field(2, int64: Int64(lastAt.timeIntervalSince1970 * 1000))
                    }
                }
            }
        }

        for sourceId in sourceIds.sorted() {
            writer.message(101) { source in
                source.field(1, string: extensions.source(id: sourceId)?.name ?? "")
                source.field(2, int64: sourceId)
            }
        }

        return try TachiJVMCompression.gzip(writer.data)
    }

    static func suggestedFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "wizardcatreader_\(formatter.string(from: Date())).tachibk"
    }

    /// Mihon's per-manga viewer values: 1 LTR, 2 RTL, 4 webtoon.
    private static func viewerFlags(_ mode: ReadingMode) -> UInt64 {
        switch mode {
            case .leftToRight: return 1
            case .rightToLeft: return 2
            case .webtoon: return 4
        }
    }
}
