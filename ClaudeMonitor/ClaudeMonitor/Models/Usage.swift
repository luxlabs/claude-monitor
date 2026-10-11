import Foundation

/// Shared helper: format the time remaining until an ISO-8601 reset instant.
func formattedResetInterval(_ resetsAt: String?) -> String? {
    guard let resetsAt, let date = ISO8601DateFormatter.flexible.date(from: resetsAt) else { return nil }
    let remaining = date.timeIntervalSince(Date.now)
    guard remaining > 0 else { return nil }

    let totalMinutes = Int(remaining) / 60
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    let days = hours / 24
    let remainingHours = hours % 24

    if days > 0 {
        return remainingHours > 0 ? "\(days)d \(remainingHours)h" : "\(days)d"
    }
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
}

struct UsageWindow: Codable, Equatable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        return ISO8601DateFormatter.flexible.date(from: resetsAt)
    }

    var formattedResetTime: String? { formattedResetInterval(resetsAt) }
}

/// One entry of the modern `limits[]` array the usage API now returns. It
/// supersedes the flat `five_hour`/`seven_day` windows and adds the
/// model-scoped weekly limit (`weekly_scoped`) plus a `severity` signal.
struct UsageLimit: Codable, Equatable, Identifiable {
    let kind: String
    let group: String?
    let percent: Int
    let severity: String?
    let resetsAt: String?
    let isActive: Bool?

    var id: String { kind }

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    /// Human label for a limit kind.
    var label: String {
        switch kind {
        case "session": return "Session"
        case "weekly_all": return "Week"
        case "weekly_scoped": return "Week (Opus)"
        default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var formattedResetTime: String? { formattedResetInterval(resetsAt) }
}

/// Pay-as-you-go "extra usage" credits block.
struct ExtraUsage: Codable, Equatable {
    let isEnabled: Bool
    let utilization: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case utilization
        case currency
    }
}

struct UsageResponse: Codable, Equatable {
    // Legacy flat windows — still returned; used as a fallback when `limits` is absent.
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    // Modern canonical representation.
    let limits: [UsageLimit]?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case limits
        case extraUsage = "extra_usage"
    }

    // Decode each field independently so one malformed field (e.g. a new limit
    // shape) can never blank out the whole usage bar — the rest still renders.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = (try? c.decodeIfPresent(UsageWindow.self, forKey: .fiveHour)) ?? nil
        sevenDay = (try? c.decodeIfPresent(UsageWindow.self, forKey: .sevenDay)) ?? nil
        sevenDayOpus = (try? c.decodeIfPresent(UsageWindow.self, forKey: .sevenDayOpus)) ?? nil
        limits = (try? c.decodeIfPresent([UsageLimit].self, forKey: .limits)) ?? nil
        extraUsage = (try? c.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)) ?? nil
    }
}
