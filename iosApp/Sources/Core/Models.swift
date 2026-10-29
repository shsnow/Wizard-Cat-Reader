import Foundation

/// A manga as MokaReader stores it. Identified by source + URL, the same key Mihon uses, so a
/// Mihon backup can later be matched entry by entry.
struct MangaItem: Codable, Hashable, Identifiable {
    var sourceId: Int64
    var url: String
    var title: String
    var thumbnailURL: String?
    var author: String?
    var artist: String?
    var summary: String?
    var genre: String?
    var status: Int

    var id: String { "\(sourceId)|\(url)" }

    /// Imported on the device (CBZ archives): read from disk, never from the engine.
    var isLocal: Bool { sourceId == LocalSource.sourceId }

    var genres: [String] {
        (genre ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Mihon's SManga status codes.
    var statusText: String? {
        switch status {
            case 1: return NSLocalizedString("En curso", comment: "")
            case 2: return NSLocalizedString("Completado", comment: "")
            case 3: return NSLocalizedString("Licenciado", comment: "")
            case 4: return NSLocalizedString("Publicación terminada", comment: "")
            case 5: return NSLocalizedString("Cancelado", comment: "")
            case 6: return NSLocalizedString("En pausa", comment: "")
            default: return nil
        }
    }

    /// Long-strip formats read best as a vertical webtoon by default.
    var looksLikeWebtoon: Bool {
        let lowered = genres.map { $0.lowercased() }
        return lowered.contains { tag in
            ["manhwa", "manhua", "webtoon", "long strip", "full color", "korean", "chinese"]
                .contains { tag.contains($0) }
        }
    }
}

struct ChapterItem: Codable, Hashable, Identifiable {
    var url: String
    var name: String
    var number: Float?
    var scanlator: String?
    var dateUpload: Int64
    var memo: String?

    var id: String { url }

    var date: Date? {
        dateUpload > 0 ? Date(timeIntervalSince1970: TimeInterval(dateUpload) / 1000) : nil
    }
}

struct PageItem: Hashable, Identifiable {
    var index: Int
    var url: String
    var imageURL: String?
    /// Set for downloaded chapters: the image is read from disk, no network or extension needed.
    var localURL: URL? = nil

    var id: Int { index }
}

enum ReadingMode: String, Codable, CaseIterable, Identifiable {
    case webtoon
    case leftToRight
    case rightToLeft

    var id: String { rawValue }

    var title: String {
        switch self {
            case .webtoon: return NSLocalizedString("Webtoon (vertical)", comment: "")
            case .leftToRight: return NSLocalizedString("Izquierda → derecha", comment: "")
            case .rightToLeft: return NSLocalizedString("Derecha → izquierda (manga)", comment: "")
        }
    }

    var symbol: String {
        switch self {
            case .webtoon: return "rectangle.split.1x2"
            case .leftToRight: return "arrow.right"
            case .rightToLeft: return "arrow.left"
        }
    }
}

/// A source inside an installed extension. One extension (MangaDex) can expose dozens.
struct SourceInfo: Codable, Hashable, Identifiable {
    var id: Int64
    var name: String
    var lang: String
    var supportsLatest: Bool
    var extensionId: String
}

struct InstalledExtension: Codable, Hashable, Identifiable {
    /// The package name, e.g. eu.kanade.tachiyomi.extension.all.mangadex
    var id: String
    var name: String
    var versionName: String
    var versionCode: Int64
    var iconURL: URL?
    var jarFileName: String
    var nsfw: Bool
    var repositoryURL: URL?
    var sources: [SourceInfo]

    var jarURL: URL {
        Storage.extensionsDirectory.appendingPathComponent(jarFileName)
    }
}

struct ExtensionRepository: Codable, Hashable, Identifiable {
    var url: URL
    var name: String

    var id: URL { url }
}

struct CatalogSource: Hashable {
    var id: Int64
    var name: String
    var lang: String
}

struct CatalogExtension: Hashable, Identifiable {
    var name: String
    var packageName: String
    var versionName: String
    var versionCode: Int64
    var extensionLib: String
    var nsfw: Bool
    var iconURL: URL?
    var jarURL: URL
    var sources: [CatalogSource]
    var repositoryURL: URL
    /// Mihon's rating: 0 unspecified, 1 safe, 2 mixed, 3 NSFW.
    var contentWarning: UInt64 = 0

    var id: String { packageName }

    var languages: [String] {
        var seen = Set<String>()
        return sources.map(\.lang).filter { seen.insert($0).inserted }
    }

    /// The JVM host accepts extension-lib 1.4 through 1.6.
    var isSupported: Bool {
        guard let version = Double(extensionLib) else { return false }
        return version >= 1.4 && version < 1.7
    }
}

struct SourceRef: Hashable {
    var source: SourceInfo
}

enum Language {
    static func displayName(_ code: String) -> String {
        if code == "all" { return NSLocalizedString("Multi-idioma", comment: "") }
        if code == "other" { return NSLocalizedString("Otro", comment: "") }
        return Locale.autoupdatingCurrent.localizedString(forIdentifier: code)?.capitalized
            ?? code
    }
}
