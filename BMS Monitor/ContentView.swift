import SwiftUI
import FirebaseCore
import FirebaseDatabase
import Combine
import UserNotifications
import UniformTypeIdentifiers
import ServiceManagement

// MARK: - ViewModel
class BatteryViewModel: ObservableObject {

    static let shared = BatteryViewModel()

    @Published var soc: Int = 0
    @Published var voltage: Double = 0
    @Published var current: Double = 0
    @Published var power: Double = 0
    @Published var temp: Double = 0
    @Published var status: String = "Loading..."
    @Published var remainingTime: String = "--"
    @Published var lastUpdate: Date = Date()
    @Published var isConnected: Bool = false

    private var ref: DatabaseReference?
    private var isListening = false
    private var offlineCheckTimer: Timer?
    private var batteryHandle: DatabaseHandle?
    private var previousStatus = ""
    private var offlineNotified = false
    private var fullBatteryNotified = false

    private init() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, error in
            if let error = error {
                print(error.localizedDescription)
            }
        }
    }

    func startListening() {
        guard !isListening else { return }

        // Safety net: Database.database() fatally crashes the whole app if
        // FirebaseApp.configure() hasn't actually succeeded. This used to be
        // reachable when a stale "plistConfigured" flag told AppDelegate
        // Firebase was ready when it wasn't. Even with that flag fixed, this
        // guard keeps startListening() crash-proof against any other caller
        // (restartListener(), future code, etc.) that might invoke it too early.
        guard FirebaseApp.app() != nil else {
            print("⚠️ startListening() called before Firebase was configured — skipping.")
            status = "Not Configured"
            isConnected = false
            return
        }

        ref = Database.database().reference().child(SettingsManager.shared.databasePath)
        isListening = true

        batteryHandle = ref?.observe(.value) { snapshot in
            guard let data = snapshot.value as? [String: Any] else { return }

            DispatchQueue.main.async {
                self.lastUpdate = Date()
                self.isConnected = true
                self.offlineNotified = false
                self.updateValues(from: data)
            }
        }

        offlineCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkOfflineStatus()
        }
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false

        if let handle = batteryHandle {
            ref?.removeObserver(withHandle: handle)
            batteryHandle = nil
        }
        offlineCheckTimer?.invalidate()
        offlineCheckTimer = nil
        ref = nil
    }

    func restartListener() {
        stopListening()
        startListening()
    }

    private func updateValues(from data: [String: Any]) {

        let oldSoc = soc
        soc = Int((data["soc"] as? NSNumber)?.doubleValue ?? 0)
        voltage = (data["voltage"] as? NSNumber)?.doubleValue ?? 0
        current = (data["current"] as? NSNumber)?.doubleValue ?? 0
        power = (data["power"] as? NSNumber)?.doubleValue ?? 0
        temp = (data["temp"] as? NSNumber)?.doubleValue ?? 0

        let newStatus = (data["status"] as? String ?? "Unknown")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let rawTime = data["remainingTime"] as? String ?? "--"

        if newStatus.lowercased() == "idle" {
            remainingTime = "Standby"
        } else if rawTime == "N/A" || rawTime.isEmpty {
            remainingTime = "--"
        } else {
            remainingTime = rawTime
        }

        let oldLower = previousStatus.lowercased()
        let newLower = newStatus.lowercased()

        if !previousStatus.isEmpty {

            let wasCharging = oldLower.contains("charging") && !oldLower.contains("discharging")
            let isChargingNow = newLower.contains("charging") && !newLower.contains("discharging")
            let wasDischarging = oldLower.contains("discharging")
            let isDischargingNow = newLower.contains("discharging")

            let settings = SettingsManager.shared

            if isChargingNow && !wasCharging && settings.notifyCharging {
                sendNotification(
                    title: "🔋 Charging Started",
                    body: " Charging time: \(remainingTime)"
                )
            }

            if isDischargingNow && !wasDischarging && settings.notifyDischarging {
                sendNotification(
                    title: "🔌 Battery Discharging",
                    body: "Load: \(Int(power.rounded())) W 🪫 Backup time: \(remainingTime)"
                )
            }

            if soc <= 20 && oldSoc > 20 && settings.notifyLowBattery {
                sendNotification(
                    title: "🪫 Low Battery",
                    body: " Battery at \(soc)% — connect charger"
                )
            }

            // === NEW FULL BATTERY LOGIC ===
            let isNowFullAndIdle = (soc >= 100 && newLower == "idle")
            let wasNotFullOrNotIdle = !(oldSoc >= 100 && oldLower == "idle")

            if isNowFullAndIdle && wasNotFullOrNotIdle && settings.notifyBatteryFull && !fullBatteryNotified {
                sendNotification(
                    title: "🔋 Battery Full",
                    body: " Battery fully charged - Standby Mode"
                )
                fullBatteryNotified = true
            }

            // Reset flag when it leaves full + idle state
            if !isNowFullAndIdle {
                fullBatteryNotified = false
            }
            // === END OF NEW LOGIC ===
        }

        previousStatus = newStatus
        status = newStatus
    }

    private func checkOfflineStatus() {
        let timeout = SettingsManager.shared.offlineTimeout
        let secs = Int(Date().timeIntervalSince(lastUpdate))

        if secs >= timeout && status != "Unknown" {
            isConnected = false

            if !offlineNotified && SettingsManager.shared.notifyOffline && !previousStatus.isEmpty {
                sendNotification(
                    title: "📡 Offline",
                    body: "BMS connection lost"
                )
                offlineNotified = true
            }

            soc = 0
            voltage = 0
            current = 0
            power = 0
            temp = 0
            status = "Unknown"
            remainingTime = "--"
            previousStatus = ""
        }
    }
}

