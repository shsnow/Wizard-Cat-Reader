import Combine
import Foundation
import WizardJVMRunner

enum EngineState: Equatable {
    case idle
    case starting
    case ready(String)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

@MainActor
final class EngineStatus: ObservableObject {
    static let shared = EngineStatus()
    @Published var state: EngineState = .idle
}

enum EngineError: LocalizedError {
    case host(String)
    case emptyImage

    var errorDescription: String? {
        switch self {
            case .host(let message): return Self.readable(message)
            case .emptyImage:
                return NSLocalizedString("La extensión devolvió una imagen vacía.", comment: "")
        }
    }

    static func readable(_ message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("cloudflare") {
            return NSLocalizedString(
                "El sitio pidió una verificación de Cloudflare. Abre la fuente en WebView (el botón del globo), resuelve la verificación y reintenta.",
                comment: ""
            )
        }
        return message
    }
}

private struct ImageRequestDescriptor: Decodable {
    let url: String
    let headers: [String: String]?
}

/// One of a source's search filters, as the extension host serializes them.
/// `type` is note, text, check, sort or select; `id` is the filter's position path.
struct SourceFilter: Decodable, Hashable, Identifiable {
    let id: String
    let type: String
    let name: String
    let options: [String]?
    let defaultValue: String?
    /// check: "true" marks a three-state filter (include/exclude). sort: the default direction.
    let auxiliary: String?
    let group: String?
}

/// One long-lived worker thread for every Java call. A GCD queue would not do: its worker
/// threads come and go, and a thread that dies while attached to the VM leaks a JavaThread.
/// A single persistent thread also gives the Android-compat layer a stable thread identity.
private final class JVMWorkThread {
    private let condition = NSCondition()
    private var jobs: [() -> Void] = []

    init() {
        let thread = Thread { [self] in
            while true {
                condition.lock()
                while jobs.isEmpty {
                    condition.wait()
                }
                let job = jobs.removeFirst()
                condition.unlock()
                job()
            }
        }
        thread.name = "cl.jonas.wizardcat.jvm"
        // Native stack for JNI frames; the Java stack is sized separately (-Xss).
        thread.stackSize = 2 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func async(_ job: @escaping () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }
}

/// Owns the single in-process Java VM that runs Mihon extension JARs.
///
/// Every Java call is blocking, so they all run on one dedicated thread rather than on
/// Swift's cooperative pool. The VM itself is created on the main thread, which is what the
/// Android main-looper emulation inside the compatibility layer expects.
final class JVMEngine: @unchecked Sendable {
    static let shared = JVMEngine()

    private let queue = JVMWorkThread()
    /// Set once the VM is created and its compatibility layer initialized.
    private var runtime: JVMRuntime?
    /// The VM as soon as it exists, kept even if compatibility init fails.
    private var createdRuntime: JVMRuntime?
    private var startTask: Task<JVMRuntime, Error>?
    /// Touched only on `queue`: extension id → jar path currently loaded into the VM.
    private var loadedExtensions: [String: String] = [:]

    private init() {}

    // MARK: - Lifecycle

    @MainActor
    func start() async throws -> JVMRuntime {
        if let runtime { return runtime }
        if let startTask { return try await startTask.value }

        let task = Task { @MainActor () async throws -> JVMRuntime in
            EngineStatus.shared.state = .starting
            // Let SwiftUI draw the "starting" state before the main thread blocks in JNI.
            try? await Task.sleep(nanoseconds: 50_000_000)
            do {
                // JNI allows one VM per process: if compatibility init failed before, retry it on
                // the VM that already exists instead of trying to create a second one.
                let created: JVMRuntime
                if let existing = self.createdRuntime {
                    created = existing
                } else {
                    let configuration = try JVMRuntimeConfiguration.bundled(in: .main)
                    created = try JVMRuntime(configuration: configuration)
                    self.createdRuntime = created
                }
                // Compatibility init runs before `runtime` is published, so a concurrent caller
                // waiting on `startTask` never dispatches to a half-initialized host.
                let description = try await self.run(on: created) { runtime -> String in
                    try runtime.initializeExtensionCompatibility()
                    let ping: ExtensionHostResponse = try runtime.dispatch(
                        ExtensionHostRequest(operation: "ping")
                    )
                    return [ping.runtime, ping.javaVersion]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                }
                self.runtime = created
                EngineStatus.shared.state = .ready(description.isEmpty ? "Listo" : description)
                return created
            } catch {
                EngineStatus.shared.state = .failed(error.localizedDescription)
                self.startTask = nil
                throw error
            }
        }
        startTask = task
        return try await task.value
    }

