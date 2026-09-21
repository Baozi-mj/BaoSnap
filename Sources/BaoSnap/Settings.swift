import Foundation
import Combine
import ServiceManagement

/// User preferences, persisted through UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var copyToClipboard: Bool { didSet { d.set(copyToClipboard, forKey: "copyToClipboard") } }
    @Published var showToast: Bool { didSet { d.set(showToast, forKey: "showToast") } }
    @Published var playSound: Bool { didSet { d.set(playSound, forKey: "playSound") } }
    @Published var historyLimit: Int { didSet { d.set(historyLimit, forKey: "historyLimit") } }
    @Published var pinShadow: Bool { didSet { d.set(pinShadow, forKey: "pinShadow") } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("launch at login failed: \(error)")
                launchAtLogin = oldValue
            }
        }
    }

    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "copyToClipboard": true,
            "showToast": true,
            "playSound": true,
            "historyLimit": 300,
            "pinShadow": true,
        ])
        copyToClipboard = d.bool(forKey: "copyToClipboard")
        showToast = d.bool(forKey: "showToast")
        playSound = d.bool(forKey: "playSound")
        historyLimit = d.integer(forKey: "historyLimit")
        pinShadow = d.bool(forKey: "pinShadow")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
