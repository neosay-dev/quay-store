import Foundation

/// An app as the store shows it: the app and the source it is in.
struct CatalogApp: Identifiable, Hashable {
    let app: StoreApp
    let source: Source

    var id: String { source.sourceUrl + "|" + app.bundleId }
    var latest: AppVersion? { app.versions.first }

    static func == (a: CatalogApp, b: CatalogApp) -> Bool { a.id == b.id && a.latest?.fingerprint == b.latest?.fingerprint }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct SourceEntry: Identifiable {
    let record: SourceRecord
    let source: Source?
    var id: String { record.url }
}

struct NewsEntry: Identifiable {
    let item: NewsItem
    let source: Source
    var id: String { source.sourceUrl + "|" + item.identifier }
}

struct UpdateItem: Identifiable {
    let record: InstalledRecord
    let app: CatalogApp
    let kind: UpdateKind
    var id: String { record.id }
}

/// Sources, their apps, and what is installed. One instance for the whole app.
@MainActor
final class Catalog: ObservableObject {
    static let shared = Catalog()

    @Published private(set) var records: [SourceRecord] = []
    @Published private(set) var sources: [String: Source] = [:]
    @Published private(set) var installed: [InstalledRecord] = []
    @Published private(set) var refreshing = false

    private init() {
        records = RecordStore.load("sources.json", as: [SourceRecord].self) ?? []
        installed = RecordStore.load("installed.json", as: [InstalledRecord].self) ?? []
        for r in records where r.kind == .json {
            if let json = r.cachedJSON, let s = try? parseSource(json: json, sourceUrl: r.url) {
                sources[r.url] = s
            }
        }
    }

    // MARK: sources

    /// Sources in the order they were added, with what loaded.
    var orderedSources: [SourceEntry] {
        records.map { SourceEntry(record: $0, source: sources[$0.url]) }
    }

    func refreshAll() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await withTaskGroup(of: Void.self) { group in
            for r in records {
                group.addTask { await self.refresh(r) }
            }
        }
    }

    func refresh(_ record: SourceRecord) async {
        var r = record
        do {
            let source = try await load(record)
            sources[r.url] = source.0
            if let json = source.1 { r.cachedJSON = json }
            r.lastError = nil
            r.lastRefreshed = Date()
        } catch {
            r.lastError = errorText(error)
        }
        if let i = records.firstIndex(where: { $0.url == r.url }) {
            records[i] = r
            saveSources()
        }
    }

    /// The source, and its JSON text when it is a JSON source (to cache).
    private func load(_ r: SourceRecord) async throws -> (Source, String?) {
        switch r.kind {
        case .github:
            guard let repo = parseRepoLink(input: r.url) else { throw QuayMessage("Неверная ссылка на репозиторий") }
            let info = try await fetchGithubRepo(repo: repo, cacheDir: Paths.github.path, token: SettingsModel.shared.githubToken)
            return (githubRepoAsSource(info: info, includePrereleases: SettingsModel.shared.includePrereleases), nil)
        case .json:
            let json = try await Self.download(r.url)
            return (try parseSource(json: json, sourceUrl: r.url), json)
        }
    }

