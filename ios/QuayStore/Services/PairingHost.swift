import AVFoundation
import SwiftUI
import UserNotifications

/// A pairing file made on this iPhone (iOS 27+): Quay is advertised as a Mac over Bonjour,
/// the user pairs from Settings → Privacy & Security → Developer Mode and types the PIN.
@MainActor
final class PairingHost: ObservableObject {
    static let shared = PairingHost()

    enum State: Equatable { case idle, waiting, pin(String), done, failed(String) }
    @Published var state: State = .idle

    static var supported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    private var service: NetService?
    private var audio: AVAudioEngine?

    final class Observer: PairingHostObserver, @unchecked Sendable {
        weak var owner: PairingHost?
        init(owner: PairingHost) { self.owner = owner }
        func advertise(serviceName: String, port: UInt16, txt: [TxtEntry]) {
            Task { @MainActor in self.owner?.publish(name: serviceName, port: port, txt: txt) }
        }
        func showPin(pin: String) {
            Task { @MainActor in self.owner?.show(pin) }
        }
    }

    func start() {
        switch state { case .waiting, .pin: return; default: break }
        state = .waiting
        keepAwake(true)
        Task {
            do {
                let file = try await pairThisDevice(observer: Observer(owner: self))
                Keychain.set(file, for: Keychain.Key.pairing)
                SettingsModel.shared.objectWillChange.send()
                state = .done
                notify("Сопряжение готово", "Вернись в Quay Store")
            } catch QuayError.Cancelled {
                state = .idle
            } catch {
                state = .failed(errorText(error))
            }
            service?.stop()
            service = nil
            keepAwake(false)
        }
    }

    func cancel() { cancelPairing() }

    private func publish(name: String, port: UInt16, txt: [TxtEntry]) {
        let s = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: name, port: Int32(port))
        s.setTXTRecord(NetService.data(fromTXTRecord: Dictionary(uniqueKeysWithValues: txt.map { ($0.key, Data($0.value.utf8)) })))
        s.publish()
        service = s
    }

    private func show(_ pin: String) {
        state = .pin(pin)
        // Visible on top of Settings, where the PIN is typed.
        notify("PIN для сопряжения: \(pin)", "Введи его в Настройках")
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pairing", content: c, trigger: nil))
    }

    /// Quay must keep listening while the user is in Settings: silent audio keeps the app running.
    private func keepAwake(_ on: Bool) {
        let session = AVAudioSession.sharedInstance()
        guard on else {
            audio?.stop()
            audio = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { return }
        buffer.frameLength = buffer.frameCapacity  // zero-filled: silence
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        guard (try? engine.start()) != nil else { return }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        audio = engine
    }
}

struct PairingHostSection: View {
    @ObservedObject var host = PairingHost.shared

    var body: some View {
        if PairingHost.supported {
            Section {
                switch host.state {
                case .idle, .failed:
                    Button("Создать pairing file на этом iPhone") {
                        Task {
                            _ = await Notifier.requestPermission()
                            host.start()
                        }
                    }
                    if case .failed(let e) = host.state { Text(e).foregroundStyle(.red).font(.footnote) }
                case .waiting:
                    HStack { ProgressView(); Text("Жду iPhone…").padding(.leading, 6) }
                    Text("Открой Настройки → Конфиденциальность и безопасность → Режим разработчика, пролистай вниз и нажми «Pair with Quay Store».")
                        .font(.footnote)
                    Button("Открыть Настройки") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                    Button("Отмена", role: .cancel) { host.cancel() }
                case .pin(let pin):
                    Text(pin).font(.system(size: 40, weight: .semibold, design: .monospaced)).frame(maxWidth: .infinity)
                    Text("Введи этот код в Настройках. Он же пришёл уведомлением.").font(.footnote)
                    Button("Отмена", role: .cancel) { host.cancel() }
                case .done:
                    Text("Pairing file создан и сохранён").foregroundStyle(.green)
                }
            } header: {
                Text("Без компьютера")
            } footer: {
                Text("iOS 27+. Нужен Wi-Fi: iPhone находит Quay через локальную сеть. Разреши доступ к локальной сети, если iOS спросит.")
            }
        }
    }
}
