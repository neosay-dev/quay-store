import SwiftUI

// MARK: Today

struct TodayView: View {
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var router: Router

    var body: some View {
        ScrollView {
            if catalog.records.isEmpty {
                EmptySources { router.tab = .sources }
                    .padding(.top, 80)
            } else {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if !catalog.featured.isEmpty {
                        section("Избранное") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(catalog.featured) { app in
                                        NavigationLink(value: app) { FeaturedCard(app: app) }.buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    if !catalog.news.isEmpty {
                        section("Новости") {
                            VStack(spacing: 12) {
                                ForEach(Array(catalog.news.prefix(5))) { entry in
                                    NewsCard(item: entry.item, source: entry.source)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    section("Недавно обновлённые") {
                        VStack(spacing: 0) {
                            ForEach(catalog.recentlyUpdated.prefix(15)) { app in
                                NavigationLink(value: app) { AppRow(app: app, showSource: true) }
                                    .buttonStyle(.plain)
                                Divider().padding(.leading, 68)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("Сегодня")
        .navigationDestination(for: CatalogApp.self) { AppDetailView(app: $0) }
        .refreshable { await catalog.refreshAll() }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.bold)).padding(.horizontal)
            content()
        }
    }
}

struct EmptySources: View {
    let action: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text("Пока пусто").font(.title3.weight(.semibold))
            Text("Приложения появятся, когда ты добавишь источник или репозиторий GitHub.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Добавить источник", action: action).buttonStyle(.borderedProminent).padding(.top, 4)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }
}

struct FeaturedCard: View {
    let app: CatalogApp
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppIcon(url: app.app.iconUrl, size: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.app.name).font(.headline).lineLimit(1)
                Text(app.app.subtitle ?? app.source.name).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            GetButton(app: app)
        }
        .padding(14)
        .frame(width: 200, height: 210, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct NewsCard: View {
    let item: NewsItem
    let source: Source

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            if let img = item.imageUrl, let u = URL(string: img) {
                AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color(.secondarySystemFill) }
                    .frame(height: 150)
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Color(hex: item.tintColor ?? source.tintColor) ?? .secondary)
                Text(item.title).font(.headline)
                if let c = item.caption { Text(c).font(.subheadline).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .padding(.top, item.imageUrl == nil ? 14 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

        if let link = item.url, let u = URL(string: link) {
            Link(destination: u) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

// MARK: Search

struct SearchView: View {
    @EnvironmentObject var catalog: Catalog
    @State var query = ""

    var body: some View {
        List {
            if let repo = parseRepoLink(input: query), query.contains("/") {
                Section {
                    NavigationLink {
                        GithubRepoView(repo: repo)
                    } label: {
                        Label("Релизы \(repo.owner)/\(repo.repo) на GitHub", systemImage: "shippingbox")
                    }
                }
            }
            if query.isEmpty {
                Section("Все приложения") {
                    ForEach(catalog.allApps.sorted { $0.app.name.lowercased() < $1.app.name.lowercased() }) { app in
                        NavigationLink(value: app) { AppRow(app: app, showSource: true) }
                    }
                }
            } else {
                let results = catalog.search(query)
                if results.isEmpty && parseRepoLink(input: query) == nil {
                    Text("Ничего не найдено").foregroundStyle(.secondary)
                }
                ForEach(results) { app in
                    NavigationLink(value: app) { AppRow(app: app, showSource: true) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Поиск")
        .searchable(text: $query, prompt: "Приложения или ссылка на GitHub")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .navigationDestination(for: CatalogApp.self) { AppDetailView(app: $0) }
    }
}

// MARK: App detail

struct AppDetailView: View {
    let app: CatalogApp
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var installer: Installer
    @State var expanded = false

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    AppIcon(url: app.app.iconUrl, size: 104)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.app.name).font(.title2.weight(.bold)).lineLimit(2)
                        Text(app.app.developer ?? app.source.name).font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        GetButton(app: app)
                    }
                }
                .padding(.vertical, 6)
                if let r = catalog.installedRecord(for: app) {
                    InstalledStatus(record: r)
                }
            }

            if !app.app.screenshots.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(app.app.screenshots, id: \.self) { s in
                                AsyncImage(url: URL(string: s)) { $0.resizable().scaledToFit() } placeholder: { Color(.secondarySystemFill) }
                                    .frame(height: 380)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            if let latest = app.latest {
                Section("Что нового") {
                    HStack {
                        Text("Версия \(latest.version)\(latest.buildVersion.map { " (\($0))" } ?? "")").font(.subheadline.weight(.semibold))
                        Spacer()
                        if let d = parseSourceDate(latest.date) {
                            Text(d, style: .date).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if let notes = latest.notes { Text(notes).font(.subheadline) }
                    if app.app.versions.count > 1 {
                        NavigationLink("Все версии (\(app.app.versions.count))") { VersionsView(app: app) }
                    }
                }
            }

            if let d = app.app.description {
                Section("Описание") {
                    Text(d).font(.subheadline).lineLimit(expanded ? nil : 6)
                    if d.count > 300 {
                        Button(expanded ? "Свернуть" : "Ещё") { expanded.toggle() }.font(.subheadline)
                    }
                }
            }

            Section("Информация") {
                InfoRow(title: "Источник", value: app.source.name)
                if let size = byteCount(app.latest?.size) { InfoRow(title: "Размер", value: size) }
                if let os = app.latest?.minOsVersion { InfoRow(title: "Нужна iOS", value: "\(os) или новее") }
                if let c = app.app.category { InfoRow(title: "Категория", value: c) }
                if !app.app.bundleIdIsPlaceholder { InfoRow(title: "Bundle ID", value: app.app.bundleId) }
            }

            if !app.app.entitlements.isEmpty || !app.app.privacy.isEmpty {
                Section {
                    ForEach(app.app.privacy, id: \.key) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(PermissionNames.privacy(p.key)).font(.subheadline.weight(.medium))
                            Text(p.text).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(app.app.entitlements, id: \.self) { e in
                        Text(PermissionNames.entitlement(e)).font(.subheadline)
                    }
                } header: {
                    Text("Разрешения")
                } footer: {
                    if app.app.entitlements.contains(where: PermissionNames.needsPaid) {
                        Text("Часть прав бесплатный Apple ID не выдаёт: без них приложение может работать хуже.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color(hex: app.app.tintColor) ?? .accentColor)
    }
}

struct InstalledStatus: View {
    let record: InstalledRecord
    @EnvironmentObject var installer: Installer

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Установлена \(record.version)").font(.subheadline)
                if let end = record.expiresAt {
                    Text(end.daysLeftText).font(.footnote)
                        .foregroundStyle(end.timeIntervalSinceNow < 2 * 86_400 ? Color.orange : Color.secondary)
                }
            }
            Spacer()
            Menu {
                Button { Task { await installer.refresh(record) } } label: { Label("Обновить подпись", systemImage: "signature") }
                Button(role: .destructive) { Task { await installer.uninstall(record) } } label: { Label("Удалить с iPhone", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .disabled(installer.job != nil)
        }
    }
}

struct VersionsView: View {
    let app: CatalogApp
    @EnvironmentObject var installer: Installer

    var body: some View {
        List(app.app.versions, id: \.fingerprint) { v in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(v.version + (v.buildVersion.map { " (\($0))" } ?? "")).font(.headline)
                    Spacer()
                    Button("Установить") { Task { await installer.install(app, version: v) } }
                        .buttonStyle(.bordered)
                        .disabled(installer.job != nil)
                }
                if let d = parseSourceDate(v.date) { Text(d, style: .date).font(.caption).foregroundStyle(.secondary) }
                if let n = v.notes { Text(n).font(.subheadline).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Версии")
    }
}

/// Human names for the usual keys.
enum PermissionNames {
    static func privacy(_ key: String) -> String {
        let map = [
            "NSCameraUsageDescription": "Камера",
            "NSMicrophoneUsageDescription": "Микрофон",
            "NSPhotoLibraryUsageDescription": "Фото",
            "NSPhotoLibraryAddUsageDescription": "Сохранение фото",
            "NSLocationWhenInUseUsageDescription": "Геопозиция",
            "NSLocationAlwaysAndWhenInUseUsageDescription": "Геопозиция всегда",
            "NSContactsUsageDescription": "Контакты",
            "NSLocalNetworkUsageDescription": "Локальная сеть",
            "NSBluetoothAlwaysUsageDescription": "Bluetooth",
            "NSFaceIDUsageDescription": "Face ID",
            "NSUserTrackingUsageDescription": "Отслеживание",
            "NSCalendarsUsageDescription": "Календарь",
            "NSMotionUsageDescription": "Движение",
            "NSSpeechRecognitionUsageDescription": "Распознавание речи",
        ]
        return map[key] ?? key
    }

    static func entitlement(_ e: String) -> String {
        let map = [
            "com.apple.developer.kernel.increased-memory-limit": "Больше памяти",
            "com.apple.developer.kernel.extended-virtual-addressing": "Расширенная адресация памяти",
            "com.apple.security.application-groups": "Общие данные с расширениями",
            "com.apple.developer.associated-domains": "Связанные домены",
            "aps-environment": "Push-уведомления",
            "com.apple.developer.icloud-services": "iCloud",
            "keychain-access-groups": "Связка ключей",
        ]
        return map[e] ?? e
    }

    static func needsPaid(_ e: String) -> Bool {
        ["com.apple.developer.kernel.extended-virtual-addressing", "aps-environment",
         "com.apple.developer.icloud-services", "com.apple.developer.associated-domains"].contains(e)
    }
}