    private static func download(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw QuayMessage("Неверная ссылка") }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("QuayStore", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw QuayMessage("Сервер ответил \(h.statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8) else { throw QuayMessage("Источник не в UTF-8") }
        return text
    }

    /// Adds a source from what the user typed: a GitHub repository or a source URL.
    @discardableResult
    func add(_ input: String) async throws -> Source {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let isJSON = trimmed.lowercased().hasSuffix(".json") || trimmed.contains("://source")
        let record: SourceRecord
        if !isJSON, let repo = parseRepoLink(input: trimmed) {
            record = SourceRecord(url: "https://github.com/\(repo.owner)/\(repo.repo)", kind: .github)
        } else {
            record = SourceRecord(url: try normalizeSourceUrl(input: trimmed), kind: .json)
        }
        if records.contains(where: { $0.url.lowercased() == record.url.lowercased() }) {
            throw QuayMessage("Этот источник уже добавлен")
        }
        let (source, json) = try await load(record)
        if records.contains(where: { $0.url != record.url && sources[$0.url]?.identifier == source.identifier && record.kind == .json }) {
            throw QuayMessage("Источник «\(source.name)» уже добавлен по другой ссылке")
        }
        var r = record
        r.cachedJSON = json
        r.lastRefreshed = Date()
        records.append(r)
        sources[r.url] = source
        saveSources()
        return source
    }

    func remove(_ record: SourceRecord) {
        records.removeAll { $0.url == record.url }
        sources[record.url] = nil
        saveSources()
    }

    func move(from: IndexSet, to: Int) {
        records.move(fromOffsets: from, toOffset: to)
        saveSources()
    }

    private func saveSources() { RecordStore.save(records, as: "sources.json") }

    // MARK: apps

    var allApps: [CatalogApp] {
        orderedSources.flatMap { entry -> [CatalogApp] in
            guard let s = entry.source else { return [] }
            return s.apps.filter { !$0.versions.isEmpty }.map { CatalogApp(app: $0, source: s) }
        }
    }

    func apps(in source: Source) -> [CatalogApp] {
        source.apps.filter { !$0.versions.isEmpty }.map { CatalogApp(app: $0, source: source) }
    }

    /// Featured apps: what sources mark as featured, else every source's first apps.
    var featured: [CatalogApp] {
        var out: [CatalogApp] = []
        for entry in orderedSources {
            guard let s = entry.source else { continue }
            let apps = apps(in: s)
            let marked = apps.filter { s.featuredBundleIds.contains($0.app.bundleId) }
            out += marked.isEmpty ? Array(apps.prefix(2)) : marked
        }
        return out
    }

    /// Newest versions first, across all sources.
    var recentlyUpdated: [CatalogApp] {
        allApps
            .sorted { (parseSourceDate($0.latest?.date) ?? .distantPast) > (parseSourceDate($1.latest?.date) ?? .distantPast) }
    }

    var news: [NewsEntry] {
        orderedSources.flatMap { e -> [NewsEntry] in
            guard let s = e.source else { return [] }
            return s.news.map { NewsEntry(item: $0, source: s) }
        }
        .sorted { (parseSourceDate($0.item.date) ?? .distantPast) > (parseSourceDate($1.item.date) ?? .distantPast) }
    }

    func search(_ query: String) -> [CatalogApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return allApps.filter {
            $0.app.name.lowercased().contains(q)
                || ($0.app.developer?.lowercased().contains(q) ?? false)
                || ($0.app.subtitle?.lowercased().contains(q) ?? false)
                || $0.app.bundleId.lowercased().contains(q)
        }
    }

    // MARK: installed

    func installedRecord(for app: CatalogApp) -> InstalledRecord? {
        installed.first { $0.sourceURL == app.source.sourceUrl && $0.sourceBundleId == app.app.bundleId }
            ?? installed.first { $0.sourceBundleId == app.app.bundleId && !app.app.bundleIdIsPlaceholder }
    }

    func catalogApp(for record: InstalledRecord) -> CatalogApp? {
        guard let bid = record.sourceBundleId else { return nil }
        if let url = record.sourceURL, let s = sources[url], let a = s.apps.first(where: { $0.bundleId == bid }), !a.versions.isEmpty {
            return CatalogApp(app: a, source: s)
        }
        return allApps.first { $0.app.bundleId == bid }
    }

    var updates: [UpdateItem] {
        installed.compactMap { r in
            guard let app = catalogApp(for: r), let latest = app.latest else { return nil }
            let kind = checkUpdate(installed: r.installedState, latest: latest)
            return kind == .upToDate ? nil : UpdateItem(record: r, app: app, kind: kind)
        }
    }

    func upsert(_ record: InstalledRecord) {
        if let i = installed.firstIndex(where: { $0.installedBundleId == record.installedBundleId }) {
            installed[i] = record
        } else {
            installed.append(record)
        }
        RecordStore.save(installed, as: "installed.json")
    }

    func removeInstalled(_ bundleId: String) {
        if let r = installed.first(where: { $0.installedBundleId == bundleId }), let url = r.ipaURL {
            try? FileManager.default.removeItem(at: url)
        }
        installed.removeAll { $0.installedBundleId == bundleId }
        RecordStore.save(installed, as: "installed.json")
    }

    /// Apps signed with the free Apple ID that still count against the 3-app limit (Quay itself is the third).
    var activeFreeApps: [InstalledRecord] {
        installed.filter { $0.signedWith == .appleID && ($0.expiresAt ?? .distantFuture) > Date() }
    }
}
