import Foundation

/// Adult content policy: extensions rated NSFW (+18) are never listed, installed or kept.
/// Everything else — SAFE and MIXED extensions alike — runs without any filtering inside:
/// what a source lists is what the user sees.
enum ContentFilter {
    /// Mihon's content warning: 0 unspecified, 1 safe, 2 mixed, 3 NSFW.
    static func isAllowedExtension(contentWarning: UInt64) -> Bool {
        contentWarning < 3
    }

    /// The `tachiyomi.extension.nsfw` manifest value, as the JVM host reports it. Only
    /// consulted when the repository does not rate the extension (content warning 0): the
    /// manifest flag is also set for MIXED extensions, so it cannot tell them apart.
    static func manifestDeclaresAdult(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return value == "1" || value == "true"
    }
}
