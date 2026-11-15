import Foundation
import Security

/// Folders inside the sandbox.
enum Paths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("quay", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let caches: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("quay", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Downloaded IPAs, kept for signature refreshes (iOS may clear Caches: then they are downloaded again).
    static let ipas: URL = {
        let url = caches.appendingPathComponent("ipas", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let github = caches.appendingPathComponent("github", isDirectory: true)

    /// isideload's state (anisette identity, the signing certificate).
    static var signingState: String { support.appendingPathComponent("signing", isDirectory: true).path }
}

/// Secrets: Apple ID password, pairing file, certificate, GitHub token.
enum Keychain {
    private static let service = "dev.neosay.quaystore"

    static func set(_ data: Data?, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var add = query
        add[kSecValueData as String] = data
        // Background refresh runs while the phone is locked: available after the first unlock.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func data(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func setString(_ s: String?, for key: String) { set(s.map { Data($0.utf8) }, for: key) }
    static func string(for key: String) -> String? { data(for: key).flatMap { String(data: $0, encoding: .utf8) } }

    enum Key {
        static let applePassword = "apple.password"
        static let pairing = "device.pairing"
        static let p12 = "cert.p12"
        static let p12Password = "cert.password"
        static let provision = "cert.provision"
        static let githubToken = "github.token"
    }
}

/// A readable message from any error, the core's included (their text is already Russian).
func errorText(_ error: Error) -> String {
    if let q = error as? QuayError {
        return findString(in: q) ?? "Отменено"
    }
    if let u = error as? URLError {
        switch u.code {
        case .notConnectedToInternet: return "Нет интернета"
        case .timedOut: return "Сервер не ответил вовремя"
        case .cannotFindHost, .cannotConnectToHost: return "Сервер недоступен"
        default: return u.localizedDescription
        }
    }
    if let s = error as? LocalizedError, let d = s.errorDescription { return d }
    return error.localizedDescription
}

private func findString(in value: Any) -> String? {
    if let s = value as? String { return s }
    for child in Mirror(reflecting: value).children {
        if let s = findString(in: child.value) { return s }
    }
    return nil
}

/// Errors made on the Swift side.
struct QuayMessage: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

extension Date {
    /// "через 5 дн.", "истекло"
    var daysLeftText: String {
        let secs = timeIntervalSinceNow
        if secs <= 0 { return "Подпись истекла" }
        let days = Int(secs / 86_400)
        if days >= 1 { return "Осталось \(days) дн." }
        let hours = max(1, Int(secs / 3600))
        return "Осталось \(hours) ч."
    }
}

extension Int64 {
    var date: Date { Date(timeIntervalSince1970: TimeInterval(self)) }
}

func byteCount(_ n: UInt64?) -> String? {
    guard let n, n > 0 else { return nil }
    return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}

/// ISO 8601 dates from sources, with or without fractional seconds, or a bare day.
func parseSourceDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withFullDate]
    return f.date(from: String(s.prefix(10)))
}