// MARK: - Main View
struct ContentView: View {
    @ObservedObject private var viewModel = BatteryViewModel.shared
    @ObservedObject private var popoverVisibility = PopoverVisibility.shared
    @ObservedObject private var settings = SettingsManager.shared

    var timeSinceUpdate: String {
        let seconds = Int(Date().timeIntervalSince(viewModel.lastUpdate))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    var liveStatusText: String {
        let secs = Int(Date().timeIntervalSince(viewModel.lastUpdate))
        let timeout = settings.offlineTimeout
        if secs < timeout {
            return "Live"
        } else {
            return "Offline for • \(timeSinceUpdate)"
        }
    }

    var liveStatusColor: Color {
        let secs = Int(Date().timeIntervalSince(viewModel.lastUpdate))
        return secs < settings.offlineTimeout ? .green : .red
    }

    var statusColor: Color {
        let lower = viewModel.status.lowercased()
        if lower.contains("charging") && !lower.contains("discharging") {
            return .green
        } else if lower.contains("discharging") {
            return .orange
        } else {
            return .white
        }
    }

    var body: some View {
        ZStack {
            ParticleBackground(
                status: viewModel.status,
                fps: settings.particleFPS,
                count: settings.particleCount,
                isVisible: popoverVisibility.isVisible && settings.particleEnabled
            )
            .opacity(
                settings.plistConfigured &&
                settings.particleEnabled &&
                popoverVisibility.isVisible &&
                (viewModel.status.lowercased().contains("charginga") ||
                 viewModel.status.lowercased().contains("discharging")) ? 1 : 0
            )

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Battery Status")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(liveStatusText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(liveStatusColor)
                            .monospacedDigit()
                            .id(viewModel.lastUpdate)
                    }

                    StatusPill(status: viewModel.status)
                }

                if !settings.plistConfigured {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)

                        Text("Firebase not configured. Go to")
                            .font(.system(size: 12))
                            .foregroundColor(.yellow.opacity(0.9))

                        Text("Settings")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.yellow)
                            .underline()
                            .onTapGesture {
                                NotificationCenter.default.post(name: .openPreferencesRequested, object: nil)
                            }
                            .onHover { isHovering in
                                if isHovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }

