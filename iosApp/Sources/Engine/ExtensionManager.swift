import Combine
import Foundation

/// Repositories the user added, the catalog they publish, and the extensions installed from it.
/// MokaReader ships with no repository: every source comes from one the user chose.
@MainActor
final class ExtensionManager: ObservableObject {
    static let shared = ExtensionManager()

    @Published private(set) var repositories: [ExtensionRepository]
    @Published private(set) var installed: [InstalledExtension]
    @Published private(set) var catalog: [CatalogExtension] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var installing: Set<String> = []
    @Published var lastError: String?
    /// Sources of extensions the content restriction removed: their series stay in the
    /// library data but are hidden everywhere until the restriction allows them again.
    @Published private(set) var restrictedSources: Set<Int64>

    private static let repositoriesFile = "repositories.json"
    private static let installedFile = "extensions.json"

    private init() {
        repositories = Storage.load([ExtensionRepository].self, from: Self.repositoriesFile) ?? []
        installed = Storage.load([InstalledExtension].self, from: Self.installedFile) ?? []
        // Every stored property must be set before `installed` is mutated below: that goes
        // through the @Published wrapper, which needs a fully initialized self.
        restrictedSources = Set(
            (UserDefaults.standard.array(forKey: Self.restrictedSourcesKey) as? [NSNumber] ?? [])
                .map(\.int64Value)
        )
        // Drop records whose JAR went missing (for example after an OS storage purge).
        installed.removeAll { !FileManager.default.fileExists(atPath: $0.jarURL.path) }
        enforceContentPolicy()
    }

    // MARK: - Content restriction

    private static let restrictedSourcesKey = "restrictedSources"

    /// Whether the current restriction lets this catalog entry in.
    func isAllowed(_ item: CatalogExtension) -> Bool {
        ContentFilter.allows(rating: item.contentWarning, packageName: item.packageName)
    }

    /// The catalog as the Extensiones tab shows it: only what the restriction allows.
    var visibleCatalog: [CatalogExtension] {
        catalog.filter(isAllowed)
    }

    /// The catalog's MIXED extensions, for picking exceptions (+18 ones are never allowed).
    var restrictedCandidates: [CatalogExtension] {
        catalog.filter { $0.contentWarning == ContentFilter.mixedRating }
    }

    func isRestricted(sourceId: Int64) -> Bool {
        restrictedSources.contains(sourceId)
    }

    /// Uninstalls whatever the restriction no longer allows and hides its series. Runs at
    /// launch, when the restriction changes and when the catalog brings ratings for records
    /// installed by older builds.
    func enforceContentPolicy() {
        var removed: [InstalledExtension] = []
        for record in installed {
            let rating = record.contentRating ?? (record.nsfw ? ContentFilter.adultRating : ContentFilter.unrated)
            if !ContentFilter.allows(rating: rating, packageName: record.id) {
                removed.append(record)
            }
        }
        for record in removed {
            uninstall(record)
        }
        var hidden = restrictedSources
        hidden.formUnion(removed.flatMap { $0.sources.map(\.id) })
        // Sources of extensions installed (again) are visible again.
        hidden.subtract(installed.flatMap { $0.sources.map(\.id) })
        setRestrictedSources(hidden)
    }

    private func setRestrictedSources(_ value: Set<Int64>) {
        guard value != restrictedSources else { return }
        restrictedSources = value
        UserDefaults.standard.set(value.map { NSNumber(value: $0) }, forKey: Self.restrictedSourcesKey)
    }

    /// Records from older builds carry no rating: take it from the catalog once it loads.
    private func backfillRatings() {
        var changed = false
        for index in installed.indices where installed[index].contentRating == nil {
            if let item = catalog.first(where: { $0.packageName == installed[index].id }),
               item.contentWarning != ContentFilter.unrated {
                installed[index].contentRating = item.contentWarning
                changed = true
            }
        }
        if changed { Storage.saveNow(installed, to: Self.installedFile) }
        enforceContentPolicy()
    }

    // MARK: - Lookup

    var allSources: [SourceInfo] {
        installed.flatMap(\.sources)
    }

    func extensionFor(sourceId: Int64) -> InstalledExtension? {
        // Imported series get a stand-in, so the reader and library flows work;
        // local reads never reach the engine.
        if sourceId == LocalSource.sourceId { return LocalSource.installedExtension }
        return installed.first { $0.sources.contains { $0.id == sourceId } }
    }

    func source(id: Int64) -> SourceInfo? {
        allSources.first { $0.id == id }
    }

    func installedVersion(of packageName: String) -> InstalledExtension? {
        installed.first { $0.id == packageName }
    }

    func hasUpdate(_ item: CatalogExtension) -> Bool {
        guard let current = installedVersion(of: item.packageName) else { return false }
        return item.versionCode > current.versionCode
    }

    /// Installed extensions whose repository published a newer version.
    var updatableExtensions: [CatalogExtension] {
        catalog.filter { hasUpdate($0) && isAllowed($0) }
    }

