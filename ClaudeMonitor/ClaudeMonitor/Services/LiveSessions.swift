import Foundation
import Darwin
import os.log

private let log = Logger(subsystem: "com.mitobit.ClaudeMonitor", category: "LiveSessions")

/// Live session data from Claude Code: `claude agents --json`, falling back to
/// the per-process registry. Mirrors the I/O half of `live.py`; the pure merge
/// lives in Merge.swift.
actor LiveSessions {
    enum StopResult: Equatable, Sendable {
        case stopped  // `claude stop <id>` succeeded
        case terminated  // SIGTERM sent
        case killed  // SIGKILL sent
        case failed(String)
    }

    private static let claudeCandidates = [
        "~/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.claude/local/claude",
    ]

    private var resolveTask: Task<String?, Never>?

    /// The `claude` binary, looked up once (a failed lookup is remembered too).
    func claudePath() async -> String? {
        if let resolveTask {
            return await resolveTask.value
        }
        let task = Task.detached(priority: .utility) { await Self.resolveClaude() }
        resolveTask = task
        let path = await task.value
        log.info("claude binary: \(path ?? "not found", privacy: .public)")
        return path
    }

    /// One live snapshot: `claude agents --json`, else the session registry.
    func poll() async -> LiveSnapshot? {
        let observedAt = Date().timeIntervalSince1970  // start of the call: freshness checks stay conservative
        if let claude = await claudePath() {
            let output = await Subprocess.run(
                claude, ["agents", "--json"], environment: Self.claudeEnvironment(), timeout: Merge.pollTimeout
            )
            if let output, !output.timedOut, output.status == 0,
               let snapshot = LiveSnapshot.parse(agentsJSON: output.stdout, observedAt: observedAt) {
                return snapshot
            }
            log.debug("claude agents --json failed; falling back to the registry")
        }
        return Self.readRegistry(observedAt: observedAt)
    }

    /// Stop a session. Background sessions must go through `claude stop`:
    /// the supervisor respawns workers that get killed.
    func stop(entry: LiveEntry, force: Bool) async -> StopResult {
        if entry.kind == .background, let jobId = entry.jobId, !jobId.isEmpty, !force {
            guard let claude = await claudePath() else {
                return .failed("claude binary not found")
            }
            guard let output = await Subprocess.run(
                claude, ["stop", jobId], environment: Self.claudeEnvironment(), timeout: 15
            ) else {
                return .failed("claude stop failed")
            }
            if output.status == 0 && !output.timedOut {
                return .stopped
            }
            let message = String(decoding: output.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(message.isEmpty ? "claude stop failed" : message)
        }
        guard let pid = entry.pid, pid > 0 else {
            return .failed("no process")
        }
        if kill(pid, force ? SIGKILL : SIGTERM) != 0 {
            return .failed("kill failed: \(String(cString: strerror(errno)))")
        }
        return force ? .killed : .terminated
    }

    // MARK: - Locating `claude`

    /// A poll every few seconds must not trigger update checks.
    private static func claudeEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["DISABLE_AUTOUPDATER"] = "1"
        return env
    }

    /// Env override, PATH, known installs, then one login-shell lookup.
    private static func resolveClaude() async -> String? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = env["CLAUDE_MONITOR_CLAUDE_BIN"], !override.isEmpty {
            candidates.append(expandTilde(override))
        }
        // Like shutil.which: only useful when launched from a shell.
        for dir in (env["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            candidates.append("\(dir)/claude")
        }
        candidates += claudeCandidates.map(expandTilde)
        if let path = candidates.first(where: isExecutableFile) {
            return path
        }
        // GUI apps get a minimal PATH: ask a login shell.
        guard let output = await Subprocess.run("/bin/zsh", ["-lc", "command -v claude"], environment: nil, timeout: 5),
              !output.timedOut else {
            return nil
        }
        let lines = String(decoding: output.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces), isExecutableFile(last) else {
            return nil
        }
        return last
    }

    private static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// A regular file (symlinks followed) we may execute.
    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: - Fallback: Claude Code's per-process registry (~/.claude/sessions/<pid>.json)

    static func registryDirectory() -> URL {
        if let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !base.isEmpty {
            return URL(fileURLWithPath: expandTilde(base)).appending(path: "sessions")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/sessions")
    }

    /// `live.read_registry`. Nil when the directory is missing, or has
    /// `*.json` files but none parse (unknown format: better hooks-only mode
    /// than "nobody is alive").
    static func readRegistry(observedAt: Double, directory: URL = registryDirectory()) -> LiveSnapshot? {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? [])
            .filter { $0.hasSuffix(".json") }
        let decoder = JSONDecoder()
        let allRecords: [RegistryRecord] = names.compactMap { name in
            guard let data = fm.contents(atPath: directory.appending(path: name).path(percentEncoded: false)) else {
                return nil
            }
            return try? decoder.decode(RegistryRecord.self, from: data)
        }
        if allRecords.isEmpty && !names.isEmpty {
            return nil
        }
        guard fm.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return nil
        }

        var entries: [String: LiveEntry] = [:]
        var bestUpdated: [String: Double] = [:]
        for record in allRecords where pidAlive(record.pid) {
            let started = record.startedAt.map { $0 / 1000 } ?? 0
            // Entries survive unclean exits, so a recycled pid can look alive:
            // the process must have started before the session registered.
            if let processStart = processStartTime(record.pid), started != 0, processStart > started + 5 {
                continue
            }
            let sid = record.sessionId
            let updated = record.updatedAt ?? 0
            if entries[sid] != nil && (bestUpdated[sid] ?? 0) >= updated {
                continue
            }
            let jobId = record.jobId
            entries[sid] = LiveEntry(
                sessionId: sid,
                pid: record.pid,
                status: record.status,
                waitingFor: record.waitingFor,
                kind: record.kind == "interactive" || jobId == nil || jobId == "" ? .interactive : .background,
                jobId: jobId,
                name: record.name ?? "",
                cwd: record.cwd ?? "",
                startedAt: started
            )
            bestUpdated[sid] = updated
        }
        return LiveSnapshot(observedAt: observedAt, entries: entries, source: .registry)
    }

    static func pidAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM  // EPERM: exists, owned by someone we can't signal
    }

    /// Process start time (epoch seconds), nil if unavailable.
    static func processStartTime(_ pid: pid_t) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }
}

