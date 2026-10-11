import Foundation

/// Display labels; mirrors `src/claude_monitor/labels.py`. Both are checked
/// against `tests/fixtures/labels.json`.
enum Labels {
    static let modelFamilies = ["opus", "sonnet", "haiku", "fable", "mythos"]

    // "claude-opus-5-5[1m]" -> opus 5.5; the look-aheads stop a date suffix such
    // as "-20250514" from being read as a minor version.
    private static let modelRegex = try! NSRegularExpression(
        pattern: #"(opus|sonnet|haiku|fable|mythos)-(\d{1,2})(?!\d)(?:-(\d{1,2})(?!\d))?"#
    )
    // Pre-4 ids put the version first: "claude-3-5-sonnet-20241022".
    private static let legacyModelRegex = try! NSRegularExpression(
        pattern: #"claude-(\d)(?:-(\d))?-(opus|sonnet|haiku)"#
    )

    static let modeLabels: [String: String] = [
        "default": "manual",  // shown as "Manual" by Claude Code itself
        "plan": "plan",
        "acceptEdits": "accept",
        "auto": "auto",
        "dontAsk": "dontAsk",  // its own locked-down mode, not an alias of auto
        "bypassPermissions": "bypass",
    ]

    /// Family plus version, e.g. `claude-opus-5-5[1m]` -> `opus 5.5`.
    static func shortModel(_ model: String) -> String {
        if model.isEmpty { return "-" }
        let lowered = model.lowercased()
        if let g = firstMatch(modelRegex, in: lowered) {
            return version(family: g[1], major: g[2], minor: g[3])
        }
        if let g = firstMatch(legacyModelRegex, in: lowered) {
            return version(family: g[3], major: g[1], minor: g[2])
        }
        for family in modelFamilies where lowered.contains(family) {
            return family
        }
        return model
    }

    static func shortMode(_ mode: String) -> String {
        if mode.isEmpty { return "-" }
        return modeLabels[mode] ?? mode
    }

    /// Label for one entry of the usage API's `limits[]` array; a missing kind
    /// or scoped model name is passed as nil or "".
    static func limitLabel(kind: String?, scopedModelName: String?) -> String {
        let kind = kind ?? ""
        let scopedName = scopedModelName ?? ""
        switch kind {
        case "session": return "Session"
        case "weekly_all": return "Week"
        case "weekly_scoped": return scopedName.isEmpty ? "Week (model)" : "Week (\(scopedName))"
        case "spend_limit": return "Spend"
        case "": return "Limit"
        default: return capitalize(kind.replacingOccurrences(of: "_", with: " "))
        }
    }

    static func formatTokens(_ count: Int) -> String {
        if count <= 0 { return "-" }
        if count < 1000 { return String(count) }
        if count < 1_000_000 {
            // Half-up, like labels.py (which avoids Python's half-even round()).
            return "\(Int(Double(count) / 1000 + 0.5))k"
        }
        return String(format: "%.1fM", Double(count) / 1_000_000)
    }

    // MARK: - Helpers

    /// Python's `str.capitalize()`: first character titlecased (so "ß" -> "Ss",
    /// not "SS"), the rest lowercased. Not `.capitalized`, which capitalizes
    /// every word ("Monthly Credits").
    private static func capitalize(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).capitalized + text.dropFirst().lowercased()
    }

    private static func version(family: String?, major: String?, minor: String?) -> String {
        let family = family ?? ""
        let major = major ?? ""
        if let minor, !minor.isEmpty {
            return "\(family) \(major).\(minor)"
        }
        return "\(family) \(major)"
    }

    /// Capture groups of the first match (index 0 = whole match); nil groups
    /// for optional groups that did not participate.
    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> [String?]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
