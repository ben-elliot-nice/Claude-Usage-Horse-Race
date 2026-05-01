// Claude Usage/Shared/Services/ClaudeAPIService+Enterprise.swift
import Foundation

// MARK: - Enterprise Account Support

extension ClaudeAPIService {

    /// Fetches usage data for an enterprise claude.ai account.
    /// Uses the same /usage endpoint as the standard flow but reads
    /// the `extra_usage` block instead of `five_hour`/`seven_day`.
    func fetchEnterpriseUsageData(sessionKey: String, organizationId: String) async throws -> ClaudeUsage {
        let data = try await performRequest(
            endpoint: "/organizations/\(organizationId)/usage",
            sessionKey: sessionKey
        )
        return try parseEnterpriseResponse(data)
    }

    /// Parses the `extra_usage` block from the /usage response.
    /// Internal (not private) so tests can call it directly via @testable import.
    /// - Throws: `AppError(.apiParsingFailed)` if `extra_usage` is absent or disabled.
    func parseEnterpriseResponse(_ data: Data) throws -> ClaudeUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extraUsage = json["extra_usage"] as? [String: Any] else {
            throw AppError(
                code: .apiParsingFailed,
                message: "No extra_usage data available",
                technicalDetails: "This account may not have Enterprise extra usage enabled",
                isRecoverable: false,
                recoverySuggestion: "Ensure your account has an Enterprise extra usage allocation, or switch to a different connection type"
            )
        }

        let isEnabled = extraUsage["is_enabled"] as? Bool ?? false
        guard isEnabled else {
            throw AppError(
                code: .apiParsingFailed,
                message: "Enterprise extra usage is not enabled for this account",
                isRecoverable: false,
                recoverySuggestion: "Contact your administrator to enable extra usage for your account"
            )
        }

        // utilization is 0.0–1.0 from the API; convert to 0–100 percentage
        let utilization = (extraUsage["utilization"] as? Double ?? 0.0) * 100.0
        let usedCredits = extraUsage["used_credits"] as? Double ?? 0.0
        let monthlyLimit = extraUsage["monthly_limit"] as? Double ?? 0.0
        let currency = extraUsage["currency"] as? String ?? "USD"

        // Reset time = last second of the current calendar month
        let resetTime = endOfCurrentMonth()

        return ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 0,
            sessionPercentage: utilization,
            sessionResetTime: resetTime,
            weeklyTokensUsed: 0,
            weeklyLimit: 0,
            weeklyPercentage: 0.0,
            weeklyResetTime: endOfCurrentMonth(),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0.0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0.0,
            sonnetWeeklyResetTime: nil,
            costUsed: usedCredits,
            costLimit: monthlyLimit,
            costCurrency: currency,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: Date(),
            userTimezone: .current
        )
    }

    // MARK: - Private Helpers

    private func endOfCurrentMonth() -> Date {
        var calendar = Calendar.current
        let now = Date()
        // Start of next month, minus 1 second = last second of current month
        var components = calendar.dateComponents([.year, .month], from: now)
        components.month = (components.month ?? 1) + 1
        let startOfNextMonth = calendar.date(from: components) ?? now.addingTimeInterval(32 * 24 * 3600)
        return startOfNextMonth.addingTimeInterval(-1)
    }
}
