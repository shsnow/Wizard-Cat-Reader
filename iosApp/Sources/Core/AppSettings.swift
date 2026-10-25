import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, spanish, english

    var id: String { rawValue }

    var title: String {
        switch self {
            case .system: return NSLocalizedString("Como el sistema", comment: "")
            case .spanish: return "Español"
            case .english: return "English"
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
            case .system: return NSLocalizedString("Como el sistema", comment: "")
            case .light: return NSLocalizedString("Claro", comment: "")
            case .dark: return NSLocalizedString("Oscuro", comment: "")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
        }
    }
}

enum ReaderBackground: String, CaseIterable, Identifiable {
    case black, white, system

    var id: String { rawValue }

    var title: String {
        switch self {
            case .black: return NSLocalizedString("Negro", comment: "")
            case .white: return NSLocalizedString("Blanco", comment: "")
            case .system: return NSLocalizedString("Como el sistema", comment: "")
        }
    }

    var color: Color {
        switch self {
            case .black: return .black
            case .white: return .white
            case .system: return Color(.systemBackground)
        }
    }
}

/// When the paged reader shows two pages side by side, like an open book.
enum DoublePageMode: String, CaseIterable, Identifiable {
    case off, landscape, always

    var id: String { rawValue }

    var title: String {
        switch self {
            case .off: return NSLocalizedString("Nunca", comment: "")
            case .landscape: return NSLocalizedString("En horizontal", comment: "")
            case .always: return NSLocalizedString("Siempre", comment: "")
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, unread

    var id: String { rawValue }

    var title: String {
        switch self {
            case .recent: return NSLocalizedString("Recién leídos", comment: "")
            case .title: return NSLocalizedString("Título", comment: "")
            case .unread: return NSLocalizedString("Sin leer", comment: "")
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// Used for manga that do not look like a long-strip format and have no per-series choice.
    @Published var defaultReadingMode: ReadingMode {
        didSet { defaults.set(defaultReadingMode.rawValue, forKey: "defaultReadingMode") }
    }

    /// Source languages shown in Explorar. Empty means all.
    @Published var languages: Set<String> {
        didSet { defaults.set(Array(languages), forKey: "languages") }
    }

    @Published var appTheme: AppTheme {
        didSet { defaults.set(appTheme.rawValue, forKey: "appTheme") }
    }

    /// The app's own language. iOS reads AppleLanguages at launch, so a change
    /// applies the next time the app opens.
    @Published var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: "appLanguage")
            switch appLanguage {
                case .system: defaults.removeObject(forKey: "AppleLanguages")
                case .spanish: defaults.set(["es"], forKey: "AppleLanguages")
                case .english: defaults.set(["en"], forKey: "AppleLanguages")
            }
        }
    }

    @Published var gridColumns: Int {
        didSet { defaults.set(gridColumns, forKey: "gridColumns") }
    }

    @Published var librarySort: LibrarySort {
        didSet { defaults.set(librarySort.rawValue, forKey: "librarySort") }
    }

    @Published var readerBackground: ReaderBackground {
        didSet { defaults.set(readerBackground.rawValue, forKey: "readerBackground") }
    }

    /// Webtoon side margin as a fraction of the width per side (0, 0.04 or 0.08).
    @Published var webtoonPadding: Double {
        didSet { defaults.set(webtoonPadding, forKey: "webtoonPadding") }
    }

    /// Off: tapping anywhere only shows or hides the controls.
    @Published var tapZonesEnabled: Bool {
        didSet { defaults.set(tapZonesEnabled, forKey: "tapZonesEnabled") }
    }

    @Published var keepScreenAwake: Bool {
        didSet { defaults.set(keepScreenAwake, forKey: "keepScreenAwake") }
    }

    @Published var deleteAfterReading: Bool {
        didSet { defaults.set(deleteAfterReading, forKey: "deleteAfterReading") }
    }

    /// Pages fetched at once while downloading a chapter.
    @Published var downloadBatch: Int {
        didSet { defaults.set(downloadBatch, forKey: "downloadBatch") }
    }

    /// Download the new chapters a library update finds, automatically.
    @Published var autoDownloadUpdates: Bool {
        didSet { defaults.set(autoDownloadUpdates, forKey: "autoDownloadUpdates") }
    }

    /// Webtoon autoscroll speed, in points per second.
    @Published var autoScrollSpeed: Double {
        didSet { defaults.set(autoScrollSpeed, forKey: "autoScrollSpeed") }
    }

    /// Swaps which edge goes forward in paged mode, for reading with the other hand.
    @Published var invertTapZones: Bool {
        didSet { defaults.set(invertTapZones, forKey: "invertTapZones") }
    }

    /// Small page counter in the corner while the controls are hidden.
    @Published var alwaysShowPageNumber: Bool {
        didSet { defaults.set(alwaysShowPageNumber, forKey: "alwaysShowPageNumber") }
    }

    /// Unread-count badges on the library covers.
    @Published var showUnreadBadges: Bool {
        didSet { defaults.set(showUnreadBadges, forKey: "showUnreadBadges") }
    }

    /// The "Seguir leyendo" row at the top of the library.
    @Published var showContinueRow: Bool {
        didSet { defaults.set(showContinueRow, forKey: "showContinueRow") }
    }

    /// Refresh the library when the app opens, at most every six hours.
    @Published var updateOnLaunch: Bool {
        didSet { defaults.set(updateOnLaunch, forKey: "updateOnLaunch") }
    }

    /// Two pages side by side in the paged reader.
    @Published var doublePageMode: DoublePageMode {
        didSet { defaults.set(doublePageMode.rawValue, forKey: "doublePageMode") }
    }

    /// Crop uniform borders around pages in the paged reader.
    @Published var trimPageBorders: Bool {
        didSet { defaults.set(trimPageBorders, forKey: "trimPageBorders") }
    }

    private init() {
        // A local, so nothing reads `self` before every stored property is initialized.
        let defaults = UserDefaults.standard
        defaultReadingMode = ReadingMode(rawValue: defaults.string(forKey: "defaultReadingMode") ?? "")
            ?? .webtoon
        if let stored = defaults.array(forKey: "languages") as? [String] {
            languages = Set(stored)
        } else {
            languages = ["es", "es-419", "en", "all"]
        }
        appTheme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .system
        appLanguage = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system
        let columns = defaults.integer(forKey: "gridColumns")
        gridColumns = (2...4).contains(columns) ? columns : 3
        librarySort = LibrarySort(rawValue: defaults.string(forKey: "librarySort") ?? "") ?? .recent
        readerBackground = ReaderBackground(rawValue: defaults.string(forKey: "readerBackground") ?? "")
            ?? .black
        webtoonPadding = defaults.object(forKey: "webtoonPadding") as? Double ?? 0
        tapZonesEnabled = defaults.object(forKey: "tapZonesEnabled") as? Bool ?? true
        keepScreenAwake = defaults.object(forKey: "keepScreenAwake") as? Bool ?? true
        deleteAfterReading = defaults.bool(forKey: "deleteAfterReading")
        let batch = defaults.integer(forKey: "downloadBatch")
        downloadBatch = (1...5).contains(batch) ? batch : 3
        autoDownloadUpdates = defaults.bool(forKey: "autoDownloadUpdates")
        let speed = defaults.double(forKey: "autoScrollSpeed")
        autoScrollSpeed = speed == 0 ? 80 : min(max(speed, 20), 300)
        invertTapZones = defaults.bool(forKey: "invertTapZones")
        alwaysShowPageNumber = defaults.object(forKey: "alwaysShowPageNumber") as? Bool ?? true
        showUnreadBadges = defaults.object(forKey: "showUnreadBadges") as? Bool ?? true
        showContinueRow = defaults.object(forKey: "showContinueRow") as? Bool ?? true
        updateOnLaunch = defaults.bool(forKey: "updateOnLaunch")
        doublePageMode = DoublePageMode(rawValue: defaults.string(forKey: "doublePageMode") ?? "")
            ?? .landscape
        trimPageBorders = defaults.bool(forKey: "trimPageBorders")
    }

    func shows(language: String) -> Bool {
        languages.isEmpty || languages.contains(language)
    }
}

extension Color {
    /// The terracotta of the app icon.
    static let moka = Color(red: 0.80, green: 0.33, blue: 0.18)
}
