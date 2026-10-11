import XCTest
@testable import ClaudeMonitor

/// The non-blocking child-process runner behind `claude agents --json`.
final class SubprocessTests: XCTestCase {
    func testCapturesOutputAndExitStatus() async throws {
        let output = await Subprocess.run("/bin/sh", ["-c", "printf out; printf err >&2; exit 3"], environment: nil, timeout: 5)
        let result = try XCTUnwrap(output)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err")
        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(result.timedOut)
    }

    func testPassesEnvironmentAndClosesStdin() async throws {
        // stdin is /dev/null: `cat` sees EOF at once instead of waiting forever.
        let output = await Subprocess.run(
            "/bin/sh", ["-c", "cat; printf %s \"$DISABLE_AUTOUPDATER\""],
            environment: ["DISABLE_AUTOUPDATER": "1"], timeout: 5
        )
        let result = try XCTUnwrap(output)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "1")
        XCTAssertFalse(result.timedOut)
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        // 1 MB on each pipe, far beyond the pipe buffers.
        let output = await Subprocess.run(
            "/bin/sh", ["-c", "head -c 1048576 /dev/zero; head -c 1048576 /dev/zero >&2"],
            environment: nil, timeout: 10
        )
        let result = try XCTUnwrap(output)
        XCTAssertEqual(result.stdout.count, 1_048_576)
        XCTAssertEqual(result.stderr.count, 1_048_576)
        XCTAssertEqual(result.status, 0)
    }

    func testTimeoutTerminatesTheChild() async throws {
        let start = Date()
        let output = await Subprocess.run("/bin/sleep", ["30"], environment: nil, timeout: 0.5)
        let result = try XCTUnwrap(output)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testGrandchildHoldingThePipesDoesNotHang() async throws {
        // The child exits at once; a background grandchild keeps the pipes open.
        let start = Date()
        let output = await Subprocess.run("/bin/sh", ["-c", "printf done; sleep 5 &"], environment: nil, timeout: 10)
        let result = try XCTUnwrap(output)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done")
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testLaunchFailureIsNil() async {
        let output = await Subprocess.run("/nonexistent/claude", ["agents", "--json"], environment: nil, timeout: 1)
        XCTAssertNil(output)
    }
}

/// Opt-in check against the installed Claude Code:
/// `CLAUDE_MONITOR_LIVE_TEST=1 swift test --filter LiveSessionsTests`
final class LiveSessionsTests: XCTestCase {
    func testPollInstalledClaude() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CLAUDE_MONITOR_LIVE_TEST"] != nil,
            "set CLAUDE_MONITOR_LIVE_TEST=1 to poll the installed claude"
        )
        let live = LiveSessions()
        let path = await live.claudePath()
        let polled = await live.poll()
        let snapshot = try XCTUnwrap(polled, "neither `claude agents --json` nor the registry answered")
        print("claude: \(path ?? "not found"), source: \(snapshot.source), sessions: \(snapshot.entries.count)")
        for entry in snapshot.entries.values.sorted(by: { $0.startedAt < $1.startedAt }) {
            print("  \(entry.sessionId) pid=\(entry.pid.map(String.init) ?? "-") \(entry.kind) \(entry.status ?? entry.state ?? "-") \(entry.name)")
        }

        // Every hook file decodes, and the merge gives one status per session.
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/monitor/sessions")
        let files = ((try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        let now = Date().timeIntervalSince1970
        for file in files {
            let session = try Session.decode(Data(contentsOf: file), fallbackId: file.deletingPathExtension().lastPathComponent)
            let effective = Merge.effective(hook: session, live: snapshot.entries[session.sessionId], observedAt: snapshot.observedAt, now: now)
            print("  hook \(session.project): hook=\(session.status.rawValue) -> \(effective.status.rawValue)"
                + "\(effective.hidden ? " hidden" : "")\(effective.staleIdle ? " staleIdle" : "")\(effective.legacy ? " legacy" : "")"
                + " subagents=\(session.subagents.count) model=\(Labels.shortModel(session.model))")
        }
    }
}