                        Text(".")
                            .font(.system(size: 12))
                            .foregroundColor(.yellow.opacity(0.9))

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.yellow.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Divider().overlay(Color.white.opacity(0.08))

                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 0) {
                        CircularBatteryRing(soc: viewModel.soc)
                            .padding(.top, 20)

                        Spacer()

                        VStack(spacing: 6) {
                            Text(viewModel.remainingTime)
                                .foregroundColor(statusColor)
                                .font(.system(size: 24, weight: .bold))
                                .lineLimit(1)

                            Text(viewModel.status.lowercased() == "idle" ? "Standby Mode" : "Remaining Time")
                                .foregroundColor(.white.opacity(0.5))
                                .font(.system(size: 13))
                                .lineLimit(1)
                        }
                        .frame(width: 190, height: 88)
                        .multilineTextAlignment(.center)
                        .background(Color.cardBackground.opacity(0.50))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    }
                    .frame(width: 190)
                    .frame(maxHeight: .infinity)

                    VStack(spacing: 12) {
                        MetricCard(title: "Voltage", value: "\(String(format: "%.2f", viewModel.voltage)) V", icon: "waveform.path.ecg")
                        MetricCard(title: "Current", value: "\(String(format: "%.2f", viewModel.current)) A", icon: "bolt.horizontal.circle")
                        MetricCard(title: "Power", value: "\(String(format: "%.0f", viewModel.power.rounded())) W", icon: "bolt.fill")
                        MetricCard(title: "Temperature", value: "\(String(format: "%.1f", viewModel.temp)) °C", icon: "thermometer")
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 282)

                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Color.green.opacity(0.12)).frame(width: 40, height: 40)
                        Image(systemName: "chart.bar").foregroundColor(.green)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("All systems normal").foregroundColor(.white).fontWeight(.medium)
                        Text("Battery performance is good").foregroundColor(.white.opacity(0.65)).font(.system(size: 13))
                    }

                    Spacer()

                    Text("Healthy")
                        .foregroundColor(.green)
                        .fontWeight(.medium)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                }
                .padding(16)
                .background(Color.cardBackground.opacity(0.50))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.05), lineWidth: 0.8)
                )
            }
            .padding(20)
        }
        .background {
            ZStack {
                Color.windowBackground
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
    }
}

// MARK: - Particle Background
struct ParticleBackground: View {
    let status: String
    let fps: Int
    let count: Int
    let isVisible: Bool

    @State private var particles: [Particle] = []

    var isCharging: Bool {
        let lower = status.lowercased()
        return lower.contains("charging") && !lower.contains("discharging")
    }

    var body: some View {
        Group {
            if isVisible {
                TimelineView(.periodic(from: .now, by: 1.0 / Double(fps))) { timeline in
                    Canvas(opaque: false, colorMode: .linear) { context, size in
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        let color: Color = isCharging ? .green : .orange

                        for particle in particles {
                            let raw = (time * particle.speed + particle.phase)
                                .truncatingRemainder(dividingBy: particle.cycle) / particle.cycle
                            let progress = easedProgress(raw)

                            let y = isCharging
                                ? size.height * (1.08 - progress * 1.16)
                                : size.height * (progress * 1.16 - 0.08)

                            // Drift calculation (compiler-friendly)
                            let drift1 = sin(time * particle.driftFreq1 + particle.phase) * particle.driftAmp1
                            let drift2 = cos(time * particle.driftFreq2 + particle.phase * 1.7) * particle.driftAmp2
                            let drift = drift1 + drift2

                            let x = particle.baseX * size.width + drift

                            let fadeIn = min(1, raw / 0.12)
                            let fadeOut = min(1, (1 - raw) / 0.22)
                            let edgeFade = min(fadeIn, fadeOut)

                            let alpha = particle.baseAlpha * edgeFade

                            let pulsate = 1.0 + sin(time * particle.sizeFreq + particle.phase * 2.1) * 0.18
                            let radius = particle.baseRadius * pulsate

                            let rect = CGRect(
                                x: x - radius,
                                y: y - radius,
                                width: radius * 2,
                                height: radius * 2
                            )

                            context.fill(
                                Path(ellipseIn: rect),
                                with: .color(color.opacity(alpha))
                            )
                        }
                    }
                }
                .opacity(0.82)
                .blur(radius: 0.4)
                .drawingGroup()
            }
        }
        .onAppear {
            particles = (0..<count).map { _ in Particle.random() }
        }
        .onChange(of: count) { _, newCount in
            particles = (0..<newCount).map { _ in Particle.random() }
        }
    }

