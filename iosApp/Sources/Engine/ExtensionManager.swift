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

    private static let repositoriesFile = "repositories.json"
    private static let installedFile = "extensions.json"

    private init() {
        repositories = Storage.load([ExtensionRepository].self, from: Self.repositoriesFile) ?? []
        installed = Storage.load([InstalledExtension].self, from: Self.installedFile) ?? []
        // Drop records whose JAR went missing (for example after an OS storage purge).
        installed.removeAll { !FileManager.default.fileExists(atPath: $0.jarURL.path) }
        // Family friendly: anything flagged as adult is removed, even if an older build kept it.
        for record in installed where record.nsfw {
            try? FileManager.default.removeItem(at: record.jarURL)
        }
        if installed.contains(where: \.nsfw) {
            installed.removeAll(where: \.nsfw)
            Storage.saveNow(installed, to: Self.installedFile)
        }
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
        catalog.filter { hasUpdate($0) }
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
    }

    private func deduplicated(_ items: [CatalogExtension]) -> [CatalogExtension] {
        var best: [String: CatalogExtension] = [:]
        for item in items where item.isSupported && !item.nsfw {
            if let existing = best[item.packageName], existing.versionCode >= item.versionCode { continue }
            best[item.packageName] = item
        }
        return best.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Install

    func install(_ item: CatalogExtension) async {
        guard !installing.contains(item.packageName) else { return }
        guard !item.nsfw else {
            lastError = "Wizard Cat Reader no permite extensiones de contenido para adultos."
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

            // The repository index can be wrong or edited; the JAR's own manifest is checked
            // too. Allowlisted MIXED extensions inherit `nsfw = 1` in their manifest from the
            // binary flag, so for them the per-series keyword filter does the blocking instead.
            if !ContentFilter.isMixedException(item.packageName),
               try await JVMEngine.shared.declaresAdultContent(jarURL: destination) {
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
                nsfw: item.nsfw,
                repositoryURL: item.repositoryURL,
                sources: sources
            )
            installed.removeAll { $0.id == item.packageName }
            installed.append(record)
            installed.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Storage.saveNow(installed, to: Self.installedFile)

            if let previous, previous.jarFileName != fileName {
                try? FileManager.default.removeItem(at: previous.jarURL)
            }
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
        "Esta extensión está marcada como contenido para adultos y Wizard Cat Reader no la permite."
    }
}
