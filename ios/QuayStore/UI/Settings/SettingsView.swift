import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsModel
    @EnvironmentObject var installer: Installer
    @State var cacheSize: String = ""
    @State var token = ""

    var body: some View {
        Form {
            Section {
                Picker("Способ подписи", selection: $settings.signingMode) {
                    ForEach(SigningMode.allCases) { Text($0.title).tag($0) }
                }
                switch settings.signingMode {
                case .appleID:
                    NavigationLink { AppleIDView() } label: {
                        InfoRow(title: "Apple ID", value: settings.appleEmail.isEmpty ? "Не выполнен вход" : settings.appleEmail)
                    }
                    NavigationLink { AnisetteServersView() } label: {
                        InfoRow(title: "Anisette-сервер", value: URL(string: settings.anisetteURL)?.host ?? settings.anisetteURL)
                    }
                    Toggle("Отдельные App ID для расширений", isOn: $settings.registerExtensions)
                case .certificate:
                    NavigationLink { CertificateView() } label: {
                        InfoRow(title: "Сертификат", value: settings.hasCertificate ? "Добавлен" : "Не добавлен")
                    }
                }
            } header: {
                Text("Подпись")
            } footer: {
                if settings.signingMode == .appleID {
                    Text("Расширения (виджеты, «Поделиться») с отдельными App ID работают полностью, но быстрее тратят лимит: 10 новых App ID в неделю.")
                }
            }

            Section("Устройство") {
                NavigationLink { DeviceView() } label: {
                    InfoRow(title: "Pairing file", value: settings.hasPairingFile ? "Есть" : "Нет")
                }
                Link(destination: URL(string: "https://apps.apple.com/search?term=LocalDevVPN")!) {
                    Label("LocalDevVPN в App Store", systemImage: "network")
                }
            }

            Section {
                Toggle("Пре-релизы с GitHub", isOn: $settings.includePrereleases)
                Toggle("Уведомлять об обновлениях", isOn: $settings.notifyUpdates)
                Toggle("Напоминать о конце подписи", isOn: $settings.notifyExpiry)
                SecureField("Токен GitHub (необязательно)", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { settings.githubToken = token }
            } header: {
                Text("Источники")
            } footer: {
                Text("Без токена GitHub даёт 60 запросов в час. Токен без прав (fine-grained, только чтение публичных репозиториев) поднимает лимит до 5000.")
            }

            Section {
                Toggle("Хранить .ipa после установки", isOn: $settings.keepIPAs)
                InfoRow(title: "Занято", value: cacheSize)
                Button("Очистить кэш .ipa", role: .destructive) {
                    try? FileManager.default.removeItem(at: Paths.ipas)
                    try? FileManager.default.createDirectory(at: Paths.ipas, withIntermediateDirectories: true)
                    cacheSize = Self.size(of: Paths.ipas)
                }
            } header: {
                Text("Хранилище")
            } footer: {
                Text("С сохранённым .ipa подпись обновляется без скачивания. Без него файл скачается заново по ссылке из источника.")
            }

            Section {
                InfoRow(title: "Версия", value: SettingsModel.versionText)
                Link("Исходный код на GitHub", destination: URL(string: "https://github.com/neosay-dev/quay-store")!)
                Button("Пройти настройку заново") { settings.onboardingDone = false }
            }
        }
        .navigationTitle("Настройки")
        .onAppear {
            cacheSize = Self.size(of: Paths.ipas)
            token = settings.githubToken ?? ""
        }
        .onDisappear { settings.githubToken = token }
    }

    static func size(of dir: URL) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let total = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}

// MARK: Apple ID

struct AppleIDView: View {
    @EnvironmentObject var settings: SettingsModel
    @EnvironmentObject var installer: Installer

    var body: some View {
        Form {
            if let a = installer.account {
                Section {
                    InfoRow(title: "Apple ID", value: a.email)
                    InfoRow(title: "Команда", value: a.teamName)
                    InfoRow(title: "Team ID", value: a.teamId)
                    InfoRow(title: "Тип", value: a.isFree ? "Бесплатный" : "Платный")
                }
                Section {
                    Button("Выйти", role: .destructive) { Task { await installer.signOut() } }
                }
            } else {
                AppleIDSignInForm()
            }
        }
        .navigationTitle("Apple ID")
        .task {
            if installer.account == nil, settings.hasAppleID { try? await installer.ensureSession() }
        }
    }
}

struct AppleIDSignInForm: View {
    var onDone: (() -> Void)? = nil
    @EnvironmentObject var settings: SettingsModel
    @EnvironmentObject var installer: Installer
    @State var email = ""
    @State var password = ""
    @State var busy = false
    @State var error: String?