    private func easedProgress(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}

private struct Particle {
    let baseX: Double
    let phase: Double
    let speed: Double
    let cycle: Double
    let driftFreq1: Double
    let driftFreq2: Double
    let driftAmp1: Double
    let driftAmp2: Double
    let sizeFreq: Double
    let baseRadius: Double
    let baseAlpha: Double

    static func random() -> Particle {
        Particle(
            baseX: Double.random(in: 0.02...0.98),
            phase: Double.random(in: 0...30),
            speed: Double.random(in: 0.5...1.2),
            cycle: Double.random(in: 3.6...7.8),
            driftFreq1: Double.random(in: 0.12...0.35),
            driftFreq2: Double.random(in: 0.18...0.5),
            driftAmp1: Double.random(in: 6...16),
            driftAmp2: Double.random(in: 3...10),
            sizeFreq: Double.random(in: 0.7...2.2),
            baseRadius: Double.random(in: 0.8...2.6),
            baseAlpha: Double.random(in: 0.26...0.55)
        )
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared

    // Everything the user edits lives here in "draft" form first. Nothing
    // touches SettingsManager (or Firebase, or the listener) until Save is
    // pressed — that's what lets the Save button appear only when there's
    // something to apply, and lets us apply it all live without an app restart.
    @State private var draftDatabasePath: String = ""
    @State private var draftOfflineTimeout: Int = 30
    @State private var draftParticleEnabled: Bool = true
    @State private var draftParticleFPS: Int = 60
    @State private var draftParticleCount: Int = 100
    @State private var draftNotifyCharging: Bool = true
    @State private var draftNotifyDischarging: Bool = true
    @State private var draftNotifyLowBattery: Bool = true
    @State private var draftNotifyBatteryFull: Bool = true
    @State private var draftNotifyOffline: Bool = true

    // A newly-picked plist that hasn't been copied into place yet.
    @State private var pendingPlistURL: URL?

    // Launch at Login reflects macOS's actual SMAppService status directly —
    // toggling it takes effect immediately (it's a system registration call,
    // not app data), so it doesn't go through the draft/Save flow.
    @State private var launchAtLoginEnabled: Bool = false

    @State private var plistStatus: String = "Not Configured"
    @State private var plistStatusColor: Color = .red
    @State private var testResult: String = ""
    @State private var testResultColor: Color = .gray
    @State private var uploadError: String = ""
    @State private var isSaving = false
    @State private var saveMessage: String = ""
    @State private var saveMessageColor: Color = .green

    private var hasUnsavedChanges: Bool {
        pendingPlistURL != nil ||
        draftDatabasePath != settings.databasePath ||
        draftOfflineTimeout != settings.offlineTimeout ||
        draftParticleEnabled != settings.particleEnabled ||
        draftParticleFPS != settings.particleFPS ||
        draftParticleCount != settings.particleCount ||
        draftNotifyCharging != settings.notifyCharging ||
        draftNotifyDischarging != settings.notifyDischarging ||
        draftNotifyLowBattery != settings.notifyLowBattery ||
        draftNotifyBatteryFull != settings.notifyBatteryFull ||
        draftNotifyOffline != settings.notifyOffline
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Title + Save (top bar)
            HStack {
                Text("Settings")
                    .font(.system(size: 20, weight: .bold))

                Spacer()

                if !saveMessage.isEmpty {
                    Text(saveMessage)
                        .font(.system(size: 12))
                        .foregroundColor(saveMessageColor)
                }

                if hasUnsavedChanges {
                    Button(action: saveSettings) {
                        HStack(spacing: 6) {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isSaving ? "Saving..." : "Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Divider()

            Form {
                // MARK: General Section
                Section {
                    Toggle(isOn: Binding(
                        get: { launchAtLoginEnabled },
                        set: { newValue in
                            launchAtLoginEnabled = newValue
                            setLaunchAtLogin(newValue)
                        }
                    )) {
                        HStack {
                            Image(systemName: "power")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.indigo)
                                .cornerRadius(6)
                            Text("Launch at Login")
                        }
                    }
                } header: {
                    Text("GENERAL")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.gray)
                }

                // MARK: Firebase Section
                Section {
                    HStack {
                        Image(systemName: "doc.text")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(8)

                        Text("GoogleService-Info.plist")

                        Spacer()

                        HStack(spacing: 6) {
                            Circle()
                                .fill(plistStatusColor)
                                .frame(width: 8, height: 8)
                            Text(plistStatus)
                                .foregroundColor(plistStatusColor)
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Update File...") {
                            selectPlistFile()
                        }
                        .foregroundColor(.blue)

                        Button("Open Folder") {
                            openPlistFolder()
                        }
                        .foregroundColor(.blue)
                    }

                    if let staged = pendingPlistURL {
                        Text("📄 \(staged.lastPathComponent) selected — click Save to apply")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    }

                    if !uploadError.isEmpty {
                        Text(uploadError)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }

                    // Database Path — only editable text field
                    HStack {
                        Text("Database Path")
                        Spacer()
                        TextField("", text: $draftDatabasePath, prompt: Text("bms/live"))
                            .frame(width: 120)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(PlainTextFieldStyle())
                    }

                    // Offline Timeout — input field instead of stepper
                    HStack {
                        Text("Offline Timeout")
                        Spacer()
                        TextField("", text: Binding(
                            get: { String(draftOfflineTimeout) },
                            set: {
                                if let val = Int($0), val >= 5, val <= 300 {
                                    draftOfflineTimeout = val
                                }
                            }
                        ), prompt: Text("30"))
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(PlainTextFieldStyle())
                        Text("seconds")
                            .foregroundColor(.gray)
                            .font(.system(size: 12))
                    }

                    // Status — shows connection state automatically (updated
                    // right after a Firebase-related Save, and when the
                    // Settings window opens). No manual "Test Connection"
                    // button needed anymore.
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(testResultColor)
                                .frame(width: 8, height: 8)
                            Text(testResult.isEmpty ? "Not Configured" : testResult)
                                .foregroundColor(testResultColor)
                                .font(.system(size: 12))
                        }
                    }
                } header: {
                    Text("FIREBASE")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.gray)
                }

                // MARK: Notifications Section
                Section {
                    Toggle(isOn: $draftNotifyCharging) {
                        HStack {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.blue)
                                .cornerRadius(6)
                            Text("Charging Started")
                        }
                    }

                    Toggle(isOn: $draftNotifyDischarging) {
                        HStack {
                            Image(systemName: "battery.75")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.orange)
                                .cornerRadius(6)
                            Text("Discharging Started")
                        }
                    }

                    Toggle(isOn: $draftNotifyLowBattery) {
                        HStack {
                            Image(systemName: "battery.25")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.red)
                                .cornerRadius(6)
                            Text("Low Battery")
                        }
                    }

