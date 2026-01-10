import SwiftUI

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var usageManager = UsageManager()
    var timer: Timer?

    private let hasLaunchedKey = "hasLaunchedBefore"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon - menubar only
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        setupWakeNotification()

        // Show first launch explanation if needed
        if !UserDefaults.standard.bool(forKey: hasLaunchedKey) {
            showKeychainExplanation {
                UserDefaults.standard.set(true, forKey: self.hasLaunchedKey)
                self.startFetching()
            }
        } else {
            startFetching()
        }
    }

    func setupWakeNotification() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc func handleWake() {
        // Delay refresh after wake to allow keychain to unlock
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            await usageManager.refresh()
            updateStatusItem()
        }
    }

    func showKeychainExplanation(completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Keychain Access Required"
        alert.informativeText = "Claude Usage needs to access the macOS Keychain to read your Claude Code credentials.\n\nThis allows the app to check your usage limits without requiring you to log in again.\n\nYour credentials are stored securely by Claude Code and are never sent anywhere except to Anthropic's API."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.runModal()
        completion()
    }

    func startFetching() {
        // Initial fetch and update check
        Task {
            await usageManager.refresh()
            await usageManager.checkForUpdates()
            updateStatusItem()
        }

        // Refresh every 2 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.usageManager.refresh()
                self?.updateStatusItem()
            }
        }
    }
    
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "⏳"
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 280, height: 320)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: UsageView(manager: usageManager))
    }
    
    func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        if let usage = usageManager.usage {
            let sessionPct = usage.sessionPercentage
            let emoji = usageManager.statusEmoji
            button.title = "\(emoji) \(sessionPct)%"
        } else if usageManager.error != nil {
            button.title = "❌"
        } else {
            button.title = "⏳"
        }
    }
    
    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            
            // Bring to front
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
