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
        .sheet(isPresented: $router.showLog) { NavigationStack { LogView() }.modifier(CorePrompts(active: true)) }
        .tint(settings.accentColor)
        .preferredColorScheme(settings.colorScheme)
        .animation(.easeInOut(duration: 0.25), value: installer.job?.title)
        // While onboarding or the log covers this view, a sheet from here cannot appear: they show the prompts instead.
        .modifier(CorePrompts(active: settings.onboardingDone && !router.showLog))
        .alert("Не получилось", isPresented: alertShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(installer.alert ?? "")
        }
        .fullScreenCover(isPresented: onboardingShown) { OnboardingView() }
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { installer.alert != nil }, set: { if !$0 { installer.alert = nil } })
    }

    private var onboardingShown: Binding<Bool> {
        Binding(get: { !settings.onboardingDone }, set: { if !$0 { settings.onboardingDone = true } })
    }
}

/// Questions from the core (2FA code, which certificate to revoke), on whatever screen is on top.
struct CorePrompts: ViewModifier {
    let active: Bool
    @EnvironmentObject var installer: Installer

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: twoFactorShown) {
                if let r = installer.twoFactor { TwoFactorSheet(request: r) }
            }
            .sheet(isPresented: certificatesShown) {
                if let c = installer.certificateChoice { CertificatesSheet(certificates: c) }
            }
    }

    // A sheet swiped away without an answer still has to answer the core, or it waits forever.
    private var twoFactorShown: Binding<Bool> {
        Binding(get: { active && installer.twoFactor != nil }, set: { shown in
            if !shown, installer.twoFactor != nil {
                installer.twoFactor = nil
                answerTwoFactor(answer: .cancel)
            }
        })
    }

    private var certificatesShown: Binding<Bool> {
        Binding(get: { active && installer.certificateChoice != nil }, set: { shown in
            if !shown, installer.certificateChoice != nil {
                installer.certificateChoice = nil
                answerCertificates(revokeSerials: nil)
            }
        })
    }
}