    private func onQueue<T>(_ work: @escaping (JVMRuntime) throws -> T) async throws -> T {
        let runtime = try await start()
        return try await run(on: runtime, work)
    }

    private func run<T>(
        on runtime: JVMRuntime,
        _ work: @escaping (JVMRuntime) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work(runtime))
                } catch let error as EngineError {
                    continuation.resume(throwing: error)
                } catch {
                    // The JVM bridge throws raw Java messages ("java.io.IOException:
                    // Cloudflare bypass…"); route them through the same readable
                    // mapping the host responses get.
                    continuation.resume(throwing: EngineError.host(error.localizedDescription))
                }
            }
        }
    }

    private func onQueue<T>(
        loading installed: InstalledExtension,
        _ work: @escaping (JVMRuntime) throws -> T
    ) async throws -> T {
        try await onQueue { runtime in
            try self.ensureLoaded(installed, in: runtime)
            return try work(runtime)
        }
    }

    /// Runs on `queue`.
    private func ensureLoaded(_ installed: InstalledExtension, in runtime: JVMRuntime) throws {
        let path = installed.jarURL.path
        if loadedExtensions[installed.id] == path { return }
        try runtime.loadTachiyomiXExtension(id: installed.id, jarURL: installed.jarURL)
        loadedExtensions[installed.id] = path
    }

    private static func checked(_ response: ExtensionHostResponse) throws -> ExtensionHostResponse {
        guard response.success else {
            throw EngineError.host(response.error ?? "Error desconocido de la extensión")
        }
        return response
    }

    // MARK: - Extensions

    /// Loads a freshly downloaded JAR and asks it which sources it provides.
    func inspectSources(extensionId: String, jarURL: URL) async throws -> [SourceInfo] {
        try await onQueue { runtime in
            try runtime.loadTachiyomiXExtension(id: extensionId, jarURL: jarURL)
            self.loadedExtensions[extensionId] = jarURL.path
            return try runtime.sources(extensionId: extensionId).map {
                SourceInfo(
                    id: $0.id,
                    name: $0.name,
                    lang: $0.lang,
                    supportsLatest: $0.supportsLatest,
                    extensionId: extensionId
                )
            }
        }
    }

    /// Reads the JAR's manifest without loading its code.
    func declaresAdultContent(jarURL: URL) async throws -> Bool {
        try await onQueue { runtime -> Bool in
            let response = try Self.checked(
                runtime.dispatch(
                    ExtensionHostRequest(operation: "inspectExtension", jarPath: jarURL.path)
                )
            )
            return ContentFilter.manifestDeclaresAdult(response.nsfw)
        }
    }

    func forget(extensionId: String) {
        queue.async {
            self.loadedExtensions[extensionId] = nil
        }
    }

    // MARK: - Browsing

    enum Listing: Hashable {
        case popular
        case latest
        case search(String)
    }

    func mangaPage(
        _ listing: Listing,
        source: SourceInfo,
        installed: InstalledExtension,
        page: Int
    ) async throws -> (items: [MangaItem], hasNextPage: Bool) {
        try await onQueue(loading: installed) { runtime in
            let result: TachiyomiXMangaPage
            switch listing {
                case .popular:
                    result = try runtime.popularManga(
                        extensionId: installed.id, sourceId: source.id, page: page
                    )
                case .latest:
                    result = try runtime.latestManga(
                        extensionId: installed.id, sourceId: source.id, page: page
                    )
                case .search(let query):
                    result = try runtime.searchManga(
                        extensionId: installed.id, sourceId: source.id, query: query, page: page
                    )
            }
            return (result.mangas.map { Self.manga($0, sourceId: source.id) }, result.hasNextPage)
        }
    }

    /// The filters the source offers for its search (genres, status, order…).
    func searchFilters(
        source: SourceInfo,
        installed: InstalledExtension
    ) async throws -> [SourceFilter] {
        try await onQueue(loading: installed) { runtime in
            let response = try Self.checked(
                runtime.dispatch(
                    ExtensionHostRequest(
                        operation: "getSearchFilters",
                        extensionId: installed.id,
                        sourceId: String(source.id)
                    )
                )
            )
            guard let result = response.result else { return [] }
            return try JSONDecoder().decode([SourceFilter].self, from: Data(result.utf8))
        }
    }

    /// Search applying the source's own filters. Unlike the plain search, the query may be
    /// empty: the filters alone narrow the catalog.
    func filteredSearch(
        query: String,
        filterStates: String,
        source: SourceInfo,
        installed: InstalledExtension,
        page: Int
    ) async throws -> (items: [MangaItem], hasNextPage: Bool) {
        try await onQueue(loading: installed) { runtime in
            let response = try Self.checked(
                runtime.dispatch(
                    ExtensionHostRequest(
                        operation: "searchManga",
                        extensionId: installed.id,
                        sourceId: String(source.id),
                        argument: String(page),
                        query: query.isEmpty ? nil : query,
                        filterStates: filterStates
                    )
                )
            )
            guard let result = response.result else {
                throw EngineError.host("La fuente no devolvió resultados.")
            }
            let decoded = try JSONDecoder().decode(
                TachiyomiXMangaPage.self, from: Data(result.utf8)
            )
            return (decoded.mangas.map { Self.manga($0, sourceId: source.id) }, decoded.hasNextPage)
        }
    }

    func details(
        of manga: MangaItem,
        installed: InstalledExtension
    ) async throws -> (manga: MangaItem, chapters: [ChapterItem]) {
        try await onQueue(loading: installed) { runtime in
            let update = try runtime.mangaUpdate(
                extensionId: installed.id,
                sourceId: manga.sourceId,
                mangaURL: manga.url,
                mangaTitle: manga.title,
                mangaThumbnailURL: manga.thumbnailURL,
                mangaArtist: manga.artist,
                mangaAuthor: manga.author,
                mangaStatus: manga.status,
                mangaDescription: manga.summary,
                mangaGenre: manga.genre
            )
            var refreshed = Self.manga(update.manga, sourceId: manga.sourceId)
            // Some sources return details without echoing the URL or cover back.
            if refreshed.url.isEmpty { refreshed.url = manga.url }
            if refreshed.thumbnailURL?.isEmpty ?? true { refreshed.thumbnailURL = manga.thumbnailURL }
            if refreshed.title.isEmpty { refreshed.title = manga.title }
            let chapters = update.chapters.map {
                ChapterItem(
                    url: $0.url,
                    name: $0.name,
                    number: $0.chapterNumber,
                    scanlator: $0.scanlator,
                    dateUpload: $0.dateUpload,
                    memo: $0.memo
                )
            }
            return (refreshed, chapters)
        }
    }

    func pages(
        of chapter: ChapterItem,
        manga: MangaItem,
        installed: InstalledExtension
    ) async throws -> [PageItem] {
        try await onQueue(loading: installed) { runtime in
            try runtime.pages(
                extensionId: installed.id,
                sourceId: manga.sourceId,
                chapterURL: chapter.url,
                chapterName: chapter.name,
                chapterNumber: chapter.number,
                chapterScanlator: chapter.scanlator,
                chapterDateUpload: chapter.dateUpload,
                chapterMemo: chapter.memo
            )
            .map { PageItem(index: $0.index, url: $0.url, imageURL: $0.imageURL) }
            .sorted { $0.index < $1.index }
        }
    }

    // MARK: - Web login (Cloudflare, sign-ins)

    /// What the WebView flow needs: the site to open. The engine also reports its
    /// agent, but the WebView navigates with its own Safari agent and hands THAT
    /// one back with the cookies — Cloudflare's checker loops on a WebKit view
    /// pretending to be the engine's desktop Chrome.
    struct WebLoginInfo: Decodable {
        let baseURL: String
        let userAgent: String
    }

    func webLoginInfo(sourceId: Int64, installed: InstalledExtension) async throws -> WebLoginInfo {
        let response = try await onQueue(loading: installed) { runtime -> ExtensionHostResponse in
            try Self.checked(
                runtime.dispatch(
                    ExtensionHostRequest(
                        operation: "getWebLoginInfo",
                        extensionId: installed.id,
                        sourceId: String(sourceId)
                    )
                )
            )
        }
        guard
            let result = response.result,
            let info = try? JSONDecoder().decode(WebLoginInfo.self, from: Data(result.utf8))
        else {
            throw EngineError.host("La fuente no entregó la información de su sitio.")
        }
        return info
    }

    /// Hands cookies from the WebView to the source's HTTP client, so a solved
    /// Cloudflare challenge (cf_clearance) or sign-in applies to its requests.
    /// `lines` is the host's format: one cookie per line,
    /// name/value/domain/path percent-encoded and tab-separated with
    /// expiresAtMs, secure, httpOnly and hostOnly.
    func setWebLoginCookies(
        _ lines: String,
        sourceId: Int64,
        installed: InstalledExtension,
        userAgent: String?
    ) async throws {
        _ = try await onQueue(loading: installed) { runtime -> ExtensionHostResponse in
            try Self.checked(
                runtime.dispatch(
                    ExtensionHostRequest(
                        operation: "setWebLoginCookies",
                        extensionId: installed.id,
                        sourceId: String(sourceId),
                        argument: lines,
                        userAgent: userAgent
                    )
                )
            )
        }
    }

    /// Clears the cookie jar of one source (sign-ins, Cloudflare clearances).
    func clearCookies(source: SourceInfo, installed: InstalledExtension) async throws {
        _ = try await onQueue(loading: installed) { runtime -> ExtensionHostResponse in
            try Self.checked(
                runtime.dispatch(
                    ExtensionHostRequest(
                        operation: "clearCookies",
                        extensionId: installed.id,
                        sourceId: String(source.id)
                    )
                )
            )
        }
    }

    /// The absolute web address of the series on its site, resolved by the extension.
    func siteURL(of manga: MangaItem, installed: InstalledExtension) async throws -> URL {
        let response = try await onQueue(loading: installed) { runtime -> ExtensionHostResponse in
            try Self.checked(
                runtime.dispatch(
                    ExtensionHostRequest(
                        operation: "getMangaUrl",
                        extensionId: installed.id,
                        sourceId: String(manga.sourceId),
                        mangaURL: manga.url,
                        mangaTitle: manga.title
                    )
                )
            )
        }
        guard let text = response.result, let url = URL(string: text), url.scheme != nil else {
            throw EngineError.host("La fuente no entregó la dirección de la serie.")
        }
        return url
    }

    // MARK: - Images

    /// The URL and headers (Referer, cookies, user agent) the source would use for an image.
    /// `pageURL` is nil for covers, which use the source's plain headers.
    func imageRequest(
        imageURL: String,
        pageURL: String?,
        sourceId: Int64,
        installed: InstalledExtension
    ) async throws -> URLRequest {
        let descriptor = try await onQueue(loading: installed) { runtime -> ImageRequestDescriptor in
            let response = try Self.checked(
                runtime.dispatch(
                    ExtensionHostRequest(
                        operation: "getImageRequest",
                        extensionId: installed.id,
                        sourceId: String(sourceId),
                        imageURL: imageURL,
                        pageURL: pageURL
                    )
                )
            )
            guard let result = response.result else {
                throw EngineError.host("La extensión no devolvió la petición de imagen")
            }
            return try JSONDecoder().decode(ImageRequestDescriptor.self, from: Data(result.utf8))
        }
        guard let url = URL(string: descriptor.url) else {
            throw EngineError.host("URL de imagen inválida: \(descriptor.url)")
        }
        var request = URLRequest(url: url)
        for (name, value) in descriptor.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Downloads an image through the extension's own HTTP client. Slower than URLSession, but
    /// it runs the source's interceptors, which is what descrambles some sites' images.
    func materializeImage(
        imageURL: String,
        pageURL: String?,
        sourceId: Int64,
        installed: InstalledExtension
    ) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MokaImages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }

        _ = try await onQueue(loading: installed) { runtime -> ExtensionHostResponse in
            try Self.checked(
                runtime.dispatch(
                    ExtensionHostRequest(
                        operation: "materializeImage",
                        extensionId: installed.id,
                        sourceId: String(sourceId),
                        imageURL: imageURL,
                        pageURL: pageURL,
                        destinationPath: destination.path
                    )
                )
            )
        }
        let data = try Data(contentsOf: destination)
        guard !data.isEmpty else { throw EngineError.emptyImage }
        return data
    }

    // MARK: - Mapping

    private static func manga(_ value: TachiyomiXManga, sourceId: Int64) -> MangaItem {
        MangaItem(
            sourceId: sourceId,
            url: value.url,
            title: value.title,
            thumbnailURL: value.thumbnailURL,
            author: value.author,
            artist: value.artist,
            summary: value.description,
            genre: value.genre,
            status: value.status
        )
    }
}

/// The JVM compatibility layer calls this to drive a WKWebView (Cloudflare challenges, sites
/// that render with JavaScript). MokaReader does not ship that bridge yet; answering "unavailable"
/// lets those extensions fail with a readable error instead of an unresolved symbol.
@_cdecl("wizardcat_webkit_command")
func wizardWebKitCommand(
    _ operation: UnsafePointer<CChar>?,
    _ handle: Int64,
    _ argument1: UnsafePointer<CChar>?,
    _ argument2: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    strdup("__UNAVAILABLE__WKWebView bridge is not installed")
}
