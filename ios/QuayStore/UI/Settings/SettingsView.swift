import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsModel
    @EnvironmentObject var installer: Installer
    @EnvironmentObject var catalog: Catalog
    @State var cacheSize: String = ""
    @State var token = ""
    @State var importMessage: String?

    var body: some View {
        Form {
            Section {
                NavigationLink { AccountsView() } label: {
                    InfoRow(title: "Аккаунты и сертификаты", value: settings.activeAccount?.title ?? "Нет")
                }
                if settings.signingMode == .appleID {
                    NavigationLink { AnisetteServersView() } label: {
                        InfoRow(title: "Anisette-сервер", value: URL(string: settings.anisetteURL)?.host ?? settings.anisetteURL)
                    }
                    Toggle("Отдельные App ID для расширений", isOn: $settings.registerExtensions)
                } else {
                    TextField("Сервер манифеста", text: $settings.manifestServer)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if settings.manifestServer != SettingsModel.defaultManifestServer {
                        Button("Вернуть api.palera.in") { settings.manifestServer = SettingsModel.defaultManifestServer }
                    }
                }
            } header: {
                Text("Подпись")
            } footer: {
                Text(settings.signingMode == .appleID
                     ? "Расширения (виджеты, «Поделиться») с отдельными App ID работают полностью, но быстрее тратят лимит: 10 новых App ID в неделю."
                     : "Сервер манифеста отдаёт iOS https-описание установки. Ему уходят bundle ID, название и версия; сам .ipa остаётся на телефоне. Нужен тот же формат запроса, что у api.palera.in/genPlist.")
            }

            Section("Устройство") {
                NavigationLink { DeviceView() } label: {
                    InfoRow(title: "Pairing file", value: settings.hasPairingFile ? "Есть" : "Нет")
                }
                Link(destination: URL(string: "https://apps.apple.com/search?term=LocalDevVPN")!) {
                    Label("LocalDevVPN в App Store", systemImage: "network")
                }
            }

            Section("Оформление") {
                Picker("Тема", selection: $settings.appearance) {
                    Text("Как в системе").tag("system")
                    Text("Светлая").tag("light")
                    Text("Тёмная").tag("dark")
                }
                HStack(spacing: 12) {
                    ForEach(SettingsModel.accents, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex) ?? Color("AccentColor"))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.primary, lineWidth: settings.accent == hex ? 2 : 0).padding(-3))
                            .onTapGesture { settings.accent = hex }
                            .accessibilityLabel(hex.isEmpty ? "Цвет по умолчанию" : hex)
                    }
                }
                .padding(.vertical, 4)
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
                NavigationLink { LogView() } label: { Label("Логи", systemImage: "doc.text") }
                if let file = try? settings.exportFile(sources: catalog.records) {
                    ShareLink(item: file) { Label("Экспорт настроек", systemImage: "square.and.arrow.up") }
                }
                Button { Task { await importSettings() } } label: { Label("Импорт настроек", systemImage: "square.and.arrow.down") }
                if let importMessage { Text(importMessage).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Экспорт: настройки и список источников. Аккаунты, сертификаты, пароли и pairing file в файл не попадают.")
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

    private func importSettings() async {
        guard let url = await FilePicker.pick([.json, .data]).first, let data = try? Data(contentsOf: url) else { return }
        do {
            let sources = try settings.importFile(data)
            var added = 0
            for s in sources where !catalog.records.contains(where: { $0.url.lowercased() == s.url.lowercased() }) {
                if (try? await catalog.add(s.url)) != nil { added += 1 }
            }
            importMessage = "Настройки применены, источников добавлено: \(added)"
        } catch {
            importMessage = errorText(error)
        }
    }

    static func size(of dir: URL) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let total = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}

// MARK: accounts

struct AccountsView: View {
    @EnvironmentObject var settings: SettingsModel
    @EnvironmentObject var installer: Installer
    @State var exportPassword = ""
    @State var exported: URL?
    @State var exportError: String?
    @State var exporting = false

