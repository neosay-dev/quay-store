import Foundation
import UIKit

/// Download → check → sign → install, and signature refreshes. Shows its progress, asks for 2FA.
@MainActor
final class Installer: ObservableObject {
    static let shared = Installer()

    struct Job: Equatable {
        var title: String
        var iconURL: String?
        var stage: String
        var fraction: Double
    }

    @Published var job: Job?
    @Published var twoFactor: TwoFactorRequest?
    @Published var certificateChoice: [DevCertificate]?
    @Published var alert: String?
    @Published var account: AccountInfo?
    /// Quay's own signature (from its embedded profile).
    @Published private(set) var selfExpiresAt: Date? = SelfProfile.expirationDate()

    /// False in the background: nobody can type a 2FA code there, so the core is told to stop.
    var interactive = true

    private let settings = SettingsModel.shared
    private let catalog = Catalog.shared
    private lazy var observer = Observer(owner: self)

    // MARK: observer (called from Rust threads)

    final class Observer: SigningObserver, @unchecked Sendable {
        weak var owner: Installer?
        init(owner: Installer) { self.owner = owner }

        func progress(stage: InstallStage, fraction: Float) {
            Task { @MainActor in self.owner?.update(stage: stage, fraction: Double(fraction)) }
        }

        func twoFactorRequired(request: TwoFactorRequest) {
            Task { @MainActor in
                guard let owner = self.owner, owner.interactive else {
                    answerTwoFactor(answer: .cancel)
                    return
                }
                owner.twoFactor = request
            }
        }

        func certificatesFull(certificates: [DevCertificate]) {
            Task { @MainActor in
                guard let owner = self.owner, owner.interactive else {
                    answerCertificates(revokeSerials: nil)
                    return
                }
                owner.certificateChoice = certificates
            }
        }
    }

    private func update(stage: InstallStage, fraction: Double) {
        guard var j = job else { return }
        let text = Self.stageText(stage)
        if text != j.stage { Log.write("\(j.title): \(text)") }
        j.stage = text
        j.fraction = fraction
        job = j
    }

    static func stageText(_ s: InstallStage) -> String {
        switch s {
        case .connecting: return "Подключение к iPhone"
        case .signingIn: return "Вход в Apple ID"
        case .registering: return "Регистрация устройства"
        case .signing: return "Подпись"
        case .uploading: return "Передача"
        case .installing: return "Установка"
        case .done: return "Готово"
        }
    }

    // MARK: Apple ID

    /// Signs in and saves the Apple ID as an account (made active). An existing one keeps its state folder.
    func signIn(email: String, password: String) async throws -> AccountInfo {
        var acc = settings.accounts.first { $0.kind == .appleID && $0.title == email } ?? SigningAccount(kind: .appleID, title: email)
        let info = try await signInTryingServers(email: email, password: password, storageDir: acc.storageDir)
        acc.detail = info.teamName
        acc = settings.save(acc)
        Keychain.setString(password, for: "\(acc.id).password")
        account = info
        Log.write("Вход в Apple ID: \(email), команда \(info.teamName)")
        return info
    }

    func signOut() async {
        await appleIdSignOut()
        account = nil
    }

    /// Makes sure the session is the active Apple ID's (switching accounts signs in again).
    func ensureSession() async throws {
        guard let acc = settings.activeAccount, acc.kind == .appleID, let pw = acc.password else {
            throw QuayMessage("Добавь Apple ID: Настройки → Аккаунты и сертификаты")
        }
        if let a = await appleIdCurrent(), a.email == acc.title {
            account = a
            return
        }
        account = try await signInTryingServers(email: acc.title, password: pw, storageDir: acc.storageDir)
    }