    var updateCount: Int { updatableExtensions.count }

    func updateAll() async {
        for item in updatableExtensions {
            await install(item)
        }
    }

    // MARK: - Repositories

    func addRepository(_ text: String) async {
        guard let url = ExtensionIndex.normalizedURL(text) else {
            lastError = "Esa no parece una URL válida."
            return
        }
        guard !repositories.contains(where: { $0.url == url }) else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let store = try await ExtensionIndex.fetch(url)
            repositories.append(ExtensionRepository(url: url, name: store.name))
            Storage.save(repositories, to: Self.repositoriesFile)
            mergeCatalog(store.extensions, from: url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeRepository(_ repository: ExtensionRepository) {
        repositories.removeAll { $0.url == repository.url }
        Storage.save(repositories, to: Self.repositoriesFile)
        catalog.removeAll { $0.repositoryURL == repository.url }
    }

    func refreshCatalog() async {
        guard !repositories.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var merged: [CatalogExtension] = []
        for repository in repositories {
            do {
                let store = try await ExtensionIndex.fetch(repository.url)
                merged.append(contentsOf: store.extensions)
            } catch {
                lastError = "\(repository.name): \(error.localizedDescription)"
            }
        }
        catalog = deduplicated(merged)
        lastCatalogRefresh = Date()
        backfillRatings()
    }

    /// When the catalog was last fetched in this run of the app.
    private var lastCatalogRefresh: Date?

    /// Keeps the update badge honest without hammering the repositories.
    func refreshCatalogIfStale() async {
        let stale = lastCatalogRefresh.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
        guard stale else { return }
        await refreshCatalog()
    }

    private func mergeCatalog(_ items: [CatalogExtension], from url: URL) {
        catalog = deduplicated(catalog.filter { $0.repositoryURL != url } + items)
        backfillRatings()
    }

    private func deduplicated(_ items: [CatalogExtension]) -> [CatalogExtension] {
        var best: [String: CatalogExtension] = [:]
        // The whole catalog is kept, restricted entries included: the exceptions picker lists
        // them, and loosening the restriction must not need a refetch.
        for item in items where item.isSupported {
            if let existing = best[item.packageName], existing.versionCode >= item.versionCode { continue }
            best[item.packageName] = item
        }
        return best.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Install

    func install(_ item: CatalogExtension) async {
        guard !installing.contains(item.packageName) else { return }
        guard isAllowed(item) else {
            lastError = NSLocalizedString(
                "La restricción de contenido no permite esta extensión.", comment: ""
            )
            return
        }
        installing.insert(item.packageName)
        defer { installing.remove(item.packageName) }

        let previous = installedVersion(of: item.packageName)
        let fileName = "\(item.packageName)-\(item.versionCode).jar"
        let destination = Storage.extensionsDirectory.appendingPathComponent(fileName)
        do {
            let (temporary, response) = try await URLSession.shared.download(from: item.jarURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ExtensionIndexError.badResponse(http.statusCode)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)

            // A repository that does not rate its extensions leaves only the JAR's manifest
            // to go by. Rated ones are trusted: MIXED extensions carry the same manifest flag
            // as NSFW ones, so checking it there would block every MIXED extension.
            var rating = item.contentWarning
            if rating == ContentFilter.unrated,
               try await JVMEngine.shared.declaresAdultContent(jarURL: destination) {
                rating = ContentFilter.adultRating
            }
            guard ContentFilter.allows(rating: rating, packageName: item.packageName) else {
                throw ExtensionBlockedError()
            }

            let sources = try await JVMEngine.shared.inspectSources(
                extensionId: item.packageName,
                jarURL: destination
            )
            let record = InstalledExtension(
                id: item.packageName,
                name: item.name,
                versionName: item.versionName,
                versionCode: item.versionCode,
                iconURL: item.iconURL,
                jarFileName: fileName,
                nsfw: rating >= ContentFilter.adultRating,
                repositoryURL: item.repositoryURL,
                sources: sources,
                contentRating: rating
            )
            installed.removeAll { $0.id == item.packageName }
            installed.append(record)
            installed.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Storage.saveNow(installed, to: Self.installedFile)

            if let previous, previous.jarFileName != fileName {
                try? FileManager.default.removeItem(at: previous.jarURL)
            }
            // Its sources come back if a looser restriction had hidden them.
            enforceContentPolicy()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            lastError = "\(item.name): \(error.localizedDescription)"
        }
    }

    func uninstall(_ record: InstalledExtension) {
        installed.removeAll { $0.id == record.id }
        Storage.saveNow(installed, to: Self.installedFile)
        JVMEngine.shared.forget(extensionId: record.id)
        try? FileManager.default.removeItem(at: record.jarURL)
    }
}

struct ExtensionBlockedError: LocalizedError {
    var errorDescription: String? {
        NSLocalizedString(
            "Esta extensión es solo para adultos y la restricción de contenido no la permite.",
            comment: ""
        )
    }
}
