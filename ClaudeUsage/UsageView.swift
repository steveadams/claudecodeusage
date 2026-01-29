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
        VStack() {
            // Circular gauges
            HStack() {
                // 5-hour session gauge
                let sessionTime = formatTimeRemaining(usage.sessionResetsAt)
                PeriodGaugeCard(
                    title: "5 hour",
                    duration: sessionTime?.duration,
                    resetTime: sessionTime?.resetTime,
                    usagePercent: usage.sessionPercentage,
                    periodPercent: usage.sessionPeriodProgress ?? 0
                )

                // 7-day period gauge
                let weeklyTime = formatTimeRemaining(usage.weeklyResetsAt)
                PeriodGaugeCard(
                    title: "7 day",
                    duration: weeklyTime?.duration,
                    resetTime: weeklyTime?.resetTime,
                    usagePercent: usage.weeklyPercentage,
                    periodPercent: usage.weeklyPeriodProgress ?? 0,
                    isSession: false
                )
            }

            if let lastUpdated = manager.lastUpdated {
                Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
        .padding()
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
        if diff <= 0 { return ("soon", "now") }

        let totalHours = diff / 3600

        // Format duration (rounded)
        let duration: String
        if totalHours >= 24 {
            let days = totalHours / 24
            if days >= 2 {
                duration = "~\(Int(days.rounded()))d"
            } else {
                // Show half-day precision for 1-2 days
                let roundedDays = (days * 2).rounded() / 2
                if roundedDays == roundedDays.rounded() {
                    duration = "~\(Int(roundedDays))d"
                } else {
                    duration = "~\(String(format: "%.1f", roundedDays))d"
                }
            }
        } else if totalHours < 1 {
            let minutes = Int(diff / 60)
            duration = "~\(minutes)m"
        } else {
            // Round to nearest 0.5h
            let roundedHours = (totalHours * 2).rounded() / 2
            if roundedHours == roundedHours.rounded() {
                duration = "~\(Int(roundedHours))h"
            } else {
                duration = "~\(String(format: "%.1f", roundedHours))h"
            }
        }

        // Format reset time (use current timezone explicitly for consistency)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "ha"
        timeFormatter.timeZone = .current
        let timeString = timeFormatter.string(from: date).lowercased()

        let resetTime: String
        if totalHours >= 24 {
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "EEE"
            dayFormatter.timeZone = .current
            let dayString = dayFormatter.string(from: date)
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

// MARK: - Nested Circular Gauge

struct PeriodGaugeCard: View {
    let title: String
    let duration: String?
    let resetTime: String?
    let usagePercent: Int
    let periodPercent: Int
    var isSession: Bool = true

    var body: some View {
        VStack(spacing: 4) {
            // Header
            Text(title)
                .font(.caption)
                .fontWeight(.medium)

            // Gauge
            CircularGaugeView(
                usagePercent: usagePercent,
                periodPercent: periodPercent
            )
            .padding(.top, 4)

            // Remaining time (compact single line)
            if let duration = duration, let resetTime = resetTime {
                Text("\(duration) · \(resetTime)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
                    .help(isSession ? "Time until session resets" : "Time until weekly limit resets")
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

struct CircularGaugeView: View {
    let usagePercent: Int      // Usage (0-100)
    let periodPercent: Int     // Time progress (0-100) - outer ring

    private let size: CGFloat = 80
    private let lineWidth: CGFloat = 10
    private let outerLineWidth: CGFloat = 2
    private let outerGap: CGFloat = 4
    private let startAngle: Double = 135   // Bottom-left
    private let endAngle: Double = 405     // Bottom-right (270° arc)

    // Usage gradient: green → yellow/orange → red
    private let usageGradientColors: [Color] = [
        Color(red: 0.2, green: 0.8, blue: 0.3),   // Green
        Color(red: 0.5, green: 0.85, blue: 0.3),  // Yellow-green
        Color(red: 0.95, green: 0.8, blue: 0.2),  // Yellow
        Color(red: 0.95, green: 0.6, blue: 0.2),  // Orange
        Color(red: 0.95, green: 0.4, blue: 0.3),  // Red-orange
        Color(red: 0.9, green: 0.25, blue: 0.25), // Red
    ]

    // Period colors: simple blue progression
    private let periodColor = Color(red: 0.3, green: 0.5, blue: 0.95)
    private let periodBackgroundColor = Color(red: 0.3, green: 0.5, blue: 0.95).opacity(0.2)

    private var needleAngle: Double {
        startAngle + (Double(usagePercent) / 100.0) * (endAngle - startAngle)
    }

    private var periodAngle: Double {
        startAngle + (Double(periodPercent) / 100.0) * (endAngle - startAngle)
    }

    private var outerSize: CGFloat {
        size + lineWidth + outerGap * 2 + outerLineWidth
    }

    /// Color sampled from gradient at current usage percentage
    private var usageColor: Color {
        let index = Double(usagePercent) / 100.0 * Double(usageGradientColors.count - 1)
        let clampedIndex = max(0, min(index, Double(usageGradientColors.count - 1)))
        return usageGradientColors[Int(clampedIndex.rounded())]
    }

    var body: some View {
        ZStack {
            // Outer ring - Period Progress (background)
            Arc(startAngle: .degrees(startAngle), endAngle: .degrees(endAngle), clockwise: false)
                .stroke(periodBackgroundColor, style: StrokeStyle(lineWidth: outerLineWidth, lineCap: .butt))
                .frame(width: outerSize, height: outerSize)

            // Outer ring - Period Progress (filled)
            Arc(startAngle: .degrees(startAngle), endAngle: .degrees(periodAngle), clockwise: false)
                .stroke(periodColor, style: StrokeStyle(lineWidth: outerLineWidth, lineCap: .butt))
                .frame(width: outerSize, height: outerSize)

            // Inner gauge - Background arc (unfilled portion, tinted by usage level)
            Arc(startAngle: .degrees(startAngle), endAngle: .degrees(endAngle), clockwise: false)
                .stroke(usageColor.opacity(0.2), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .frame(width: size, height: size)

            // Inner gauge - Gradient arc (filled up to period or usage, whichever is less)
            Arc(startAngle: .degrees(startAngle), endAngle: .degrees(min(needleAngle, periodAngle)), clockwise: false)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: usageGradientColors),
                        center: .center,
                        startAngle: .degrees(startAngle),
                        endAngle: .degrees(endAngle)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                )
                .frame(width: size, height: size)

            // Inner gauge - Over pace indicator (red arc when usage exceeds period progress)
            if usagePercent > periodPercent {
                Arc(startAngle: .degrees(periodAngle), endAngle: .degrees(needleAngle), clockwise: false)
                    .stroke(Color(red: 0.9, green: 0.25, blue: 0.25), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .frame(width: size, height: size)
            }

            // Needle
            NeedleView(angle: needleAngle, length: size / 1.75 - lineWidth - 4)

            // Center dot
            Circle()
                .fill(Color(NSColor.separatorColor).opacity(0.5))
                .frame(width: 8, height: 8)

            // Percentage label below
            Text("\(usagePercent)%")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .offset(y: size / 4 + 8)
        }
        .frame(width: outerSize + outerLineWidth, height: outerSize + outerLineWidth)
    }
}

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

// Needle indicator
struct NeedleView: View {
    let angle: Double
    let length: CGFloat

    var body: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.9, green: 0.3, blue: 0.4), Color(red: 0.8, green: 0.2, blue: 0.3)],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
            .frame(width: 2, height: length)
            .offset(y: -length / 2)
            .rotationEffect(.degrees(angle + 90))
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
#endif

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

    private let size: CGFloat = 18
    private let usageLineWidth: CGFloat = 3
    private let periodLineWidth: CGFloat = 1
    private let gap: CGFloat = 1.5

    // Full circle starting from top (-90° in SwiftUI coordinates)
    private let startAngle: Double = -90
    private let totalSweep: Double = 360

    // Adaptive colors that work in light and dark mode
    private let periodColor = Color.primary.opacity(0.5)
    private let usageColor = Color.primary

    private var usageAngle: Double {
        startAngle + (Double(usagePercent) / 100.0) * totalSweep
    }

    private var periodAngle: Double {
        startAngle + (Double(periodPercent) / 100.0) * totalSweep
    }

    private var usageRadius: CGFloat {
        (size - usageLineWidth) / 2 - periodLineWidth - gap
    }

    private var periodRadius: CGFloat {
        (size - periodLineWidth) / 2
    }

    var body: some View {
        ZStack {
            // Period background (full circle)
            Circle()
                .stroke(periodColor.opacity(0.2), style: StrokeStyle(lineWidth: periodLineWidth))
                .frame(width: periodRadius * 2, height: periodRadius * 2)

            // Period filled
            Arc(startAngle: .degrees(startAngle), endAngle: .degrees(periodAngle), clockwise: false)
                .stroke(periodColor, style: StrokeStyle(lineWidth: periodLineWidth, lineCap: .butt))
                .frame(width: periodRadius * 2, height: periodRadius * 2)

            // Usage background (full circle)
            Circle()
                .stroke(usageColor.opacity(0.2), style: StrokeStyle(lineWidth: usageLineWidth))
                .frame(width: usageRadius * 2, height: usageRadius * 2)

            // Usage filled
            Arc(startAngle: .degrees(startAngle), endAngle: .degrees(usageAngle), clockwise: false)
                .stroke(usageColor, style: StrokeStyle(lineWidth: usageLineWidth, lineCap: .butt))
                .frame(width: usageRadius * 2, height: usageRadius * 2)

            // Status indicator dot in lower right
            if showErrorDot {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .offset(x: size / 2 - 4, y: size / 2 - 4)
            } else if let opacity = loadingDotOpacity {
                Circle()
                    .fill(Color.blue.opacity(opacity))
                    .frame(width: 6, height: 6)
                    .offset(x: size / 2 - 4, y: size / 2 - 4)
            }
        }
        .frame(width: size, height: size)
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
