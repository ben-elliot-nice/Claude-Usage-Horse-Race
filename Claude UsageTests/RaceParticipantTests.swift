// Claude UsageTests/RaceParticipantTests.swift
import XCTest
@testable import Claude_Usage

final class RaceParticipantTests: XCTestCase {

    func testPercentUsed_normal() {
        let p = RaceParticipant(
            name: "Alice",
            costUsedCents: 61500,
            costLimitCents: 100000,
            updatedAt: Date()
        )
        XCTAssertEqual(p.percentUsed, 61.5, accuracy: 0.001)
    }

    func testPercentUsed_zeroLimit() {
        let p = RaceParticipant(
            name: "Alice",
            costUsedCents: 100,
            costLimitCents: 0,
            updatedAt: Date()
        )
        XCTAssertEqual(p.percentUsed, 0.0)
    }

    func testIsStale_fresh() {
        let p = RaceParticipant(
            name: "Alice",
            costUsedCents: 100,
            costLimitCents: 100000,
            updatedAt: Date()
        )
        XCTAssertFalse(p.isStale)
    }

    func testIsStale_old() {
        let oldDate = Date().addingTimeInterval(-301) // 5min 1sec ago
        let p = RaceParticipant(
            name: "Alice",
            costUsedCents: 100,
            costLimitCents: 100000,
            updatedAt: oldDate
        )
        XCTAssertTrue(p.isStale)
    }

    func testFormattedCost() {
        let p = RaceParticipant(
            name: "Alice",
            costUsedCents: 61500,
            costLimitCents: 100000,
            updatedAt: Date()
        )
        // $615
        XCTAssertTrue(p.formattedCostUsed.contains("615"))
    }

    func testRaceStandings_decodable() throws {
        let json = """
        {
          "race_slug": "NICE-TEAM",
          "participants": [
            {
              "name": "Alice",
              "cost_used_cents": 61500,
              "cost_limit_cents": 100000,
              "updated_at": "2026-05-01T14:20:00Z"
            }
          ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let standings = try decoder.decode(RaceStandings.self, from: json)

        XCTAssertEqual(standings.raceSlug, "NICE-TEAM")
        XCTAssertEqual(standings.participants.count, 1)
        XCTAssertEqual(standings.participants[0].name, "Alice")
        XCTAssertEqual(standings.participants[0].costUsedCents, 61500)
    }
}
