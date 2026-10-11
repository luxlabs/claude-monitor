import Foundation
import Darwin
import os.log

private let log = Logger(subsystem: "com.mitobit.ClaudeMonitor", category: "ProcessDiscovery")

struct ClaudeProcess {
    let pid: pid_t
    let sessionId: String?
    let cwd: String?
}

enum ProcessDiscovery {

    /// Discover running Claude Code processes and match them to known sessions.
    /// Returns a map of session ID → candidate PIDs (usually 1, but may be multiple for ambiguous cwd matches).
    static func pidsBySession(for sessions: [Session]) -> [String: [pid_t]] {
        let processes = discoverClaudeProcesses()
        log.debug("Discovered \(processes.count) Claude processes for \(sessions.count) sessions")
        let result = matchToSessions(processes: processes, sessions: sessions)
        log.debug("Matched PIDs for \(result.count) sessions")
        return result
    }

    // MARK: - Discovery

    private static func discoverClaudeProcesses() -> [ClaudeProcess] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid,args"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var results: [ClaudeProcess] = []

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int32(trimmed[..<spaceIdx]) else { continue }
            let args = String(trimmed[trimmed.index(after: spaceIdx)...])

            let executable: String
            if let firstArg = args.split(separator: " ", maxSplits: 1).first {
                let path = String(firstArg)
                executable = (path as NSString).lastPathComponent
            } else {
                continue
            }

            guard executable == "claude" else { continue }
            if args.contains("Claude.app") { continue }
            if args.contains("--claude-in-chrome-mcp") { continue }

            let sessionId = parseResumeSessionId(from: args)
            let cwd: String? = sessionId == nil ? getCwd(for: pid) : nil

            results.append(ClaudeProcess(pid: pid, sessionId: sessionId, cwd: cwd))
        }

        return results
    }

    // MARK: - Matching

    private static func matchToSessions(
        processes: [ClaudeProcess],
        sessions: [Session]
    ) -> [String: [pid_t]] {
        var result: [String: [pid_t]] = [:]

        // 1. Direct match via --resume <session-id>
        let sessionIds = Set(sessions.map(\.sessionId))
        var matchedPids = Set<pid_t>()
        for proc in processes {
            if let sid = proc.sessionId, sessionIds.contains(sid) {
                result[sid] = [proc.pid]
                matchedPids.insert(proc.pid)
            }
        }

        // 2. Fallback: match by cwd for processes without --resume
        // Group unmatched processes by cwd
        var processesByCwd: [String: [pid_t]] = [:]
        for proc in processes where proc.sessionId == nil && !matchedPids.contains(proc.pid) {
            guard let cwd = proc.cwd else { continue }
            processesByCwd[cwd, default: []].append(proc.pid)
        }

        // Assign all matching PIDs to each unmatched session with that cwd
        for session in sessions where result[session.sessionId] == nil && !session.cwd.isEmpty {
            if let pids = processesByCwd[session.cwd] {
                result[session.sessionId] = pids
            }
        }

        return result
    }

    // MARK: - Helpers

    private static func parseResumeSessionId(from args: String) -> String? {
        guard let range = args.range(of: "--resume ") else { return nil }
        let rest = args[range.upperBound...]
        let token = rest.prefix(while: { !$0.isWhitespace })
        return token.isEmpty ? nil : String(token)
    }

    private static func getCwd(for pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size))
        guard ret == size else { return nil }
        return withUnsafePointer(to: info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cpath in
                String(cString: cpath)
            }
        }
    }
}
