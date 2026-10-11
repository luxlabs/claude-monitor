import Foundation

struct Session: Codable, Identifiable, Equatable {
    let sessionId: String
    let cwd: String
    let project: String
    var status: String
    let toolName: String?
    let permissionMode: String
    let model: String
    let topic: String
    let title: String
    let lastPrompt: String
    let toolCount: Int
    let startedAt: String
    let lastUpdated: String
    let subagents: [Subagent]

    /// Pre-parsed dates — computed once at decode time, not on every access.
    /// ISO8601DateFormatter is extremely expensive (goes through ICU).
    let startDate: Date?
    let lastUpdatedDate: Date?

    var id: String { sessionId }

    var parsedStatus: SessionStatus {
        SessionStatus(rawValue: status) ?? .ended
    }

    var duration: TimeInterval? {
        guard let start = startDate else { return nil }
        return Date.now.timeIntervalSince(start)
    }

    var formattedLastUpdated: String {
        guard let date = lastUpdatedDate else { return "-" }
        return RelativeDateTimeFormatter.monitor.localizedString(for: date, relativeTo: Date.now)
    }

    var formattedDuration: String {
        guard let duration else { return "-" }
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        return String(format: "%dm %02ds", minutes, seconds)
    }

    var shortModel: String {
        if model.contains("opus") { return "opus" }
        if model.contains("sonnet") { return "sonnet" }
        if model.contains("haiku") { return "haiku" }
        if model.contains("fable") { return "fable" }
        return model
    }

    var shortMode: String {
        switch permissionMode {
        case "bypassPermissions": return "bypass"
        case "acceptEdits": return "accept"
        case "auto", "dontAsk": return "auto"  // dontAsk is the legacy name
        default: return permissionMode
        }
    }

    /// AI-generated session title when available, else the latest prompt/topic.
    var displayTopic: String { title.isEmpty ? topic : title }

    /// True for the 1M-context model variant (its id ends with "[1m]").
    var hasLargeContext: Bool { model.lowercased().contains("[1m]") }

    var isActive: Bool {
        parsedStatus != .ended
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case project
        case status
        case toolName = "tool_name"
        case permissionMode = "permission_mode"
        case model
        case topic
        case title
        case lastPrompt = "last_prompt"
        case toolCount = "tool_count"
        case startedAt = "started_at"
        case lastUpdated = "last_updated"
        case subagents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "STARTING"
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        lastPrompt = try c.decodeIfPresent(String.self, forKey: .lastPrompt) ?? ""
        toolCount = try c.decodeIfPresent(Int.self, forKey: .toolCount) ?? 0
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
        lastUpdated = try c.decodeIfPresent(String.self, forKey: .lastUpdated) ?? ""
        subagents = try c.decodeIfPresent([Subagent].self, forKey: .subagents) ?? []
        // Parse dates once at decode time (ISO8601DateFormatter is very expensive)
        startDate = ISO8601DateFormatter.flexible.date(from: startedAt)
        lastUpdatedDate = ISO8601DateFormatter.flexible.date(from: lastUpdated)
    }

    // Custom Equatable: exclude pre-parsed dates (derived from startedAt/lastUpdated)
    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.sessionId == rhs.sessionId
            && lhs.cwd == rhs.cwd
            && lhs.project == rhs.project
            && lhs.status == rhs.status
            && lhs.toolName == rhs.toolName
            && lhs.permissionMode == rhs.permissionMode
            && lhs.model == rhs.model
            && lhs.topic == rhs.topic
            && lhs.title == rhs.title
            && lhs.lastPrompt == rhs.lastPrompt
            && lhs.toolCount == rhs.toolCount
            && lhs.startedAt == rhs.startedAt
            && lhs.lastUpdated == rhs.lastUpdated
            && lhs.subagents == rhs.subagents
    }
}

struct Subagent: Codable, Identifiable, Equatable {
    let agentId: String
    let agentType: String
    let status: String
    let lastUpdated: String

    var id: String { agentId }

    var parsedStatus: SessionStatus {
        // Subagent statuses come as lowercase (e.g. "running") while
        // SessionStatus uses uppercase rawValues ("THINKING", "EXECUTING", …).
        // Map known subagent-specific values first, then try uppercase match.
        switch status.lowercased() {
        case "running": return .executing
        default: return SessionStatus(rawValue: status.uppercased()) ?? .ended
        }
    }

    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case agentType = "agent_type"
        case status
        case lastUpdated = "last_updated"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try c.decode(String.self, forKey: .agentId)
        agentType = try c.decodeIfPresent(String.self, forKey: .agentType) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "running"
        lastUpdated = try c.decodeIfPresent(String.self, forKey: .lastUpdated) ?? ""
    }
}

extension RelativeDateTimeFormatter {
    nonisolated(unsafe) static let monitor: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
