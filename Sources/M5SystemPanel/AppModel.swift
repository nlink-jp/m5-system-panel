import AppKit
import Foundation
import Observation
import PanelCore
import PanelSystem

/// The companion's state, as the menu and the setup window see it. Owns the
/// drivers; holds no protocol logic of its own.
@MainActor
@Observable
final class AppModel {
    private(set) var registration: Registration?
    private(set) var status: ConnectionSupervisor.Status = .searching
    private(set) var setupPhase: SetupDriver.Phase = .idle
    private(set) var loginItem: LoginItemState
    private(set) var lastError: String?
    /// The screen brightness level sent with every frame (ADR-0003).
    private(set) var brightness = BrightnessPreference.level(
        stored: UserDefaults.standard.object(forKey: BrightnessPreference.key))

    @ObservationIgnored private let store: RegistrationStore
    @ObservationIgnored private let loginService = LoginItemService()
    @ObservationIgnored private var collector: MetricsCollector?
    @ObservationIgnored private var run: RunDriver?
    @ObservationIgnored private var setup: SetupDriver?
    /// App Nap would throttle the one-second timer of a windowless app
    /// (ADR-0001 constraint); held while a panel is registered.
    @ObservationIgnored private var activity: NSObjectProtocol?

    init() {
        // A bare `swift run` has no bundle and no Keychain identity: keep it in memory.
        store = Bundle.main.bundleIdentifier == nil ? MemoryRegistrationStore() : KeychainRegistrationStore()
        loginItem = loginService.state
        do {
            registration = try store.active()
        } catch {
            lastError = "登録を読めませんでした: \(error)"
        }
        let setup = SetupDriver(
            store: store,
            onPhase: { [weak self] phase in self?.setupPhase = phase },
            onRegistered: { [weak self] in self?.reloadRegistration() })
        self.setup = setup
        setup.start()
        startRunIfRegistered()
    }

    var statusText: String { MenuText.status(registered: registration, supervisor: status) }
    var hintText: String? { registration == nil ? nil : MenuText.hint(supervisor: status) }
    var brightnessHint: String? { MenuText.brightnessHint(supervisor: status) }
    var brightnessSelectable: Bool { brightnessHint == nil }
    var setupOffered: Bool {
        if case .offered = setupPhase { return true }
        return false
    }

    // MARK: actions

    func startSetup() { setup?.requestList() }

    func join(ssid: [UInt8], password: [UInt8]?) { setup?.join(ssid: ssid, password: password) }

    func dismissSetupResult() { setup?.dismissResult() }

    func unregister() {
        do {
            try store.removeAll()
        } catch {
            lastError = "登録を解除できませんでした: \(error)"
            return
        }
        stopRun()
        registration = nil
        status = .searching
    }

    func setBrightness(_ level: Int) {
        guard Readings.brightnessLevels.contains(level) else { return }
        brightness = level
        UserDefaults.standard.set(level, forKey: BrightnessPreference.key)
        run?.brightness = level  // goes out with the next frame
    }

    func setLoginItem(_ on: Bool) {
        do {
            try loginService.set(on)
        } catch {
            lastError = "ログイン時の起動を変更できませんでした: \(error.localizedDescription)"
        }
        loginItem = loginService.state
    }

    // MARK: run session

    private func reloadRegistration() {
        stopRun()
        registration = try? store.active()
        status = .searching
        startRunIfRegistered()
    }

    private func startRunIfRegistered() {
        guard let registration else { return }
        let collector = self.collector ?? makeCollector()
        self.collector = collector
        let run = RunDriver(registration: registration, collector: collector, brightness: brightness) {
            [weak self] status in self?.status = status
        }
        self.run = run
        run.start()
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Sending readings to the panel")
    }

    private func stopRun() {
        run?.stop()
        run = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func makeCollector() -> MetricsCollector {
        // Probe GPU once: when the key is missing the panel hides GPU (RFP §3).
        let gpu = IOKitGPUSampler()
        return MetricsCollector(gpu: gpu.sample() == nil ? nil : gpu)
    }
}
