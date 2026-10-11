import Foundation

/// One live session as listed by `claude agents --json` (or, as a fallback,
/// by Claude Code's per-process registry). Mirrors `live.LiveEntry`.
struct LiveEntry: Decodable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case interactive
        case background
    }

    let sessionId: String
    let pid: pid_t?
    /// busy | waiting | idle (while the process is alive)
    let status: String?
    /// e.g. "permission prompt", "input needed", "dialog open"
    let waitingFor: String?
    let kind: Kind
    /// Background short id, for `claude stop <id>`.
    let jobId: String?
    /// Background: working | blocked | done | failed | stopped
    let state: String?
    let name: String
    let cwd: String
    /// Epoch seconds.
    let startedAt: Double

    init(
        sessionId: String,
        pid: pid_t? = nil,
        status: String? = nil,
        waitingFor: String? = nil,
        kind: Kind = .interactive,
        jobId: String? = nil,
        state: String? = nil,
        name: String = "",
        cwd: String = "",
        startedAt: Double = 0
    ) {
        self.sessionId = sessionId
        self.pid = pid
        self.status = status
        self.waitingFor = waitingFor
        self.kind = kind
        self.jobId = jobId
        self.state = state
        self.name = name
        self.cwd = cwd
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, pid, status, waitingFor, kind, id, state, name, cwd, startedAt
    }

    /// `LiveEntry.from_agents_json`; throws for an item without a session id.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let sid = try? c.decode(String.self, forKey: .sessionId), !sid.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .sessionId, in: c, debugDescription: "No sessionId")
        }
        sessionId = sid
        if let raw = try? c.decode(Int.self, forKey: .pid), raw > 0 {
            pid = pid_t(exactly: raw)
        } else {
            pid = nil
        }
        status = try? c.decode(String.self, forKey: .status)
        waitingFor = try? c.decode(String.self, forKey: .waitingFor)
        kind = (try? c.decode(String.self, forKey: .kind)) == "background" ? .background : .interactive
        jobId = try? c.decode(String.self, forKey: .id)
        state = try? c.decode(String.self, forKey: .state)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        cwd = (try? c.decode(String.self, forKey: .cwd)) ?? ""
        startedAt = (try? c.decode(Double.self, forKey: .startedAt)).map { $0 / 1000 } ?? 0
    }
}

/// One observation of the live sessions. Mirrors `live.Snapshot`.
struct LiveSnapshot: Equatable, Sendable {
    enum Source: String, Sendable {
        case agents  // `claude agents --json`
        case registry  // fallback: ~/.claude/sessions/<pid>.json
    }

    /// Epoch seconds at the start of the observation (freshness checks stay conservative).
    let observedAt: Double
    let entries: [String: LiveEntry]
    let source: Source

    /// `live.parse_agents_json`: nil unless the output is a JSON array.
    static func parse(agentsJSON data: Data, observedAt: Double) -> LiveSnapshot? {
        guard let items = try? JSONDecoder().decode([LossyLiveEntry].self, from: data) else {
            return nil
        }
        var entries: [String: LiveEntry] = [:]
        for case let entry? in items.map(\.entry) {
            // One conversation can briefly have two rows (e.g. a phantom twin
            // after backgrounding): prefer the one with a live process.
            if let prev = entries[entry.sessionId], !(prev.pid == nil && entry.pid != nil) {
                continue
            }
            entries[entry.sessionId] = entry
        }
        return LiveSnapshot(observedAt: observedAt, entries: entries, source: .agents)
    }
}

/// An array element that may not be a usable entry (not an object, no sessionId).
private struct LossyLiveEntry: Decodable {
    let entry: LiveEntry?

    init(from decoder: Decoder) throws {
        entry = try? LiveEntry(from: decoder)
    }
}

/// What to display for one session. Mirrors `live.Effective`.
struct EffectiveState: Equatable, Sendable {
    let status: SessionStatus
    /// e.g. "permission prompt" from waitingFor
    var detail: String? = nil
    /// Not shown at all (presumed dead).
    var hidden: Bool = false
    /// No fresh live data: hooks-only mode.
    var legacy: Bool = false
    /// Live session with no hook state file.
    var untracked: Bool = false
    /// Idle for a long time: hidden unless "show all".
    var staleIdle: Bool = false
}

