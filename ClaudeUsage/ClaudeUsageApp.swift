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

        // Redraw when menu bar appearance changes (e.g., wallpaper change, dark mode toggle)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleAppearanceChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc func handleAppearanceChange() {
        // Small delay to let the appearance fully update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.updateStatusItem()
        }
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
        // Don't update if timer was stopped (race condition with async Task)
        guard loadingAnimationTimer != nil else { return }
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
        let height: CGFloat = 18
        let barWidth: CGFloat = 16
        let spacing: CGFloat = 3

        // Measure text width dynamically
        let displayText = showErrorDot ? "!" : "\(usagePercent)%"
        let font = showErrorDot
            ? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
            : NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let textAttributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = displayText.size(withAttributes: textAttributes)
        let textWidth = ceil(textSize.width)

        let totalWidth = barWidth + spacing + textWidth + 1  // +1 for right margin
        let image = NSImage(size: NSSize(width: totalWidth, height: height))

        // Horizontal bar layout
        let horizontalPadding: CGFloat = 1
        let usageBarHeight: CGFloat = 3
        let periodBarHeight: CGFloat = 2
        let gap: CGFloat = 2

        // Vertical centering for bars
        let totalBarHeight = usageBarHeight + gap + periodBarHeight
        let topY = (height + totalBarHeight) / 2 - usageBarHeight
        let bottomY = topY - gap - periodBarHeight

        // Set appearance context for correct color resolution
        let appearance = statusItem?.button?.effectiveAppearance ?? NSAppearance.current ?? NSAppearance(named: .aqua)!
        let previousAppearance = NSAppearance.current
        NSAppearance.current = appearance

        // Use semantic color that adapts to the current appearance
        let primaryColor = NSColor.labelColor

        image.lockFocus()

        // Usage bar - background
        let effectiveBarWidth = barWidth - (horizontalPadding * 2)
        let usageBgRect = NSRect(x: horizontalPadding, y: topY, width: effectiveBarWidth, height: usageBarHeight)
        let usageBgPath = NSBezierPath(roundedRect: usageBgRect, xRadius: usageBarHeight / 2, yRadius: usageBarHeight / 2)
        primaryColor.withAlphaComponent(0.5).setFill()
        usageBgPath.fill()

        // Usage bar - filled
        if usagePercent > 0 {
            let usageFillWidth = effectiveBarWidth * CGFloat(min(usagePercent, 100)) / 100.0
            let usageFillRect = NSRect(x: horizontalPadding, y: topY, width: usageFillWidth, height: usageBarHeight)
            let usageFillPath = NSBezierPath(roundedRect: usageFillRect, xRadius: usageBarHeight / 2, yRadius: usageBarHeight / 2)
            primaryColor.withAlphaComponent(0.9).setFill()
            usageFillPath.fill()
        }

        // Period bar - background (same color as usage, just thinner)
        let periodBgRect = NSRect(x: horizontalPadding, y: bottomY, width: effectiveBarWidth, height: periodBarHeight)
        let periodBgPath = NSBezierPath(roundedRect: periodBgRect, xRadius: periodBarHeight / 2, yRadius: periodBarHeight / 2)
        primaryColor.withAlphaComponent(0.5).setFill()
        periodBgPath.fill()

        // Period bar - filled
        if periodPercent > 0 {
            let periodFillWidth = effectiveBarWidth * CGFloat(min(periodPercent, 100)) / 100.0
            let periodFillRect = NSRect(x: horizontalPadding, y: bottomY, width: periodFillWidth, height: periodBarHeight)
            let periodFillPath = NSBezierPath(roundedRect: periodFillRect, xRadius: periodBarHeight / 2, yRadius: periodBarHeight / 2)
            primaryColor.withAlphaComponent(0.9).setFill()
            periodFillPath.fill()
        }

        // Draw percentage text (or exclamation mark for error state)
        let drawAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: primaryColor
        ]
        let textX = barWidth + spacing
        let textY = (height - textSize.height) / 2
        displayText.draw(at: NSPoint(x: textX, y: textY), withAttributes: drawAttributes)

        // Status indicator dot in lower right (of the bar area)
        let dotSize: CGFloat = 6
        let dotCenter = NSPoint(x: barWidth - dotSize / 2, y: dotSize / 2 + 1)
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
            NSColor.systemGreen.withAlphaComponent(opacity).setFill()
            dotPath.fill()
        }

        image.unlockFocus()

        // Restore previous appearance
        NSAppearance.current = previousAppearance

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