    /// The account's signing certificate as .p12 with your password, ready to share.
    func exportCertificate(password: String) async throws -> URL {
        try await ensureSession()
        let data = try await exportAppleCertificate(password: password, observer: observer)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(account?.email ?? "apple-id").p12")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The chosen anisette server; if it is down, the first one from the public list that answers.
    private func signInTryingServers(email: String, password: String, storageDir: String) async throws -> AccountInfo {
        do {
            return try await appleIdSignIn(email: email, password: password, anisetteUrl: settings.anisetteURL,
                                           storageDir: storageDir, observer: observer)
        } catch {
            let text = errorText(error)
            guard text.lowercased().contains("anisette") else { throw error }
            let servers = (try? await fetchAnisetteServers()) ?? []
            for s in servers where s.address != settings.anisetteURL {
                guard (try? await checkAnisetteServer(address: s.address)) != nil else { continue }
                let info = try await appleIdSignIn(email: email, password: password, anisetteUrl: s.address,
                                                   storageDir: storageDir, observer: observer)
                settings.anisetteURL = s.address
                Log.write("Anisette: переключился на \(s.address)")
                return info
            }
            throw error
        }
    }

    // MARK: install

    /// `tweaks`: .dylib files to inject; empty keeps the ones the installed copy had.
    func install(_ app: CatalogApp, version: AppVersion? = nil, tweaks: [URL] = []) async {
        guard let v = version ?? app.latest else { return }
        await run(title: app.app.name, icon: app.app.iconUrl) {
            let existing = self.catalog.installedRecord(for: app)
            let ipa = try await self.fetchIPA(v.downloadUrl, sha256: v.sha256)
            let info = try inspectIpa(path: ipa.path)
            try self.checkOS(info.minOsVersion ?? v.minOsVersion)
            let increased = app.app.entitlements.contains("com.apple.developer.kernel.increased-memory-limit")
            let tweakFiles = try tweaks.isEmpty ? (existing?.tweaks ?? []) : Self.storeTweaks(tweaks)
            let toSign = try self.withTweaks(ipa, tweakFiles)
            let outcome = try await self.sign(ipaPath: toSign.path, increasedMemory: increased, replacing: existing?.installedBundleId)
            var record = InstalledRecord(
                installedBundleId: outcome.installedBundleId,
                sourceURL: app.source.sourceUrl,
                sourceBundleId: app.app.bundleId,
                name: app.app.name,
                version: v.version,
                buildVersion: v.buildVersion ?? info.buildVersion,
                sha256: info.sha256,
                fingerprint: v.fingerprint,
                iconURL: app.app.iconUrl ?? Self.saveIcon(info.iconPng, for: app.app.bundleId) ?? existing?.iconURL,
                downloadURL: v.downloadUrl,
                ipaFile: ipa.lastPathComponent,
                expiresAt: outcome.expiresAt?.date,
                signedWith: self.settings.signingMode,
                increasedMemory: increased,
                tweaks: tweakFiles.isEmpty ? nil : tweakFiles,
                accountID: self.settings.activeAccountID
            )
            if !self.settings.keepIPAs {
                try? FileManager.default.removeItem(at: ipa)
                record.ipaFile = nil
            }
            self.finish(record, replacing: existing)
        }
    }

    /// An .ipa opened from Files, Safari or another app.
    func installLocal(_ url: URL) async {
        await run(title: url.deletingPathExtension().lastPathComponent, icon: nil) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = Paths.ipas.appendingPathComponent("local-\(UUID().uuidString).ipa")
            try FileManager.default.copyItem(at: url, to: dest)
            let info = try inspectIpa(path: dest.path)
            try self.checkOS(info.minOsVersion)
            self.job?.title = info.name
            let existing = self.catalog.installed.first { $0.sourceURL == nil && $0.sourceBundleId == info.bundleId }
            let outcome = try await self.sign(ipaPath: dest.path, increasedMemory: false, replacing: existing?.installedBundleId)
            let record = InstalledRecord(
                installedBundleId: outcome.installedBundleId,
                sourceURL: nil,
                sourceBundleId: info.bundleId,
                name: info.name,
                version: info.version,
                buildVersion: info.buildVersion,
                sha256: info.sha256,
                fingerprint: "sha256:\(info.sha256)",
                iconURL: Self.saveIcon(info.iconPng, for: info.bundleId),
                downloadURL: nil,
                ipaFile: dest.lastPathComponent,
                expiresAt: outcome.expiresAt?.date,
                signedWith: self.settings.signingMode,
                accountID: self.settings.activeAccountID
            )
            self.finish(record, replacing: existing)
        }
    }

