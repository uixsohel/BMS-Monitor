import SwiftUI
import AppKit
import Combine
import FirebaseCore
import FirebaseDatabase

// MARK: - Custom Settings Window (No Icon)
class SettingsWindow: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        self.title = ""
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.standardWindowButton(.documentIconButton)?.removeFromSuperview()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {

        NSApp.setActivationPolicy(.accessory)

        if FirebaseApp.app() != nil {
            BatteryViewModel.shared.startListening()
        }

        popover.contentSize = NSSize(width: 470, height: 500)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ContentView())

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {

            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            updateButton(soc: BatteryViewModel.shared.soc, status: BatteryViewModel.shared.status)
        }

        BatteryViewModel.shared.$soc
            .combineLatest(BatteryViewModel.shared.$status)
            .receive(on: RunLoop.main)
            .sink { [weak self] soc, status in
                self?.updateButton(soc: soc, status: status)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: .openPreferencesRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.popover.performClose(nil)
            self?.openPreferences()
        }
    }

    private func updateButton(soc: Int, status: String) {
        guard let button = statusItem.button else { return }

        let lower = status.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let isCharging = lower.contains("charging") && !lower.contains("discharging")

        let imageName: String
        if isCharging {
            imageName = "battery.100.bolt"
        } else if soc <= 20 {
            imageName = "battery.25"
        } else if soc <= 50 {
            imageName = "battery.50"
        } else if soc <= 80 {
            imageName = "battery.75"
        } else {
            imageName = "battery.100"
        }

        if let image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil) {

            if isCharging {
                image.isTemplate = false
                button.contentTintColor = .systemGreen
            } else {
                image.isTemplate = true
                button.contentTintColor = nil
            }

            button.image = image
        }

        button.title = " \(soc)%"
    }

    @objc
    private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            openWindow()
            return
        }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Dashboard", action: #selector(openWindow), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Preferences", action: #selector(openPreferences), keyEquivalent: "")
        menu.addItem(withTitle: "About", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
        }
    }

    @objc
    private func openWindow() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)

        if !popover.isShown {
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
        }
    }

    @objc
    private func openPreferences() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "BMS Monitor"
        alert.informativeText = "Battery Management System Monitor\nVersion 1.0"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        PopoverVisibility.shared.isVisible = false
        if let window = notification.object as? NSWindow, window == settingsWindow {
            settingsWindow = nil
        }
    }

    // MARK: - NSPopoverDelegate
    func popoverWillShow(_ notification: Notification) {
        PopoverVisibility.shared.isVisible = true
    }

    func popoverDidClose(_ notification: Notification) {
        PopoverVisibility.shared.isVisible = false
    }
}
