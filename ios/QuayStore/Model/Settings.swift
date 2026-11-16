import Foundation
import SwiftUI

enum SigningMode: String, Codable, CaseIterable, Identifiable {
    case appleID
    case certificate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleID: return "Apple ID"
        case .certificate: return "Свой сертификат"
        }
    }
}

/// An Apple ID or a certificate to sign with. Secrets are in the Keychain under the account's id.
struct SigningAccount: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var kind: SigningMode
    /// Apple ID e-mail, or the certificate's name.
    var title: String
    /// Team name.
    var detail: String?

    var password: String? { Keychain.string(for: "\(id).password") }
    var p12: Data? { Keychain.data(for: "\(id).p12") }
    var p12Password: String { Keychain.string(for: "\(id).p12password") ?? "" }
    var provision: Data? { Keychain.data(for: "\(id).provision") }
    /// isideload's state for this Apple ID (anisette identity, certificate).
    var storageDir: String { Paths.support.appendingPathComponent("signing/\(id)", isDirectory: true).path }

    func forgetSecrets() {
        for k in ["password", "p12", "p12password", "provision"] { Keychain.set(nil, for: "\(id).\(k)") }
        try? FileManager.default.removeItem(atPath: storageDir)
    }
}

/// Everything in Settings, saved in UserDefaults (secrets live in the Keychain).
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    private let d = UserDefaults.standard

    @Published var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    @Published var signingMode: SigningMode { didSet { d.set(signingMode.rawValue, forKey: "signingMode") } }
    @Published var anisetteURL: String { didSet { d.set(anisetteURL, forKey: "anisetteURL") } }
    /// Makes the https manifest for installs with your own certificate (iOS requires one).
    @Published var manifestServer: String { didSet { d.set(manifestServer, forKey: "manifestServer") } }
    @Published var deviceAddress: String { didSet { d.set(deviceAddress, forKey: "deviceAddress") } }
    /// Separate App IDs for app extensions (widgets etc.): they work, but use the weekly 10 faster.
    @Published var registerExtensions: Bool { didSet { d.set(registerExtensions, forKey: "registerExtensions") } }
    @Published var includePrereleases: Bool { didSet { d.set(includePrereleases, forKey: "includePrereleases") } }
    @Published var notifyUpdates: Bool { didSet { d.set(notifyUpdates, forKey: "notifyUpdates") } }
    @Published var notifyExpiry: Bool { didSet { d.set(notifyExpiry, forKey: "notifyExpiry") } }
    /// Keep the IPA after installing (refreshes then don't download again).
    @Published var keepIPAs: Bool { didSet { d.set(keepIPAs, forKey: "keepIPAs") } }
    /// "system", "light", "dark".
    @Published var appearance: String { didSet { d.set(appearance, forKey: "appearance") } }
    /// Hex of the accent color, "" = the app's own.
    @Published var accent: String { didSet { d.set(accent, forKey: "accent") } }

    @Published private(set) var accounts: [SigningAccount] { didSet { saveAccounts() } }
    @Published private(set) var activeAccountID: String? { didSet { d.set(activeAccountID, forKey: "activeAccount") } }

    static let defaultManifestServer = "https://api.palera.in/genPlist"
    static let accents = ["", "#3478F6", "#30B0C7", "#34C759", "#AF52DE", "#FF2D55", "#8E8E93"]

    private init() {
        d.register(defaults: [
            "signingMode": SigningMode.appleID.rawValue,
            "anisetteURL": "https://ani.iloader.app",
            "manifestServer": Self.defaultManifestServer,
            "deviceAddress": "10.7.0.1",
            "registerExtensions": true,
            "notifyUpdates": true,
            "notifyExpiry": true,
            "keepIPAs": true,
            "appearance": "system",
            "accent": "",
        ])
        onboardingDone = d.bool(forKey: "onboardingDone")
        signingMode = SigningMode(rawValue: d.string(forKey: "signingMode") ?? "") ?? .appleID
        anisetteURL = d.string(forKey: "anisetteURL") ?? "https://ani.iloader.app"
        manifestServer = d.string(forKey: "manifestServer") ?? Self.defaultManifestServer
        deviceAddress = d.string(forKey: "deviceAddress") ?? "10.7.0.1"
        registerExtensions = d.bool(forKey: "registerExtensions")
        includePrereleases = d.bool(forKey: "includePrereleases")
        notifyUpdates = d.bool(forKey: "notifyUpdates")
        notifyExpiry = d.bool(forKey: "notifyExpiry")
        keepIPAs = d.bool(forKey: "keepIPAs")
        appearance = d.string(forKey: "appearance") ?? "system"
        accent = d.string(forKey: "accent") ?? ""
        accounts = (d.data(forKey: "accounts")).flatMap { try? JSONDecoder().decode([SigningAccount].self, from: $0) } ?? []
        activeAccountID = d.string(forKey: "activeAccount")
        migrateSingleAccount()
    }

    private func saveAccounts() { d.set(try? JSONEncoder().encode(accounts), forKey: "accounts") }

    /// 0.1.0 kept one Apple ID and one certificate under fixed keys: move them into accounts.
    private func migrateSingleAccount() {
        if let email = d.string(forKey: "appleEmail"), !email.isEmpty, let pw = Keychain.string(for: "apple.password") {
            let a = SigningAccount(kind: .appleID, title: email)
            Keychain.setString(pw, for: "\(a.id).password")
            accounts.append(a)
            if signingMode == .appleID { activeAccountID = a.id }
        }
        if let p12 = Keychain.data(for: "cert.p12"), let prov = Keychain.data(for: "cert.provision") {
            let a = SigningAccount(kind: .certificate, title: "Сертификат")
            Keychain.set(p12, for: "\(a.id).p12")
            Keychain.set(prov, for: "\(a.id).provision")
            Keychain.setString(Keychain.string(for: "cert.password"), for: "\(a.id).p12password")
            accounts.append(a)
            if signingMode == .certificate { activeAccountID = a.id }
        }
        // Observers don't run inside init: save by hand.
        saveAccounts()
        d.set(activeAccountID, forKey: "activeAccount")
        d.removeObject(forKey: "appleEmail")
        for k in ["apple.password", "cert.p12", "cert.provision", "cert.password"] { Keychain.set(nil, for: k) }
    }

    // MARK: accounts

    var activeAccount: SigningAccount? { accounts.first { $0.id == activeAccountID } }

    func activate(_ a: SigningAccount) {
        activeAccountID = a.id
        signingMode = a.kind
    }

    /// Adds or replaces (same kind and title) and makes it active.
    @discardableResult
    func save(_ a: SigningAccount) -> SigningAccount {
        if let i = accounts.firstIndex(where: { $0.id == a.id || ($0.kind == a.kind && $0.title == a.title) }) {
            var kept = a
            kept.id = accounts[i].id
            accounts[i] = kept
            activate(kept)
            return kept
        }
        accounts.append(a)
        activate(a)
        return a
    }

    func remove(_ a: SigningAccount) {
        a.forgetSecrets()
        accounts.removeAll { $0.id == a.id }
        if activeAccountID == a.id { activeAccountID = accounts.first(where: { $0.kind == signingMode })?.id }
    }

    var hasCertificate: Bool { activeAccount?.kind == .certificate }

    // MARK: other

    var pairingFile: Data? { Keychain.data(for: Keychain.Key.pairing) }
    var hasPairingFile: Bool { pairingFile != nil }
    var githubToken: String? {
        get { Keychain.string(for: Keychain.Key.githubToken) }
        set { Keychain.setString(newValue?.isEmpty == true ? nil : newValue, for: Keychain.Key.githubToken); objectWillChange.send() }
    }

    var colorScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }
    var accentColor: Color { Color(hex: accent) ?? .accentColor }

    /// The version shown in Settings: app version (build) · core version.
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b)) · core \(coreVersion())"
    }

    // MARK: export / import (no certificates, passwords or pairing file)

    struct Exported: Codable {
        var version = 1
        var anisetteURL: String
        var manifestServer: String
        var deviceAddress: String
        var registerExtensions: Bool
        var includePrereleases: Bool
        var notifyUpdates: Bool
        var notifyExpiry: Bool
        var keepIPAs: Bool
        var appearance: String
        var accent: String
        var sources: [ExportedSource]
    }

    struct ExportedSource: Codable {
        var url: String
        var kind: SourceRecord.Kind
    }

    func exportFile(sources: [SourceRecord]) throws -> URL {
        let e = Exported(anisetteURL: anisetteURL, manifestServer: manifestServer, deviceAddress: deviceAddress,
                         registerExtensions: registerExtensions, includePrereleases: includePrereleases,
                         notifyUpdates: notifyUpdates, notifyExpiry: notifyExpiry, keepIPAs: keepIPAs,
                         appearance: appearance, accent: accent,
                         sources: sources.map { ExportedSource(url: $0.url, kind: $0.kind) })
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("QuayStore-settings.json")
        try enc.encode(e).write(to: url, options: .atomic)
        return url
    }

    /// Applies the settings; returns the sources to add.
    func importFile(_ data: Data) throws -> [ExportedSource] {
        guard let e = try? JSONDecoder().decode(Exported.self, from: data) else {
            throw QuayMessage("Это не файл настроек Quay Store")
        }
        anisetteURL = e.anisetteURL
        manifestServer = e.manifestServer
        deviceAddress = e.deviceAddress
        registerExtensions = e.registerExtensions
        includePrereleases = e.includePrereleases
        notifyUpdates = e.notifyUpdates
        notifyExpiry = e.notifyExpiry
        keepIPAs = e.keepIPAs
        appearance = e.appearance
        accent = e.accent
        return e.sources
    }
}
