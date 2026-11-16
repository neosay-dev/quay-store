import SwiftUI
import UniformTypeIdentifiers

struct MyAppsView: View {
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var installer: Installer
    @EnvironmentObject var settings: SettingsModel

    var body: some View {
        List {
            let updates = catalog.updates
            if !updates.isEmpty {
                Section {
                    ForEach(updates) { u in
                        NavigationLink(value: u.app) {
                            HStack(spacing: 12) {
                                AppIcon(url: u.record.iconURL ?? u.app.app.iconUrl, size: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(u.record.name).font(.body.weight(.medium))
                                    Text(u.kind == .rebuilt
                                         ? "\(u.record.version): пересобрано"
                                         : "\(u.record.version) → \(u.app.latest?.version ?? "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                GetButton(app: u.app)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Обновления")
                        Spacer()
                        if updates.count > 1 {
                            Button("Обновить все") {
                                Task { for u in updates { await installer.install(u.app) } }
                            }
                            .font(.footnote)
                            .disabled(installer.job != nil)
                        }
                    }
                }
            }

            Section {
                SelfRow()
                ForEach(catalog.installed.sorted { $0.name.lowercased() < $1.name.lowercased() }) { r in
                    InstalledRow(record: r)
                }
            } header: {
                Text("Установлено")
            } footer: {
                if settings.signingMode == .appleID {
                    Text("Бесплатный Apple ID: до 3 приложений вместе с Quay Store, подпись на 7 дней. Обновить подписи без открытия приложения можно действием «Обновить подписи» в Командах.")
                }
            }

            Section {
                Button {
                    Task { await installer.refreshAll() }
                } label: {
                    Label("Обновить все подписи", systemImage: "signature")
                }
                .disabled(installer.job != nil)
                Button {
                    Task {
                        if let url = await FilePicker.pick([UTType(filenameExtension: "ipa") ?? .data, .data]).first {
                            await installer.installLocal(url)
                        }
                    }
                } label: {
                    Label("Установить .ipa из Файлов", systemImage: "doc.badge.plus")
                }
                .disabled(installer.job != nil)
            }
        }
        .navigationTitle("Мои приложения")
        .navigationDestination(for: CatalogApp.self) { AppDetailView(app: $0) }
        .refreshable {
            await catalog.refreshAll()
            await installer.syncWithDevice()
        }
    }
}

struct SelfRow: View {
    @EnvironmentObject var installer: Installer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 48 * 0.225, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Quay Store").font(.body.weight(.medium))
                if let end = installer.selfExpiresAt {
                    Text(end.daysLeftText).font(.caption)
                        .foregroundStyle(end.timeIntervalSinceNow < 2 * 86_400 ? Color.orange : Color.secondary)
                } else {
                    Text("Срок подписи неизвестен").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Продлить") { Task { await installer.refreshSelf() } }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .disabled(installer.job != nil)
        }
    }
}

struct InstalledRow: View {
    let record: InstalledRecord
    @EnvironmentObject var installer: Installer
    @EnvironmentObject var catalog: Catalog

    var body: some View {
        let row = HStack(spacing: 12) {
            AppIcon(url: record.iconURL, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.version)
                    if let end = record.expiresAt {
                        Text("·")
                        Text(end.daysLeftText)
                            .foregroundStyle(end.timeIntervalSinceNow < 2 * 86_400 ? Color.orange : Color.secondary)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contextMenu { actions }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { Task { await installer.uninstall(record) } } label: { Label("Удалить", systemImage: "trash") }
            Button { Task { await installer.refresh(record) } } label: { Label("Подпись", systemImage: "signature") }.tint(.accentColor)
        }

        if let app = catalog.catalogApp(for: record) {
            NavigationLink(value: app) { row }
        } else {
            row
        }
    }

    @ViewBuilder private var actions: some View {
        Button { Task { await installer.refresh(record) } } label: { Label("Обновить подпись", systemImage: "signature") }
        Button { catalog.removeInstalled(record.installedBundleId) } label: { Label("Забыть (оставить на iPhone)", systemImage: "eye.slash") }
        Button(role: .destructive) { Task { await installer.uninstall(record) } } label: { Label("Удалить с iPhone", systemImage: "trash") }
    }
}

// MARK: prompts from the core

struct TwoFactorSheet: View {
    let request: TwoFactorRequest
    @EnvironmentObject var installer: Installer
    @State var code = ""
    @FocusState var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Код из 6 цифр", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title2.monospacedDigit())
                        .focused($focused)
                } header: {
                    Text(request.sms ? "Код пришёл по SMS" : "Код на твоих устройствах Apple")
                } footer: {
                    if let e = request.lastError { Text(e).foregroundStyle(.red) }
                }
                Section {
                    Button("Отправить код ещё раз") { reply(.resend) }
                    if request.sms || request.unknown {
                        Button("Отправить на устройства") { reply(.sendToDevices) }
                    }
                    ForEach(request.phones.filter { $0.id != request.selectedPhoneId }, id: \.id) { p in
                        Button("SMS на \(p.number)") { reply(.sendSms(phoneId: p.id)) }
                    }
                }
            }
            .navigationTitle("Двухфакторный код")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { reply(.cancel) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { reply(.code(code: code)) }.disabled(code.count < 6)
                }
            }
            .onAppear { focused = true }
            .onChange(of: code) { c in
                let digits = String(c.filter(\.isNumber).prefix(6))
                if digits != c { code = digits }
                if digits.count == 6 { reply(.code(code: digits)) }
            }
        }
        .interactiveDismissDisabled()
    }

    private func reply(_ a: TwoFactorAnswer) {
        guard installer.twoFactor != nil else { return }
        installer.twoFactor = nil
        answerTwoFactor(answer: a)
    }
}

struct CertificatesSheet: View {
    let certificates: [DevCertificate]
    @EnvironmentObject var installer: Installer
    @State var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            List(certificates, id: \.serial, selection: $selected) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.machineName.isEmpty ? c.name : c.machineName).font(.body)
                    Text(c.serial).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            .environment(\.editMode, .constant(.active))
            .safeAreaInset(edge: .top) {
                Text("У аккаунта уже максимум сертификатов. Выбери, какие отозвать: приложения, подписанные ими (например, через SideStore или iLoader), перестанут открываться.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding()
            }
            .navigationTitle("Сертификаты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { reply(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Отозвать") { reply(Array(selected)) }.disabled(selected.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func reply(_ serials: [String]?) {
        installer.certificateChoice = nil
        answerCertificates(revokeSerials: serials)
    }
}