                    Toggle(isOn: $draftNotifyBatteryFull) {
                        HStack {
                            Image(systemName: "battery.100.bolt")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.green)
                                .cornerRadius(6)
                            Text("Battery Full")
                        }
                    }

                    Toggle(isOn: $draftNotifyOffline) {
                        HStack {
                            Image(systemName: "wifi.slash")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.gray)
                                .cornerRadius(6)
                            Text("Offline")
                        }
                    }
                } header: {
                    Text("NOTIFICATIONS")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.gray)
                }

                // MARK: Animation Section
                Section {
                    Toggle("Enable Particle Animation", isOn: $draftParticleEnabled)

                    Picker("FPS", selection: $draftParticleFPS) {
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                    }
                    .pickerStyle(SegmentedPickerStyle())

                    // Particle Count — input field instead of stepper
                    HStack {
                        Text("Particle Count")
                        Spacer()
                        TextField("", text: Binding(
                            get: { String(draftParticleCount) },
                            set: {
                                if let val = Int($0), val >= 10, val <= 1000 {
                                    draftParticleCount = val
                                }
                            }
                        ), prompt: Text("100"))
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(PlainTextFieldStyle())
                        Text("(10 - 1000)")
                            .foregroundColor(.gray)
                            .font(.system(size: 11))
                    }
                } header: {
                    Text("ANIMATION")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.gray)
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 420, minHeight: 650)
        .onAppear {
            updatePlistStatus()
            loadDraftFromSettings()
            testFirebaseConnection()
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }

    /// Shows a save-result message and auto-clears it after 5 seconds —
    /// only if a newer message hasn't already replaced it in the meantime.
    private func showSaveMessage(_ text: String, color: Color) {
        saveMessage = text
        saveMessageColor = color

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if saveMessage == text {
                saveMessage = ""
            }
        }
    }

    /// Registers/unregisters this app as a login item via SMAppService
    /// (macOS 13+). Takes effect immediately — no restart, no Save needed.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update Launch at Login: \(error)")
            // Reflect whatever macOS actually did, in case the call partially failed.
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func loadDraftFromSettings() {
        draftDatabasePath = settings.databasePath
        draftOfflineTimeout = settings.offlineTimeout
        draftParticleEnabled = settings.particleEnabled
        draftParticleFPS = settings.particleFPS
        draftParticleCount = settings.particleCount
        draftNotifyCharging = settings.notifyCharging
        draftNotifyDischarging = settings.notifyDischarging
        draftNotifyLowBattery = settings.notifyLowBattery
        draftNotifyBatteryFull = settings.notifyBatteryFull
        draftNotifyOffline = settings.notifyOffline
    }

    private func updatePlistStatus() {
        if let url = settings.plistURL, FileManager.default.fileExists(atPath: url.path) {
            plistStatus = "Configured"
            plistStatusColor = .green
        } else {
            plistStatus = "Not Configured"
            plistStatusColor = .red
        }
    }

    private func selectPlistFile() {
        uploadError = ""

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.propertyList]

        if panel.runModal() == .OK, let url = panel.url {
            // Validate it's actually a GoogleService-Info.plist
            if !url.lastPathComponent.contains("GoogleService") {
                uploadError = "✗ Please select a valid GoogleService-Info.plist file"
                return
            }

            // Just stage it — the file isn't copied and Firebase isn't
            // touched until Save is pressed. This is what makes the Save
            // button appear instead of applying immediately.
            pendingPlistURL = url
            uploadError = ""
        }
    }

    private func openPlistFolder() {
        guard let folderURL = settings.appSupportFolderURL else { return }

        // Create folder if it doesn't exist
        if !FileManager.default.fileExists(atPath: folderURL.path) {
            try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }

        NSWorkspace.shared.open(folderURL)
    }

    /// Applies every staged change live — no app restart. Copies a newly
    /// staged plist and reconfigures Firebase (delete + recreate, since
    /// Firebase can't hot-swap options on a running app) only if the plist
    /// actually changed; otherwise it just restarts the listener against
    /// whatever database path is now saved.
    private func saveSettings() {
        isSaving = true
        saveMessage = ""

        let plistWasStaged = (pendingPlistURL != nil)

        // Stop the current listener first so nothing holds a reference to
        // a FirebaseApp/path that's about to change out from under it.
        BatteryViewModel.shared.stopListening()

        if let newPlistURL = pendingPlistURL {
            _ = FirebaseConfigurator.copyPlist(from: newPlistURL)
            pendingPlistURL = nil
        }

        // Commit every draft value now.
        settings.databasePath = draftDatabasePath
        settings.offlineTimeout = draftOfflineTimeout
        settings.particleEnabled = draftParticleEnabled
        settings.particleFPS = draftParticleFPS
        settings.particleCount = draftParticleCount
        settings.notifyCharging = draftNotifyCharging
        settings.notifyDischarging = draftNotifyDischarging
        settings.notifyLowBattery = draftNotifyLowBattery
        settings.notifyBatteryFull = draftNotifyBatteryFull
        settings.notifyOffline = draftNotifyOffline

        func finish(success: Bool) {
            DispatchQueue.main.async {
                updatePlistStatus()
                if success {
                    BatteryViewModel.shared.startListening()
                    showSaveMessage("✓ Settings saved", color: .green)
                    // Refresh the Status row automatically — no separate
                    // "Test Connection" button needed anymore.
                    testFirebaseConnection()
                } else {
                    showSaveMessage("✗ Could not apply — check the plist file", color: .red)
                }
                isSaving = false
            }
        }

        if plistWasStaged {
            FirebaseConfigurator.reconfigure { success in
                finish(success: success)
            }
        } else {
            // Nothing about the plist changed, so the existing FirebaseApp
            // (if any) is still valid — just restart the listener with the
            // (possibly new) database path / timeout.
            finish(success: FirebaseApp.app() != nil)
        }
    }

    private func testFirebaseConnection() {
        guard FirebaseApp.app() != nil, settings.plistConfigured else {
            testResult = "Not Configured"
            testResultColor = .red
            return
        }

        testResult = "Testing..."
        testResultColor = .gray

        // Test with timeout to avoid getting stuck
        let testRef = Database.database().reference().child(settings.databasePath)

        // Set a timer to catch timeout/errors
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            if self.testResult == "Testing..." {
                self.testResult = "Connection Timeout"
                self.testResultColor = .red
            }
        }

        testRef.observeSingleEvent(of: .value) { snapshot in
            timer.invalidate()
            DispatchQueue.main.async {
                if snapshot.exists() {
                    self.testResult = "Connected"
                    self.testResultColor = .green
                } else {
                    self.testResult = "Path Not Found"
                    self.testResultColor = .orange
                }
            }
        } withCancel: { error in
            timer.invalidate()
            DispatchQueue.main.async {
                let message = error.localizedDescription.lowercased()
                if message.contains("permission") {
                    self.testResult = "Access Denied"
                } else if message.contains("credential") || message.contains("unauthorized") || message.contains("invalid") {
                    self.testResult = "Wrong Credentials"
                } else {
                    self.testResult = "✗ \(error.localizedDescription)"
                }
                self.testResultColor = .red
            }
        }
    }
}

