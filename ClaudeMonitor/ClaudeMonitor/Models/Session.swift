import Foundation

/// A permission prompt one agent ("main" or a subagent id) is waiting on.
struct PendingPrompt: Equatable, Sendable {
    let tool: String
    let fp: String
    let since: Double
}

/// Summary of the session's background tasks (`background` in the file).
struct BackgroundTasks: Equatable, Sendable {
    let active: Int
    let types: [String: Int]
}

/// One hook-written session file (`~/.claude/monitor/sessions/<id>.json`).
///
/// Decodes schema 2 and the legacy schema 1 exactly like
/// `SessionState.from_dict` in state.py.
struct Session: Decodable, Identifiable, Equatable, Sendable {
    let sessionId: String
    let cwd: String
    let project: String
    /// Main-agent status; PERMISSION is derived from `pending`, not stored here.
    let baseStatus: SessionStatus
    /// Last main-status transition (epoch seconds, event clock).
    let statusTs: Double
    /// Last event of any kind, main agent or subagent (epoch seconds).
    let activityTs: Double
    let toolName: String?
    let permissionMode: String
    let model: String
    let effort: String
    let contextTokens: Int
    let topic: String
    let lastPrompt: String
    let customTitle: String
    let aiTitle: String
    let toolCount: Int
    let startedAt: String
    /// Agent key ("main" or a subagent id) -> the prompt it waits on.
    let pending: [String: PendingPrompt]
    let lastError: String
    let background: BackgroundTasks
    let crons: Int
    let subagents: [Subagent]
    let subagentsOverflow: Int

    /// `startedAt` parsed once at decode time.
    let startDate: Date?

    var id: String { sessionId }

    // MARK: Derived

    /// PERMISSION while any agent waits on a prompt, else the main status.
    var status: SessionStatus {
        pending.isEmpty ? baseStatus : .permission
    }

    /// The user's custom title, else Claude Code's AI title.
    var title: String {
        customTitle.isEmpty ? aiTitle : customTitle
    }

    /// The session title when known, else the latest prompt.
    var displayTopic: String {
        title.isEmpty ? topic : title
    }

    var statusDate: Date? {
        statusTs > 0 ? Date(timeIntervalSince1970: statusTs) : nil
    }

    var activityDate: Date? {
        activityTs > 0 ? Date(timeIntervalSince1970: activityTs) : nil
    }

    // MARK: Decoding

    /// The file's object as in state.py's `from_dict(d, fallback_id)`.
    init(json d: [String: JSONValue], fallbackId: String = "") {
        let legacy = d["base_status"] == nil
        let activity = d["activity_ts"]?.numberValue ?? 0
        let lastTs = activity != 0 ? activity : Self.isoSeconds(d["last_updated"])

        var pending: [String: PendingPrompt] = [:]
        for (key, value) in d["pending"]?.objectValue ?? [:] {
            guard let p = value.objectValue else { continue }
            pending[key] = PendingPrompt(
                tool: p["tool"]?.stringValue ?? "",
                fp: p["fp"]?.stringValue ?? "",
                since: p["since"]?.numberValue ?? 0
            )
        }

        var base = d["base_status"]?.stringValue ?? ""
        if base.isEmpty {
            base = d["status"]?.stringValue ?? SessionStatus.starting.rawValue
        }
        if legacy && base == SessionStatus.permission.rawValue {
            // Schema-1 PERMISSION: keep it visible until the main agent moves on.
            base = (d["tool_name"]?.isTruthy ?? false)
                ? SessionStatus.executing.rawValue
                : SessionStatus.thinking.rawValue
            pending = ["main": PendingPrompt(tool: d["tool_name"]?.stringValue ?? "", fp: "", since: lastTs)]
        }
        let background = d["background"]?.objectValue ?? [:]

        let statusTs = d["status_ts"]?.numberValue ?? 0
        let started = d["started_at"]?.stringValue ?? ""

        let sid = d["session_id"]?.stringValue ?? ""
        sessionId = sid.isEmpty ? fallbackId : sid
        cwd = d["cwd"]?.stringValue ?? ""
        project = d["project"]?.stringValue ?? ""
        baseStatus = SessionStatus(lenient: base)
        self.statusTs = statusTs != 0 ? statusTs : lastTs
        activityTs = lastTs
        toolName = d["tool_name"]?.stringValue
        permissionMode = d["permission_mode"]?.stringValue ?? ""
        model = d["model"]?.stringValue ?? ""
        effort = d["effort"]?.stringValue ?? ""
        contextTokens = d["context_tokens"]?.intValue ?? 0
        topic = d["topic"]?.stringValue ?? ""
        lastPrompt = d["last_prompt"]?.stringValue ?? ""
        customTitle = d["custom_title"]?.stringValue ?? ""
        // Schema 1 stored the AI title in "title".
        let ai = d["ai_title"]?.stringValue ?? ""
        aiTitle = !ai.isEmpty ? ai : (legacy ? d["title"]?.stringValue ?? "" : "")
        toolCount = d["tool_count"]?.intValue ?? 0
        startedAt = started
        self.pending = pending
        lastError = d["last_error"]?.stringValue ?? ""
        var types: [String: Int] = [:]
        for (key, value) in background["types"]?.objectValue ?? [:] {
            types[key] = value.intValue ?? 0
        }
        self.background = BackgroundTasks(active: background["active"]?.intValue ?? 0, types: types)
        crons = d["crons"]?.intValue ?? 0
        subagents = (d["subagents"]?.arrayValue ?? []).compactMap { item in
            guard let sa = item.objectValue, sa["agent_id"]?.isTruthy == true else { return nil }
            return Subagent(json: sa)
        }
        subagentsOverflow = d["subagents_overflow"]?.intValue ?? 0
        startDate = ISOTime.date(started)
    }

