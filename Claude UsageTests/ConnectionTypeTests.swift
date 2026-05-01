// Claude UsageTests/ConnectionTypeTests.swift
import XCTest
@testable import Claude_Usage

final class ConnectionTypeTests: XCTestCase {

    func testDefaultIsClaudeAI() {
        let decoded = try? JSONDecoder().decode(ConnectionType.self,
                                                from: Data("\"claudeAI\"".utf8))
        XCTAssertEqual(decoded, .claudeAI)
    }

    func testEnterpriseRoundTrip() throws {
        let encoded = try JSONEncoder().encode(ConnectionType.enterprise)
        let decoded = try JSONDecoder().decode(ConnectionType.self, from: encoded)
        XCTAssertEqual(decoded, .enterprise)
    }

    func testAllCasesRoundTrip() throws {
        for connectionType in [ConnectionType.claudeAI, .cliOAuth, .console, .enterprise] {
            let encoded = try JSONEncoder().encode(connectionType)
            let decoded = try JSONDecoder().decode(ConnectionType.self, from: encoded)
            XCTAssertEqual(decoded, connectionType)
        }
    }

    func testUnknownRawValueThrows() throws {
        XCTAssertThrowsError(
            try JSONDecoder().decode(ConnectionType.self,
                                     from: Data("\"unknownFutureCase\"".utf8))
        )
    }
}
