import CryptoKit
import Foundation
import ImageIO
import UIKit

/// Loads covers and chapter pages.
///
/// The fast path asks the extension only for the URL and headers (Referer, cookies, user agent)
/// and downloads with URLSession. If that fails or the bytes are not an image, it falls back to
/// letting the extension download the image itself, which runs the source's interceptors.
/// Downloaded chapters are read straight from disk.
actor ImagePipeline {
    static let shared = ImagePipeline()

    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 220 * 1024 * 1024
        return cache
    }()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 300 * 1024 * 1024
        )
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// Cover headers are the source's plain headers, the same for every cover of that source.
    private var coverHeaders: [Int64: (headers: [String: String], expires: Date)] = [:]

    /// Sources whose covers just hit a Cloudflare challenge, until when.
    private var coverChallenged: [Int64: Date] = [:]

    /// What is known about a source's page headers, per source + image host.
    private enum PageHeaderState {
        /// One page answered with these headers and an untouched URL; a second page decides.
        case probing(headers: [String: String], firstURL: String, expires: Date)
        /// Two pages agreed: later pages reuse these headers without asking the engine.
        case cached(headers: [String: String], expires: Date)
        /// The source rewrites URLs or varies headers per page: always ask the engine.
        case dynamic(until: Date)
    }

    /// Reader pages used to cost one round trip through the serial engine each, just for
    /// the headers: queued behind a library update, the reader froze. Most sources answer
    /// every page with the same headers, so once two pages agree they are reused.
    private var pageHeaders: [String: PageHeaderState] = [:]
    private static let headerLifetime: TimeInterval = 600

    /// One load per page at a time, so the reader and the prefetcher never fetch the same page
    /// twice through the (serial) extension engine.
    private var inFlight: [String: Task<UIImage, Error>] = [:]

    private var coverDirectory: URL {
        let url = Storage.cacheDirectory.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Covers

    func cover(for manga: MangaItem, installed: InstalledExtension?, maxWidth: CGFloat) async throws -> UIImage {
        guard let address = manga.thumbnailURL, !address.isEmpty else { throw URLError(.badURL) }
        let key = "cover|\(address)" as NSString
        if let cached = memory.object(forKey: key) { return cached }

        // Imported series: the cover is a file next to the archives, never a download.
        if manga.isLocal {
            guard
                let data = LocalStore.coverData(for: manga),
                let image = Self.decode(data, maxWidth: maxWidth)
            else { throw URLError(.fileDoesNotExist) }
            store(image, for: key)
            return image
        }

        let file = coverDirectory.appendingPathComponent(Self.hash(address))
        if let data = try? Data(contentsOf: file), let image = Self.decode(data, maxWidth: maxWidth) {
            store(image, for: key)
            return image
        }

        let data: Data
        if let installed {
            data = try await fetchCover(address, sourceId: manga.sourceId, installed: installed)
        } else {
            guard let url = URL(string: address) else { throw URLError(.badURL) }
            data = try await download(URLRequest(url: url))
        }
        guard let image = Self.decode(data, maxWidth: maxWidth) else { throw URLError(.cannotDecodeContentData) }
        try? data.write(to: file, options: .atomic)
        store(image, for: key)
        return image
    }

    /// Covers are background work on the engine: the grid must never hold up the WebView,
    /// a search or the reader.
    private func fetchCover(
        _ address: String,
        sourceId: Int64,
        installed: InstalledExtension,
        bypassCache: Bool = false
    ) async throws -> Data {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        do {
            var request = URLRequest(url: url)
            if bypassCache { request.cachePolicy = .reloadIgnoringLocalCacheData }
            for (name, value) in try await headersForCovers(sourceId: sourceId, sample: address, installed: installed) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let data = try await download(request)
            if Self.isImage(data) { return data }
        } catch let error where Self.isCancellation(error) {
            throw error
        } catch let error as ImageHTTPError where error.isCloudflareChallenge {
            // The extension's client would hit the same wall, one cover at a time on the
            // serial engine — a grid of forty covers kept the WebView waiting a minute.
            // Fail fast; the covers retry once the WebView clears the challenge.
            coverChallenged[sourceId] = Date().addingTimeInterval(120)
            throw error
        } catch {
            // Fall through to the extension's own client.
        }
        if let until = coverChallenged[sourceId], until > Date() {
            throw ImageHTTPError(status: 403, isCloudflareChallenge: true)
        }
        return try await JVMEngine.shared.materializeImage(
            imageURL: address, pageURL: nil, sourceId: sourceId, installed: installed,
            priority: .background
        )
    }

    private func headersForCovers(sourceId: Int64, sample: String, installed: InstalledExtension) async throws -> [String: String] {
        if let cached = coverHeaders[sourceId], cached.expires > Date() { return cached.headers }
        let request = try await JVMEngine.shared.imageRequest(
            imageURL: sample, pageURL: nil, sourceId: sourceId, installed: installed,
            priority: .background
        )
        let headers = request.allHTTPHeaderFields ?? [:]
        coverHeaders[sourceId] = (headers, Date().addingTimeInterval(Self.headerLifetime))
        return headers
    }

    /// Downloads a series' cover again even though a copy is saved: covers are otherwise
    /// kept until their address changes, and some sources replace the image behind the same
    /// address. The saved copy is only replaced once the new one arrived, so a refresh while
    /// offline never loses it.
    func refreshCover(for manga: MangaItem, installed: InstalledExtension) async {
        guard !manga.isLocal, let address = manga.thumbnailURL, !address.isEmpty else { return }
        guard
            let data = try? await fetchCover(
                address, sourceId: manga.sourceId, installed: installed, bypassCache: true
            ),
            Self.isImage(data)
        else { return }
        let file = coverDirectory.appendingPathComponent(Self.hash(address))
        if let saved = try? Data(contentsOf: file), saved == data { return }
        try? data.write(to: file, options: .atomic)
        memory.removeObject(forKey: "cover|\(address)" as NSString)
        let mangaId = manga.id
        await MainActor.run {
            NotificationCenter.default.post(
                name: .coverChanged, object: nil, userInfo: ["mangaId": mangaId]
            )
        }
    }

    /// Cookies or agent of the source changed (WebView, cleared cookies): every cached
    /// header set of it is stale.
    func invalidate(sourceId: Int64) {
        coverHeaders[sourceId] = nil
        coverChallenged[sourceId] = nil
        let prefix = "\(sourceId)|"
        for key in pageHeaders.keys where key.hasPrefix(prefix) {
            pageHeaders[key] = nil
        }
    }

    // MARK: - Pages

    private static func key(for page: PageItem) -> String {
        if let localURL = page.localURL { return "local|\(localURL.path)" }
        return "page|\(page.imageURL ?? page.url)"
    }

    func page(_ page: PageItem, sourceId: Int64, installed: InstalledExtension, maxWidth: CGFloat) async throws -> UIImage {
        let key = Self.key(for: page)
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let running = inFlight[key] { return try await running.value }

        let task = Task<UIImage, Error> {
            let data = try await self.pageData(page, sourceId: sourceId, installed: installed)
            guard let image = Self.decode(data, maxWidth: maxWidth) else {
                throw URLError(.cannotDecodeContentData)
            }
            return image
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let image = try await task.value
        store(image, for: key as NSString)
        return image
    }

    /// Loads the next pages into memory ahead of the reader. Errors are ignored: the page view
    /// retries on its own when it appears.
    func prefetch(_ pages: [PageItem], sourceId: Int64, installed: InstalledExtension, maxWidth: CGFloat) {
        for page in pages {
            let key = Self.key(for: page)
            if memory.object(forKey: key as NSString) != nil || inFlight[key] != nil { continue }
            Task { _ = try? await self.page(page, sourceId: sourceId, installed: installed, maxWidth: maxWidth) }
        }
    }

    /// The raw image bytes, used by the reader (`.normal`) and by downloads (`.background`).
    func pageData(
        _ page: PageItem,
        sourceId: Int64,
        installed: InstalledExtension,
        priority: JVMPriority = .normal
    ) async throws -> Data {
        if let localURL = page.localURL {
            return try Data(contentsOf: localURL)
        }
        guard let imageURL = page.imageURL, !imageURL.isEmpty else { throw URLError(.badURL) }
        let pageURL = page.url.isEmpty ? imageURL : page.url
        let headerKey = Self.pageHeaderKey(sourceId: sourceId, imageURL: imageURL)

        // Fast path: headers already learned for this source and host, no engine call.
        if let headerKey,
           case .cached(let headers, let expires)? = pageHeaders[headerKey],
           expires > Date(),
           let url = URL(string: imageURL) {
            var request = URLRequest(url: url)
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            do {
                let data = try await download(request)
                if Self.isImage(data) { return data }
            } catch let error where Self.isCancellation(error) {
                throw error
            } catch {
                // Handled below.
            }
            // The shared headers did not work for this page: stop guessing for a while.
            pageHeaders[headerKey] = .dynamic(until: Date().addingTimeInterval(Self.headerLifetime))
        }

        do {
            let request = try await JVMEngine.shared.imageRequest(
                imageURL: imageURL, pageURL: pageURL, sourceId: sourceId, installed: installed,
                priority: priority
            )
            if let headerKey { learnPageHeaders(request, requested: imageURL, key: headerKey) }
            let downloaded = try await download(request)
            if Self.isImage(downloaded) { return downloaded }
        } catch let error where Self.isCancellation(error) {
            throw error
        } catch {
            // Fall through to the extension's own client.
        }
        return try await JVMEngine.shared.materializeImage(
            imageURL: imageURL, pageURL: pageURL, sourceId: sourceId, installed: installed,
            priority: priority
        )
    }

    private static func pageHeaderKey(sourceId: Int64, imageURL: String) -> String? {
        guard let host = URL(string: imageURL)?.host else { return nil }
        return "\(sourceId)|\(host)"
    }

    /// Two different pages answering with the same headers and their URL untouched means
    /// the source's headers are static: cache them. Anything else marks the host dynamic.
    private func learnPageHeaders(_ request: URLRequest, requested imageURL: String, key: String) {
        let now = Date()
        let headers = request.allHTTPHeaderFields ?? [:]
        let normalized = URL(string: imageURL)?.absoluteString ?? imageURL
        guard request.url?.absoluteString == normalized else {
            pageHeaders[key] = .dynamic(until: now.addingTimeInterval(Self.headerLifetime))
            return
        }
        switch pageHeaders[key] {
            case .dynamic(let until)? where until > now:
                return
            case .cached(_, let expires)? where expires > now:
                return
            case .probing(let first, let firstURL, let expires)? where expires > now:
                if firstURL == imageURL { return }
                pageHeaders[key] = first == headers
                    ? PageHeaderState.cached(
                        headers: headers, expires: now.addingTimeInterval(Self.headerLifetime)
                    )
                    : PageHeaderState.dynamic(until: now.addingTimeInterval(Self.headerLifetime))
            default:
                pageHeaders[key] = .probing(
                    headers: headers,
                    firstURL: imageURL,
                    expires: now.addingTimeInterval(Self.headerLifetime)
                )
        }
    }

    // MARK: - Maintenance

    func diskCacheBytes() -> Int64 {
        var total = Int64(session.configuration.urlCache?.currentDiskUsage ?? 0)
        if let files = try? FileManager.default.contentsOfDirectory(
            at: coverDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) {
            for file in files {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    func clearCaches() {
        memory.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
        try? FileManager.default.removeItem(at: coverDirectory)
        coverHeaders.removeAll()
        coverChallenged.removeAll()
        pageHeaders.removeAll()
    }

    // MARK: - Helpers

    private func download(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImageHTTPError(response: http)
        }
        return data
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func store(_ image: UIImage, for key: NSString) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memory.setObject(image, forKey: key, cost: cost)
    }

    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0 && CGImageSourceGetType(source) != nil
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Crops uniform borders (white margins, scan edges) around a page. The border color is
    /// whatever the corners agree on; if the content box is implausibly small, or the image has
    /// no real border, the original comes back untouched.
    static func trimmingBorders(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let fullWidth = cgImage.width
        let fullHeight = cgImage.height
        guard fullWidth > 16, fullHeight > 16 else { return image }

        // Analyze a small grayscale copy; precision at the pixel level is not needed.
        let sampleWidth = 96
        let sampleHeight = max(16, Int(Double(sampleWidth) * Double(fullHeight) / Double(fullWidth)))
        var samples = [UInt8](repeating: 0, count: sampleWidth * sampleHeight)
        let drew = samples.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let space = CGColorSpace(name: CGColorSpace.linearGray),
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: sampleWidth,
                    height: sampleHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: sampleWidth,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard drew else { return image }

        func value(_ x: Int, _ y: Int) -> Int { Int(samples[y * sampleWidth + x]) }
        let background = (
            value(0, 0) + value(sampleWidth - 1, 0) +
            value(0, sampleHeight - 1) + value(sampleWidth - 1, sampleHeight - 1)
        ) / 4
        let threshold = 28

        var minX = sampleWidth, maxX = -1, minY = sampleHeight, maxY = -1
        for y in 0..<sampleHeight {
            for x in 0..<sampleWidth where abs(value(x, y) - background) > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }

        // One sample cell of breathing room, then scale back up to pixels.
        let scaleX = Double(fullWidth) / Double(sampleWidth)
        let scaleY = Double(fullHeight) / Double(sampleHeight)
        let crop = CGRect(
            x: max(0, (Double(minX) - 1) * scaleX),
            y: max(0, (Double(minY) - 1) * scaleY),
            width: min(Double(fullWidth), (Double(maxX - minX) + 3) * scaleX),
            height: min(Double(fullHeight), (Double(maxY - minY) + 3) * scaleY)
        ).intersection(CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight))

        let area = crop.width * crop.height
        let fullArea = CGFloat(fullWidth * fullHeight)
        // No meaningful border, or so aggressive it would eat the page: leave it alone.
        guard area < fullArea * 0.97, area > fullArea * 0.25 else { return image }
        guard let trimmed = cgImage.cropping(to: crop) else { return image }
        return UIImage(cgImage: trimmed, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Two pages side by side as one image, for the double-page spread. The pages are scaled
    /// to a common height; `rightToLeft` puts the first page on the right, like a printed manga.
    static func spread(_ first: UIImage, _ second: UIImage, rightToLeft: Bool) -> UIImage {
        let height = min(first.size.height, second.size.height)
        guard height > 0 else { return first }
        let firstWidth = first.size.width * (height / first.size.height)
        let secondWidth = second.size.width * (height / second.size.height)
        let size = CGSize(width: firstWidth + secondWidth, height: height)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            let leading = rightToLeft ? second : first
            let trailing = rightToLeft ? first : second
            let leadingWidth = rightToLeft ? secondWidth : firstWidth
            let trailingWidth = rightToLeft ? firstWidth : secondWidth
            leading.draw(in: CGRect(x: 0, y: 0, width: leadingWidth, height: height))
            trailing.draw(in: CGRect(x: leadingWidth, y: 0, width: trailingWidth, height: height))
        }
    }

    /// Decodes at most `maxWidth` pixels wide. A webtoon page can be 800×12000 px; decoding it at
    /// full size for every page is what gets a reader killed for memory.
    static func decode(_ data: Data, maxWidth: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
            width > 0, height > 0
        else {
            return UIImage(data: data)
        }
        let limit = Double(maxWidth)
        let scale = width > limit ? limit / width : 1
        let maxPixelSize = max(width, height) * scale
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: image)
    }
}

/// A non-2xx answer to an image request.
struct ImageHTTPError: LocalizedError {
    let status: Int
    /// Cloudflare answered with a challenge page instead of the image.
    let isCloudflareChallenge: Bool

    init(status: Int, isCloudflareChallenge: Bool) {
        self.status = status
        self.isCloudflareChallenge = isCloudflareChallenge
    }

    init(response: HTTPURLResponse) {
        status = response.statusCode
        let mitigated = (response.value(forHTTPHeaderField: "cf-mitigated") ?? "").lowercased()
        let server = (response.value(forHTTPHeaderField: "Server") ?? "").lowercased()
        isCloudflareChallenge = mitigated == "challenge"
            || ((status == 403 || status == 503) && server.contains("cloudflare"))
    }

    var errorDescription: String? {
        if isCloudflareChallenge {
            return EngineError.readable("cloudflare")
        }
        return String(
            format: NSLocalizedString("El servidor respondió con el error %d.", comment: ""),
            status
        )
    }
}

extension Notification.Name {
    /// Posted on the main thread with `userInfo["mangaId"]` when a saved cover was replaced.
    static let coverChanged = Notification.Name("cl.jonas.wizardcat.coverChanged")
}
