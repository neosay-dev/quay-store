import SwiftUI
import UIKit

/// First launch: everything Quay needs, one step at a time. Each step can be skipped and done later in Settings.
struct OnboardingView: View {
    @EnvironmentObject var settings: SettingsModel
    @EnvironmentObject var installer: Installer
    @EnvironmentObject var catalog: Catalog
    @State var step = 0
    @State var deviceOK = false
    @State var sourceLink = ""
    @State var sourceError: String?
    @State var addingSource = false

    let steps = ["Привет", "iPhone", "Режим разработчика", "LocalDevVPN", "Pairing file", "Подпись", "Источник", "Готово"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Шаг \(step + 1) из \(steps.count)").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                    }
                    ProgressView(value: Double(step + 1), total: Double(steps.count))
                }
                content
            }
            .navigationTitle(steps[step])
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if step > 0 { Button("Назад") { step -= 1 } }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if step < steps.count - 1 {
                        Button(nextTitle) { step += 1 }
                    } else {
                        Button("Начать") { finish() }.fontWeight(.semibold)
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var nextTitle: String {
        switch step {
        case 4: return settings.hasPairingFile ? "Далее" : "Пропустить"
        case 5: return (installer.account != nil || settings.hasCertificate) ? "Далее" : "Пропустить"
        case 6: return catalog.records.isEmpty ? "Пропустить" : "Далее"
        default: return "Далее"
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcome
        case 1: device
        case 2: developerMode
        case 3: vpn
        case 4: pairing
        case 5: signing
        case 6: source
        default: done
        }
    }

    private var welcome: some View {
        Section {
            Text("Quay Store ставит приложения на этот iPhone сам, без компьютера: скачивает .ipa из твоих источников, подписывает и устанавливает.")
            VStack(alignment: .leading, spacing: 8) {
                Label("LocalDevVPN из App Store", systemImage: "network")
                Label("Pairing file (один раз, с компьютера)", systemImage: "cable.connector")
                Label("Apple ID или свой сертификат", systemImage: "signature")
            }
            .font(.subheadline)
        } header: {
            Text("Что понадобится")
        }
    }

    private var device: some View {
        let version = UIDevice.current.systemVersion
        let model = Self.modelIdentifier()
        let needsRemotePairing = compareVersions(a: version, b: "26.4") >= 0
        return Group {
            Section("Этот iPhone") {
                InfoRow(title: "Модель", value: model)
                InfoRow(title: "iOS", value: version)
            }
            Section {
                if compareVersions(a: version, b: "16.0") < 0 {
                    Text("Нужна iOS 16 или новее.").foregroundStyle(.red)
                } else if needsRemotePairing {
                    Text("На iOS 26.4 и новее обычный pairing file не работает: нужен RPPairing. Его делает idevice_pair (StikPair) или свежий iLoader на компьютере, с iPhone на кабеле.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Эта версия iOS поддерживается.").foregroundStyle(.green)
                }
            }
        }
    }

    private var developerMode: some View {
        Section {
            Text("Приложения с бесплатной подписью открываются только в режиме разработчика (iOS 16+).")
            Text("Настройки → Конфиденциальность и безопасность → Режим разработчика → включить, перезагрузить iPhone и подтвердить.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Пункт появляется после первой установки подписанного приложения. Если его нет, вернись сюда после установки Quay.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Открыть Настройки") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }
        }
    }

    private var vpn: some View {
        Section {
            Text("LocalDevVPN заворачивает соединение обратно в iPhone, и Quay может говорить с системным установщиком. Трафик из телефона не уходит.")
            Link("Открыть LocalDevVPN в App Store", destination: URL(string: "https://apps.apple.com/search?term=LocalDevVPN")!)
            Text("Установи, открой и включи VPN. Включать его нужно на время установки и обновления подписей.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var pairing: some View {
        Group {
            PairingSection()
            if settings.hasPairingFile {
                DeviceCheckSection(onSuccess: { _ in deviceOK = true })
            }
        }
    }

    @ViewBuilder private var signing: some View {
        Section {
            Picker("Способ подписи", selection: $settings.signingMode) {
                ForEach(SigningMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(settings.signingMode == .appleID
                 ? "Бесплатный Apple ID: подпись на 7 дней, до 3 приложений вместе с Quay. Quay продлевает подписи сам."
                 : "Свой сертификат (.p12 + .mobileprovision): подпись живёт, пока жив сертификат.")
        }
        if settings.signingMode == .appleID {
            if let a = installer.account {
                Section { InfoRow(title: "Вход выполнен", value: a.email) }
            } else {
                AppleIDSignInForm(onDone: { step += 1 })
            }
        } else {
            Section {
                NavigationLink("Добавить сертификат") { CertificateView() }
                if settings.hasCertificate { Text("Сертификат сохранён").foregroundStyle(.green) }
            }
        }
    }

    @ViewBuilder private var source: some View {
        Section {
            TextField("https://… или github.com/owner/repo", text: $sourceLink)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                Task {
                    addingSource = true
                    do {
                        try await catalog.add(sourceLink)
                        sourceLink = ""
                        sourceError = nil
                    } catch {
                        sourceError = errorText(error)
                    }
                    addingSource = false
                }
            } label: {
                HStack { Text("Добавить"); if addingSource { Spacer(); ProgressView() } }
            }
            .disabled(sourceLink.isEmpty || addingSource)
            if let sourceError { Text(sourceError).foregroundStyle(.red).font(.footnote) }
        } footer: {
            Text("Встроенных источников нет: добавь свой. Подходят ссылки AltStore, SideStore, Feather, ESign и репозитории GitHub.")
        }
        if !catalog.records.isEmpty {
            Section("Добавлено") {
                ForEach(catalog.orderedSources) { e in
                    Text(e.source?.name ?? e.record.url)
                }
            }
        }
    }

    private var done: some View {
        Section {
            Text("Чтобы подписи продлевались сами, создай автоматизацию в «Командах»: «Каждый день» → действие Quay Store «Обновить подписи». LocalDevVPN при этом должен быть включён.")
            Button("Разрешить уведомления") {
                Task { _ = await Notifier.requestPermission() }
            }
        } footer: {
            Text("Всё это можно поменять потом в настройках.")
        }
    }

    private func finish() {
        settings.onboardingDone = true
        Task { _ = await Notifier.requestPermission() }
    }

    static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buf in
            String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
