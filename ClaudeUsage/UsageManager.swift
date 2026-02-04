import Foundation
import Security
import os.log

private let logger = Logger(subsystem: "com.steveadams.ClaudeUsage", category: "UsageManager")

struct UsageData {
    let sessionUtilization: Double
    let sessionResetsAt: Date?
    let weeklyUtilization: Double
    let weeklyResetsAt: Date?
    let sonnetUtilization: Double?
    let sonnetResetsAt: Date?

    // Optional overrides for preview/testing (when set, bypass computed logic)
    private let _sessionPeriodProgress: Int?
    private let _weeklyPeriodProgress: Int?

    var sessionPercentage: Int { Int(sessionUtilization) }
    var weeklyPercentage: Int { Int(weeklyUtilization) }
    var sonnetPercentage: Int? { sonnetUtilization.map { Int($0) } }

    /// How far through the 5-hour session period (0-100%)
    var sessionPeriodProgress: Int? {
        if let override = _sessionPeriodProgress { return override }
        guard let resetsAt = sessionResetsAt else { return nil }
        let periodDuration: TimeInterval = 5 * 60 * 60 // 5 hours in seconds
        let periodStart = resetsAt.addingTimeInterval(-periodDuration)
        let now = Date()
        let elapsed = now.timeIntervalSince(periodStart)
        let progress = (elapsed / periodDuration) * 100
        return Int(min(max(progress, 0), 100))
    }

    /// How far through the 7-day billing period (0-100%)
    var weeklyPeriodProgress: Int? {
        if let override = _weeklyPeriodProgress { return override }
        guard let resetsAt = weeklyResetsAt else { return nil }
        let periodDuration: TimeInterval = 7 * 24 * 60 * 60 // 7 days in seconds
        let periodStart = resetsAt.addingTimeInterval(-periodDuration)
        let now = Date()
        let elapsed = now.timeIntervalSince(periodStart)
        let progress = (elapsed / periodDuration) * 100
        return Int(min(max(progress, 0), 100))
    }

    init(
        sessionUtilization: Double,
        sessionResetsAt: Date?,
        weeklyUtilization: Double,
        weeklyResetsAt: Date?,
        sonnetUtilization: Double? = nil,
        sonnetResetsAt: Date? = nil,
        sessionPeriodProgress: Int? = nil,
        weeklyPeriodProgress: Int? = nil
    ) {
        self.sessionUtilization = sessionUtilization
        self.sessionResetsAt = sessionResetsAt
        self.weeklyUtilization = weeklyUtilization
        self.weeklyResetsAt = weeklyResetsAt
        self.sonnetUtilization = sonnetUtilization
        self.sonnetResetsAt = sonnetResetsAt
        self._sessionPeriodProgress = sessionPeriodProgress
        self._weeklyPeriodProgress = weeklyPeriodProgress
    }
}

@MainActor
class UsageManager: ObservableObject {
    @Published var usage: UsageData?
    @Published var error: String?
    @Published var isLoading = false
    @Published var lastUpdated: Date?

    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    // Configured URLSession with timeouts
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    var statusEmoji: String {
        guard let usage = usage else { return "❓" }
        let maxUtil = max(usage.sessionUtilization, usage.weeklyUtilization)
        if maxUtil >= 90 { return "🔴" }
        if maxUtil >= 70 { return "🟡" }
        return "🟢"
    }

    func refresh() async {
        await refreshWithRetry(retriesRemaining: 3)
    }

    private func refreshWithRetry(retriesRemaining: Int) async {
        isLoading = true
        error = nil

        defer { isLoading = false }

        do {
            let token = try await getAccessToken()
            let data = try await fetchUsage(token: token)
            usage = data
            lastUpdated = Date()
        } catch let keychainError as KeychainError {
            // Retry on keychain errors that may resolve after unlock
            if retriesRemaining > 0 && keychainError.isRetryable {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                await refreshWithRetry(retriesRemaining: retriesRemaining - 1)
                return
            }
            self.error = keychainError.localizedDescription
        } catch let urlError as URLError {
            // Retry on network errors (common after wake from sleep)
            if retriesRemaining > 0 && urlError.isRetryable {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds for network
                await refreshWithRetry(retriesRemaining: retriesRemaining - 1)
                return
            }
            self.error = urlError.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func getAccessToken() async throws -> String {
        // Get token from Claude Code's keychain via security CLI
        return try getClaudeCodeToken()
    }

    /// Get token from Claude Code's keychain using security CLI (avoids ACL prompt!)
    private func getClaudeCodeToken() throws -> String {
        // Use security CLI which is already in the keychain ACL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw KeychainError.unexpectedError(status: -1)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorString = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            // Try alternate keychain entry as fallback
            if let token = try? getAccessTokenFromAlternateKeychain() {
                return token
            }
            // Include error detail for debugging
            if errorString.contains("could not be found") {
                throw KeychainError.notLoggedIn
            }
            throw KeychainError.securityCommandFailed(errorString.isEmpty ? "Exit code \(process.terminationStatus)" : errorString)
        }

        guard let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !jsonString.isEmpty else {
            if let token = try? getAccessTokenFromAlternateKeychain() {
                return token
            }
            throw KeychainError.notLoggedIn
        }

        // Try to parse as OAuth credentials
        if let jsonData = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            // Check for claudeAiOauth structure
            if let oauth = json["claudeAiOauth"] as? [String: Any],
               let accessToken = oauth["accessToken"] as? String {
                return accessToken
            }
            // Show what keys ARE present for debugging
            let keys = Array(json.keys).joined(separator: ", ")
            throw KeychainError.missingOAuthToken(availableKeys: keys)
        }

        // Primary entry doesn't have OAuth - try alternate keychain
        if let token = try? getAccessTokenFromAlternateKeychain() {
            return token
        }

        throw KeychainError.invalidCredentialFormat
    }

