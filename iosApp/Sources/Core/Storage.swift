import Foundation

/// Small JSON-file persistence. The shared Kotlin database replaces this once backup restore
/// lands; until then the formats stay deliberately simple.
///
/// Writes are coalesced: `save` only records the latest value of a file, and the encode plus
/// the atomic write run once, on a background queue, a moment after the last change. A
/// library update touching hundreds of series used to re-encode the whole library on the
/// main thread once per series. `flush()` forces pending writes out (app going to the
/// background or terminating).
enum Storage {
    // The folder keeps the pre-rebrand name: renaming it would orphan installed users' data.
    static let supportDirectory: URL = directory(
        in: .applicationSupportDirectory, named: "MokaReader"
    )

    static let extensionsDirectory: URL = {
        let url = supportDirectory.appendingPathComponent("Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let cacheDirectory: URL = directory(in: .cachesDirectory, named: "MokaReader")

    private static func directory(
        in base: FileManager.SearchPathDirectory,
        named name: String
    ) -> URL {
        let root = FileManager.default.urls(for: base, in: .userDomainMask)[0]
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load<Value: Decodable>(_ type: Value.Type, from name: String) -> Value? {
        // A write still waiting in the queue is newer than the file on disk.
        StorageWriter.shared.flush()
        let url = supportDirectory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Schedules the write; the value is snapshotted now (value types copy on write, so
    /// this is cheap) and encoded later, off the main thread.
    static func save<Value: Encodable>(_ value: Value, to name: String) {
        StorageWriter.shared.enqueue(name) { try? JSONEncoder().encode(value) }
    }

    /// For records that must be on disk before the next step (an extension's JAR is
    /// deleted right after its record changes).
    static func saveNow<Value: Encodable>(_ value: Value, to name: String) {
        save(value, to: name)
        flush()
    }

    /// Writes everything pending, blocking until done.
    static func flush() {
        StorageWriter.shared.flush()
    }
}

/// The serial writer behind `Storage.save`. One pending snapshot per file name: a newer
/// save replaces the older one before it is ever encoded.
private final class StorageWriter: @unchecked Sendable {
    static let shared = StorageWriter()

    private let lock = NSLock()
    private var pending: [String: () -> Data?] = [:]
    private var scheduled = false
    private let queue = DispatchQueue(label: "cl.jonas.wizardcat.storage", qos: .utility)
    private static let delay: TimeInterval = 1.0

    func enqueue(_ name: String, encode: @escaping () -> Data?) {
        lock.lock()
        pending[name] = encode
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard needsSchedule else { return }
        queue.asyncAfter(deadline: .now() + Self.delay) { [self] in drain() }
    }

    func flush() {
        lock.lock()
        let empty = pending.isEmpty
        lock.unlock()
        if empty { return }
        queue.sync { drain() }
    }

    /// Runs on `queue`.
    private func drain() {
        lock.lock()
        let jobs = pending
        pending.removeAll()
        scheduled = false
        lock.unlock()
        for (name, encode) in jobs {
            guard let data = encode() else { continue }
            let url = Storage.supportDirectory.appendingPathComponent(name)
            try? data.write(to: url, options: .atomic)
        }
    }
}