    init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let object = value.objectValue else {
            throw DecodingError.typeMismatch(
                [String: JSONValue].self,
                .init(codingPath: decoder.codingPath, debugDescription: "A session file must be a JSON object")
            )
        }
        let fallback = decoder.userInfo[.sessionFallbackId] as? String ?? ""
        self.init(json: object, fallbackId: fallback)
    }

    /// Decode one session file; `fallbackId` (the file name) is used when the
    /// file has no `session_id`, like `read_session`/`list_sessions`.
    static func decode(_ data: Data, fallbackId: String) throws -> Session {
        let decoder = JSONDecoder()
        decoder.userInfo[.sessionFallbackId] = fallbackId
        return try decoder.decode(Session.self, from: data)
    }

    /// `parse_iso`: 0 when missing or invalid.
    static func isoSeconds(_ value: JSONValue?) -> Double {
        guard let text = value?.stringValue, !text.isEmpty else { return 0 }
        return ISOTime.parse(text) ?? 0
    }
}

extension CodingUserInfoKey {
    static let sessionFallbackId = CodingUserInfoKey(rawValue: "sessionFallbackId")!
}

/// A subagent row of a session (`subagents[]`).
struct Subagent: Identifiable, Equatable, Sendable {
    let agentId: String
    let agentType: String
    let description: String
    let toolName: String?
    let toolCount: Int
    let startedAt: String
    /// This agent's own clock (epoch seconds); legacy files: from `last_updated`.
    let ts: Double
    /// Derived by the writer from the session's pending map: "running" | "permission".
    let status: String

    var id: String { agentId }

    var parsedStatus: SessionStatus {
        status.lowercased() == "permission" ? .permission : .executing
    }

    /// `SubagentState.from_dict`, plus the legacy-compatible `status` field.
    init(json d: [String: JSONValue]) {
        let ts = d["ts"]?.numberValue ?? 0
        agentId = d["agent_id"]?.stringValue ?? ""
        agentType = d["agent_type"]?.stringValue ?? ""
        description = d["description"]?.stringValue ?? ""
        toolName = d["tool_name"]?.stringValue
        toolCount = d["tool_count"]?.intValue ?? 0
        startedAt = d["started_at"]?.stringValue ?? ""
        self.ts = ts != 0 ? ts : Session.isoSeconds(d["last_updated"])
        status = d["status"]?.stringValue ?? "running"
    }
}

/// "1h 05m" / "4m 09s", or "-" when unknown.
func formattedDuration(since start: Date?) -> String {
    guard let start else { return "-" }
    let duration = max(0, Date.now.timeIntervalSince(start))
    let hours = Int(duration) / 3600
    let minutes = (Int(duration) % 3600) / 60
    let seconds = Int(duration) % 60
    if hours > 0 {
        return String(format: "%dh %02dm", hours, minutes)
    }
    return String(format: "%dm %02ds", minutes, seconds)
}

/// "2 min. ago" style relative time, or "-" when unknown.
func formattedRelative(_ date: Date?) -> String {
    guard let date else { return "-" }
    return RelativeDateTimeFormatter.monitor.localizedString(for: date, relativeTo: Date.now)
}

extension RelativeDateTimeFormatter {
    nonisolated(unsafe) static let monitor: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