/// One `~/.claude/sessions/<pid>.json` record: `pid` and `sessionId` are
/// required, everything else is optional and lenient.
private struct RegistryRecord: Decodable {
    let pid: pid_t
    let sessionId: String
    let cwd: String?
    let startedAt: Double?
    let status: String?
    let waitingFor: String?
    let kind: String?
    let jobId: String?
    let name: String?
    let updatedAt: Double?

    private enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, startedAt, status, waitingFor, kind, jobId, name, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawPid = try c.decode(Int.self, forKey: .pid)
        guard rawPid > 0, let pid = pid_t(exactly: rawPid) else {
            throw DecodingError.dataCorruptedError(forKey: .pid, in: c, debugDescription: "Invalid pid")
        }
        self.pid = pid
        sessionId = try c.decode(String.self, forKey: .sessionId)
        cwd = try? c.decode(String.self, forKey: .cwd)
        startedAt = try? c.decode(Double.self, forKey: .startedAt)
        status = try? c.decode(String.self, forKey: .status)
        waitingFor = try? c.decode(String.self, forKey: .waitingFor)
        kind = try? c.decode(String.self, forKey: .kind)
        jobId = try? c.decode(String.self, forKey: .jobId)
        name = try? c.decode(String.self, forKey: .name)
        updatedAt = try? c.decode(Double.self, forKey: .updatedAt)
    }
}

// MARK: - Subprocess

/// Result of one child process run.
struct SubprocessOutput: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
}

