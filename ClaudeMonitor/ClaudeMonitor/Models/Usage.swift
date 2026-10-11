import Foundation

/// Shared helper: format the time remaining until an ISO-8601 reset instant.
func formattedResetInterval(_ resetsAt: String?) -> String? {
    guard let resetsAt, let date = ISOTime.date(resetsAt) else { return nil }
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

struct UsageWindow: Decodable, Equatable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        return ISOTime.date(resetsAt)
    }

    var formattedResetTime: String? { formattedResetInterval(resetsAt) }
}

/// One entry of the modern `limits[]` array the usage API now returns. It
/// supersedes the flat `five_hour`/`seven_day` windows and adds the
/// model-scoped weekly limit (`weekly_scoped`) plus a `severity` signal.
struct UsageLimit: Decodable, Equatable {
    /// What a limit applies to; only the model's display name is used.
    struct Scope: Decodable, Equatable {
        /// `scope.model.display_name`, e.g. "Fable".
        let modelDisplayName: String?

        private enum CodingKeys: String, CodingKey { case model }
        private enum ModelKeys: String, CodingKey { case displayName = "display_name" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let model = try? c.nestedContainer(keyedBy: ModelKeys.self, forKey: .model)
            modelDisplayName = (try? model?.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        }
    }

    let kind: String
    let group: String?
    let percent: Int
    let severity: String?
    let resetsAt: String?
    let isActive: Bool?
    /// Null for most limits; set for model-scoped ones (`weekly_scoped`).
    let scope: Scope?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        group = try? c.decodeIfPresent(String.self, forKey: .group)
        percent = try c.decode(Int.self, forKey: .percent)
        severity = try? c.decodeIfPresent(String.self, forKey: .severity)
        resetsAt = try? c.decodeIfPresent(String.self, forKey: .resetsAt)
        isActive = try? c.decodeIfPresent(Bool.self, forKey: .isActive)
        // Lenient: an unexpected shape reads as "no scope" instead of failing the limit.
        scope = (try? c.decodeIfPresent(Scope.self, forKey: .scope)) ?? nil
    }

    /// Human label, e.g. "Week (Fable)" for a model-scoped weekly limit.
    var label: String {
        Labels.limitLabel(kind: kind, scopedModelName: scope?.modelDisplayName)
    }

    var formattedResetTime: String? { formattedResetInterval(resetsAt) }
}

/// Pay-as-you-go "extra usage" credits block.
struct ExtraUsage: Decodable, Equatable {
    let isEnabled: Bool
    let utilization: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case utilization
        case currency
    }
}

/// The newer `spend` block (usage credits); every field is optional.
struct SpendUsage: Decodable, Equatable {
    let percent: Int?
    let severity: String?
    let enabled: Bool?

    enum CodingKeys: String, CodingKey {
        case percent, severity, enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? c.decodeIfPresent(Int.self, forKey: .percent) {
            percent = value
        } else if let value = try? c.decodeIfPresent(Double.self, forKey: .percent), value.isFinite {
            percent = Int(value.rounded())
        } else {
            percent = nil
        }
        severity = try? c.decodeIfPresent(String.self, forKey: .severity)
        enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
    }
}

struct UsageResponse: Decodable, Equatable {
    // Legacy flat windows — still returned; used as a fallback when `limits` is absent.
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    // Modern canonical representation.
    let limits: [UsageLimit]?
    let extraUsage: ExtraUsage?
    let spend: SpendUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case limits
        case extraUsage = "extra_usage"
        case spend
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
        spend = (try? c.decodeIfPresent(SpendUsage.self, forKey: .spend)) ?? nil
    }
}
