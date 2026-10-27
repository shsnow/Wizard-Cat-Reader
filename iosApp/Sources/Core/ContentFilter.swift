import Foundation

/// MokaReader is family friendly by design: adult content is not a setting, it is never shown.
///
/// Three layers, so one missing flag does not let anything through:
/// 1. Extensions marked NSFW in the repository index never appear and cannot be installed.
///    MIXED extensions are also blocked, except the short allowlist below of sources whose
///    catalog is mostly safe; for those, layer 3 does the blocking series by series.
/// 2. A downloaded JAR whose own manifest declares `nsfw` is rejected before it is kept
///    (again except the allowlist, whose manifests inherit the binary flag from MIXED).
/// 3. Individual series tagged with adult genres — or whose title, tags or description
///    carry an adult keyword — are hidden from every list and cannot be opened.
enum ContentFilter {
    /// Package names of MIXED-rated extensions allowed through layers 1 and 2 because their
    /// catalog is overwhelmingly safe and the keyword filter below cleans the rest.
    /// NSFW-rated (3) extensions are never allowed, allowlisted or not.
    private static let mixedExceptions: Set<String> = [
        // MangaGeko (mgeko.cc)
        "eu.kanade.tachiyomi.extension.en.mangarawclub",
    ]

    /// Exact genre tags (case-insensitive) that mark a series as adult. Exact matching, so
    /// "Young Adult" or "Adventure" are not caught by "adult".
    private static let blockedGenres: Set<String> = [
        "adult", "adults only", "adulto", "adultos", "+18", "18+", "r-18", "r18",
        "hentai", "smut", "ecchi", "erotica", "erotic", "erótico", "erotico", "erotismo",
        "mature", "maduro", "pornographic", "porn", "nsfw", "sexual violence",
        "violencia sexual", "gore",
    ]

    /// Adult markers caught anywhere inside a title, tag or description.
    /// "smut" is NOT here: as a substring it would block "transmutation".
    private static let blockedSubstrings: [String] = [
        "hentai", "porn", "erotic", "eróti", "18+", "+18", "r-18", "(18)",
    ]

    /// Adult markers matched only as whole words, so titles like "xxxHOLiC" never trip them.
    private static let blockedTokens: Set<String> = [
        "nsfw", "r18", "xxx", "ecchi", "uncensored", "smut",
    ]

    /// True when the text carries an adult keyword, by substring or by whole word.
    static func isBlockedText(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if blockedSubstrings.contains(where: { lowered.contains($0) }) { return true }
        let tokens = lowered.split { !$0.isLetter && !$0.isNumber }
        return tokens.contains { blockedTokens.contains(String($0)) }
    }

    static func isAllowed(_ manga: MangaItem) -> Bool {
        // `genres` is computed; read it once.
        let genres = manga.genres
        if genres.contains(where: { blockedGenres.contains($0.lowercased()) }) { return false }
        if isBlockedText(manga.title) { return false }
        if genres.contains(where: isBlockedText) { return false }
        // Substring pass only: the library filters every entry on each render.
        if let summary = manga.summary {
            let lowered = summary.lowercased()
            if blockedSubstrings.contains(where: { lowered.contains($0) }) { return false }
        }
        return true
    }

    static func allowed(_ items: [MangaItem]) -> [MangaItem] {
        items.filter(isAllowed)
    }

    /// Mihon's content warning: 0 unspecified, 1 safe, 2 mixed, 3 NSFW.
    static func isAllowedExtension(contentWarning: UInt64, packageName: String) -> Bool {
        if contentWarning < 2 { return true }
        return contentWarning == 2 && mixedExceptions.contains(packageName)
    }

    /// Allowlisted MIXED extensions skip the JAR-manifest gate; the series filter covers them.
    static func isMixedException(_ packageName: String) -> Bool {
        mixedExceptions.contains(packageName)
    }

    /// The `tachiyomi.extension.nsfw` manifest value, as the JVM host reports it.
    static func manifestDeclaresAdult(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return value == "1" || value == "true"
    }
}
