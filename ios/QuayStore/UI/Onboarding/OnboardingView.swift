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

    enum Step { case question, device, developerMode, vpn, pairing, signing, source, done }

    /// With your own certificate iOS installs apps itself: no LocalDevVPN, no pairing file.
    var steps: [Step] {
        settings.signingMode == .certificate
            ? [.question, .device, .developerMode, .signing, .source, .done]
            : [.question, .device, .developerMode, .vpn, .pairing, .signing, .source, .done]
    }

    func title(_ s: Step) -> String {
        switch s {
        case .question: return "Привет"
        case .device: return "iPhone"
        case .developerMode: return "Режим разработчика"
        case .vpn: return "LocalDevVPN"
        case .pairing: return "Pairing file"
        case .signing: return settings.signingMode == .certificate ? "Сертификат" : "Apple ID"
        case .source: return "Источник"
        case .done: return "Готово"
        }
    }

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
            .navigationTitle(title(steps[step]))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if step > 0 { Button("Назад") { step -= 1 } }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if step == 0 {
                        EmptyView()
                    } else if step < steps.count - 1 {
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
        switch steps[step] {
        case .pairing: return settings.hasPairingFile ? "Далее" : "Пропустить"
        case .signing: return (installer.account != nil || settings.hasCertificate) ? "Далее" : "Пропустить"
        case .source: return catalog.records.isEmpty ? "Пропустить" : "Далее"
        default: return "Далее"
        }
    }

    @ViewBuilder private var content: some View {
        switch steps[step] {
        case .question: question
        case .device: device
        case .developerMode: developerMode
        case .vpn: vpn
        case .pairing: pairing
        case .signing: signing
        case .source: source
        case .done: done
        }
    }

    @ViewBuilder private var question: some View {
        Section {
            Text("Quay Store скачивает .ipa из твоих источников, подписывает и ставит на этот iPhone без компьютера.")
        }
        Section {
            Button {
                settings.signingMode = .certificate
                step = 1
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Да, есть свой сертификат").font(.headline)
                    Text(".p12 и .mobileprovision. Ничего больше не нужно: iOS ставит приложения сама.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button {
                settings.signingMode = .appleID
                step = 1
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Нет, подпишу через Apple ID").font(.headline)
                    Text("Бесплатно, подпись на 7 дней. Нужны LocalDevVPN и pairing file из iLoader.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("У тебя есть свой сертификат?")
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
                    Text("На iOS 26.4 и новее обычный pairing file не работает: нужен RPPairing. Экспортируй его в iLoader на компьютере (список экспорта), с iPhone на кабеле.")
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
            PairingHostSection()
            PairingSection()
            if settings.hasPairingFile {
                DeviceCheckSection(onSuccess: { _ in deviceOK = true })
            }
        }
    }

    @ViewBuilder private var signing: some View {
        // The mode was chosen on the first step; changing it here would reshuffle the steps.
        Section {
            Text(settings.signingMode == .appleID
                 ? "Бесплатный Apple ID: подпись на 7 дней, до 3 приложений вместе с Quay. Quay продлевает подписи сам."
                 : "Свой сертификат (.p12 + .mobileprovision): подпись живёт, пока жив сертификат.")
                .font(.footnote).foregroundStyle(.secondary)
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
