import SwiftUI
import Combine

/// Returns true when running in Xcode's SwiftUI preview canvas
var isRunningInPreview: Bool {
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Hosting controller that prevents automatic focus on first control
class NoAutoFocusHostingController<Content: View>: NSHostingController<Content> {
    override func viewDidAppear() {
        super.viewDidAppear()
        // Clear first responder to prevent checkbox from being focused
        view.window?.makeFirstResponder(nil)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var usageManager = UsageManager()
    var timer: Timer?
    var loadingAnimationTimer: Timer?
    var loadingAnimationPhase: Double = 0
    var cancellables = Set<AnyCancellable>()
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip full app setup when running in SwiftUI preview canvas
        guard !isRunningInPreview else { return }

        // Hide dock icon - menubar only
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        setupWakeNotification()
        setupUsageObserver()
        startFetching()
    }

    func setupWakeNotification() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func setupUsageObserver() {
        // Auto-update status item when usage or error changes
        usageManager.$usage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        usageManager.$error
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        // Animate loading state
        usageManager.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                if isLoading {
                    self?.startLoadingAnimation()
                } else {
                    self?.stopLoadingAnimation()
                }
            }
            .store(in: &cancellables)
    }

    func startLoadingAnimation() {
        // Prevent multiple timers
        if loadingAnimationTimer != nil { return }
        loadingAnimationPhase = 0
        updateLoadingIcon()
        loadingAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.loadingAnimationPhase += 0.03
                self?.updateLoadingIcon()
            }
        }
    }

    func stopLoadingAnimation() {
        loadingAnimationTimer?.invalidate()
        loadingAnimationTimer = nil
        updateStatusItem()
    }

    func updateLoadingIcon() {
        guard let button = statusItem?.button else { return }
        // Sine wave creates smooth pulse: 0.3 -> 1.0 -> 0.3 (faster cycle)
        let opacity = CGFloat((sin(loadingAnimationPhase * 6) + 1) / 2 * 0.7 + 0.3)
        // Preserve current usage values during loading
        let usagePercent = usageManager.usage?.sessionPercentage ?? 0
        let periodPercent = usageManager.usage?.sessionPeriodProgress ?? 0
        button.image = createGaugeImage(usagePercent: usagePercent, periodPercent: periodPercent, loadingDotOpacity: opacity)
        button.title = ""
    }

    @objc func handleWake() {
        // Delay refresh after wake to allow keychain to unlock
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            await usageManager.refresh()
        }
    }

    func startFetching() {
        // Initial fetch and update check
        Task {
            // If system recently booted (within 60 seconds), wait before accessing keychain
            // The keychain/login system takes time to be fully available after boot
            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime < 60 {
                let delaySeconds = max(30 - uptime, 5) // Wait until ~30s after boot, minimum 5s
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }

            await usageManager.refresh()
        }

        // Refresh every 2 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.usageManager.refresh()
            }
        }
    }
    
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = createGaugeImage(usagePercent: 0, periodPercent: 0)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 280, height: 320)
        popover?.behavior = .transient
        popover?.contentViewController = NoAutoFocusHostingController(rootView: UsageView(manager: usageManager))
    }
    
    func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        // Don't override during loading animation (check timer, not isLoading, to avoid race conditions)
        if loadingAnimationTimer != nil {
            return
        }

        if let usage = usageManager.usage {
            button.image = createGaugeImage(
                usagePercent: usage.sessionPercentage,
                periodPercent: usage.sessionPeriodProgress ?? 0
            )
            button.title = ""
        } else if usageManager.error != nil {
            button.image = createGaugeImage(usagePercent: 0, periodPercent: 0, showErrorDot: true)
            button.title = ""
        } else {
            // No data yet and not loading - show empty gauge
            button.image = createGaugeImage(usagePercent: 0, periodPercent: 0)
            button.title = ""
        }
    }

    func createGaugeImage(usagePercent: Int, periodPercent: Int, showErrorDot: Bool = false, loadingDotOpacity: CGFloat? = nil) -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size))

        let usageLineWidth: CGFloat = 3
        let periodLineWidth: CGFloat = 1
        let gap: CGFloat = 1.5

        // Full circle starting from top (90° in NSBezierPath coordinates)
        let startAngle: CGFloat = 90
        let totalSweep: CGFloat = 360

        let center = NSPoint(x: size / 2, y: size / 2)
        let usageRadius = (size - usageLineWidth) / 2 - periodLineWidth - gap
        let periodRadius = (size - periodLineWidth) / 2

        // Use label color which adapts to menu bar appearance (light/dark)
        let isDarkMenuBar = statusItem?.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let periodColor = isDarkMenuBar ? NSColor(white: 0.7, alpha: 1) : NSColor(white: 0.4, alpha: 1)
        let usageFillColor = isDarkMenuBar ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.15, alpha: 1)

        image.lockFocus()

        // Period arc - background (full circle)
        let periodBgPath = NSBezierPath()
        periodBgPath.appendArc(withCenter: center, radius: periodRadius, startAngle: 0, endAngle: 360, clockwise: false)
        periodBgPath.lineWidth = periodLineWidth
        periodBgPath.lineCapStyle = .butt
        periodColor.withAlphaComponent(0.2).setStroke()
        periodBgPath.stroke()

        // Period arc - filled
        if periodPercent > 0 {
            let periodAngle = startAngle - (CGFloat(periodPercent) / 100.0) * totalSweep
            let periodPath = NSBezierPath()
            periodPath.appendArc(withCenter: center, radius: periodRadius, startAngle: startAngle, endAngle: periodAngle, clockwise: true)
            periodPath.lineWidth = periodLineWidth
            periodPath.lineCapStyle = .butt
            periodColor.setStroke()
            periodPath.stroke()
        }

        // Usage arc - background (full circle)
        let usageBgPath = NSBezierPath()
        usageBgPath.appendArc(withCenter: center, radius: usageRadius, startAngle: 0, endAngle: 360, clockwise: false)
        usageBgPath.lineWidth = usageLineWidth
        usageBgPath.lineCapStyle = .butt
        usageFillColor.withAlphaComponent(0.2).setStroke()
        usageBgPath.stroke()

        // Usage arc - filled
        if usagePercent > 0 {
            let usageAngle = startAngle - (CGFloat(usagePercent) / 100.0) * totalSweep
            let usagePath = NSBezierPath()
            usagePath.appendArc(withCenter: center, radius: usageRadius, startAngle: startAngle, endAngle: usageAngle, clockwise: true)
            usagePath.lineWidth = usageLineWidth
            usagePath.lineCapStyle = .butt
            usageFillColor.setStroke()
            usagePath.stroke()
        }

        // Status indicator dot in lower right
        let dotSize: CGFloat = 6
        let dotCenter = NSPoint(x: size - dotSize / 2 - 1, y: dotSize / 2 + 1)
        let dotRect = NSRect(
            x: dotCenter.x - dotSize / 2,
            y: dotCenter.y - dotSize / 2,
            width: dotSize,
            height: dotSize
        )

        if showErrorDot {
            let dotPath = NSBezierPath(ovalIn: dotRect)
            NSColor.red.setFill()
            dotPath.fill()
        } else if let opacity = loadingDotOpacity {
            let dotPath = NSBezierPath(ovalIn: dotRect)
            NSColor.systemBlue.withAlphaComponent(opacity).setFill()
            dotPath.fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
    
    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            addEventMonitor()
        }
    }

    func closePopover() {
        popover?.performClose(nil)
        removeEventMonitor()
    }

    func addEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.popover?.isShown == true {
                self?.closePopover()
            }
        }
    }

    func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
