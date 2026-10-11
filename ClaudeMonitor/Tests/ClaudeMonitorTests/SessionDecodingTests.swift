import XCTest
@testable import ClaudeMonitor

/// Session.swift against the files the hooks write (tests/fixtures/session_v*.json).
final class SessionDecodingTests: XCTestCase {
    func testSchema2() throws {
        let session = try JSONDecoder().decode(Session.self, from: Fixtures.data("session_v2.json"))

        XCTAssertEqual(session.sessionId, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(session.project, "project")
        XCTAssertEqual(session.cwd, "/Users/me/project/src")
        // A subagent's pending prompt makes the session PERMISSION; the main agent is executing.
        XCTAssertEqual(session.baseStatus, .executing)
        XCTAssertEqual(session.status, .permission)
        XCTAssertEqual(session.pending["a72b09f1ce480cbcf"], PendingPrompt(tool: "Bash", fp: "ffeeddccbbaa", since: 1_791_702_459.0))
        XCTAssertEqual(session.statusTs, 1_791_702_455.25)
        XCTAssertEqual(session.activityTs, 1_791_702_460.5)
        XCTAssertEqual(session.toolName, "Bash")
        XCTAssertEqual(session.permissionMode, "auto")
        XCTAssertEqual(session.model, "claude-opus-5-5")
        XCTAssertEqual(session.effort, "max")
        XCTAssertEqual(session.contextTokens, 412_345)
        XCTAssertEqual(session.title, "flaky-test")  // the custom title wins over the AI title
        XCTAssertEqual(session.aiTitle, "Flaky test fix")
        XCTAssertEqual(session.displayTopic, "flaky-test")
        XCTAssertEqual(session.topic, "Fix the flaky test")
        XCTAssertEqual(session.toolCount, 12)
        XCTAssertEqual(session.lastError, "")
        XCTAssertEqual(session.background, BackgroundTasks(active: 2, types: ["subagent": 2, "shell": 1]))
        XCTAssertEqual(session.crons, 1)
        // "2026-10-11T07:07:34.767302+00:00": 5.732698 s before activity_ts.
        XCTAssertEqual(try XCTUnwrap(session.startDate).timeIntervalSince1970, 1_791_702_454.767302, accuracy: 1e-6)

        XCTAssertEqual(session.subagents.count, 2)
        XCTAssertEqual(session.subagentsOverflow, 3)
        let first = session.subagents[0]
        XCTAssertEqual(first.agentId, "a72b09f1ce480cbcf")
        XCTAssertEqual(first.agentType, "Explore")
        XCTAssertEqual(first.description, "Changelog analysis")
        XCTAssertEqual(first.toolName, "Read")
        XCTAssertEqual(first.toolCount, 5)
        XCTAssertEqual(first.ts, 1_791_702_459.0)
        XCTAssertEqual(first.parsedStatus, .permission)
        let second = session.subagents[1]
        XCTAssertNil(second.toolName)
        XCTAssertEqual(second.parsedStatus, .executing)
    }

    func testSchema1() throws {
        let session = try JSONDecoder().decode(Session.self, from: Fixtures.data("session_v1.json"))

        XCTAssertEqual(session.sessionId, "abc-123")
        // Legacy PERMISSION: base EXECUTING (a tool was running) plus a pending "main" prompt.
        XCTAssertEqual(session.baseStatus, .executing)
        XCTAssertEqual(session.status, .permission)
        let lastUpdated = 1_736_937_322.0  // 2025-01-15T10:35:22+00:00
        XCTAssertEqual(session.pending, ["main": PendingPrompt(tool: "ExitPlanMode", fp: "", since: lastUpdated)])
        // Timestamps come from last_updated when the numeric ones are missing.
        XCTAssertEqual(session.activityTs, lastUpdated)
        XCTAssertEqual(session.statusTs, lastUpdated)
        // Schema 1 kept the AI title in "title".
        XCTAssertEqual(session.aiTitle, "Feature X implementation")
        XCTAssertEqual(session.customTitle, "")
        XCTAssertEqual(session.title, "Feature X implementation")
        XCTAssertEqual(session.model, "claude-opus-4-8")
        XCTAssertEqual(session.effort, "")
        XCTAssertEqual(session.contextTokens, 0)
        XCTAssertEqual(session.toolCount, 12)
        XCTAssertEqual(session.startDate?.timeIntervalSince1970, 1_736_937_000)

        XCTAssertEqual(session.subagents.count, 1)
        let agent = session.subagents[0]
        XCTAssertEqual(agent.agentId, "sub-456")
        XCTAssertEqual(agent.ts, 1_736_937_240)  // from last_updated 10:34:00
        XCTAssertEqual(agent.parsedStatus, .executing)
    }

    func testLegacyPermissionWithoutToolIsThinking() throws {
        let json = #"{"session_id": "x", "status": "PERMISSION", "tool_name": null, "last_updated": "2025-01-15T10:35:22+00:00"}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.baseStatus, .thinking)
        XCTAssertEqual(session.pending["main"]?.tool, "")
        XCTAssertEqual(session.status, .permission)
    }

    func testSchema2PermissionIsNotLegacy() throws {
        // A schema-2 file's "status" is derived; only base_status + pending count.
        let json = #"{"session_id": "x", "status": "PERMISSION", "base_status": "WAITING", "pending": {}}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.status, .waiting)
        XCTAssertTrue(session.pending.isEmpty)
    }

    func testUnknownStatusIsStartingNeverEnded() throws {
        let json = #"{"session_id": "x", "base_status": "HIBERNATING"}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.baseStatus, .starting)
        XCTAssertEqual(SessionStatus(lenient: "SOMETHING_NEW"), .starting)
        XCTAssertEqual(SessionStatus(lenient: "ENDED"), .ended)
    }

    func testLenientFieldTypes() throws {
        // Wrong types fall back to defaults instead of failing the file (like
        // state.py's _num/_int/_str); bools are not numbers; floats truncate.
        let json = """
        {"session_id": 42, "tool_count": true, "context_tokens": 1234.9, "model": 5,
         "pending": {"main": "oops", "a1": {"tool": "Bash", "since": "x"}},
         "subagents": [{"agent_id": ""}, "junk", {"agent_id": "a1", "ts": 0, "last_updated": "2026-10-11T07:07:39+00:00"}],
         "background": {"active": "2", "types": {"shell": 1.0}}}
        """
        let session = try Session.decode(Data(json.utf8), fallbackId: "from-file-name")
        XCTAssertEqual(session.sessionId, "from-file-name")
        XCTAssertEqual(session.toolCount, 0)
        XCTAssertEqual(session.contextTokens, 1234)
        XCTAssertEqual(session.model, "")
        XCTAssertEqual(session.pending, ["a1": PendingPrompt(tool: "Bash", fp: "", since: 0)])
        XCTAssertEqual(session.subagents.map(\.agentId), ["a1"])
        XCTAssertEqual(session.subagents.first?.ts, 1_791_702_459)
        XCTAssertEqual(session.background, BackgroundTasks(active: 0, types: ["shell": 1]))
        XCTAssertThrowsError(try Session.decode(Data("[]".utf8), fallbackId: "x"))
    }

    func testISOTimeAcceptsBothIsoformatShapes() {
        // isoformat() drops the fraction when microseconds are 0.
        XCTAssertEqual(ISOTime.parse("2026-10-11T07:07:39+00:00"), 1_791_702_459)
        XCTAssertEqual(ISOTime.parse("2026-10-11T07:07:40.500000+00:00"), 1_791_702_460.5)
        XCTAssertEqual(ISOTime.parse("2026-10-11T07:07:40.5Z"), 1_791_702_460.5)
        XCTAssertEqual(ISOTime.parse("2026-10-11T09:07:39+02:00"), 1_791_702_459)
        XCTAssertEqual(ISOTime.parse("1970-01-01T00:00:00+00:00"), 0)
        XCTAssertEqual(ISOTime.parse("2024-02-29T00:00:00+00:00"), 1_709_164_800)
        XCTAssertNil(ISOTime.parse(""))
        XCTAssertNil(ISOTime.parse("yesterday"))
        XCTAssertNil(ISOTime.parse("2025-02-30T00:00:00+00:00"))
        XCTAssertNil(ISOTime.parse("2026-10-11T07:07:39+00:00junk"))
    }
}