    /// Signs again with a fresh profile (another 7 days for a free Apple ID). Same bundle id: data stays.
    func refresh(_ record: InstalledRecord) async {
        await run(title: record.name, icon: record.iconURL) {
            try await self.refreshNow(record)
        }
    }

    private func refreshNow(_ record: InstalledRecord) async throws {
        let ipa: URL
        if let cached = record.ipaURL {
            ipa = cached
        } else if let dl = record.downloadURL {
            ipa = try await fetchIPA(dl, sha256: record.sha256)
        } else {
            throw QuayMessage("Файл «\(record.name)» удалён из кэша, а ссылки на него нет. Установи его заново")
        }
        let toSign = try withTweaks(ipa, record.tweaks ?? [])
        let outcome = try await sign(ipaPath: toSign.path, increasedMemory: record.increasedMemory, replacing: record.installedBundleId)
        var r = record
        r.expiresAt = outcome.expiresAt?.date
        r.signedWith = settings.signingMode
        r.accountID = settings.activeAccountID
        r.installedBundleId = outcome.installedBundleId
        r.ipaFile = settings.keepIPAs ? ipa.lastPathComponent : nil
        if !settings.keepIPAs { try? FileManager.default.removeItem(at: ipa) }
        catalog.upsert(r)
        Notifier.scheduleExpiry(for: r)
    }

    /// Every app whose signature ends within `days` (all of them when `force`), Quay last: installing over
    /// itself ends Quay.
    @discardableResult
    func refreshExpiring(withinDays days: Double = 2, force: Bool = false) async -> (done: Int, failed: [String]) {
        let limit = Date().addingTimeInterval(days * 86_400)
        var done = 0
        var failed: [String] = []
        for r in catalog.installed where force || (r.expiresAt ?? .distantFuture) < limit {
            do {
                job = Job(title: r.name, iconURL: r.iconURL, stage: "Подготовка", fraction: 0)
                try await refreshNow(r)
                done += 1
            } catch {
                failed.append("\(r.name): \(errorText(error))")
            }
            job = nil
        }
        if force || (selfExpiresAt ?? .distantFuture) < limit {
            do {
                try await refreshSelfNow()
                done += 1
            } catch {
                failed.append("Quay Store: \(errorText(error))")
            }
        }
        return (done, failed)
    }

    func refreshAll() async {
        await runPlain {
            let result = await self.refreshExpiring(force: true)
            if !result.failed.isEmpty { self.alert = result.failed.joined(separator: "\n") }
        }
    }

    /// Re-signs Quay Store from its own installed copy.
    func refreshSelf() async {
        await run(title: "Quay Store", icon: nil) { try await self.refreshSelfNow() }
    }

    private func refreshSelfNow() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("self-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: copy)
        // iOS ends Quay when the install finishes: what follows may never run.
        _ = try await sign(ipaPath: copy.path, increasedMemory: false, replacing: Bundle.main.bundleIdentifier)
        selfExpiresAt = SelfProfile.expirationDate()
    }

    func uninstall(_ record: InstalledRecord) async {
        await run(title: record.name, icon: record.iconURL) {
            guard let pairing = self.settings.pairingFile else {
                throw QuayMessage("Без pairing file Quay не может удалять приложения: удали его с домашнего экрана и выбери «Забыть» в меню приложения")
            }
            self.job?.stage = "Удаление"
            try await uninstallApp(pairingFile: pairing, address: self.settings.deviceAddress, bundleId: record.installedBundleId)
            self.catalog.removeInstalled(record.installedBundleId)
            Notifier.cancelExpiry(for: record)
        }
    }