    var body: some View {
        List {
            Section {
                if settings.accounts.isEmpty {
                    Text("Пока нет ни Apple ID, ни сертификата").foregroundStyle(.secondary)
                }
                ForEach(settings.accounts) { a in
                    Button {
                        settings.activate(a)
                        exported = nil
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: a.kind == .appleID ? "person.crop.circle" : "doc.badge.gearshape")
                                .font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.title).foregroundStyle(.primary)
                                Text([a.kind.title, a.detail].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if a.id == settings.activeAccountID {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            if a.id == settings.activeAccountID, a.kind == .appleID { Task { await installer.signOut() } }
                            settings.remove(a)
                        } label: { Label("Удалить", systemImage: "trash") }
                    }
                }
            } footer: {
                Text("Подпись идёт активным аккаунтом (с галочкой). Нажми на другой, чтобы переключиться.")
            }

            Section {
                NavigationLink("Добавить Apple ID") {
                    Form { AppleIDSignInForm() }.navigationTitle("Apple ID")
                }
                NavigationLink("Добавить сертификат") { CertificateView() }
            }

            if settings.activeAccount?.kind == .appleID {
                Section {
                    SecureField("Пароль для .p12", text: $exportPassword)
                    Button {
                        Task {
                            exporting = true
                            do {
                                exported = try await installer.exportCertificate(password: exportPassword)
                                exportError = nil
                            } catch {
                                exportError = errorText(error)
                            }
                            exporting = false
                        }
                    } label: {
                        HStack { Text("Подготовить .p12"); if exporting { Spacer(); ProgressView() } }
                    }
                    .disabled(exporting)
                    if let exported {
                        ShareLink(item: exported) { Label("Сохранить или отправить", systemImage: "square.and.arrow.up") }
                    }
                    if let exportError { Text(exportError).foregroundStyle(.red).font(.footnote) }
                } header: {
                    Text("Экспорт сертификата Apple ID")
                } footer: {
                    Text("Сертификат и ключ, которыми Quay подписывает этим Apple ID, в .p12 под твоим паролем. Подойдёт для SideStore, Feather, ESign.")
                }
            }
        }
        .navigationTitle("Аккаунты")
    }
}

struct AppleIDSignInForm: View {
    var onDone: (() -> Void)? = nil
    @EnvironmentObject var installer: Installer
    @Environment(\.dismiss) var dismiss
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
    }

    private func signIn() async {
        busy = true
        error = nil
        do {
            _ = try await installer.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            if let onDone { onDone() } else { dismiss() }
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

/// Adds a certificate account: .p12 (+ its password) and .mobileprovision.
struct CertificateView: View {
    @EnvironmentObject var settings: SettingsModel
    @Environment(\.dismiss) var dismiss
    @State var p12: Data?
    @State var provision: Data?
    @State var password = ""
    @State var summary: CertificateSummary?
    @State var error: String?

    var body: some View {
        Form {
            Section {
                Button { Task { await pickFiles() } } label: {
                    InfoRow(title: "Сертификат .p12", value: p12 == nil ? "Выбрать" : "Выбран")
                }
                SecureField("Пароль от .p12", text: $password)
                Button { Task { await pickFiles() } } label: {
                    InfoRow(title: "Профиль .mobileprovision", value: provision == nil ? "Выбрать" : "Выбран")
                }
            } footer: {
                Text("Можно выбрать оба файла сразу. Сертификат разработчика или дистрибуции со своим профилем: iPhone должен быть в профиле, если профиль не корпоративный. Pairing file и VPN не нужны: iOS ставит приложения сама.")
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
                Button("Сохранить") { save() }.disabled(summary == nil)
            }
        }
        .navigationTitle("Новый сертификат")
        .onChange(of: password) { _ in inspect() }
    }

    /// .p12 and .mobileprovision, one or both at once; told apart by extension.
    private func pickFiles() async {
        for url in await FilePicker.pick([.data], multiple: true) {
            let data = try? Data(contentsOf: url)
            if url.pathExtension.lowercased() == "mobileprovision" { provision = data } else { p12 = data }
        }
        inspect()
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
        guard let p12, let provision, let s = summary else { return }
        let a = settings.save(SigningAccount(kind: .certificate, title: s.commonName, detail: s.teamName))
        Keychain.set(p12, for: "\(a.id).p12")
        Keychain.set(provision, for: "\(a.id).provision")
        Keychain.setString(password, for: "\(a.id).p12password")
        dismiss()
    }
}

// MARK: device

struct DeviceView: View {
    @EnvironmentObject var settings: SettingsModel
    var body: some View {
        Form {
            PairingHostSection()
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
    @State var message: String?

    var body: some View {
        Section {
            Button(settings.hasPairingFile ? "Заменить pairing file" : "Выбрать pairing file") { Task { await importPairing() } }
            if let message { Text(message).font(.footnote).foregroundStyle(message.hasPrefix("Готово") ? Color.green : Color.red) }
        } header: {
            Text("Pairing file")
        } footer: {
            Text("Нужен для подписи через Apple ID (со своим сертификатом не нужен). В iLoader на компьютере (iPhone на кабеле): список экспорта → pairing file. На iOS 26.4 и новее (и iOS 27) нужен RPPairing. Файл переносишь сюда через «Файлы», AirDrop или Telegram.")
        }
    }

    private func importPairing() async {
        guard let url = await FilePicker.pick([.data]).first else { return }
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
