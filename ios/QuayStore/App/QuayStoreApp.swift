import SwiftUI

@main
struct QuayStoreApp: App {
    @Environment(\.scenePhase) private var phase

    init() {
        quayInit(verbose: false)
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 400 << 20)
        BackgroundWork.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(SettingsModel.shared)
                .environmentObject(Catalog.shared)
                .environmentObject(Installer.shared)
                .environmentObject(Router.shared)
                .onOpenURL { Router.shared.open($0) }
        }
        .onChange(of: phase) { p in
            guard p == .active else { return }
            BackgroundWork.schedule()
            Task { @MainActor in
                let catalog = Catalog.shared
                let stale = catalog.records.contains { ($0.lastRefreshed ?? .distantPast) < Date().addingTimeInterval(-15 * 60) }
                if stale {
                    await catalog.refreshAll()
                    Notifier.announce(catalog.updates)
                }
            }
        }
    }
}

/// Navigation that comes from outside: opened links and files.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()

    enum Tab: Hashable { case today, search, sources, mine, settings }

    @Published var tab: Tab = .today
    /// A source link to confirm (quay://, altstore://, sidestore://).
    @Published var pendingSource: String?

    func open(_ url: URL) {
        if url.isFileURL {
            if url.pathExtension.lowercased() == "ipa" || url.pathExtension.lowercased() == "tipa" {
                tab = .mine
                Task { await Installer.shared.installLocal(url) }
            }
            return
        }
        // quay://source?url=… · altstore://source?url=… · sidestore://source?url=…
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let link = comps.queryItems?.first(where: { $0.name == "url" })?.value {
            tab = .sources
            pendingSource = link
        }
    }
}
