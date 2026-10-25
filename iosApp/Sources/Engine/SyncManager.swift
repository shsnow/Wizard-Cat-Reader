import Combine
import CryptoKit
import Foundation

/// Folder-based sync between devices, with no accounts and no servers: the user
/// picks a cloud folder in the Files app (iCloud Drive, Google Drive, Dropbox…),
/// the app keeps its own `.tachibk` backup there and merges any newer backup it
/// finds. Mihon on Android pointing its automatic backups at the same folder
/// closes the loop: progress flows both ways through the user's own cloud.
@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()

    @Published private(set) var folderName: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncing = false

    private let defaults = UserDefaults.standard
    private static let bookmarkKey = "syncFolderBookmark"
    private static let folderNameKey = "syncFolderName"
    private static let lastSyncKey = "syncLastDate"
    /// File name → last imported modification time (seconds since 1970).
    private static let importedKey = "syncImportedFiles"
    private static let deviceIdKey = "syncDeviceId"
    private static let lastExportHashKey = "syncLastExportHash"

    /// This device's own file in the folder; never re-imported here. The name is
    /// per-device: two devices sharing one name would skip each other's data as
    /// "their own" and overwrite it, and sync between them would never happen.
    private var exportName: String {
        if let id = defaults.string(forKey: Self.deviceIdKey) {
            return "wizardcatreader-sync-\(id).tachibk"
        }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Self.deviceIdKey)
        return "wizardcatreader-sync-\(id).tachibk"
    }

    private init() {
        folderName = defaults.string(forKey: Self.folderNameKey)
        lastSync = defaults.object(forKey: Self.lastSyncKey) as? Date
    }

    var isConfigured: Bool { defaults.data(forKey: Self.bookmarkKey) != nil }

    // MARK: - Folder choice

    func setFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData()
            defaults.set(bookmark, forKey: Self.bookmarkKey)
            defaults.set(url.lastPathComponent, forKey: Self.folderNameKey)
            defaults.removeObject(forKey: Self.importedKey)
            folderName = url.lastPathComponent
            lastError = nil
        } catch {
            lastError = String(
                format: NSLocalizedString("No se pudo guardar el acceso a la carpeta: %@", comment: ""),
                error.localizedDescription
            )
        }
    }

    func clearFolder() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.folderNameKey)
        defaults.removeObject(forKey: Self.importedKey)
        folderName = nil
        lastError = nil
    }

    // MARK: - Sync

    /// Merges newer backups from the folder, then writes this device's own.
    /// `exportOnly` skips the import pass — used when the app goes to the
    /// background, where iOS only grants a short window.
    func sync(library: LibraryStore, extensions: ExtensionManager, exportOnly: Bool = false) async {
        guard !isSyncing, let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return }
        isSyncing = true
        defer { isSyncing = false }

        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        else {
            lastError = NSLocalizedString(
                "La carpeta de sincronización ya no está disponible. Elígela de nuevo.",
                comment: ""
            )
            return
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        if stale, let fresh = try? folder.bookmarkData() {
            defaults.set(fresh, forKey: Self.bookmarkKey)
        }

        var problem: String?

        if !exportOnly {
            problem = await importNewBackups(from: folder, library: library, extensions: extensions)
        }

        // Export after importing, so the written backup carries the merged state.
        // An empty library never overwrites a good backup. Local (CBZ) series are
        // skipped by the export, so a library with only those would write an empty
        // backup that other devices then reject as "not a backup".
        if library.entries.values.contains(where: { !$0.manga.isLocal }) {
            do {
                let data = try MihonBackupExport.make(library: library, extensions: extensions)
                let destination = folder.appendingPathComponent(exportName)
                // An unchanged payload is not rewritten: bumping the file's date on
                // every foregrounding would make other devices re-import it for nothing.
                let digest = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
                if digest != defaults.string(forKey: Self.lastExportHashKey)
                    || !FileManager.default.fileExists(atPath: destination.path) {
                    try await Task.detached(priority: .utility) {
                        do {
                            try data.write(to: destination, options: .atomic)
                        } catch {
                            // Some Files providers refuse the atomic rename; plain replace then.
                            try data.write(to: destination)
                        }
                    }.value
                    defaults.set(digest, forKey: Self.lastExportHashKey)
                }
                lastSync = Date()
                defaults.set(lastSync, forKey: Self.lastSyncKey)
            } catch {
                problem = problem ?? String(
                    format: NSLocalizedString("No se pudo escribir la copia: %@", comment: ""),
                    error.localizedDescription
                )
            }
        }

        lastError = problem
    }

    /// Returns a message for the first file that failed, or nil.
    private func importNewBackups(
        from folder: URL,
        library: LibraryStore,
        extensions: ExtensionManager
    ) async -> String? {
        var imported = (defaults.dictionary(forKey: Self.importedKey) as? [String: Double]) ?? [:]
        defer { defaults.set(imported, forKey: Self.importedKey) }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let ownName = exportName
        let backups = files
            .filter {
                $0.pathExtension.lowercased() == "tachibk" && $0.lastPathComponent != ownName
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var problem: String?
        for file in backups {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let stamp = modified.timeIntervalSince1970
            if let seen = imported[file.lastPathComponent], seen >= stamp { continue }

            // A read failure (file not downloaded yet, provider offline) is NOT
            // remembered: downloading later does not change the file's date, so
            // recording it here would skip the backup forever.
            let raw: Data
            do {
                raw = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: file)
                }.value
            } catch {
                if problem == nil {
                    problem = "\(file.lastPathComponent): \(error.localizedDescription)"
                }
                continue
            }

            do {
                // Gunzip + protobuf decode are heavy; off the main actor.
                let backup = try await Task.detached(priority: .userInitiated) {
                    try MihonBackup.decode(raw)
                }.value
                _ = try MihonBackupImporter.restore(
                    backup, into: library, extensions: extensions
                )
                imported[file.lastPathComponent] = stamp
            } catch MihonBackupError.noFavorites {
                // An empty backup is not an error; just don't look at it again.
                imported[file.lastPathComponent] = stamp
            } catch {
                // A genuinely broken file is remembered, so it does not re-fail on
                // every launch; a changed file carries a newer date and retries.
                imported[file.lastPathComponent] = stamp
                if problem == nil {
                    problem = "\(file.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
        return problem
    }
}
