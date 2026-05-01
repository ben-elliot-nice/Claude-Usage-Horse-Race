// Claude UsageTests/RaceEntryTests.swift
import XCTest
@testable import Claude_Usage

final class RaceEntryTests: XCTestCase {

    func testRaceEntry_encodeDecode() throws {
        let id = UUID()
        let entry = RaceEntry(id: id, url: "https://server/races/abc", name: "NICE-TEAM")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RaceEntry.self, from: data)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.url, "https://server/races/abc")
        XCTAssertEqual(decoded.name, "NICE-TEAM")
    }

    func testRaceEntry_nameIsOptional() throws {
        let entry = RaceEntry(url: "https://server/races/abc")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RaceEntry.self, from: data)
        XCTAssertNil(decoded.name)
    }

    func testRaceEntry_defaultsUUID() {
        let entry = RaceEntry(url: "https://server/races/abc")
        XCTAssertNotNil(UUID(uuidString: entry.id.uuidString))
    }

    func testRaceEntry_equatable() {
        let id = UUID()
        let a = RaceEntry(id: id, url: "https://server/races/abc", name: "NICE")
        let b = RaceEntry(id: id, url: "https://server/races/abc", name: "NICE")
        XCTAssertEqual(a, b)
    }
}
