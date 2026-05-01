// Claude UsageTests/RaceSettingsTests.swift
import XCTest
@testable import Claude_Usage

final class RaceSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        let keys = ["raceEnabled", "raceParticipantName",
                    "racePushInterval", "racePollInterval",
                    "raceParticipantID", "raceServerBaseURL",
                    "raceEntries"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.removeObject(forKey: "raceURL")
        UserDefaults.standard.removeObject(forKey: "raceCurrentRaceName")
    }

    // MARK: - Unchanged settings

    func testDefaults() {
        XCTAssertFalse(RaceSettings.shared.raceEnabled)
        XCTAssertFalse(RaceSettings.shared.participantName.isEmpty)
        XCTAssertEqual(RaceSettings.shared.pushInterval, 60.0)
        XCTAssertEqual(RaceSettings.shared.pollInterval, 30.0)
    }

    func testSaveAndLoadEnabled() {
        RaceSettings.shared.raceEnabled = true
        XCTAssertTrue(RaceSettings.shared.raceEnabled)
    }

    func testSaveAndLoadParticipantName() {
        RaceSettings.shared.participantName = "Alice"
        XCTAssertEqual(RaceSettings.shared.participantName, "Alice")
    }

    func testSaveAndLoadPushInterval() {
        RaceSettings.shared.pushInterval = 120.0
        XCTAssertEqual(RaceSettings.shared.pushInterval, 120.0)
    }

    func testSaveAndLoadPollInterval() {
        RaceSettings.shared.pollInterval = 45.0
        XCTAssertEqual(RaceSettings.shared.pollInterval, 45.0)
    }

    func testParticipantID_generatedOnce() {
        UserDefaults.standard.removeObject(forKey: "raceParticipantID")
        let id1 = RaceSettings.shared.participantID
        let id2 = RaceSettings.shared.participantID
        XCTAssertNotNil(UUID(uuidString: id1))
        XCTAssertEqual(id1, id2)
    }

    func testServerBaseURL_defaultsNil() {
        XCTAssertNil(RaceSettings.shared.serverBaseURL)
    }

    func testServerBaseURL_saveAndLoad() {
        RaceSettings.shared.serverBaseURL = "https://example.com"
        XCTAssertEqual(RaceSettings.shared.serverBaseURL, "https://example.com")
    }

    // MARK: - raceEntries

    func testRaceEntries_defaultsEmpty() {
        XCTAssertTrue(RaceSettings.shared.raceEntries.isEmpty)
    }

    func testAddRaceEntry() {
        let entry = RaceEntry(url: "https://server/races/abc", name: "TEST")
        RaceSettings.shared.addRaceEntry(entry)
        XCTAssertEqual(RaceSettings.shared.raceEntries.count, 1)
        XCTAssertEqual(RaceSettings.shared.raceEntries[0].url, "https://server/races/abc")
        XCTAssertEqual(RaceSettings.shared.raceEntries[0].name, "TEST")
    }

    func testAddMultipleEntries() {
        RaceSettings.shared.addRaceEntry(RaceEntry(url: "https://server/races/a"))
        RaceSettings.shared.addRaceEntry(RaceEntry(url: "https://server/races/b"))
        XCTAssertEqual(RaceSettings.shared.raceEntries.count, 2)
    }

    func testRemoveRaceEntry() {
        let entry = RaceEntry(url: "https://server/races/abc")
        RaceSettings.shared.addRaceEntry(entry)
        RaceSettings.shared.removeRaceEntry(id: entry.id)
        XCTAssertTrue(RaceSettings.shared.raceEntries.isEmpty)
    }

    func testUpdateRaceEntryName() {
        let entry = RaceEntry(url: "https://server/races/abc")
        RaceSettings.shared.addRaceEntry(entry)
        RaceSettings.shared.updateRaceEntryName(url: "https://server/races/abc", name: "NICE-TEAM")
        XCTAssertEqual(RaceSettings.shared.raceEntries[0].name, "NICE-TEAM")
    }

    func testMigration_legacyRaceURL() {
        UserDefaults.standard.set("https://server/races/legacy", forKey: "raceURL")
        UserDefaults.standard.set("LEGACY-RACE", forKey: "raceCurrentRaceName")
        let entries = RaceSettings.shared.raceEntries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].url, "https://server/races/legacy")
        XCTAssertEqual(entries[0].name, "LEGACY-RACE")
        XCTAssertNil(UserDefaults.standard.string(forKey: "raceURL"))
        XCTAssertNil(UserDefaults.standard.string(forKey: "raceCurrentRaceName"))
    }

    func testMigration_noLegacyKey_returnsEmpty() {
        XCTAssertTrue(RaceSettings.shared.raceEntries.isEmpty)
    }
}