/// The merge of hook state with live data; a line-by-line port of
/// `live.effective()`, checked against `tests/fixtures/merge_cases.json`.
enum Merge {
    /// Live data must postdate the hook's last transition by this much.
    static let freshMargin: Double = 2.0
    /// Older snapshots are ignored (hooks-only mode).
    static let snapshotMaxAge: Double = 15.0
    /// Hook activity this recent keeps an unlisted session visible.
    static let absentGrace: Double = 90.0
    /// BACKGROUND with no agent activity for 30 min shows as WAITING.
    static let backgroundDecay: Double = 1800.0
    /// Idle sessions older than this are hidden unless "show all".
    static let idleHideAfter: Double = 4 * 3600.0
    /// Hooks-only mode: an active status this old is presumed dead.
    static let legacyActiveHide: Double = 3600.0
    static let pollTimeout: Double = 5.0

    private static let legacyActive: Set<SessionStatus> = [.thinking, .executing, .permission, .starting, .compacting]

    static func liveOnlyStatus(_ live: LiveEntry) -> SessionStatus {
        if live.status == "waiting" {
            return live.waitingFor == "dialog open" ? .waiting : .permission
        }
        if live.status == "busy" {
            return .thinking
        }
        if live.status == "idle" {
            return .waiting
        }
        if live.state == "blocked" {
            return .permission
        }
        if live.state == "working" {
            return .thinking
        }
        return .waiting
    }

    /// The status to display for one session (see the README's merge table).
    static func effective(hook: Session?, live: LiveEntry?, observedAt: Double?, now: Double) -> EffectiveState {
        guard let hook else {
            guard let live else {
                return EffectiveState(status: .waiting, hidden: true)
            }
            let status = liveOnlyStatus(live)
            return EffectiveState(
                status: status,
                detail: status == .permission ? live.waitingFor : nil,
                untracked: true,
                staleIdle: status == .waiting  // idle for an unknown time
            )
        }

        func result(_ status: SessionStatus, _ detail: String? = nil, hidden: Bool = false, legacy: Bool = false) -> EffectiveState {
            let age = now - hook.activityTs
            var hidden = hidden
            if legacy && legacyActive.contains(status) && age > legacyActiveHide {
                hidden = true
            }
            return EffectiveState(
                status: status, detail: detail, hidden: hidden, legacy: legacy,
                staleIdle: status == .waiting && age > idleHideAfter
            )
        }

        var base = hook.baseStatus
        if base == .background && now - hook.activityTs > backgroundDecay {
            base = .waiting
        }
        let hookStatus: SessionStatus = hook.pending.isEmpty ? base : .permission

        guard let observedAt, now - observedAt <= snapshotMaxAge else {
            return result(hookStatus, legacy: true)
        }
        guard let live else {
            return result(hookStatus, hidden: now - hook.activityTs >= absentGrace)
        }

        let latest = ([hook.statusTs] + hook.pending.values.map(\.since)).max() ?? hook.statusTs
        if observedAt <= latest + freshMargin {
            return result(hookStatus)  // live data predates the hook's last change
        }

        if live.status == "waiting" {
            if live.waitingFor != "dialog open" {  // a dialog the user opened isn't a request
                return result(.permission, live.waitingFor)
            }
            return result(hookStatus)
        }
        if live.status == "idle" {
            if [.thinking, .executing, .starting, .compacting].contains(base) {
                return result(.waiting)  // e.g. Esc: the turn ended without a Stop hook
            }
            return result(base)  // pending prompts were answered: Claude Code isn't waiting
        }
        if live.status == "busy" {
            if base == .waiting || base == .starting {
                return result(.thinking)  // work started without a prompt (/loop, auto-continue…)
            }
            return result(base)
        }
        if live.state == "blocked" {
            return result(.permission, live.waitingFor)
        }
        return result(hookStatus)
    }
}
