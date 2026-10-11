import XCTest
@testable import ClaudeMonitor

/// Labels.swift against tests/fixtures/labels.json (also checked by test_labels.py).
final class LabelsTests: XCTestCase {
    private var fixture: JSONValue!

    override func setUpWithError() throws {
        fixture = try Fixtures.json("labels.json")
    }

    /// The `[input, expected]` pairs of one fixture section.
    private func pairs(_ section: String) throws -> [(JSONValue, String)] {
        let items = try XCTUnwrap(fixture[section]?.arrayValue, "missing section \(section)")
        XCTAssertFalse(items.isEmpty, "empty section \(section)")
        return try items.map { item in
            let pair = try XCTUnwrap(item.arrayValue)
            XCTAssertEqual(pair.count, 2)
            return (pair[0], try XCTUnwrap(pair[1].stringValue))
        }
    }

    func testModels() throws {
        for (input, expected) in try pairs("models") {
            let model = try XCTUnwrap(input.stringValue)
            XCTAssertEqual(Labels.shortModel(model), expected, "model \(model)")
        }
    }

    func testModes() throws {
        for (input, expected) in try pairs("modes") {
            let mode = try XCTUnwrap(input.stringValue)
            XCTAssertEqual(Labels.shortMode(mode), expected, "mode \(mode)")
        }
    }

    func testLimits() throws {
        for (limit, expected) in try pairs("limits") {
            // Same extraction as labels.limit_label().
            let kind = limit["kind"]?.stringValue
            let scopedName = limit["scope"]?["model"]?["display_name"]?.stringValue
            XCTAssertEqual(Labels.limitLabel(kind: kind, scopedModelName: scopedName), expected, "limit \(limit)")
        }
    }

    /// The usage bar's path: each fixture limit decoded as a `UsageLimit`.
    func testLimitsDecodedAsUsageLimit() throws {
        for (limit, expected) in try pairs("limits") {
            let data = try JSONEncoder().encode(limit)
            let decoded = try JSONDecoder().decode(UsageLimit.self, from: data)
            XCTAssertEqual(decoded.label, expected, "limit \(limit)")
        }
    }

    func testTokens() throws {
        for (input, expected) in try pairs("tokens") {
            let count = try XCTUnwrap(input.intValue)
            XCTAssertEqual(Labels.formatTokens(count), expected, "tokens \(count)")
        }
    }

    /// A usage.json as the API returns it today: scoped weekly limit and `spend`.
    func testUsageResponseWithScopeAndSpend() throws {
        let json = """
        {"five_hour": {"utilization": 21.0, "resets_at": "2026-10-11T10:30:00.276471+00:00"},
         "extra_usage": {"is_enabled": false, "utilization": 0.0, "currency": "EUR"},
         "limits": [
           {"kind": "session", "group": "session", "percent": 21, "severity": "normal",
            "resets_at": "2026-10-11T10:30:00.276471+00:00", "scope": null, "is_active": false},
           {"kind": "weekly_all", "group": "weekly", "percent": 25, "severity": "normal",
            "resets_at": "2026-10-13T02:00:00.276495+00:00", "scope": null, "is_active": true},
           {"kind": "weekly_scoped", "group": "weekly", "percent": 0, "severity": "normal",
            "resets_at": "2026-10-13T02:00:00+00:00",
            "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false}
         ],
         "spend": {"used": {"amount_minor": 0}, "percent": 7, "severity": "normal", "enabled": true}}
        """
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        XCTAssertEqual(usage.limits?.map(\.label), ["Session", "Week", "Week (Fable)"])
        XCTAssertEqual(usage.limits?.last?.scope?.modelDisplayName, "Fable")
        XCTAssertNil(usage.limits?.first?.scope)
        XCTAssertEqual(usage.spend, try JSONDecoder().decode(SpendUsage.self, from: Data(#"{"percent": 7, "severity": "normal", "enabled": true}"#.utf8)))
        XCTAssertEqual(usage.spend?.enabled, true)
        XCTAssertEqual(usage.spend?.percent, 7)
        // Reset instants with and without fractional seconds both parse.
        XCTAssertNotNil(ISOTime.parse(try XCTUnwrap(usage.limits?[1].resetsAt)))
        XCTAssertNotNil(ISOTime.parse(try XCTUnwrap(usage.limits?[2].resetsAt)))
    }

    /// An odd `scope`/`spend` shape never blanks the usage bar.
    func testLenientScopeAndSpend() throws {
        let json = """
        {"limits": [{"kind": "weekly_scoped", "percent": 3, "scope": "unexpected"}],
         "spend": {"percent": "n/a", "enabled": "yes"}}
        """
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        XCTAssertEqual(usage.limits?.map(\.label), ["Week (model)"])
        XCTAssertNotNil(usage.spend)
        XCTAssertNil(usage.spend?.percent)
        XCTAssertNil(usage.spend?.enabled)
    }
}
