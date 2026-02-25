import Foundation

struct Session: Codable, Identifiable {
    let sessionId: String
    let cwd: String
    let project: String
    let status: String
    let toolName: String?
    let permissionMode: String
    let model: String
    let topic: String
    let lastPrompt: String
    let toolCount: Int
    let startedAt: String
    let lastUpdated: String
    let subagents: [Subagent]

    var id: String { sessionId }

    var parsedStatus: SessionStatus {
        SessionStatus(rawValue: status) ?? .ended
    }

    var startDate: Date? {
        ISO8601DateFormatter.flexible.date(from: startedAt)
    }

    var lastUpdatedDate: Date? {
        ISO8601DateFormatter.flexible.date(from: lastUpdated)
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
        return model
    }

    var shortMode: String {
        switch permissionMode {
        case "bypassPermissions": return "bypass"
        case "acceptEdits": return "accept"
        case "dontAsk": return "auto"
        default: return permissionMode
        }
    }

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
        lastPrompt = try c.decodeIfPresent(String.self, forKey: .lastPrompt) ?? ""
        toolCount = try c.decodeIfPresent(Int.self, forKey: .toolCount) ?? 0
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
        lastUpdated = try c.decodeIfPresent(String.self, forKey: .lastUpdated) ?? ""
        subagents = try c.decodeIfPresent([Subagent].self, forKey: .subagents) ?? []
    }
}

struct Subagent: Codable, Identifiable {
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
