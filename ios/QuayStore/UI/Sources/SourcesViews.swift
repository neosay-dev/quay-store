import SwiftUI

struct SourcesView: View {
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var router: Router
    @State var adding = false

    var body: some View {
        List {
            if catalog.records.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Источников нет").font(.headline)
                        Text("Источник — это ссылка на список приложений в формате AltStore/SideStore. Ещё можно добавить репозиторий GitHub: Quay будет следить за его релизами с .ipa.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
            ForEach(catalog.orderedSources) { entry in
                NavigationLink {
                    SourceDetailView(record: entry.record)
                } label: {
                    SourceRow(record: entry.record, source: entry.source)
                }
            }
            .onDelete { idx in
                let records = idx.map { catalog.orderedSources[$0].record }
                records.forEach(catalog.remove)
            }
            .onMove { catalog.move(from: $0, to: $1) }
        }
        .navigationTitle("Источники")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { if !catalog.records.isEmpty { EditButton() } }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
            }
        }
        .refreshable { await catalog.refreshAll() }
        .sheet(isPresented: $adding) { AddSourceSheet(initial: "") }
        .sheet(item: Binding(get: { router.pendingSource.map(PendingLink.init) }, set: { router.pendingSource = $0?.url })) {
            AddSourceSheet(initial: $0.url)
        }
        .navigationDestination(for: CatalogApp.self) { AppDetailView(app: $0) }
    }
}

private struct PendingLink: Identifiable {
    let url: String
    var id: String { url }
}

struct SourceRow: View {
    let record: SourceRecord
    let source: Source?

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(url: source?.iconUrl, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source?.name ?? record.url).font(.body.weight(.medium)).lineLimit(1)
                    if record.kind == .github {
                        Text("GitHub").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.4)))
                    }
                }
                if let err = record.lastError {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text(appCount).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var appCount: String {
        let n = source?.apps.count ?? 0
        return n == 1 ? "1 приложение" : (2...4).contains(n % 10) && !(12...14).contains(n % 100) ? "\(n) приложения" : "\(n) приложений"
    }
}

struct AddSourceSheet: View {
    @State var initial: String
    @EnvironmentObject var catalog: Catalog
    @Environment(\.dismiss) var dismiss
    @State var busy = false
    @State var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://… или github.com/owner/repo", text: $initial, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if UIPasteboard.general.hasStrings {
                        Button("Вставить из буфера") { initial = UIPasteboard.general.string ?? initial }
                    }
                } footer: {
                    Text("Подходят источники AltStore, SideStore, Feather и ESign, а ещё ссылки на репозитории GitHub с .ipa в релизах.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Новый источник")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Добавить") { Task { await add() } }
                            .disabled(initial.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() async {
        busy = true
        error = nil
        do {
            try await catalog.add(initial)
            dismiss()
        } catch {
            self.error = errorText(error)
        }
        busy = false
    }
}

struct SourceDetailView: View {
    let record: SourceRecord
    @EnvironmentObject var catalog: Catalog

    var body: some View {
        let source = catalog.sources[record.url]
        List {
            if let source {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            AppIcon(url: source.iconUrl, size: 56)
                            VStack(alignment: .leading) {
                                Text(source.name).font(.title3.weight(.bold))
                                if let s = source.subtitle { Text(s).font(.subheadline).foregroundStyle(.secondary) }
                            }
                        }
                        if let d = source.description { Text(d).font(.subheadline) }
                        if let w = source.website, let u = URL(string: w) {
                            Link(w, destination: u).font(.footnote)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Приложения") {
                    ForEach(catalog.apps(in: source)) { app in
                        NavigationLink(value: app) { AppRow(app: app) }
                    }
                }
            } else if let err = record.lastError {
                Text(err).foregroundStyle(.red)
            } else {
                ProgressView()
            }
            Section {
                Text(record.url).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                if let d = record.lastRefreshed {
                    InfoRow(title: "Обновлён", value: d.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Скопировать ссылку") { UIPasteboard.general.string = record.url }
            }
        }
        .navigationTitle(source?.name ?? "Источник")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await catalog.refresh(record) }
    }
}

/// Releases of any GitHub repository (from search): install an .ipa, follow the repo, or add its source file.
struct GithubRepoView: View {
    let repo: RepoRef
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var installer: Installer
    @State var info: GithubRepoInfo?
    @State var error: String?
    @State var added = false

    var body: some View {
        List {
            if let info {
                Section {
                    let followed = catalog.records.contains { $0.url.lowercased() == "https://github.com/\(repo.owner)/\(repo.repo)".lowercased() }
                    Button(followed || added ? "Репозиторий в источниках" : "Следить за релизами") {
                        Task {
                            do { try await catalog.add("https://github.com/\(repo.owner)/\(repo.repo)"); added = true }
                            catch { self.error = errorText(error) }
                        }
                    }
                    .disabled(followed || added)
                    if let src = info.sourceUrl {
                        Button("Добавить файл источника из релиза") {
                            Task {
                                do { try await catalog.add(src) } catch { self.error = errorText(error) }
                            }
                        }
                    }
                    if let left = info.rateLimitRemaining, left < 10 {
                        Text("Осталось запросов к GitHub: \(left). Токен в настройках снимает ограничение.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if info.releases.isEmpty {
                    Text("В релизах нет .ipa").foregroundStyle(.secondary)
                }
                ForEach(info.releases, id: \.tag) { r in
                    Section {
                        ForEach(r.ipas, id: \.id) { a in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(a.name).font(.subheadline).lineLimit(2)
                                    Text(byteCount(a.size) ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Установить") { Task { await install(release: r, asset: a) } }
                                    .buttonStyle(.bordered)
                                    .disabled(installer.job != nil)
                            }
                        }
                        if let n = r.notes {
                            Text(n).font(.footnote).foregroundStyle(.secondary).lineLimit(8)
                        }
                    } header: {
                        Text(r.name + (r.prerelease ? " · пре-релиз" : ""))
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
            if let error, info != nil {
                Text(error).foregroundStyle(.red)
            }
        }
        .navigationTitle("\(repo.owner)/\(repo.repo)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            info = try await fetchGithubRepo(repo: repo, cacheDir: Paths.github.path, token: SettingsModel.shared.githubToken)
            error = nil
        } catch {
            self.error = errorText(error)
        }
    }

    /// One release asset as an app of the repo's pseudo-source, so updates are tracked if it is followed.
    private func install(release: GithubRelease, asset: GithubAsset) async {
        guard let info else { return }
        let source = githubRepoAsSource(info: info, includePrereleases: true)
        guard let app = source.apps.first else { return }
        let version = AppVersion(
            version: githubVersion(tag: release.tag), buildVersion: nil, date: release.publishedAt, notes: release.notes,
            downloadUrl: asset.downloadUrl, size: asset.size, sha256: nil, minOsVersion: nil, maxOsVersion: nil,
            fingerprint: "gh:\(asset.id)|\(asset.updatedAt)")
        await installer.install(CatalogApp(app: app, source: source), version: version)
    }
}