    /// Fallback: Check for "Claude Code" keychain entry (alternate storage location)
    private func getAccessTokenFromAlternateKeychain() throws -> String {
        // Use security CLI which is already in the keychain ACL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code", "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw KeychainError.notLoggedIn
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0,
              let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !jsonString.isEmpty,
              let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            throw KeychainError.notLoggedIn
        }

        return accessToken
    }

    private func fetchUsage(token: String) async throws -> UsageData {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ClaudeUsage/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw UsageError.apiError(statusCode: httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidResponse
        }

        let fiveHour = json["five_hour"] as? [String: Any]
        let sevenDay = json["seven_day"] as? [String: Any]
        let sonnetOnly = json["sonnet_only"] as? [String: Any]

        // Log API response for debugging
        logger.info("API response keys: \(json.keys.joined(separator: ", "))")
        if let fiveHour = fiveHour {
            logger.info("five_hour: utilization=\(fiveHour["utilization"] as? Double ?? -1), resets_at=\(fiveHour["resets_at"] as? String ?? "nil")")
        } else {
            logger.warning("five_hour is nil in API response")
        }
        if let sevenDay = sevenDay {
            logger.info("seven_day: utilization=\(sevenDay["utilization"] as? Double ?? -1), resets_at=\(sevenDay["resets_at"] as? String ?? "nil")")
        } else {
            logger.warning("seven_day is nil in API response")
        }

        return UsageData(
            sessionUtilization: fiveHour?["utilization"] as? Double ?? 0,
            sessionResetsAt: parseDate(fiveHour?["resets_at"] as? String),
            weeklyUtilization: sevenDay?["utilization"] as? Double ?? 0,
            weeklyResetsAt: parseDate(sevenDay?["resets_at"] as? String),
            sonnetUtilization: sonnetOnly?["utilization"] as? Double,
            sonnetResetsAt: parseDate(sonnetOnly?["resets_at"] as? String)
        )
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string = string else {
            logger.debug("parseDate: input string is nil")
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: string)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: string)
        }
        if date == nil {
            logger.warning("parseDate: failed to parse '\(string)'")
        }
        // Round to nearest minute to avoid jitter from API timestamps near second boundaries
        if let date = date {
            let seconds = date.timeIntervalSinceReferenceDate
            let roundedSeconds = (seconds / 60).rounded() * 60
            return Date(timeIntervalSinceReferenceDate: roundedSeconds)
        }
        return nil
    }
}

enum KeychainError: LocalizedError {
    case notLoggedIn
    case accessDenied
    case interactionNotAllowed
    case invalidData
    case invalidCredentialFormat
    case unexpectedError(status: OSStatus)
    case securityCommandFailed(String)
    case missingOAuthToken(availableKeys: String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in to Claude Code"
        case .accessDenied:
            return "Keychain access denied. Please allow access in System Settings."
        case .interactionNotAllowed:
            return "Keychain interaction not allowed. Try unlocking your Mac."
        case .invalidData:
            return "Could not read Keychain data"
        case .invalidCredentialFormat:
            return "Invalid credential format in keychain"
        case .unexpectedError(let status):
            return "Keychain error (code: \(status))"
        case .securityCommandFailed(let error):
            return "Keychain access failed: \(error.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .missingOAuthToken(let keys):
            return "No OAuth token in keychain. Found keys: \(keys). Try 'claude' to re-login."
        }
    }

    /// Errors that may resolve after the keychain unlocks (post-sleep/lock/boot)
    var isRetryable: Bool {
        switch self {
        case .notLoggedIn, .invalidCredentialFormat, .invalidData, .interactionNotAllowed, .securityCommandFailed:
            // notLoggedIn is retryable because keychain may not be accessible immediately after boot
            return true
        case .accessDenied, .unexpectedError, .missingOAuthToken:
            return false
        }
    }
}

enum UsageError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from API"
        case .apiError(let code):
            if code == 401 {
                return "Authentication expired. Run 'claude' to re-authenticate."
            }
            return "API error (code: \(code))"
        }
    }
}

extension URLError {
    /// Network errors that may resolve after wake from sleep
    var isRetryable: Bool {
        switch self.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .dnsLookupFailed,
             .cannotFindHost,
             .cannotConnectToHost,
             .timedOut,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}
