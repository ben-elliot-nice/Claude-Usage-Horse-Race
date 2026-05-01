import XCTest
@testable import Claude_Usage

final class RaceSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear all race keys before each test
        let keys = ["raceEnabled", "raceURL", "raceParticipantName",
                    "racePushInterval", "racePollInterval"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    func testDefaults() {
        XCTAssertFalse(RaceSettings.shared.raceEnabled)
        XCTAssertNil(RaceSettings.shared.raceURL)
        XCTAssertFalse(RaceSettings.shared.participantName.isEmpty)
        XCTAssertEqual(RaceSettings.shared.pushInterval, 60.0)
        XCTAssertEqual(RaceSettings.shared.pollInterval, 30.0)
    }

    func testSaveAndLoadRaceURL() {
        RaceSettings.shared.raceURL = "http://localhost:8765/races/TEST"
        XCTAssertEqual(RaceSettings.shared.raceURL, "http://localhost:8765/races/TEST")
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

    func testRaceURLNilOnEmptyString() {
        RaceSettings.shared.raceURL = ""
        XCTAssertNil(RaceSettings.shared.raceURL)
    }
}