    /// Drops records of apps that are no longer on the device (deleted from the home screen).
    func syncWithDevice() async {
        guard let pairing = settings.pairingFile, !catalog.installed.isEmpty else { return }
        guard let apps = try? await listDeviceApps(pairingFile: pairing, address: settings.deviceAddress) else { return }
        let ids = Set(apps.map(\.bundleId))
        for r in catalog.installed where !ids.contains(r.installedBundleId) {
            catalog.removeInstalled(r.installedBundleId)
            Notifier.cancelExpiry(for: r)
        }
    }

    // MARK: pieces

    private func sign(ipaPath: String, increasedMemory: Bool, replacing: String?) async throws -> InstallOutcome {
        switch settings.signingMode {
        case .appleID:
            guard let pairing = settings.pairingFile else {
                throw QuayMessage("Сначала добавь pairing file: Настройки → Устройство")
            }
            try await ensureSession()
            if account?.isFree ?? true {
                let others = catalog.activeFreeApps(account: settings.activeAccountID).filter { $0.installedBundleId != replacing }
                if others.count >= 2 && replacing != Bundle.main.bundleIdentifier {
                    let names = others.map(\.name).joined(separator: ", ")
                    throw QuayMessage("Бесплатный Apple ID держит только 3 приложения, и одно из них Quay Store. Удали одно из: \(names)")
                }
            }
            return try await installWithAppleId(
                ipaPath: ipaPath, pairingFile: pairing, deviceAddress: settings.deviceAddress,
                increasedMemoryLimit: increasedMemory, registerExtensions: settings.registerExtensions,
                observer: observer)
        case .certificate:
            guard let acc = settings.activeAccount, acc.kind == .certificate,
                  let p12 = acc.p12, let provision = acc.provision else {
                throw QuayMessage("Добавь сертификат: Настройки → Аккаунты и сертификаты")
            }
            job?.stage = "Подпись"
            let signed = FileManager.default.temporaryDirectory.appendingPathComponent("signed-\(UUID().uuidString).ipa")
            let outcome = try await signIpaWithCertificate(
                ipaPath: ipaPath, p12: p12, password: acc.p12Password,
                mobileprovision: provision, outIpaPath: signed.path)
            try await installOverTheAir(signed, outcome: outcome)
            return outcome
        }
    }

    /// iOS installs the signed .ipa itself: Quay serves it on 127.0.0.1, the manifest comes from api.palera.in
    /// (an https manifest is required; Feather's "semi-local" mode does the same). Sent there: bundle id, name, version.
    private func installOverTheAir(_ ipa: URL, outcome: InstallOutcome) async throws {
        let port = try await serveIpa(path: ipa.path)
        guard var manifest = URLComponents(string: settings.manifestServer) else {
            throw QuayMessage("Неверный адрес сервера манифеста в настройках")
        }
        manifest.queryItems = [
            URLQueryItem(name: "bundleid", value: outcome.installedBundleId),
            URLQueryItem(name: "name", value: outcome.appName),
            URLQueryItem(name: "version", value: outcome.version),
            URLQueryItem(name: "fetchurl", value: "http://127.0.0.1:\(port)/app.ipa"),
        ]
        guard let manifestURL = manifest.url?.absoluteString
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let link = URL(string: "itms-services://?action=download-manifest&url=\(manifestURL)") else {
            throw QuayMessage("Не удалось собрать ссылку установки")
        }
        job?.stage = "Подтверди установку на экране"
        job?.fraction = 1
        guard await UIApplication.shared.open(link) else {
            throw QuayMessage("iOS не открыла установку")
        }
        // shortcut: no way to learn when iOS finished; give it time to fetch the file while Quay is still awake.
        try? await Task.sleep(nanoseconds: 8_000_000_000)
    }

