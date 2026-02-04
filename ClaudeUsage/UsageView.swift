import SwiftUI
import AppKit
import ServiceManagement

struct UsageView: View {
    @ObservedObject var manager: UsageManager
    @Environment(\.openURL) var openURL
    @State private var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.accentColor)
                Text("Claude Usage")
                    .font(.headline)
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()

                ProgressView()
                    .scaleEffect(0.5)
                    .opacity(manager.isLoading ? 1 : 0)
            }
            .padding(.horizontal)
            .padding(.vertical)

            Divider()

            if let error = manager.error {
                errorView(error)
            } else if let usage = manager.usage {
                usageContent(usage)
            } else {
                loadingView()
            }
            
            Divider()
            
            // Footer
            footerView()
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: Usage Content

    @ViewBuilder
    func usageContent(_ usage: UsageData) -> some View {
        VStack(spacing: 16) {
            // Table layout with columns (5 HOUR, 7 DAY) and rows (USAGE, PERIOD)
            let sessionTime = formatTimeRemaining(usage.sessionResetsAt)
            let weeklyTime = formatTimeRemaining(usage.weeklyResetsAt)

            let rowHeight: CGFloat = 26

            Grid(horizontalSpacing: 24, verticalSpacing: 8) {
                // Header row
                GridRow {
                    Text("")
                        .gridColumnAlignment(.leading)
                    Text("5 HOUR")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .gridColumnAlignment(.leading)
                    Text("7 DAY")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .gridColumnAlignment(.leading)
                }
                .frame(height: rowHeight)

                // USAGE row
                GridRow(alignment: .center) {
                    Text("USAGE")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))
                    UsageGaugeCell(
                        percent: usage.sessionPercentage,
                        periodPercent: usage.sessionPeriodProgress ?? 0,
                        isUsage: true
                    )
                    UsageGaugeCell(
                        percent: usage.weeklyPercentage,
                        periodPercent: usage.weeklyPeriodProgress ?? 0,
                        isUsage: true
                    )
                }
                .frame(height: rowHeight)

                // PERIOD row
                GridRow(alignment: .center) {
                    Text("PERIOD")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))
                    UsageGaugeCell(
                        percent: usage.sessionPeriodProgress ?? 0,
                        periodPercent: nil,
                        isUsage: false
                    )
                    UsageGaugeCell(
                        percent: usage.weeklyPeriodProgress ?? 0,
                        periodPercent: nil,
                        isUsage: false
                    )
                }
                .frame(height: rowHeight)

                // Reset time row
                GridRow(alignment: .center) {
                    Text("RESET")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))
                    if let sessionTime = sessionTime {
                        Text("\(sessionTime.duration) - \(sessionTime.resetTime)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text("—")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if let weeklyTime = weeklyTime {
                        Text("\(weeklyTime.duration) - \(weeklyTime.resetTime)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text("—")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(height: rowHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let lastUpdated = manager.lastUpdated {
                Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical)
    }
    
    @ViewBuilder
    func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            if error.contains("Not logged in") {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.largeTitle)
                    .foregroundColor(.blue)

                Text("Not Signed In")
                    .font(.headline)

                Text("This app uses credentials from Claude Code stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("Please run `claude` in Terminal and log in first.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button("Open Terminal & Run Claude") {
                    launchClaudeCLI()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)

                Button("Install Claude Code") {
                    openURL(URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")!)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.orange)

                Text(error)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    func loadingView() -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading usage data...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    func footerView() -> some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .onChange(of: launchAtLogin) { newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !newValue
                        }
                    }

                Spacer()

                Button(action: {
                    Task { await manager.refresh() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(manager.isLoading)
                .help("Refresh usage data")

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Quit ClaudeUsage")
            }
            .padding(.horizontal)
            .padding(.vertical)
        }
    }
    
    func formatTimeRemaining(_ date: Date?) -> (duration: String, resetTime: String)? {
        guard let date = date else { return nil }
        let diff = date.timeIntervalSince(Date())
        if diff <= 0 { return ("SOON", "NOW") }

        let totalHours = diff / 3600

        // Format duration (rounded)
        let duration: String
        if totalHours >= 24 {
            let days = totalHours / 24
            if days >= 2 {
                duration = "\(Int(days.rounded()))D"
            } else {
                // Show half-day precision for 1-2 days
                let roundedDays = (days * 2).rounded() / 2
                if roundedDays == roundedDays.rounded() {
                    duration = "\(Int(roundedDays))D"
                } else {
                    duration = "\(String(format: "%.1f", roundedDays))D"
                }
            }
        } else if totalHours < 1 {
            let minutes = Int(diff / 60)
            duration = "\(minutes)M"
        } else {
            // Round to nearest 0.5h
            let roundedHours = (totalHours * 2).rounded() / 2
            if roundedHours == roundedHours.rounded() {
                duration = "\(Int(roundedHours))H"
            } else {
                duration = "\(String(format: "%.1f", roundedHours))H"
            }
        }

        // Format reset time (use current timezone explicitly for consistency)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "ha"
        timeFormatter.timeZone = .current
        let timeString = timeFormatter.string(from: date).uppercased()

        let resetTime: String
        if totalHours >= 24 {
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "EEE"
            dayFormatter.timeZone = .current
            let dayString = dayFormatter.string(from: date).uppercased()
            resetTime = "\(dayString) \(timeString)"
        } else {
            resetTime = timeString
        }

        return (duration, resetTime)
    }

    func launchClaudeCLI() {
        let script = """
        tell application "Terminal"
            activate
            do script "claude"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

// MARK: - Arc Shape

// Custom arc shape
struct Arc: Shape {
    let startAngle: Angle
    let endAngle: Angle
    let clockwise: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: clockwise)
        return path
    }
}

// MARK: - Gauge Cell Component

/// A gauge cell showing percentage above the gauge bar (for table layout)
struct UsageGaugeCell: View {
    let percent: Int
    let periodPercent: Int?  // Only used for usage gauges to show overage
    let isUsage: Bool

    private let trackHeight: CGFloat = 3
    private let markerHeight: CGFloat = 10
    private let markerWidth: CGFloat = 1

    // Usage gradient: green → yellow/orange → red
    private let usageGradientColors: [Color] = [
        Color(red: 0.2, green: 0.8, blue: 0.3),   // Green
        Color(red: 0.5, green: 0.85, blue: 0.3),  // Yellow-green
        Color(red: 0.95, green: 0.8, blue: 0.2),  // Yellow
        Color(red: 0.95, green: 0.6, blue: 0.2),  // Orange
        Color(red: 0.95, green: 0.4, blue: 0.3),  // Red-orange
        Color(red: 0.9, green: 0.25, blue: 0.25), // Red
    ]

    // Period color: blue
    private let periodColor = Color(red: 0.3, green: 0.5, blue: 0.95)

    // Overage color: red
    private let overageColor = Color(red: 0.9, green: 0.25, blue: 0.25)

    /// Color sampled from gradient at current percentage
    private var fillColor: Color {
        if isUsage {
            let index = Double(percent) / 100.0 * Double(usageGradientColors.count - 1)
            let clampedIndex = max(0, min(index, Double(usageGradientColors.count - 1)))
            return usageGradientColors[Int(clampedIndex.rounded())]
        } else {
            return periodColor
        }
    }

    /// Whether usage exceeds period progress (over-pacing)
    private var hasOverage: Bool {
        guard isUsage, let period = periodPercent else { return false }
        return percent > period
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Percentage
            Text("\(percent)%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)

            // Gauge track with marker
            GeometryReader { geometry in
                let trackWidth = geometry.size.width
                let markerPosition = trackWidth * CGFloat(percent) / 100.0

                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: trackHeight / 2)
                        .fill(fillColor.opacity(0.2))
                        .frame(height: trackHeight)

                    // Filled track (gradient for usage, solid for period)
                    if isUsage {
                        if hasOverage, let period = periodPercent {
                            // Split fill: gradient up to period, then red overage
                            let periodPosition = trackWidth * CGFloat(period) / 100.0

                            // Normal gradient up to period progress
                            RoundedRectangle(cornerRadius: trackHeight / 2)
                                .fill(
                                    LinearGradient(
                                        colors: usageGradientColors,
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: trackWidth, height: trackHeight)
                                .mask(alignment: .leading) {
                                    Rectangle()
                                        .frame(width: max(0, periodPosition))
                                }

                            // Red overage section from period to usage
                            Rectangle()
                                .fill(overageColor)
                                .frame(width: max(0, markerPosition - periodPosition), height: trackHeight)
                                .offset(x: periodPosition)
                        } else {
                            // Normal case: gradient spans full width so colors match their position
                            RoundedRectangle(cornerRadius: trackHeight / 2)
                                .fill(
                                    LinearGradient(
                                        colors: usageGradientColors,
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: trackWidth, height: trackHeight)
                                .mask(alignment: .leading) {
                                    Rectangle()
                                        .frame(width: max(0, markerPosition))
                                }
                        }
                    } else {
                        RoundedRectangle(cornerRadius: trackHeight / 2)
                            .fill(periodColor)
                            .frame(width: max(0, markerPosition), height: trackHeight)
                    }

                    // Vertical marker
                    RoundedRectangle(cornerRadius: markerWidth / 2)
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: markerWidth, height: markerHeight)
                        .offset(x: max(0, min(markerPosition - markerWidth / 2, trackWidth - markerWidth)))
                }
                .frame(height: markerHeight)
            }
            .frame(maxWidth: .infinity, minHeight: markerHeight)
        }
    }
}

// MARK: - Preview Fixtures

#if DEBUG
/// Predefined fixture scenarios for SwiftUI previews
enum UsageFixture {
    /// Fresh session: low usage, just started (needle near start)
    case freshStart
    /// Mid-session: moderate usage, halfway through period
    case midSession
    /// Heavy user: high usage but still has time left
    case heavyUsage
    /// Critical: near limit, session almost over
    case critical
    /// Weekly pressure: low session but high weekly usage
    case weeklyPressure
    /// Overpacing: usage exceeds period progress (shows red overage)
    case overpacing
    /// Custom values for specific testing
    case custom(
        sessionUsage: Int,
        sessionPeriod: Int,
        weeklyUsage: Int,
        weeklyPeriod: Int,
        sonnetUsage: Int?
    )

    var data: UsageData {
        switch self {
        case .freshStart:
            return UsageData(
                sessionUtilization: 8,
                sessionResetsAt: Date().addingTimeInterval(4.5 * 3600),  // 4.5h left
                weeklyUtilization: 12,
                weeklyResetsAt: Date().addingTimeInterval(6 * 24 * 3600), // 6 days left
                sonnetUtilization: 5,
                sonnetResetsAt: Date().addingTimeInterval(4 * 3600),
                sessionPeriodProgress: 10,  // 10% through 5h period
                weeklyPeriodProgress: 14    // 14% through week (1 day in)
            )

        case .midSession:
            return UsageData(
                sessionUtilization: 45,
                sessionResetsAt: Date().addingTimeInterval(2.5 * 3600),  // 2.5h left
                weeklyUtilization: 35,
                weeklyResetsAt: Date().addingTimeInterval(4 * 24 * 3600), // 4 days left
                sonnetUtilization: 40,
                sonnetResetsAt: Date().addingTimeInterval(2 * 3600),
                sessionPeriodProgress: 50,  // Halfway through session
                weeklyPeriodProgress: 43    // ~3 days into week
            )

        case .heavyUsage:
            return UsageData(
                sessionUtilization: 78,
                sessionResetsAt: Date().addingTimeInterval(1.5 * 3600),  // 1.5h left
                weeklyUtilization: 65,
                weeklyResetsAt: Date().addingTimeInterval(2.5 * 24 * 3600),
                sonnetUtilization: 82,
                sonnetResetsAt: Date().addingTimeInterval(1 * 3600),
                sessionPeriodProgress: 70,
                weeklyPeriodProgress: 64
            )

        case .critical:
            return UsageData(
                sessionUtilization: 94,
                sessionResetsAt: Date().addingTimeInterval(0.5 * 3600),  // 30min left
                weeklyUtilization: 88,
                weeklyResetsAt: Date().addingTimeInterval(0.5 * 24 * 3600), // 12h left
                sonnetUtilization: 97,
                sonnetResetsAt: Date().addingTimeInterval(0.25 * 3600),
                sessionPeriodProgress: 90,
                weeklyPeriodProgress: 93
            )

        case .weeklyPressure:
            return UsageData(
                sessionUtilization: 15,
                sessionResetsAt: Date().addingTimeInterval(4 * 3600),
                weeklyUtilization: 91,
                weeklyResetsAt: Date().addingTimeInterval(1 * 24 * 3600), // 1 day left
                sonnetUtilization: nil,
                sonnetResetsAt: nil,
                sessionPeriodProgress: 20,
                weeklyPeriodProgress: 86
            )

        case .overpacing:
            return UsageData(
                sessionUtilization: 65,
                sessionResetsAt: Date().addingTimeInterval(3 * 3600),  // 3h left
                weeklyUtilization: 55,
                weeklyResetsAt: Date().addingTimeInterval(4 * 24 * 3600), // 4 days left
                sonnetUtilization: nil,
                sonnetResetsAt: nil,
                sessionPeriodProgress: 40,  // Only 40% through period but 65% usage
                weeklyPeriodProgress: 43    // ~3 days into week but 55% usage
            )

        case .custom(let sessionUsage, let sessionPeriod, let weeklyUsage, let weeklyPeriod, let sonnetUsage):
            return UsageData(
                sessionUtilization: Double(sessionUsage),
                sessionResetsAt: Date().addingTimeInterval(2 * 3600),
                weeklyUtilization: Double(weeklyUsage),
                weeklyResetsAt: Date().addingTimeInterval(3 * 24 * 3600),
                sonnetUtilization: sonnetUsage.map { Double($0) },
                sonnetResetsAt: sonnetUsage != nil ? Date().addingTimeInterval(2 * 3600) : nil,
                sessionPeriodProgress: sessionPeriod,
                weeklyPeriodProgress: weeklyPeriod
            )
        }
    }
}

extension UsageManager {
    static func previewLoading() -> UsageManager {
        let manager = UsageManager()
        manager.isLoading = true
        return manager
    }

    static func preview(_ fixture: UsageFixture) -> UsageManager {
        let manager = UsageManager()
        manager.usage = fixture.data
        manager.lastUpdated = Date()
        return manager
    }

    static func previewError(_ message: String = "Not logged in to Claude Code") -> UsageManager {
        let manager = UsageManager()
        manager.error = message
        return manager
    }
}

// MARK: - Previews

#Preview("Loading") {
    UsageView(manager: .previewLoading())
}

#Preview("Fresh Start") {
    UsageView(manager: .preview(.freshStart))
}

#Preview("Mid Session") {
    UsageView(manager: .preview(.midSession))
}

#Preview("Heavy Usage") {
    UsageView(manager: .preview(.heavyUsage))
}

#Preview("Critical") {
    UsageView(manager: .preview(.critical))
}

#Preview("Weekly Pressure") {
    UsageView(manager: .preview(.weeklyPressure))
}

#Preview("Overpacing") {
    UsageView(manager: .preview(.overpacing))
}

#Preview("Not Logged In") {
    UsageView(manager: .previewError())
}

#Preview("API Error") {
    UsageView(manager: .previewError("API error (code: 500)"))
}

// MARK: - Menu Bar Icon Preview

/// Mini gauge for menubar preview (SwiftUI version of the NSImage gauge)
struct MenuBarGaugePreview: View {
    let usagePercent: Int
    let periodPercent: Int
    var showErrorDot: Bool = false
    var loadingDotOpacity: Double? = nil

    private let height: CGFloat = 18
    private let barWidth: CGFloat = 16
    private let horizontalPadding: CGFloat = 1
    private let usageBarHeight: CGFloat = 3
    private let periodBarHeight: CGFloat = 2
    private let gap: CGFloat = 2
    private let spacing: CGFloat = 3

    // Adaptive colors that work in light and dark mode
    private let periodColor = Color.primary.opacity(0.5)
    private let usageColor = Color.primary

    private var effectiveBarWidth: CGFloat {
        barWidth - (horizontalPadding * 2)
    }

    var body: some View {
        HStack(spacing: spacing) {
            // Bars section
            ZStack {
                VStack(spacing: gap) {
                    // Usage bar (top)
                    ZStack(alignment: .leading) {
                        // Background
                        RoundedRectangle(cornerRadius: usageBarHeight / 2)
                            .fill(usageColor.opacity(0.5))
                            .frame(width: effectiveBarWidth, height: usageBarHeight)

                        // Filled
                        if usagePercent > 0 {
                            RoundedRectangle(cornerRadius: usageBarHeight / 2)
                                .fill(usageColor.opacity(0.9))
                                .frame(width: effectiveBarWidth * CGFloat(min(usagePercent, 100)) / 100.0, height: usageBarHeight)
                        }
                    }

                    // Period bar (bottom)
                    ZStack(alignment: .leading) {
                        // Background
                        RoundedRectangle(cornerRadius: periodBarHeight / 2)
                            .fill(periodColor.opacity(0.5))
                            .frame(width: effectiveBarWidth, height: periodBarHeight)

                        // Filled
                        if periodPercent > 0 {
                            RoundedRectangle(cornerRadius: periodBarHeight / 2)
                                .fill(periodColor.opacity(0.9))
                                .frame(width: effectiveBarWidth * CGFloat(min(periodPercent, 100)) / 100.0, height: periodBarHeight)
                        }
                    }
                }

                // Status indicator dot in lower right of bar area
                if showErrorDot {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .offset(x: barWidth / 2 - 4, y: height / 2 - 7)
                } else if let opacity = loadingDotOpacity {
                    Circle()
                        .fill(Color.green.opacity(opacity))
                        .frame(width: 6, height: 6)
                        .offset(x: barWidth / 2 - 4, y: height / 2 - 7)
                }
            }
            .frame(width: barWidth, height: height)

            // Percentage text (or exclamation mark for error state)
            if showErrorDot {
                Text("!")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
            } else {
                Text("\(usagePercent)%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
            }
        }
        .frame(height: height)
    }
}

/// Animated loading gauge for preview
struct MenuBarLoadingPreview: View {
    @State private var phase: Double = 0
    var usagePercent: Int = 45
    var periodPercent: Int = 50

    private var opacity: Double {
        (sin(phase * 6) + 1) / 2 * 0.7 + 0.3
    }

    var body: some View {
        MenuBarGaugePreview(usagePercent: usagePercent, periodPercent: periodPercent, loadingDotOpacity: opacity)
            .onAppear {
                Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
                    phase += 0.03
                }
            }
    }
}

#Preview("Menu Bar Icons") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Menu Bar Status Items")
            .font(.headline)
            .padding(.bottom, 4)

        HStack(spacing: 24) {
            VStack {
                MenuBarGaugePreview(usagePercent: 15, periodPercent: 20)
                    .padding(8)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(4)
                Text("Low").font(.caption).foregroundColor(.secondary)
            }
            VStack {
                MenuBarGaugePreview(usagePercent: 45, periodPercent: 50)
                    .padding(8)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(4)
                Text("Normal").font(.caption).foregroundColor(.secondary)
            }
            VStack {
                MenuBarGaugePreview(usagePercent: 75, periodPercent: 60)
                    .padding(8)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(4)
                Text("Warning").font(.caption).foregroundColor(.secondary)
            }
            VStack {
                MenuBarGaugePreview(usagePercent: 92, periodPercent: 85)
                    .padding(8)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(4)
                Text("Critical").font(.caption).foregroundColor(.secondary)
            }
            VStack {
                MenuBarGaugePreview(usagePercent: 100, periodPercent: 85)
                    .padding(8)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(4)
                Text("Maxed Out").font(.caption).foregroundColor(.secondary)
            }
        }

        Divider()

        HStack(spacing: 24) {
            VStack {
                MenuBarLoadingPreview()
                    .padding(8)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(4)
                Text("Loading").font(.caption).foregroundColor(.secondary)
            }
            VStack {
                MenuBarGaugePreview(usagePercent: 0, periodPercent: 0, showErrorDot: true)
                    .padding(8)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(4)
                Text("Error").font(.caption).foregroundColor(.secondary)
            }
        }
    }
    .padding()
}
#endif
