import Foundation

/// Persists horse race configuration in UserDefaults.
/// Follows the same load/save pattern as SharedDataStore.
final class RaceSettings {
    static let shared = RaceSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let raceEnabled       = "raceEnabled"
        static let raceURL           = "raceURL"
        static let participantName   = "raceParticipantName"
        static let pushInterval      = "racePushInterval"
        static let pollInterval      = "racePollInterval"
        static let participantID     = "raceParticipantID"
        static let serverBaseURL     = "raceServerBaseURL"
        static let raceName          = "raceCurrentRaceName"
    }

    // MARK: - Race Enabled

    var raceEnabled: Bool {
        get { defaults.bool(forKey: Keys.raceEnabled) }
        set { defaults.set(newValue, forKey: Keys.raceEnabled) }
    }

    // MARK: - Race URL (full URL including slug)

    var raceURL: String? {
        get { defaults.string(forKey: Keys.raceURL).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue ?? "", forKey: Keys.raceURL) }
    }

    // MARK: - Participant Name (defaults to hostname)

    var participantName: String {
        get {
            let stored = defaults.string(forKey: Keys.participantName) ?? ""
            if stored.isEmpty {
                return ProcessInfo.processInfo.hostName
                    .components(separatedBy: ".").first ?? "Unknown"
            }
            return stored
        }
        set { defaults.set(newValue, forKey: Keys.participantName) }
    }

    // MARK: - Timer Intervals

    var pushInterval: TimeInterval {
        get {
            let v = defaults.double(forKey: Keys.pushInterval)
            return v > 0 ? v : 60.0
        }
        set { defaults.set(newValue, forKey: Keys.pushInterval) }
    }

    var pollInterval: TimeInterval {
        get {
            let v = defaults.double(forKey: Keys.pollInterval)
            return v > 0 ? v : 30.0
        }
        set { defaults.set(newValue, forKey: Keys.pollInterval) }
    }

    // MARK: - Server Base URL

    /// Root URL of the race server, e.g. "https://claude-usage-horse-race-staging.up.railway.app"
    /// Stored separately from raceURL so it persists when switching races.
    var serverBaseURL: String? {
        get { defaults.string(forKey: Keys.serverBaseURL).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue ?? "", forKey: Keys.serverBaseURL) }
    }

    // MARK: - Current Race Name

    /// Display name of the currently joined race, returned by the server on creation/join.
    var raceName: String? {
        get { defaults.string(forKey: Keys.raceName).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue ?? "", forKey: Keys.raceName) }
    }

    // MARK: - Participant Identity (private UUID, generated once, never changes)

    var participantID: String {
        let stored = defaults.string(forKey: Keys.participantID) ?? ""
        if !stored.isEmpty { return stored }
        let newID = UUID().uuidString
        defaults.set(newID, forKey: Keys.participantID)
        return newID
    }
}