    var body: some View {
        Section {
            TextField("Apple ID (почта)", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Пароль", text: $password)
                .textContentType(.password)
        } footer: {
            Text("Пароль уходит только в Apple (через anisette-сервер идут лишь данные «Мака»). Он хранится в связке ключей этого iPhone, чтобы продлевать подписи. Лучше завести отдельный Apple ID для подписи.")
        }
        Section {
            Button {
                Task { await signIn() }
            } label: {
                HStack {
                    Text("Войти")
                    if busy { Spacer(); ProgressView() }
                }
            }
            .disabled(busy || email.isEmpty || password.isEmpty)
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .onAppear { if email.isEmpty { email = settings.appleEmail } }
    }

    private func signIn() async {
        busy = true
        error = nil
        do {
            _ = try await installer.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            onDone?()
        } catch {
            self.error = errorText(error)
        }
        busy = false
    }
}

struct AnisetteServersView: View {
    @EnvironmentObject var settings: SettingsModel
    @State var servers: [AnisetteServer] = []
    @State var ping: [String: String] = [:]
    @State var custom = ""

    var body: some View {
        List {
            Section {
                ForEach(servers, id: \.address) { s in
                    Button {
                        settings.anisetteURL = s.address
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).foregroundStyle(.primary)
                                Text(s.address).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ping[s.address] ?? "…").font(.caption.monospacedDigit())
                                .foregroundStyle(ping[s.address]?.hasSuffix("мс") == true ? Color.secondary : Color.red)
                            if s.address == settings.anisetteURL {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            } footer: {
                Text("Anisette-сервер изображает Mac при входе в Apple ID. Если выбранный не отвечает, Quay сам попробует другой из списка.")
            }
            Section("Свой сервер") {
                TextField("https://…", text: $custom)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Использовать") {
                    let a = custom.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    guard !a.isEmpty else { return }
                    settings.anisetteURL = a
                    if !servers.contains(where: { $0.address == a }) {
                        servers.insert(AnisetteServer(name: "Свой", address: a), at: 0)
                        Task { await check(a) }
                    }
                }
            }
        }
        .navigationTitle("Anisette")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        servers = (try? await fetchAnisetteServers()) ?? [AnisetteServer(name: "iLoader", address: "https://ani.iloader.app")]
        if !servers.contains(where: { $0.address == settings.anisetteURL }) {
            servers.insert(AnisetteServer(name: "Выбранный", address: settings.anisetteURL), at: 0)
        }
        await withTaskGroup(of: Void.self) { g in
            for s in servers { g.addTask { await check(s.address) } }
        }
    }

    private func check(_ address: String) async {
        let text: String
        do {
            text = "\(try await checkAnisetteServer(address: address)) мс"
        } catch {
            text = "нет"
        }
        await MainActor.run { ping[address] = text }
    }
}

// MARK: certificate

struct CertificateView: View {
    @EnvironmentObject var settings: SettingsModel
    @State var p12: Data?
    @State var provision: Data?
    @State var password = ""
    @State var summary: CertificateSummary?
    @State var error: String?
    @State var picking: Picking?

    enum Picking: Identifiable { case p12, provision; var id: Self { self } }

    var body: some View {
        Form {
            Section {
                Button { picking = .p12 } label: {
                    InfoRow(title: "Сертификат .p12", value: p12 == nil ? "Выбрать" : "Выбран")
                }
                SecureField("Пароль от .p12", text: $password)
                Button { picking = .provision } label: {
                    InfoRow(title: "Профиль .mobileprovision", value: provision == nil ? "Выбрать" : "Выбран")
                }
            } footer: {
                Text("Сертификат разработчика или дистрибуции со своим профилем. iPhone должен быть в профиле, если профиль не корпоративный.")
            }
            if let s = summary {
                Section("Проверка") {
                    InfoRow(title: "Сертификат", value: s.commonName)
                    InfoRow(title: "Команда", value: "\(s.teamName) (\(s.teamId))")
                    InfoRow(title: "Профиль", value: s.profileName)
                    InfoRow(title: "App ID", value: s.appId)
                    if let e = s.expiresAt { InfoRow(title: "Действует до", value: e.date.formatted(date: .abbreviated, time: .omitted)) }
                    InfoRow(title: "Устройства", value: s.provisionsAllDevices ? "Любые" : "\(s.deviceUdids.count)")
                    if !s.certificateInProfile {
                        Text("Этого сертификата нет в профиле: подпись не установится.").foregroundStyle(.red)
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button("Сохранить") { save() }.disabled(p12 == nil || provision == nil)
                if settings.hasCertificate {
                    Button("Удалить сертификат", role: .destructive) {
                        Keychain.set(nil, for: Keychain.Key.p12)
                        Keychain.set(nil, for: Keychain.Key.provision)
                        Keychain.setString(nil, for: Keychain.Key.p12Password)
                        p12 = nil; provision = nil; summary = nil
                        settings.objectWillChange.send()
                    }
                }
            }
        }
        .navigationTitle("Свой сертификат")
        .onAppear {
            p12 = Keychain.data(for: Keychain.Key.p12)
            provision = Keychain.data(for: Keychain.Key.provision)
            password = Keychain.string(for: Keychain.Key.p12Password) ?? ""
            inspect()
        }
        .onChange(of: password) { _ in inspect() }
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: picking == .p12
                        ? [UTType(filenameExtension: "p12") ?? .data, .data]
                        : [UTType(filenameExtension: "mobileprovision") ?? .data, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try? Data(contentsOf: url)
            if url.pathExtension.lowercased() == "mobileprovision" { provision = data } else { p12 = data }
            inspect()
        }
    }

    private func inspect() {
        guard let p12, let provision else { summary = nil; return }
        do {
            summary = try inspectCertificate(p12: p12, password: password, mobileprovision: provision)
            error = nil
        } catch {
            summary = nil
            self.error = errorText(error)
        }
    }

    private func save() {
        guard let p12, let provision else { return }
        Keychain.set(p12, for: Keychain.Key.p12)
        Keychain.set(provision, for: Keychain.Key.provision)
        Keychain.setString(password, for: Keychain.Key.p12Password)
        settings.signingMode = .certificate
        settings.objectWillChange.send()
    }
}

// MARK: device

struct DeviceView: View {
    @EnvironmentObject var settings: SettingsModel
    var body: some View {
        Form {
            PairingSection()
            DeviceCheckSection()
            Section {
                TextField("10.7.0.1", text: $settings.deviceAddress)
                    .keyboardType(.numbersAndPunctuation)
            } header: {
                Text("Адрес устройства")
            } footer: {
                Text("LocalDevVPN отдаёт iPhone адрес 10.7.0.1. Меняй, только если используешь другой VPN.")
            }
        }
        .navigationTitle("Устройство")
    }
}

struct PairingSection: View {
    @EnvironmentObject var settings: SettingsModel
    @State var importing = false
    @State var message: String?

    var body: some View {
        Section {
            Button(settings.hasPairingFile ? "Заменить pairing file" : "Выбрать pairing file") { importing = true }
            if let message { Text(message).font(.footnote).foregroundStyle(message.hasPrefix("Готово") ? Color.green : Color.red) }
        } header: {
            Text("Pairing file")
        } footer: {
            Text("Делается на компьютере с iPhone на кабеле. До iOS 26.3 подходит обычный файл из iLoader или jitterbugpair. На iOS 26.4 и новее (и iOS 27) нужен RPPairing: idevice_pair, StikPair или свежий iLoader. Файл переносишь сюда через «Файлы», AirDrop или Telegram.")
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.propertyList, .xml, .data, UTType(filenameExtension: "mobiledevicepairing") ?? .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { message = "Файл не читается"; return }
            do {
                let summary = try inspectPairingFile(pairingFile: data)
                Keychain.set(data, for: Keychain.Key.pairing)
                settings.objectWillChange.send()
                switch summary.kind {
                case .remotePairing: message = "Готово: RPPairing (iOS 26.4+)"
                case .lockdown: message = "Готово: обычный pairing file" + (summary.udid.map { ", \($0)" } ?? "")
                }
            } catch {
                message = errorText(error)
            }
        }
    }
}

struct DeviceCheckSection: View {
    @EnvironmentObject var settings: SettingsModel
    @State var busy = false
    @State var info: DeviceInfo?
    @State var error: String?
    var onSuccess: ((DeviceInfo) -> Void)? = nil

    var body: some View {
        Section {
            Button {
                Task { await check() }
            } label: {
                HStack {
                    Text("Проверить связь")
                    if busy { Spacer(); ProgressView() }
                }
            }
            .disabled(busy || !settings.hasPairingFile)
            if let info {
                InfoRow(title: "iPhone", value: info.name)
                InfoRow(title: "iOS", value: info.productVersion)
                InfoRow(title: "Подключение", value: info.connection == .remotePairing ? "RPPairing" : "Lockdown")
                if let dm = info.developerMode {
                    InfoRow(title: "Режим разработчика", value: dm ? "Включён" : "Выключен")
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        } footer: {
            Text("Перед проверкой включи LocalDevVPN. Нужен Wi-Fi или любая сеть: трафик не уходит из телефона.")
        }
    }

    private func check() async {
        guard let pairing = settings.pairingFile else { return }
        busy = true
        error = nil
        do {
            let i = try await checkDevice(pairingFile: pairing, address: settings.deviceAddress)
            info = i
            if i.developerMode == false {
                error = "Включи режим разработчика: Настройки → Конфиденциальность и безопасность → Режим разработчика"
            }
            onSuccess?(i)
        } catch {
            info = nil
            self.error = errorText(error)
        }
        busy = false
    }
}
