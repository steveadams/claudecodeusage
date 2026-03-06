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
        let sessionUsage = usageManager.usage?.sessionPercentage ?? 0
        let sessionPeriod = usageManager.usage?.sessionPeriodProgress ?? 0
        let weeklyUsage = usageManager.usage?.weeklyPercentage ?? 0
        let weeklyPeriod = usageManager.usage?.weeklyPeriodProgress ?? 0
        button.image = createGaugeImage(
            sessionUsagePercent: sessionUsage, sessionPeriodPercent: sessionPeriod,
            weeklyUsagePercent: weeklyUsage, weeklyPeriodPercent: weeklyPeriod,
            loadingOpacity: opacity
        )
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

        // Refresh every 5 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.usageManager.refresh()
            }
        }
    }
    
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = createGaugeImage(sessionUsagePercent: 0, sessionPeriodPercent: 0, weeklyUsagePercent: 0, weeklyPeriodPercent: 0)
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
                sessionUsagePercent: usage.sessionPercentage,
                sessionPeriodPercent: usage.sessionPeriodProgress ?? 0,
                weeklyUsagePercent: usage.weeklyPercentage,
                weeklyPeriodPercent: usage.weeklyPeriodProgress ?? 0
            )
            button.title = ""
        } else if usageManager.error != nil {
            button.image = createGaugeImage(sessionUsagePercent: 0, sessionPeriodPercent: 0, weeklyUsagePercent: 0, weeklyPeriodPercent: 0, showError: true)
            button.title = ""
        } else {
            // No data yet and not loading - show empty gauge
            button.image = createGaugeImage(sessionUsagePercent: 0, sessionPeriodPercent: 0, weeklyUsagePercent: 0, weeklyPeriodPercent: 0)
            button.title = ""
        }
    }

    func createGaugeImage(
        sessionUsagePercent: Int, sessionPeriodPercent: Int,
        weeklyUsagePercent: Int, weeklyPeriodPercent: Int,
        showError: Bool = false, loadingOpacity: CGFloat? = nil
    ) -> NSImage {
        let height: CGFloat = 18
        let barHeight: CGFloat = 6.5
        let rowGap: CGFloat = 4
        let labelBarGap: CGFloat = 2
        let barWidth: CGFloat = 20

        let labelFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .medium)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont]
        let label5h = "5H"
        let label7d = "7D"
        let label5hSize = label5h.size(withAttributes: labelAttrs)
        let label7dSize = label7d.size(withAttributes: labelAttrs)
        let labelWidth = ceil(max(label5hSize.width, label7dSize.width))

        let totalWidth = labelWidth + labelBarGap + barWidth + 1

        let image = NSImage(size: NSSize(width: totalWidth, height: height))

        // Vertical layout: two rows centered
        let totalRowsHeight = barHeight * 2 + rowGap
        let topRowY = (height + totalRowsHeight) / 2 - barHeight
        let bottomRowY = topRowY - rowGap - barHeight

        let barX = labelWidth + labelBarGap

        // Set appearance context for correct color resolution
        let appearance = statusItem?.button?.effectiveAppearance ?? NSAppearance(named: .aqua)!

        image.lockFocus()

        // Use the appearance context for correct color resolution
        appearance.performAsCurrentDrawingAppearance {
            let primaryColor = NSColor.labelColor
            let barAlpha: CGFloat = loadingOpacity ?? 1.0

            // Helper to draw a single gauge row
            func drawGaugeRow(y: CGFloat, label: String, labelSize: NSSize, usagePercent: Int, periodPercent: Int) {
                let isOverage = usagePercent > periodPercent
                let labelColor = showError ? NSColor.red : (isOverage ? NSColor.orange : primaryColor)

                // Draw label
                let labelY = y + (barHeight - labelSize.height) / 2
                let labelDrawAttrs: [NSAttributedString.Key: Any] = [
                    .font: labelFont,
                    .foregroundColor: labelColor.withAlphaComponent(barAlpha)
                ]
                label.draw(at: NSPoint(x: 0, y: labelY), withAttributes: labelDrawAttrs)

                // 1. Background bar (full width, faint)
                let bgRect = NSRect(x: barX, y: y, width: barWidth, height: barHeight)
                let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 1, yRadius: 1)

                if showError {
                    NSColor.red.withAlphaComponent(0.3).setFill()
                } else {
                    primaryColor.withAlphaComponent(0.15 * barAlpha).setFill()
                }
                bgPath.fill()

                // Error state: fill bars fully red
                if showError {
                    let fillRect = NSRect(x: barX, y: y, width: barWidth, height: barHeight)
                    let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1, yRadius: 1)
                    NSColor.red.withAlphaComponent(0.6).setFill()
                    fillPath.fill()
                    return
                }

                // 2. Period progress fill
                if periodPercent > 0 {
                    let periodWidth = barWidth * CGFloat(min(periodPercent, 100)) / 100.0
                    let periodRect = NSRect(x: barX, y: y, width: periodWidth, height: barHeight)
                    let periodPath = NSBezierPath(roundedRect: periodRect, xRadius: 1, yRadius: 1)
                    primaryColor.withAlphaComponent(0.4 * barAlpha).setFill()
                    periodPath.fill()
                }

                // 3. Usage fill (clamped to period extent)
                if usagePercent > 0 {
                    let usageClamped = min(usagePercent, periodPercent)
                    if usageClamped > 0 {
                        let usageWidth = barWidth * CGFloat(min(usageClamped, 100)) / 100.0
                        let usageRect = NSRect(x: barX, y: y, width: usageWidth, height: barHeight)
                        let usagePath = NSBezierPath(roundedRect: usageRect, xRadius: 1, yRadius: 1)
                        primaryColor.withAlphaComponent(0.85 * barAlpha).setFill()
                        usagePath.fill()
                    }
                }

                // 4. Overage: usage beyond period in red
                if isOverage {
                    let periodWidth = barWidth * CGFloat(min(periodPercent, 100)) / 100.0
                    let usageWidth = barWidth * CGFloat(min(usagePercent, 100)) / 100.0
                    let overageWidth = usageWidth - periodWidth
                    if overageWidth > 0 {
                        let overageRect = NSRect(x: barX + periodWidth, y: y, width: overageWidth, height: barHeight)
                        let overagePath = NSBezierPath(roundedRect: overageRect, xRadius: 1, yRadius: 1)
                        NSColor.orange.withAlphaComponent(barAlpha).setFill()
                        overagePath.fill()
                    }
                }
            }

            // Top row: 5h (session)
            drawGaugeRow(y: topRowY, label: label5h, labelSize: label5hSize, usagePercent: sessionUsagePercent, periodPercent: sessionPeriodPercent)

            // Bottom row: 7d (weekly)
            drawGaugeRow(y: bottomRowY, label: label7d, labelSize: label7dSize, usagePercent: weeklyUsagePercent, periodPercent: weeklyPeriodPercent)
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
