import Foundation

/// A source the user added: an AltStore-format JSON, or a GitHub repository followed by its releases.
struct SourceRecord: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case json, github }

    var url: String
    var kind: Kind
    var addedAt: Date = Date()
    /// The last good JSON (json sources), so the store works offline.
    var cachedJSON: String?
    var lastRefreshed: Date?
    var lastError: String?
    var id: String { url }
}

/// An app Quay installed, as Quay remembers it.
struct InstalledRecord: Codable, Identifiable, Hashable {
    /// Bundle id on the device (free accounts append the team id).
    var installedBundleId: String
    /// Where it came from: the source URL and the app's bundle id there (nil for a local .ipa).
    var sourceURL: String?
    var sourceBundleId: String?
    var name: String
    var version: String
    var buildVersion: String?
    var sha256: String?
    var fingerprint: String?
    var iconURL: String?
    var downloadURL: String?
    /// File name in Paths.ipas.
    var ipaFile: String?
    var expiresAt: Date?
    var signedWith: SigningMode
    var increasedMemory: Bool = false
    var installedAt: Date = Date()

    var id: String { installedBundleId }

    var installedState: InstalledState {
        InstalledState(version: version, buildVersion: buildVersion, fingerprint: fingerprint, sha256: sha256)
    }

    var ipaURL: URL? {
        guard let ipaFile else { return nil }
        let url = Paths.ipas.appendingPathComponent(ipaFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// JSON files in Application Support.
enum RecordStore {
    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        let url = Paths.support.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, as name: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(value) else { return }
        try? data.write(to: Paths.support.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
