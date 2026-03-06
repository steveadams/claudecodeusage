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

struct OAuthCredentials {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    /// Which keychain service name this was read from
    let keychainService: String

    var isExpiredOrExpiringSoon: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date().addingTimeInterval(60) >= expiresAt
    }
}

@MainActor
class UsageManager: ObservableObject {
    @Published var usage: UsageData?
    @Published var error: String?
    @Published var isLoading = false
    @Published var lastUpdated: Date?

    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    private static let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenEndpoints = [
        "https://console.anthropic.com/v1/oauth/token",
        "https://api.anthropic.com/v1/oauth/token",
    ]

    // Configured URLSession with timeouts
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

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
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                await refreshWithRetry(retriesRemaining: retriesRemaining - 1)
                return
            }
            self.error = keychainError.localizedDescription
        } catch let usageError as UsageError {
            // For 429 with retry-after=0: likely expired token — attempt refresh
            if case .apiError(429, _, _, let retryAfter) = usageError {
                if retryAfter == 0, retriesRemaining > 0 {
                    logger.info("429 with retry-after=0, attempting token refresh")
                    do {
                        let creds = try readOAuthCredentials()
                        if let refreshToken = creds.refreshToken {
                            let _ = try await refreshAccessToken(using: refreshToken, keychainService: creds.keychainService)
                            await refreshWithRetry(retriesRemaining: 0)
                            return
                        }
                    } catch {
                        logger.error("Token refresh failed after 429: \(error.localizedDescription)")
                    }
                    self.error = "Authentication expired. Run 'claude' to re-authenticate."
                    return
                }
                self.error = usageError.localizedDescription
                if let wait = retryAfter, wait > 0, retriesRemaining > 0 {
                    let waitNanos = UInt64(max(wait, 60) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: waitNanos)
                    await refreshWithRetry(retriesRemaining: 0)
                }
                return
            }
            if retriesRemaining > 0 && usageError.isRetryable {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                await refreshWithRetry(retriesRemaining: retriesRemaining - 1)
                return
            }
            self.error = usageError.localizedDescription
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
        let creds = try readOAuthCredentials()

        // Proactively refresh if token is expired or expiring within 60s
        if creds.isExpiredOrExpiringSoon, let refreshToken = creds.refreshToken {
            logger.info("Token expired or expiring soon, refreshing proactively")
            do {
                let newCreds = try await refreshAccessToken(using: refreshToken, keychainService: creds.keychainService)
                return newCreds.accessToken
            } catch {
                logger.warning("Proactive refresh failed: \(error.localizedDescription), trying existing token")
                // Fall through to use existing token — it might still work
            }
        }

        return creds.accessToken
    }

    /// Read full OAuth credentials from keychain, trying both service names
    private func readOAuthCredentials() throws -> OAuthCredentials {
        if let creds = try? readOAuthCredentialsFromKeychain(service: "Claude Code-credentials") {
            return creds
        }
        if let creds = try? readOAuthCredentialsFromKeychain(service: "Claude Code") {
            return creds
        }
        throw KeychainError.notLoggedIn
    }

    /// Read OAuth credentials from a specific keychain service
    private func readOAuthCredentialsFromKeychain(service: String) throws -> OAuthCredentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]

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
            if errorString.contains("could not be found") {
                throw KeychainError.notLoggedIn
            }
            throw KeychainError.securityCommandFailed(errorString.isEmpty ? "Exit code \(process.terminationStatus)" : errorString)
        }

        guard let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !jsonString.isEmpty else {
            throw KeychainError.notLoggedIn
        }

        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            if let jsonData = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                let keys = Array(json.keys).joined(separator: ", ")
                throw KeychainError.missingOAuthToken(availableKeys: keys)
            }
            throw KeychainError.invalidCredentialFormat
        }

        let refreshToken = oauth["refreshToken"] as? String
        var expiresAt: Date? = nil
        if let expiresAtString = oauth["expiresAt"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiresAt = formatter.date(from: expiresAtString)
            if expiresAt == nil {
                formatter.formatOptions = [.withInternetDateTime]
                expiresAt = formatter.date(from: expiresAtString)
            }
        }

        return OAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            keychainService: service
        )
    }

    /// Refresh the OAuth access token using the refresh token
    private func refreshAccessToken(using refreshToken: String, keychainService: String) async throws -> OAuthCredentials {
        let body = "grant_type=refresh_token&refresh_token=\(refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refreshToken)&client_id=\(Self.oauthClientId)"

        var lastError: Error = TokenRefreshError.refreshFailed("No endpoints available")

        for endpoint in Self.tokenEndpoints {
            do {
                var request = URLRequest(url: URL(string: endpoint)!)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.setValue("ClaudeUsage/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
                request.httpBody = body.data(using: .utf8)

                let (data, response) = try await urlSession.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    lastError = TokenRefreshError.refreshFailed("Invalid response")
                    continue
                }

                if httpResponse.statusCode == 400 {
                    // Refresh token itself is invalid/expired
                    // Claude Code CLI may have refreshed first — re-read keychain and retry
                    logger.info("Refresh token rejected (400), re-reading keychain in case CLI refreshed")
                    if let freshCreds = try? readOAuthCredentialsFromKeychain(service: keychainService),
                       freshCreds.accessToken != refreshToken,
                       !freshCreds.isExpiredOrExpiringSoon {
                        // CLI refreshed the token for us
                        return freshCreds
                    }
                    throw TokenRefreshError.refreshTokenExpired
                }

                guard httpResponse.statusCode == 200 else {
                    let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
                    lastError = TokenRefreshError.refreshFailed("HTTP \(httpResponse.statusCode): \(bodyStr)")
                    continue
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let newAccessToken = json["access_token"] as? String else {
                    lastError = TokenRefreshError.refreshFailed("Invalid token response")
                    continue
                }

                let newRefreshToken = json["refresh_token"] as? String ?? refreshToken
                let expiresIn = json["expires_in"] as? Double
                let newExpiresAt = expiresIn.map { Date().addingTimeInterval($0) }

                logger.info("Token refreshed successfully via \(endpoint)")

                // Write updated credentials back to keychain
                try updateKeychainCredentials(
                    service: keychainService,
                    accessToken: newAccessToken,
                    refreshToken: newRefreshToken,
                    expiresAt: newExpiresAt
                )

                return OAuthCredentials(
                    accessToken: newAccessToken,
                    refreshToken: newRefreshToken,
                    expiresAt: newExpiresAt,
                    keychainService: keychainService
                )
            } catch let error as TokenRefreshError {
                throw error // Don't retry on definitive failures
            } catch {
                lastError = error
                logger.warning("Token refresh failed via \(endpoint): \(error.localizedDescription), trying next endpoint")
                continue
            }
        }

        throw lastError
    }

    /// Update the keychain entry with refreshed OAuth credentials
    private func updateKeychainCredentials(service: String, accessToken: String, refreshToken: String, expiresAt: Date?) throws {
        // Read existing full JSON to preserve other fields
        let readProcess = Process()
        readProcess.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        readProcess.arguments = ["find-generic-password", "-s", service, "-w"]

        let readPipe = Pipe()
        readProcess.standardOutput = readPipe
        readProcess.standardError = Pipe()

        try readProcess.run()
        readProcess.waitUntilExit()

        let readData = readPipe.fileHandleForReading.readDataToEndOfFile()
        guard let jsonString = String(data: readData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let jsonData = jsonString.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              var oauth = json["claudeAiOauth"] as? [String: Any] else {
            throw TokenRefreshError.keychainWriteFailed
        }

        // Update OAuth fields
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        if let expiresAt = expiresAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            oauth["expiresAt"] = formatter.string(from: expiresAt)
        }
        json["claudeAiOauth"] = oauth

        guard let updatedData = try? JSONSerialization.data(withJSONObject: json),
              let updatedString = String(data: updatedData, encoding: .utf8) else {
            throw TokenRefreshError.keychainWriteFailed
        }

        // Determine the account name for this keychain entry
        let accountProcess = Process()
        accountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        accountProcess.arguments = ["find-generic-password", "-s", service]

        let accountPipe = Pipe()
        accountProcess.standardOutput = accountPipe
        accountProcess.standardError = Pipe()

        try accountProcess.run()
        accountProcess.waitUntilExit()

        let accountOutput = String(data: accountPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Parse account name from "acct"<blob>="accountName"
        var accountName = ""
        if let range = accountOutput.range(of: "\"acct\"<blob>=\"") {
            let start = range.upperBound
            if let end = accountOutput[start...].firstIndex(of: "\"") {
                accountName = String(accountOutput[start..<end])
            }
        }

        // Write back using security add-generic-password -U
        let writeProcess = Process()
        writeProcess.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var writeArgs = ["add-generic-password", "-U", "-s", service, "-w", updatedString]
        if !accountName.isEmpty {
            writeArgs += ["-a", accountName]
        }
        writeProcess.arguments = writeArgs
        writeProcess.standardOutput = Pipe()
        writeProcess.standardError = Pipe()

        try writeProcess.run()
        writeProcess.waitUntilExit()

        guard writeProcess.terminationStatus == 0 else {
            logger.error("Failed to write updated credentials to keychain (exit \(writeProcess.terminationStatus))")
            throw TokenRefreshError.keychainWriteFailed
        }

        logger.info("Updated keychain credentials for service '\(service)'")
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

        // Log all rate limit headers for diagnostics
        let rateLimitHeaders = httpResponse.allHeaderFields.filter { key, _ in
            (key as? String)?.lowercased().contains("ratelimit") == true ||
            (key as? String)?.lowercased() == "retry-after"
        }
        if !rateLimitHeaders.isEmpty {
            let headerStr = rateLimitHeaders.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            logger.info("Rate limit headers: \(headerStr)")
        }

        guard httpResponse.statusCode == 200 else {
            // Parse error body for details
            let bodyString = String(data: data, encoding: .utf8)
            var errorType: String?
            var errorMessage: String?
            if let bodyData = bodyString?.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let errorObj = json["error"] as? [String: Any] {
                errorType = errorObj["type"] as? String
                errorMessage = errorObj["message"] as? String
            }
            let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after").flatMap { Double($0) }
            logger.error("API error \(httpResponse.statusCode): type=\(errorType ?? "unknown") message=\(errorMessage ?? bodyString ?? "no body") retry-after=\(retryAfter.map { "\($0)" } ?? "nil")")
            throw UsageError.apiError(statusCode: httpResponse.statusCode, errorType: errorType, errorMessage: errorMessage, retryAfter: retryAfter)
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
    case apiError(statusCode: Int, errorType: String?, errorMessage: String?, retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from API"
        case .apiError(let code, _, let errorMessage, let retryAfter):
            switch code {
            case 401:
                return "Authentication expired. Run 'claude' to re-authenticate."
            case 403:
                return errorMessage ?? "Permission denied."
            case 429:
                // retry-after: 0 typically means invalid token, not a real rate limit
                if retryAfter == 0 {
                    return "Authentication may have expired. Run 'claude' to re-authenticate."
                }
                if let seconds = retryAfter {
                    let minutes = Int(ceil(seconds / 60))
                    return "Rate limited. Retrying in \(minutes)m."
                }
                return "Rate limited. Retrying in 1m."
            case 500:
                return "Anthropic server error. Try again later."
            case 529:
                return "API is temporarily overloaded. Try again later."
            default:
                return errorMessage ?? "API error (\(code))."
            }
        }
    }

    /// Whether this error may resolve on retry
    var isRetryable: Bool {
        switch self {
        case .invalidResponse:
            return false
        case .apiError(let code, _, _, _):
            // 429 is handled separately with retry-after delay
            return code == 500 || code == 529
        }
    }
}

enum TokenRefreshError: LocalizedError {
    case refreshFailed(String)
    case refreshTokenExpired
    case keychainWriteFailed

    var errorDescription: String? {
        switch self {
        case .refreshFailed(let detail):
            return "Token refresh failed: \(detail)"
        case .refreshTokenExpired:
            return "Session expired. Run 'claude' to re-authenticate."
        case .keychainWriteFailed:
            return "Failed to save refreshed token to keychain."
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
