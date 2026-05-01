// Claude Usage/Shared/Models/RaceParticipant.swift
import Foundation

/// A single participant in a horse race — their cost burn for the period.
struct RaceParticipant: Codable, Identifiable {
    var id: String { name }

    let name: String
    let costUsedCents: Int
    let costLimitCents: Int
    let updatedAt: Date

    /// Percentage of limit consumed (0–100).
    var percentUsed: Double {
        guard costLimitCents > 0 else { return 0 }
        return Double(costUsedCents) / Double(costLimitCents) * 100.0
    }

    /// True if the participant's data hasn't been updated in >5 minutes.
    var isStale: Bool {
        Date().timeIntervalSince(updatedAt) > 300
    }

    /// Human-readable cost, e.g. "$615"
    var formattedCostUsed: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: Double(costUsedCents) / 100.0)) ?? "$?"
    }

    /// "2m ago" style relative time string.
    var updatedAgoString: String {
        let seconds = Date().timeIntervalSince(updatedAt)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }

    /// Tooltip string shown on horse hover.
    var tooltipString: String {
        "\(name) · \(formattedCostUsed) · \(Int(percentUsed))% · \(updatedAgoString)"
    }
}

/// The full standings response from GET {raceUrl}/standings
struct RaceStandings: Codable {
    let raceSlug: String
    let participants: [RaceParticipant]
}
