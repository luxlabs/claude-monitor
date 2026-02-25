import Foundation

struct UsageWindow: Codable {
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

    var formattedResetTime: String? {
        guard let date = resetDate else { return nil }
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
}

struct UsageResponse: Codable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDaySonnet: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}
