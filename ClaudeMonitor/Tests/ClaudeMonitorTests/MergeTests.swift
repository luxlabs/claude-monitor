import XCTest
@testable import ClaudeMonitor

/// Merge.swift against tests/fixtures/merge_cases.json (also checked by test_merge.py).
final class MergeTests: XCTestCase {
    private struct Fixture: Decodable {
        let constants: [String: Double]
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let now: Double
        let observedAt: Double?
        let hook: JSONValue?
        let live: LiveEntry?
        let expect: Expected

        enum CodingKeys: String, CodingKey {
            case name, now, hook, live, expect
            case observedAt = "observed_at"
        }
    }

    private struct Expected: Decodable, Equatable, CustomStringConvertible {
        let status: String
        let detail: String?
        let hidden: Bool
        let legacy: Bool
        let untracked: Bool
        let staleIdle: Bool

        enum CodingKeys: String, CodingKey {
            case status, detail, hidden, legacy, untracked
            case staleIdle = "stale_idle"
        }

        init(_ effective: EffectiveState) {
            status = effective.status.rawValue
            detail = effective.detail
            hidden = effective.hidden
            legacy = effective.legacy
            untracked = effective.untracked
            staleIdle = effective.staleIdle
        }

        var description: String {
            "\(status) detail=\(detail ?? "nil") hidden=\(hidden) legacy=\(legacy) untracked=\(untracked) staleIdle=\(staleIdle)"
        }
    }

    private func loadFixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Fixtures.data("merge_cases.json"))
    }

    func testConstantsMatchFixture() throws {
        let fixture = try loadFixture()
        let swift: [String: Double] = [
            "FRESH_MARGIN": Merge.freshMargin,
            "SNAPSHOT_MAX_AGE": Merge.snapshotMaxAge,
            "ABSENT_GRACE": Merge.absentGrace,
            "ABSENT_ACTIVE_GRACE": Merge.absentActiveGrace,
            "BACKGROUND_DECAY": Merge.backgroundDecay,
            "IDLE_HIDE_AFTER": Merge.idleHideAfter,
            "LEGACY_ACTIVE_HIDE": Merge.legacyActiveHide,
        ]
        XCTAssertEqual(Set(fixture.constants.keys), Set(swift.keys))
        for (name, value) in fixture.constants {
            XCTAssertEqual(swift[name], value, name)
        }
    }

    func testCases() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.cases.isEmpty)
        for testCase in fixture.cases {
            // As in test_merge.py: SessionState.from_dict({**case["hook"], "session_id": "s"}).
            var hook: Session?
            if let object = testCase.hook?.objectValue {
                var dict = object
                dict["session_id"] = .string("s")
                hook = Session(json: dict)
            }
            let effective = Merge.effective(hook: hook, live: testCase.live, observedAt: testCase.observedAt, now: testCase.now)
            XCTAssertEqual(Expected(effective), testCase.expect, testCase.name)
        }
    }

    // Mirrors AgentsJsonTest in test_merge.py.
    func testParsesDocumentedShapeAndDedupes() throws {
        let text = """
        [
          {"cwd": "/p", "kind": "background", "id": "7c5dcf5d", "state": "blocked", "pid": 4242,
           "status": "waiting", "waitingFor": "permission prompt", "startedAt": 1767225600000,
           "sessionId": "s1", "name": "flaky-test-fix"},
          {"cwd": "/p", "kind": "interactive", "startedAt": 1767225600000, "sessionId": "s2"},
          {"cwd": "/p", "kind": "interactive", "pid": 7, "status": "idle", "startedAt": 1767225600000, "sessionId": "s2"},
          {"cwd": "/p", "kind": "background", "id": "nosession", "state": "working"}
        ]
        """
        let snapshot = try XCTUnwrap(LiveSnapshot.parse(agentsJSON: Data(text.utf8), observedAt: 123))
        XCTAssertEqual(snapshot.observedAt, 123)
        XCTAssertEqual(snapshot.source, .agents)
        XCTAssertEqual(Set(snapshot.entries.keys), ["s1", "s2"])
        let s1 = try XCTUnwrap(snapshot.entries["s1"])
        XCTAssertEqual(s1.kind, .background)
        XCTAssertEqual(s1.jobId, "7c5dcf5d")
        XCTAssertEqual(s1.pid, 4242)
        XCTAssertEqual(s1.status, "waiting")
        XCTAssertEqual(s1.waitingFor, "permission prompt")
        XCTAssertEqual(s1.state, "blocked")
        XCTAssertEqual(s1.name, "flaky-test-fix")
        XCTAssertEqual(s1.cwd, "/p")
        XCTAssertEqual(s1.startedAt, 1_767_225_600)
        XCTAssertEqual(snapshot.entries["s2"]?.pid, 7)  // the row with a live process wins
    }

    func testRejectsNonJSONOrNonArray() {
        XCTAssertNil(LiveSnapshot.parse(agentsJSON: Data("not json".utf8), observedAt: 1))
        XCTAssertNil(LiveSnapshot.parse(agentsJSON: Data(#"{"a": 1}"#.utf8), observedAt: 1))
        XCTAssertEqual(LiveSnapshot.parse(agentsJSON: Data("[]".utf8), observedAt: 1)?.entries.count, 0)
    }

    func testRegistryFallback() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ClaudeMonitorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Missing directory: unknown, not "nobody is alive".
        XCTAssertNil(LiveSessions.readRegistry(observedAt: 1, directory: dir.appending(path: "missing")))
        // Empty directory: nobody is alive.
        XCTAssertEqual(LiveSessions.readRegistry(observedAt: 1, directory: dir)?.entries.count, 0)

        // This test process is alive and started before "now"; an older and a
        // newer record of the same session: the newest updatedAt wins.
        let pid = ProcessInfo.processInfo.processIdentifier
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let records = [
            ("a.json", #"{"pid": \#(pid), "sessionId": "s", "cwd": "/old", "startedAt": \#(nowMs), "status": "busy", "updatedAt": 1}"#),
            ("b.json", #"{"pid": \#(pid), "sessionId": "s", "cwd": "/new", "startedAt": \#(nowMs), "status": "idle", "updatedAt": 2, "kind": "bg", "jobId": "j1", "name": "n"}"#),
            ("c.key", "not a record"),
        ]
        for (name, text) in records {
            try Data(text.utf8).write(to: dir.appending(path: name))
        }
        let snapshot = try XCTUnwrap(LiveSessions.readRegistry(observedAt: 5, directory: dir))
        XCTAssertEqual(snapshot.source, .registry)
        XCTAssertEqual(snapshot.observedAt, 5)
        let entry = try XCTUnwrap(snapshot.entries["s"])
        XCTAssertEqual(entry.cwd, "/new")
        XCTAssertEqual(entry.status, "idle")
        XCTAssertEqual(entry.pid, pid)
        XCTAssertEqual(entry.kind, .background)  // a jobId and a kind other than "interactive"
        XCTAssertEqual(entry.jobId, "j1")
        XCTAssertEqual(entry.name, "n")

        // A record whose process started long after the session registered is
        // a recycled pid: skipped.
        try Data(#"{"pid": \#(pid), "sessionId": "old", "startedAt": 1000}"#.utf8).write(to: dir.appending(path: "d.json"))
        XCTAssertNil(try XCTUnwrap(LiveSessions.readRegistry(observedAt: 5, directory: dir)).entries["old"])

        // Files present but none parse: unknown format -> nil.
        let junk = dir.appending(path: "junk")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: junk.appending(path: "1.json"))
        XCTAssertNil(LiveSessions.readRegistry(observedAt: 1, directory: junk))
    }
}