/// Runs a child process without blocking any thread: pipes are drained by
/// readability handlers as data arrives (no pipe-buffer deadlock), exit and
/// timeout are callbacks, and the caller suspends on a continuation.
enum Subprocess {
    /// Nil if the executable could not be launched. On timeout the child gets
    /// SIGTERM (SIGKILL one second later) and `timedOut` is true.
    static func run(
        _ path: String,
        _ arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) async -> SubprocessOutput? {
        await withCheckedContinuation { (continuation: CheckedContinuation<SubprocessOutput?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            if let environment {
                process.environment = environment
            }
            process.standardInput = FileHandle.nullDevice
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let run = SubprocessRun(
                continuation: continuation,
                stdout: stdoutPipe.fileHandleForReading,
                stderr: stderrPipe.fileHandleForReading
            )
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                run.received(handle.availableData, fromStdout: true)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                run.received(handle.availableData, fromStdout: false)
            }
            process.terminationHandler = { finished in
                run.exited(status: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                run.failedToLaunch()
                return
            }
            run.started(process: process, timeout: timeout)
        }
    }
}

/// Mutable state of one `Subprocess.run`, shared by the pipe, termination and
/// timeout callbacks (which run on arbitrary queues), guarded by a lock. The
/// continuation is resumed exactly once, outside the lock.
private final class SubprocessRun: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SubprocessOutput?, Never>?
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private var process: Process?  // kept alive until the run finishes
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutDone = false
    private var stderrDone = false
    private var exitStatus: Int32?
    private var timedOut = false

    private typealias Completion = (CheckedContinuation<SubprocessOutput?, Never>, SubprocessOutput?)

    init(continuation: CheckedContinuation<SubprocessOutput?, Never>, stdout: FileHandle, stderr: FileHandle) {
        self.continuation = continuation
        self.stdoutHandle = stdout
        self.stderrHandle = stderr
    }

    func started(process: Process, timeout: TimeInterval) {
        lock.withLock {
            if continuation != nil { self.process = process }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
            self.timeoutFired()
        }
    }

    func received(_ data: Data, fromStdout: Bool) {
        if data.isEmpty {  // EOF: stop watching this pipe
            (fromStdout ? stdoutHandle : stderrHandle).readabilityHandler = nil
        }
        let completion = lock.withLock { () -> Completion? in
            if data.isEmpty {
                if fromStdout { stdoutDone = true } else { stderrDone = true }
            } else if fromStdout {
                stdout.append(data)
            } else {
                stderr.append(data)
            }
            return stdoutDone && stderrDone && exitStatus != nil ? takeCompletion() : nil
        }
        complete(completion)
    }

    func exited(status: Int32) {
        let completion = lock.withLock { () -> Completion? in
            exitStatus = status
            return stdoutDone && stderrDone ? takeCompletion() : nil
        }
        complete(completion)
        // A grandchild that inherited the pipes can keep them open after the
        // child exits: don't wait for their EOF for long.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [self] in
            self.complete(self.lock.withLock { self.takeCompletion() })
        }
    }

    func failedToLaunch() {
        let completion = lock.withLock { () -> Completion? in
            guard let pending = continuation else { return nil }
            continuation = nil
            return (pending, nil)
        }
        complete(completion)
    }

    private func timeoutFired() {
        let completion = lock.withLock { () -> Completion? in
            guard continuation != nil else { return nil }
            guard exitStatus == nil, let process else {
                return takeCompletion()  // exited, but the pipes never reached EOF
            }
            timedOut = true
            let pid = process.processIdentifier
            kill(pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                self.lock.withLock {
                    if self.exitStatus == nil { kill(pid, SIGKILL) }
                }
            }
            return nil
        }
        complete(completion)
    }

    /// Caller holds the lock. Nil if the run already finished.
    private func takeCompletion() -> Completion? {
        guard let pending = continuation else { return nil }
        continuation = nil
        process = nil
        return (pending, SubprocessOutput(status: exitStatus ?? -1, stdout: stdout, stderr: stderr, timedOut: timedOut))
    }

    /// Called without the lock.
    private func complete(_ completion: Completion?) {
        guard let (pending, output) = completion else { return }
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        pending.resume(returning: output)
    }
}
