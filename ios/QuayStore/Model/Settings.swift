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

/// Everything in Settings, saved in UserDefaults (secrets live in the Keychain).
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    private let d = UserDefaults.standard

    @Published var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    @Published var signingMode: SigningMode { didSet { d.set(signingMode.rawValue, forKey: "signingMode") } }
    @Published var appleEmail: String { didSet { d.set(appleEmail, forKey: "appleEmail") } }
    @Published var anisetteURL: String { didSet { d.set(anisetteURL, forKey: "anisetteURL") } }
    @Published var deviceAddress: String { didSet { d.set(deviceAddress, forKey: "deviceAddress") } }
    /// Separate App IDs for app extensions (widgets etc.): they work, but use the weekly 10 faster.
    @Published var registerExtensions: Bool { didSet { d.set(registerExtensions, forKey: "registerExtensions") } }
    @Published var includePrereleases: Bool { didSet { d.set(includePrereleases, forKey: "includePrereleases") } }
    @Published var notifyUpdates: Bool { didSet { d.set(notifyUpdates, forKey: "notifyUpdates") } }
    @Published var notifyExpiry: Bool { didSet { d.set(notifyExpiry, forKey: "notifyExpiry") } }
    /// Remove the IPA after installing (less space; refreshes then download it again).
    @Published var keepIPAs: Bool { didSet { d.set(keepIPAs, forKey: "keepIPAs") } }

    private init() {
        d.register(defaults: [
            "signingMode": SigningMode.appleID.rawValue,
            "anisetteURL": "https://ani.iloader.app",
            "deviceAddress": "10.7.0.1",
            "registerExtensions": true,
            "notifyUpdates": true,
            "notifyExpiry": true,
            "keepIPAs": true,
        ])
        onboardingDone = d.bool(forKey: "onboardingDone")
        signingMode = SigningMode(rawValue: d.string(forKey: "signingMode") ?? "") ?? .appleID
        appleEmail = d.string(forKey: "appleEmail") ?? ""
        anisetteURL = d.string(forKey: "anisetteURL") ?? "https://ani.iloader.app"
        deviceAddress = d.string(forKey: "deviceAddress") ?? "10.7.0.1"
        registerExtensions = d.bool(forKey: "registerExtensions")
        includePrereleases = d.bool(forKey: "includePrereleases")
        notifyUpdates = d.bool(forKey: "notifyUpdates")
        notifyExpiry = d.bool(forKey: "notifyExpiry")
        keepIPAs = d.bool(forKey: "keepIPAs")
    }

    var pairingFile: Data? { Keychain.data(for: Keychain.Key.pairing) }
    var hasPairingFile: Bool { pairingFile != nil }
    var hasAppleID: Bool { !appleEmail.isEmpty && Keychain.string(for: Keychain.Key.applePassword) != nil }
    var hasCertificate: Bool {
        Keychain.data(for: Keychain.Key.p12) != nil && Keychain.data(for: Keychain.Key.provision) != nil
    }
    var githubToken: String? {
        get { Keychain.string(for: Keychain.Key.githubToken) }
        set { Keychain.setString(newValue?.isEmpty == true ? nil : newValue, for: Keychain.Key.githubToken); objectWillChange.send() }
    }

    /// The version shown in Settings: app version (build) · core version.
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b)) · core \(coreVersion())"
    }
}