// MARK: - Other Views
struct MetricCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.green.opacity(0.12)).frame(width: 34, height: 34)
                Image(systemName: icon).foregroundColor(.green).font(.system(size: 16, weight: .medium))
            }
            Text(title).foregroundColor(.white.opacity(0.9))
            Spacer()
            Text(value).foregroundColor(.white).fontWeight(.medium)
        }
        .padding(14)
        .background(Color.cardBackground.opacity(0.50))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.8)
        )
        .frame(width: 235)
    }
}

struct CircularBatteryRing: View {
    let soc: Int

    var ringColor: Color {
        if soc <= 20 { return .red }
        if soc <= 50 { return .orange }
        return .green
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.25), lineWidth: 12)

            Circle()
                .trim(from: 0, to: CGFloat(soc) / 100)
                .stroke(
                    ringColor,
                    style: StrokeStyle(
                        lineWidth: 12,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 4) {
                Text("\(soc)%")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)

                Text("Capacity")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .frame(width: 140, height: 140)
    }
}

struct StatusPill: View {
    let status: String

    var isCharging: Bool {
        status.lowercased().contains("charging") && !status.lowercased().contains("discharging")
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(isCharging ? .green : .orange).frame(width: 8, height: 8)
            Text(status).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 0.8))
    }
}

extension Color {
    static let cardBackground = Color(red: 0.09, green: 0.114, blue: 0.133)
    static let windowBackground = Color(red: 0.055, green: 0.082, blue: 0.106)
}

private func sendNotification(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default

    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
    )

    UNUserNotificationCenter.current().add(request)
}
