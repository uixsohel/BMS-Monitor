import SwiftUI
import FirebaseCore
import FirebaseDatabase
import Combine

@main
struct BMSMonitorApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        FirebaseConfigurator.configure()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - Popover Visibility
final class PopoverVisibility: ObservableObject {
    static let shared = PopoverVisibility()
    @Published var isVisible = false
}

// MARK: - Cross-view notifications
// ContentView (hosted inside the popover) has no direct reference to
// AppDelegate's openPreferences(), so it posts this notification instead
// and AppDelegate listens for it to open the Settings window.
extension Notification.Name {
    static let openPreferencesRequested = Notification.Name("openPreferencesRequested")
}

// MARK: - Settings Manager
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var databasePath: String {
        didSet { UserDefaults.standard.set(databasePath, forKey: "databasePath") }
    }
    @Published var offlineTimeout: Int {
        didSet { UserDefaults.standard.set(offlineTimeout, forKey: "offlineTimeout") }
    }
    @Published var particleEnabled: Bool {
        didSet { UserDefaults.standard.set(particleEnabled, forKey: "particleEnabled") }
    }
    @Published var particleFPS: Int {
        didSet { UserDefaults.standard.set(particleFPS, forKey: "particleFPS") }
    }
    @Published var particleCount: Int {
        didSet { UserDefaults.standard.set(particleCount, forKey: "particleCount") }
    }
    @Published var notifyCharging: Bool {
        didSet { UserDefaults.standard.set(notifyCharging, forKey: "notifyCharging") }
    }
    @Published var notifyDischarging: Bool {
        didSet { UserDefaults.standard.set(notifyDischarging, forKey: "notifyDischarging") }
    }
    @Published var notifyLowBattery: Bool {
        didSet { UserDefaults.standard.set(notifyLowBattery, forKey: "notifyLowBattery") }
    }
    @Published var notifyBatteryFull: Bool {
        didSet { UserDefaults.standard.set(notifyBatteryFull, forKey: "notifyBatteryFull") }
    }
    @Published var notifyOffline: Bool {
        didSet { UserDefaults.standard.set(notifyOffline, forKey: "notifyOffline") }
    }
    @Published var plistConfigured: Bool {
        didSet { UserDefaults.standard.set(plistConfigured, forKey: "plistConfigured") }
    }

    private init() {
        let defaults: [String: Any] = [
            "databasePath": "bms/live",
            "offlineTimeout": 30,
            "particleEnabled": true,
            "particleFPS": 60,
            "particleCount": 100,
            "notifyCharging": true,
            "notifyDischarging": true,
            "notifyLowBattery": true,
            "notifyBatteryFull": true,
            "notifyOffline": true,
            "plistConfigured": false
        ]
        UserDefaults.standard.register(defaults: defaults)

        databasePath = UserDefaults.standard.string(forKey: "databasePath") ?? "bms/live"
        offlineTimeout = UserDefaults.standard.integer(forKey: "offlineTimeout")
        particleEnabled = UserDefaults.standard.bool(forKey: "particleEnabled")
        particleFPS = UserDefaults.standard.integer(forKey: "particleFPS")
        particleCount = UserDefaults.standard.integer(forKey: "particleCount")
        notifyCharging = UserDefaults.standard.bool(forKey: "notifyCharging")
        notifyDischarging = UserDefaults.standard.bool(forKey: "notifyDischarging")
        notifyLowBattery = UserDefaults.standard.bool(forKey: "notifyLowBattery")
        notifyBatteryFull = UserDefaults.standard.bool(forKey: "notifyBatteryFull")
        notifyOffline = UserDefaults.standard.bool(forKey: "notifyOffline")
        plistConfigured = UserDefaults.standard.bool(forKey: "plistConfigured")
    }

    var plistURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("BMS Monitor", isDirectory: true)
        return appFolder.appendingPathComponent("GoogleService-Info.plist")
    }

    var appSupportFolderURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("BMS Monitor", isDirectory: true)
    }
}

// MARK: - Firebase Configurator
enum FirebaseConfigurator {
    static func configure() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("BMS Monitor", isDirectory: true)
        let plistURL = appFolder.appendingPathComponent("GoogleService-Info.plist")

        guard FileManager.default.fileExists(atPath: plistURL.path),
              let options = FirebaseOptions(contentsOfFile: plistURL.path) else {
            // Plist missing or unreadable this launch — make sure the
            // persisted flag reflects reality instead of staying stuck on
            // a stale "true" from a previous successful launch. Leaving it
            // true here is exactly what let AppDelegate believe Firebase
            // was configured when it wasn't, causing a crash on startListening().
            print("GoogleService-Info.plist missing or invalid at \(plistURL.path)")
            SettingsManager.shared.plistConfigured = false
            return
        }

        if FirebaseApp.app() == nil {
            FirebaseApp.configure(options: options)
            print("Firebase configured from Application Support")
        }

        // Only ever mark configured once Firebase has actually confirmed it.
        SettingsManager.shared.plistConfigured = (FirebaseApp.app() != nil)
    }

    /// Live-reconfigures Firebase against whatever plist is currently at
    /// disk — used when the user has just uploaded a new
    /// GoogleService-Info.plist via Settings and clicked Save. Firebase
    /// doesn't support swapping FirebaseOptions on a running FirebaseApp,
    /// so an already-configured app has to be deleted first, then a fresh
    /// one configured with the new options. No app restart required.
    static func reconfigure(completion: @escaping (Bool) -> Void) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("BMS Monitor", isDirectory: true)
        let plistURL = appFolder.appendingPathComponent("GoogleService-Info.plist")

        guard FileManager.default.fileExists(atPath: plistURL.path),
              let options = FirebaseOptions(contentsOfFile: plistURL.path) else {
            print("GoogleService-Info.plist missing or invalid at \(plistURL.path)")
            SettingsManager.shared.plistConfigured = false
            completion(false)
            return
        }

        if let existingApp = FirebaseApp.app() {
            existingApp.delete { _ in
                FirebaseApp.configure(options: options)
                let success = FirebaseApp.app() != nil
                SettingsManager.shared.plistConfigured = success
                completion(success)
            }
        } else {
            FirebaseApp.configure(options: options)
            let success = FirebaseApp.app() != nil
            SettingsManager.shared.plistConfigured = success
            completion(success)
        }
    }

    static func copyPlist(from sourceURL: URL) -> Bool {
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appFolder = appSupport.appendingPathComponent("BMS Monitor", isDirectory: true)
            try FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)

            let destination = appFolder.appendingPathComponent("GoogleService-Info.plist")

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return true
        } catch {
            print("Failed to copy plist: \(error)")
            return false
        }
    }
}
