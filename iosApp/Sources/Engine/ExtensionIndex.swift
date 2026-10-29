import Foundation
import WizardJVMRunner

/// Minimal protobuf wire-format reader, enough for Mihon's extension repository index.
struct ProtobufReader {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
        case fixed64(UInt64)
        case fixed32(UInt32)
    }

    enum ReadError: Error {
        case truncated
        case unsupportedWireType(UInt64)
    }

    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func nextField() throws -> (number: UInt64, value: Value)? {
        guard offset < data.endIndex else { return nil }
        let key = try readVarint()
        let number = key >> 3
        switch key & 0x7 {
            case 0:
                return (number, .varint(try readVarint()))
            case 1:
                return (number, .fixed64(try readLittleEndian(8)))
            case 2:
                // Int(exactly:) and the subtraction keep a corrupt length from trapping.
                let rawLength = try readVarint()
                guard let length = Int(exactly: rawLength), length <= data.endIndex - offset else {
                    throw ReadError.truncated
                }
                let slice = data.subdata(in: offset..<(offset + length))
                offset += length
                return (number, .bytes(slice))
            case 5:
                return (number, .fixed32(UInt32(truncatingIfNeeded: try readLittleEndian(4))))
            default:
                throw ReadError.unsupportedWireType(key & 0x7)
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < data.endIndex else { throw ReadError.truncated }
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw ReadError.truncated }
        }
    }

    private mutating func readLittleEndian(_ count: Int) throws -> UInt64 {
        guard count <= data.endIndex - offset else { throw ReadError.truncated }
        var result: UInt64 = 0
        for index in 0..<count {
            result |= UInt64(data[offset + index]) << (8 * UInt64(index))
        }
        offset += count
        return result
    }
}

enum ExtensionIndexError: LocalizedError {
    case legacyJSON
    case empty
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
            case .legacyJSON:
                return "Este repositorio entregó el formato antiguo (JSON). Usa la URL que termina en index.pb."
            case .empty:
                return "El repositorio no contiene extensiones compatibles."
            case .badResponse(let code):
                return "El repositorio respondió con el código HTTP \(code)."
        }
    }
}

/// Reads a Mihon extension repository (`index.pb`, optionally gzipped).
enum ExtensionIndex {
    struct Store {
        var name: String
        var extensions: [CatalogExtension]
    }

    /// Accepts the index URL itself or the folder that contains it.
    static func normalizedURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix("index.min.json") {
            trimmed = String(trimmed.dropLast("index.min.json".count)) + "index.pb"
        }
        guard var url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        let last = url.lastPathComponent.lowercased()
        if !(last.hasSuffix(".pb") || last.hasSuffix(".json") || last.hasSuffix(".gz")) {
            url.appendPathComponent("index.pb")
        }
        return url
    }

    static func fetch(_ url: URL) async throws -> Store {
        let data = try await download(url)
        var name = url.host ?? "Repositorio"
        var extensionList: Data?
        var listURL: String?

        // index.pb is normally a store message (name + list). Some repositories serve the bare
        // extension list instead; the two only differ by which fields are present.
        var reader = ProtobufReader(data)
        var isStore = false
        while let field = try reader.nextField() {
            guard case .bytes(let value) = field.value else { continue }
            switch field.number {
                case 1: name = string(value) ?? name
                case 101: extensionList = value; isStore = true
                case 102: listURL = string(value); isStore = true
                default: break
            }
        }

        let base = url.deletingLastPathComponent()
        let listData: Data
        if isStore {
            if let extensionList {
                listData = extensionList
            } else if let listURL, let resolved = URL(string: listURL, relativeTo: base)?.absoluteURL {
                listData = try await download(resolved)
            } else {
                throw ExtensionIndexError.empty
            }
        } else {
            listData = data
            name = url.host ?? "Repositorio"
        }

        var extensions: [CatalogExtension] = []
        var listReader = ProtobufReader(listData)
        while let field = try listReader.nextField() {
            guard field.number == 1, case .bytes(let value) = field.value else { continue }
            if let item = try decodeExtension(value, base: base, repository: url) {
                extensions.append(item)
            }
        }
        guard !extensions.isEmpty else { throw ExtensionIndexError.empty }
        return Store(
            name: name,
            extensions: extensions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        )
    }

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ExtensionIndexError.badResponse(http.statusCode)
        }
        var payload = data
        if payload.count > 2, payload[payload.startIndex] == 0x1F, payload[payload.startIndex + 1] == 0x8B {
            payload = try TachiJVMCompression.gunzip(payload)
        }
        if let first = payload.first(where: { ![0x20, 0x0A, 0x0D, 0x09].contains($0) }),
           first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            throw ExtensionIndexError.legacyJSON
        }
        return payload
    }

    private static func decodeExtension(_ data: Data, base: URL, repository: URL) throws -> CatalogExtension? {
        var reader = ProtobufReader(data)
        var name: String?
        var packageName: String?
        var extensionLib = ""
        var versionCode: Int64 = 0
        var versionName = ""
        var contentWarning: UInt64 = 0
        var iconURL: URL?
        var jarURL: URL?
        var sources: [CatalogSource] = []

        while let field = try reader.nextField() {
            switch (field.number, field.value) {
                case (1, .bytes(let value)): name = string(value)
                case (2, .bytes(let value)): packageName = string(value)
                case (3, .bytes(let value)):
                    let resources = try decodeResources(value, base: base)
                    iconURL = resources.icon
                    jarURL = resources.jar
                case (4, .bytes(let value)): extensionLib = string(value) ?? ""
                case (5, .varint(let value)): versionCode = Int64(bitPattern: value)
                case (6, .bytes(let value)): versionName = string(value) ?? ""
                case (7, .varint(let value)): contentWarning = value
                case (8, .bytes(let value)): sources.append(try decodeSource(value))
                default: break
            }
        }
        guard let name, let packageName, let jarURL else { return nil }
        return CatalogExtension(
            name: name,
            packageName: packageName,
            versionName: versionName,
            versionCode: versionCode,
            extensionLib: extensionLib,
            nsfw: contentWarning >= ContentFilter.adultRating,
            iconURL: iconURL,
            jarURL: jarURL,
            sources: sources,
            repositoryURL: repository,
            contentWarning: contentWarning
        )
    }

    private static func decodeResources(_ data: Data, base: URL) throws -> (icon: URL?, jar: URL?) {
        var reader = ProtobufReader(data)
        var icon: URL?
        var jar: URL?
        while let field = try reader.nextField() {
            guard case .bytes(let value) = field.value, let text = string(value), !text.isEmpty else { continue }
            let resolved = URL(string: text, relativeTo: base)?.absoluteURL
            switch field.number {
                case 2: icon = resolved
                case 501: jar = resolved
                default: break
            }
        }
        return (icon, jar)
    }

    private static func decodeSource(_ data: Data) throws -> CatalogSource {
        var reader = ProtobufReader(data)
        var id: Int64 = 0
        var name = ""
        var lang = ""
        while let field = try reader.nextField() {
            switch (field.number, field.value) {
                case (1, .varint(let value)): id = Int64(bitPattern: value)
                case (2, .bytes(let value)): name = string(value) ?? ""
                case (3, .bytes(let value)): lang = string(value) ?? ""
                default: break
            }
        }
        return CatalogSource(id: id, name: name, lang: lang)
    }

    private static func string(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
    }
}
