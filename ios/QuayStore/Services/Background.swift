import AppIntents
import BackgroundTasks
import Foundation
import UserNotifications

/// Local notifications: a day before a signature ends, and new updates.
enum Notifier {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    @MainActor
    static func scheduleExpiry(for r: InstalledRecord) {
        cancelExpiry(for: r)
        guard SettingsModel.shared.notifyExpiry, let end = r.expiresAt else { return }
        let fire = end.addingTimeInterval(-86_400)
        guard fire > Date() else { return }
        let c = UNMutableNotificationContent()
        c.title = "Подпись «\(r.name)» заканчивается"
        c.body = "Завтра приложение перестанет открываться. Открой Quay Store и обнови подпись."
        c.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "expiry.\(r.installedBundleId)", content: c, trigger: trigger))
    }

    static func cancelExpiry(for r: InstalledRecord) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["expiry.\(r.installedBundleId)"])
    }

    /// One notification per new version or rebuild (remembered by fingerprint).
    @MainActor
    static func announce(_ updates: [UpdateItem]) {
        guard SettingsModel.shared.notifyUpdates else { return }
        let key = "announcedUpdates"
        var seen = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        for u in updates {
            let mark = "\(u.record.installedBundleId)|\(u.app.latest?.fingerprint ?? "")"
            guard !seen.contains(mark) else { continue }
            seen.insert(mark)
            let c = UNMutableNotificationContent()
            c.title = u.kind == .rebuilt ? "«\(u.record.name)» пересобрано" : "Обновление «\(u.record.name)»"
            c.body = u.kind == .rebuilt
                ? "Версия та же, но файл новый. Обнови в Quay Store."
                : "Доступна версия \(u.app.latest?.version ?? "")."
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update.\(mark)", content: c, trigger: nil))
        }
        UserDefaults.standard.set(Array(seen.suffix(500)), forKey: key)
    }
}

/// Background work: refresh sources, announce updates, refresh signatures that end within two days.
/// iOS decides when it runs; the Shortcuts action below is the reliable way.
enum BackgroundWork {
    static let identifier = "dev.neosay.quaystore.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            schedule()
            let work = Task { @MainActor in
                await run()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: identifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        try? BGTaskScheduler.shared.submit(req)
    }

    @MainActor
    static func run() async {
        let installer = Installer.shared
        installer.interactive = false
        defer { installer.interactive = true }
        await Catalog.shared.refreshAll()
        Notifier.announce(Catalog.shared.updates)
        await installer.refreshExpiring(withinDays: 2)
    }
}

/// Shortcuts → Automation → "every day" → this action: signatures stay fresh without opening the app.
struct RefreshSignaturesIntent: AppIntent {
    static var title: LocalizedStringResource = "Обновить подписи"
    static var description = IntentDescription("Подписывает заново приложения, у которых подпись заканчивается в ближайшие 2 дня. Нужен включённый LocalDevVPN.")
    static var openAppWhenRun = false

    @Parameter(title: "Все приложения", default: false)
    var all: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let installer = Installer.shared
        installer.interactive = false
        defer { installer.interactive = true }
        let result = await installer.refreshExpiring(withinDays: 2, force: all)
        if !result.failed.isEmpty {
            return .result(dialog: "Не получилось: \(result.failed.joined(separator: "; "))")
        }
        return .result(dialog: result.done == 0 ? "Обновлять нечего" : "Готово: \(result.done)")
    }
}

struct CheckUpdatesIntent: AppIntent {
    static var title: LocalizedStringResource = "Проверить обновления"
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await Catalog.shared.refreshAll()
        let updates = Catalog.shared.updates
        Notifier.announce(updates)
        return .result(dialog: updates.isEmpty ? "Всё обновлено" : "Обновлений: \(updates.count)")
    }
}

struct QuayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RefreshSignaturesIntent(), phrases: ["Обнови подписи в \(.applicationName)"])
        AppShortcut(intent: CheckUpdatesIntent(), phrases: ["Проверь обновления в \(.applicationName)"])
    }
}
