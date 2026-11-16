import SwiftUI

struct RootView: View {
    @EnvironmentObject var settings: SettingsModel
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var installer: Installer
    @EnvironmentObject var router: Router

    var body: some View {
        TabView(selection: $router.tab) {
            NavigationStack { TodayView() }
                .tabItem { Label("Сегодня", systemImage: "newspaper") }
                .tag(Router.Tab.today)
            NavigationStack { SearchView() }
                .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
                .tag(Router.Tab.search)
            NavigationStack { SourcesView() }
                .tabItem { Label("Источники", systemImage: "tray.full") }
                .tag(Router.Tab.sources)
            NavigationStack { MyAppsView() }
                .tabItem { Label("Мои", systemImage: "square.stack") }
                .badge(catalog.updates.count)
                .tag(Router.Tab.mine)
            NavigationStack { SettingsView() }
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(Router.Tab.settings)
        }
        .overlay(alignment: .bottom) {
            InstallBanner().onTapGesture { router.showLog = true }
        }
        .sheet(isPresented: $router.showLog) { NavigationStack { LogView() } }
        .tint(settings.accentColor)
        .preferredColorScheme(settings.colorScheme)
        .animation(.easeInOut(duration: 0.25), value: installer.job?.title)
        .sheet(isPresented: twoFactorShown) {
            if let r = installer.twoFactor { TwoFactorSheet(request: r) }
        }
        .sheet(isPresented: certificatesShown) {
            if let c = installer.certificateChoice { CertificatesSheet(certificates: c) }
        }
        .alert("Не получилось", isPresented: alertShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(installer.alert ?? "")
        }
        .fullScreenCover(isPresented: onboardingShown) { OnboardingView() }
    }

    // A sheet swiped away without an answer still has to answer the core, or it waits forever.
    private var twoFactorShown: Binding<Bool> {
        Binding(get: { installer.twoFactor != nil }, set: { shown in
            if !shown, installer.twoFactor != nil {
                installer.twoFactor = nil
                answerTwoFactor(answer: .cancel)
            }
        })
    }

    private var certificatesShown: Binding<Bool> {
        Binding(get: { installer.certificateChoice != nil }, set: { shown in
            if !shown, installer.certificateChoice != nil {
                installer.certificateChoice = nil
                answerCertificates(revokeSerials: nil)
            }
        })
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { installer.alert != nil }, set: { if !$0 { installer.alert = nil } })
    }

    private var onboardingShown: Binding<Bool> {
        Binding(get: { !settings.onboardingDone }, set: { if !$0 { settings.onboardingDone = true } })
    }
}
