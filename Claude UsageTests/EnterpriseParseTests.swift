// Claude UsageTests/EnterpriseParseTests.swift
import XCTest
@testable import Claude_Usage

final class EnterpriseParseTests: XCTestCase {

    private let service = ClaudeAPIService()

    func makeResponseData(extraUsage: [String: Any]?) -> Data {
        var json: [String: Any] = [
            "five_hour": NSNull(),
            "seven_day": NSNull(),
        ]
        if let eu = extraUsage {
            json["extra_usage"] = eu
        }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testParseExtraUsage_normal() throws {
        let data = makeResponseData(extraUsage: [
            "is_enabled": true,
            "monthly_limit": 100000,
            "used_credits": 660.0,
            "utilization": 0.66,   // API returns utilization as a percentage (0.66 = 0.66%)
            "currency": "USD"
        ])
        let usage = try service.parseEnterpriseResponse(data)

        // utilization is already a percentage — 0.66 means 0.66%
        XCTAssertEqual(usage.sessionPercentage, 0.66, accuracy: 0.001)
        XCTAssertEqual(usage.costUsed, 660.0)
        XCTAssertEqual(usage.costLimit, 100000.0)
        XCTAssertEqual(usage.costCurrency, "USD")
    }

    func testParseExtraUsage_zeroUsed() throws {
        let data = makeResponseData(extraUsage: [
            "is_enabled": true,
            "monthly_limit": 100000,
            "used_credits": 0.0,
            "utilization": 0.0,
            "currency": "USD"
        ])
        let usage = try service.parseEnterpriseResponse(data)
        XCTAssertEqual(usage.sessionPercentage, 0.0)
        XCTAssertEqual(usage.costUsed, 0.0)
    }

    func testParseExtraUsage_weeklyFieldsAreZero() throws {
        let data = makeResponseData(extraUsage: [
            "is_enabled": true,
            "monthly_limit": 100000,
            "used_credits": 500.0,
            "utilization": 0.005,
            "currency": "USD"
        ])
        let usage = try service.parseEnterpriseResponse(data)
        XCTAssertEqual(usage.weeklyTokensUsed, 0)
        XCTAssertEqual(usage.weeklyPercentage, 0.0)
        XCTAssertEqual(usage.opusWeeklyTokensUsed, 0)
        XCTAssertEqual(usage.sonnetWeeklyTokensUsed, 0)
    }

    func testParseExtraUsage_missingExtraUsage_throws() {
        let data = makeResponseData(extraUsage: nil)
        XCTAssertThrowsError(try service.parseEnterpriseResponse(data)) { error in
            guard let appError = error as? AppError else {
                XCTFail("Expected AppError")
                return
            }
            XCTAssertEqual(appError.code, .apiParsingFailed)
        }
    }

    func testParseExtraUsage_disabledExtraUsage_throws() {
        let data = makeResponseData(extraUsage: [
            "is_enabled": false,
            "monthly_limit": 100000,
            "used_credits": 0.0,
            "utilization": 0.0,
            "currency": "USD"
        ])
        XCTAssertThrowsError(try service.parseEnterpriseResponse(data)) { error in
            guard let appError = error as? AppError else {
                XCTFail("Expected AppError")
                return
            }
            XCTAssertEqual(appError.code, .apiParsingFailed)
        }
    }

    func testResetTimeIsEndOfCurrentMonth() throws {
        let data = makeResponseData(extraUsage: [
            "is_enabled": true,
            "monthly_limit": 100000,
            "used_credits": 100.0,
            "utilization": 0.001,
            "currency": "USD"
        ])
        let usage = try service.parseEnterpriseResponse(data)

        // Reset time should be in the future (end of current or next month)
        XCTAssertGreaterThan(usage.sessionResetTime, Date())

        // Should be within 32 days
        let thirtyTwoDays: TimeInterval = 32 * 24 * 60 * 60
        XCTAssertLessThan(usage.sessionResetTime.timeIntervalSinceNow, thirtyTwoDays)
    }
}
