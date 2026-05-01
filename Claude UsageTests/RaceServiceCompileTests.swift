// Claude UsageTests/RaceServiceCompileTests.swift
import XCTest
@testable import Claude_Usage

final class RaceServiceCompileTests: XCTestCase {

    private func makeParticipant(name: String, usedCents: Int, limitCents: Int = 100000) -> RaceParticipant {
        RaceParticipant(
            name: name,
            costUsedCents: usedCents,
            costLimitCents: limitCents,
            updatedAt: Date()
        )
    }

    private func makeStandings(slug: String, participants: [RaceParticipant]) -> RaceStandings {
        RaceStandings(raceSlug: slug, name: slug, participants: participants)
    }

    func testCompile_emptyStandings_returnsEmpty() {
        let result = RaceService.compile(from: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testCompile_singleRace_returnsAllParticipants() {
        let standings = makeStandings(slug: "A", participants: [
            makeParticipant(name: "Alice", usedCents: 6150),
            makeParticipant(name: "Ben", usedCents: 4230),
        ])
        let result = RaceService.compile(from: ["url-a": standings])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].name, "Alice")
    }

    func testCompile_multiRace_deduplicatesByName_keepsHighest() {
        let raceA = makeStandings(slug: "A", participants: [
            makeParticipant(name: "Alice", usedCents: 6150),
            makeParticipant(name: "Ben", usedCents: 2000),
        ])
        let raceB = makeStandings(slug: "B", participants: [
            makeParticipant(name: "Alice", usedCents: 3000),
            makeParticipant(name: "Carol", usedCents: 5000),
        ])
        let result = RaceService.compile(from: ["url-a": raceA, "url-b": raceB])
        XCTAssertEqual(result.count, 3)
        let alice = result.first { $0.name == "Alice" }!
        XCTAssertEqual(alice.costUsedCents, 6150)
    }

    func testCompile_sortedDescendingByPercent() {
        let standings = makeStandings(slug: "A", participants: [
            makeParticipant(name: "Carol", usedCents: 1800),
            makeParticipant(name: "Alice", usedCents: 6150),
            makeParticipant(name: "Ben", usedCents: 4230),
        ])
        let result = RaceService.compile(from: ["url-a": standings])
        XCTAssertEqual(result[0].name, "Alice")
        XCTAssertEqual(result[1].name, "Ben")
        XCTAssertEqual(result[2].name, "Carol")
    }

    func testCompile_sameName_appearsOnce() {
        let raceA = makeStandings(slug: "A", participants: [
            makeParticipant(name: "Alice", usedCents: 5000),
        ])
        let raceB = makeStandings(slug: "B", participants: [
            makeParticipant(name: "Alice", usedCents: 5000),
        ])
        let result = RaceService.compile(from: ["url-a": raceA, "url-b": raceB])
        XCTAssertEqual(result.count, 1)
    }
}
