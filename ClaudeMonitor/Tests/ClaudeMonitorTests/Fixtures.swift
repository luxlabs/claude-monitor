import Foundation
@testable import ClaudeMonitor

/// The fixtures shared with the Python tests (`<repo>/tests/fixtures`).
enum Fixtures {
    /// <repo>/ClaudeMonitor/Tests/ClaudeMonitorTests/Fixtures.swift -> <repo>/tests/fixtures
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ClaudeMonitorTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // ClaudeMonitor (package)
        .deletingLastPathComponent()  // repo root
        .appending(path: "tests/fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: name))
    }

    static func json(_ name: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data(name))
    }
}
