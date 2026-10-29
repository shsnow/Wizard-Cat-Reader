import Foundation

/// How much the user (or a parent) lets in. Decided per extension, from the rating its
/// repository publishes; inside an allowed extension nothing is filtered. Adults-only (+18)
/// extensions are blocked at every level, so the App Store age rating holds.
enum ContentLevel: String, CaseIterable, Identifiable {
    /// Normal and MIXED extensions. The default.
    case mixed
    /// Only normal extensions: no MIXED, no +18.
    case safe
    /// Normal extensions plus the MIXED ones picked by hand.
    case exceptions

    var id: String { rawValue }

    var title: String {
        switch self {
            case .mixed: return NSLocalizedString("Normales y mixtas", comment: "")
            case .safe: return NSLocalizedString("Solo normales", comment: "")
            case .exceptions: return NSLocalizedString("Normales y excepciones", comment: "")
        }
    }

    var detail: String {
        switch self {
            case .mixed:
                return NSLocalizedString("Se permiten las extensiones normales y las mixtas (con algo de contenido para adultos). Las +18 se bloquean.", comment: "")
            case .safe:
                return NSLocalizedString("Solo se permiten las extensiones normales. Las mixtas y las +18 se bloquean.", comment: "")
            case .exceptions:
                return NSLocalizedString("Se permiten las extensiones normales y solo las mixtas que elijas abajo. Las +18 se bloquean.", comment: "")
        }
    }
}

enum ContentFilter {
    /// Mihon's content warning, as repositories publish it.
    static let unrated: UInt64 = 0
    static let safeRating: UInt64 = 1
    static let mixedRating: UInt64 = 2
    static let adultRating: UInt64 = 3

    static func allows(
        rating: UInt64,
        packageName: String,
        level: ContentLevel,
        exceptions: Set<String>
    ) -> Bool {
        // Adults-only extensions never pass, whatever the level or the exceptions say.
        guard rating < adultRating else { return false }
        switch level {
            case .mixed: return true
            case .safe: return rating < mixedRating
            case .exceptions: return rating < mixedRating || exceptions.contains(packageName)
        }
    }

    /// The same decision with the user's current settings.
    @MainActor
    static func allows(rating: UInt64, packageName: String) -> Bool {
        let settings = AppSettings.shared
        return allows(
            rating: rating,
            packageName: packageName,
            level: settings.contentLevel,
            exceptions: settings.contentExceptions
        )
    }

    /// The `tachiyomi.extension.nsfw` manifest value, as the JVM host reports it. Only
    /// consulted when the repository does not rate the extension: the flag is also set for
    /// MIXED extensions, so an unrated extension carrying it is treated as adults-only.
    static func manifestDeclaresAdult(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return value == "1" || value == "true"
    }
}
