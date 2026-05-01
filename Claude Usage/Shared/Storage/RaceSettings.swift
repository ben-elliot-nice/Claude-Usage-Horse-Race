// Claude Usage/Shared/Storage/RaceSettings.swift
import Foundation

/// Persists horse race configuration in UserDefaults.
final class RaceSettings {
    static let shared = RaceSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let raceEnabled       = "raceEnabled"
        static let participantName   = "raceParticipantName"
        static let pushInterval      = "racePushInterval"
        static let pollInterval      = "racePollInterval"
        static let participantID     = "raceParticipantID"
        static let serverBaseURL     = "raceServerBaseURL"
        static let raceEntries       = "raceEntries"
        // Legacy keys (pre-multi-race) — only used for one-time migration
        static let legacyRaceURL     = "raceURL"
        static let legacyRaceName    = "raceCurrentRaceName"
    }

    // MARK: - Race Enabled

    var raceEnabled: Bool {
        get { defaults.bool(forKey: Keys.raceEnabled) }
        set { defaults.set(newValue, forKey: Keys.raceEnabled) }
    }

    // MARK: - Participant Name

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

    var serverBaseURL: String? {
        get { defaults.string(forKey: Keys.serverBaseURL).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue ?? "", forKey: Keys.serverBaseURL) }
    }

    // MARK: - Participant Identity

    var participantID: String {
        let stored = defaults.string(forKey: Keys.participantID) ?? ""
        if !stored.isEmpty { return stored }
        let newID = UUID().uuidString
        defaults.set(newID, forKey: Keys.participantID)
        return newID
    }

    // MARK: - Race Entries (replaces single raceURL/raceName)

    var raceEntries: [RaceEntry] {
        get {
            if let data = defaults.data(forKey: Keys.raceEntries),
               let entries = try? JSONDecoder().decode([RaceEntry].self, from: data) {
                return entries
            }
            // One-time migration from legacy single-race keys
            if let legacyURL = defaults.string(forKey: Keys.legacyRaceURL),
               !legacyURL.isEmpty {
                let entry = RaceEntry(
                    url: legacyURL,
                    name: defaults.string(forKey: Keys.legacyRaceName)
                )
                let migrated = [entry]
                if let encoded = try? JSONEncoder().encode(migrated) {
                    defaults.set(encoded, forKey: Keys.raceEntries)
                }
                defaults.removeObject(forKey: Keys.legacyRaceURL)
                defaults.removeObject(forKey: Keys.legacyRaceName)
                return migrated
            }
            return []
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                defaults.set(encoded, forKey: Keys.raceEntries)
            }
        }
    }

    func addRaceEntry(_ entry: RaceEntry) {
        var entries = raceEntries
        entries.append(entry)
        raceEntries = entries
    }

    func removeRaceEntry(id: UUID) {
        raceEntries = raceEntries.filter { $0.id != id }
    }

    func updateRaceEntryName(url: String, name: String) {
        var entries = raceEntries
        if let idx = entries.firstIndex(where: { $0.url == url }) {
            entries[idx].name = name
            raceEntries = entries
        }
    }

    // MARK: - Legacy compatibility shims (Task 3 will remove these)
    // These bridge the old single-race API to the new list so RaceService and
    // HorseRaceSettingsView continue to compile until Task 3 rewires them.

    @available(*, deprecated, renamed: "raceEntries")
    var raceURL: String? {
        get { raceEntries.first?.url }
        set {
            if let url = newValue, !url.isEmpty {
                if raceEntries.isEmpty {
                    addRaceEntry(RaceEntry(url: url))
                } else {
                    var entries = raceEntries
                    entries[0] = RaceEntry(id: entries[0].id, url: url, name: entries[0].name)
                    raceEntries = entries
                }
            } else {
                // nil / empty → remove the first entry
                if !raceEntries.isEmpty {
                    removeRaceEntry(id: raceEntries[0].id)
                }
            }
        }
    }

    @available(*, deprecated, renamed: "raceEntries")
    var raceName: String? {
        get { raceEntries.first?.name }
        set {
            guard !raceEntries.isEmpty else { return }
            updateRaceEntryName(url: raceEntries[0].url, name: newValue ?? "")
        }
    }
}
