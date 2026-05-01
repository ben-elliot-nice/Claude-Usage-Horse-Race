// Claude Usage/Shared/Models/ConnectionType.swift
import Foundation

/// Determines how a profile authenticates and fetches usage data.
/// Stored as a String raw value for Codable compatibility.
enum ConnectionType: String, Codable {
    /// Standard claude.ai session key — parses five_hour/seven_day utilisation
    case claudeAI
    /// CLI OAuth token — parses usage from Messages API rate limit headers
    case cliOAuth
    /// Anthropic Console API session key — provides billing/credit data
    case console
    /// Enterprise claude.ai session key — parses extra_usage as monthly spend
    case enterprise
}