    private func fetchIPA(_ link: String, sha256: String?) async throws -> URL {
        guard let url = URL(string: link) else { throw QuayMessage("Неверная ссылка на .ipa") }
        if let sha256 {
            let cached = Paths.ipas.appendingPathComponent("\(sha256.lowercased()).ipa")
            if FileManager.default.fileExists(atPath: cached.path) { return cached }
        }
        job?.stage = "Скачивание"
        let name = sha256.map { "\($0.lowercased()).ipa" } ?? "dl-\(UUID().uuidString).ipa"
        let file = try await Downloader.shared.download(url, to: name) { p in
            Task { @MainActor in
                guard var j = self.job else { return }
                j.stage = "Скачивание"
                j.fraction = p
                self.job = j
            }
        }
        if let sha256 {
            job?.stage = "Проверка файла"
            let ok = try verifySha256(path: file.path, expected: sha256)
            if !ok {
                try? FileManager.default.removeItem(at: file)
                throw QuayMessage("Файл не совпадает с тем, что обещает источник (sha256). Установка остановлена")
            }
        }
        return file
    }

    /// Copies picked .dylib files where refreshes find them again.
    private static func storeTweaks(_ urls: [URL]) throws -> [String] {
        let rel = "tweaks/\(UUID().uuidString)"
        let dir = Paths.support.appendingPathComponent(rel, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try urls.map { u in
            try FileManager.default.copyItem(at: u, to: dir.appendingPathComponent(u.lastPathComponent))
            return "\(rel)/\(u.lastPathComponent)"
        }
    }

    /// The .ipa with the tweaks injected (a temporary copy), or the .ipa itself without tweaks.
    private func withTweaks(_ ipa: URL, _ tweaks: [String]) throws -> URL {
        guard !tweaks.isEmpty else { return ipa }
        job?.stage = "Внедрение твиков"
        Log.write("Твики: \(tweaks.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tweaked-\(UUID().uuidString).ipa")
        try injectDylibs(ipaPath: ipa.path, dylibPaths: tweaks.map { Paths.support.appendingPathComponent($0).path }, outIpaPath: out.path)
        return out
    }

    /// The icon from the .ipa as a file URL AsyncImage can load.
    private static func saveIcon(_ png: Data?, for bundleId: String) -> String? {
        guard let png else { return nil }
        let dir = Paths.support.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(bundleId).png")
        return (try? png.write(to: url, options: .atomic)) != nil ? url.absoluteString : nil
    }

    private func checkOS(_ minimum: String?) throws {
        guard let minimum, !minimum.isEmpty else { return }
        if compareVersions(a: UIDevice.current.systemVersion, b: minimum) < 0 {
            throw QuayMessage("Нужна iOS \(minimum) или новее")
        }
    }

    private func finish(_ record: InstalledRecord, replacing: InstalledRecord?) {
        if let old = replacing, old.installedBundleId != record.installedBundleId {
            catalog.removeInstalled(old.installedBundleId)
        }
        if let oldFile = replacing?.ipaFile, oldFile != record.ipaFile {
            try? FileManager.default.removeItem(at: Paths.ipas.appendingPathComponent(oldFile))
        }
        catalog.upsert(record)
        Notifier.scheduleExpiry(for: record)
    }

    private func run(title: String, icon: String?, _ body: @escaping () async throws -> Void) async {
        guard job == nil else {
            alert = "Дождись окончания текущей установки"
            return
        }
        job = Job(title: title, iconURL: icon, stage: "Подготовка", fraction: 0)
        Log.write("\(title): начало")
        await runPlain {
            do {
                try await body()
            } catch is CancellationError {
                Log.write("\(title): отменено")
            } catch {
                Log.write("\(title): ошибка: \(errorText(error))")
                self.alert = errorText(error)
            }
        }
        job = nil
    }

    /// Keeps the screen on and asks iOS for time to finish if the app goes to the background.
    private func runPlain(_ body: () async -> Void) async {
        UIApplication.shared.isIdleTimerDisabled = true
        let bg = UIApplication.shared.beginBackgroundTask(withName: "install")
        await body()
        UIApplication.shared.isIdleTimerDisabled = false
        if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
    }
}

/// Quay's own provisioning profile: when its signature ends.
enum SelfProfile {
    static func expirationDate() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
        return plist?["ExpirationDate"] as? Date
    }
}
