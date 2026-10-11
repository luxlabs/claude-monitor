import Foundation
import AppKit
import os.log

private let log = Logger(subsystem: "com.mitobit.ClaudeMonitor", category: "SessionStore")

/// One row of the session table: a hook session, a live session, or both.
struct DisplayRow: Identifiable, Equatable {
    /// The session id.
    let id: String
    /// Hook state; nil for an untracked live session (no hook file).
    let session: Session?
    /// Live data; nil when the session is absent from the latest snapshot.
    let live: LiveEntry?
    let effective: EffectiveState
    /// The session's exact process, from the live data.
    let pid: pid_t?

    init(session: Session?, live: LiveEntry?, effective: EffectiveState) {
        self.id = session?.sessionId ?? live?.sessionId ?? ""
        self.session = session
        self.live = live
        self.effective = effective
        self.pid = live?.pid
    }

    var status: SessionStatus { effective.status }

    var cwd: String {
        if let cwd = session?.cwd, !cwd.isEmpty { return cwd }
        return live?.cwd ?? ""
    }

    /// The hook's project name; for untracked sessions the cwd's basename.
    var project: String {
        if let project = session?.project, !project.isEmpty { return project }
        let cwd = self.cwd
        return cwd.isEmpty ? "-" : (cwd as NSString).lastPathComponent
    }

    var startDate: Date? {
        if let start = session?.startDate { return start }
        guard let started = live?.startedAt, started > 0 else { return nil }
        return Date(timeIntervalSince1970: started)
    }

    /// Sort key: last hook activity (unknown, i.e. 0, for untracked rows; as in the TUI).
    var activityTs: Double {
        session?.activityTs ?? 0
    }

    /// PERMISSION, then THINKING/EXECUTING/COMPACTING, BACKGROUND, STARTING,
    /// WAITING; then most recent activity first.
    static func displayOrder(_ a: DisplayRow, _ b: DisplayRow) -> Bool {
        if a.status.sortRank != b.status.sortRank { return a.status.sortRank < b.status.sortRank }
        if a.activityTs != b.activityTs { return a.activityTs > b.activityTs }
        return a.id < b.id
    }
}

@Observable
@MainActor
final class SessionStore {
    /// Displayed rows, sorted.
    private(set) var rows: [DisplayRow] = []
    /// Sessions that entered WAITING (after real work) since the app was last focused.
    private(set) var waitingSessions: Set<String> = []
    private(set) var usage: UsageResponse?
    private(set) var ideInfoBySessionId: [String: IdeInfo] = [:]
    /// False until the first live poll has completed.
    private(set) var hasPolledOnce = false
    /// Where the latest live data came from (nil until a poll succeeds).
    private(set) var liveSource: LiveSnapshot.Source?

    /// Also show sessions idle for over 4 hours (persisted).
    var showAll: Bool = UserDefaults.standard.bool(forKey: showAllDefaultsKey) {
        didSet {
            guard showAll != oldValue else { return }
            UserDefaults.standard.set(showAll, forKey: showAllDefaultsKey)
            refreshRows()
        }
    }

    var waitingCount: Int { waitingSessions.count }

    var statusCounts: [SessionStatus: Int] {
        var counts: [SessionStatus: Int] = [:]
        for row in rows {
            counts[row.status, default: 0] += 1
        }
        return counts
    }

    /// Some rows only have hook data: live status is unavailable or stale.
    var isLiveOff: Bool {
        hasPolledOnce && rows.contains { $0.effective.legacy }
    }

    private static let activePollInterval: TimeInterval = 5
    private static let idlePollInterval: TimeInterval = 30
    /// Kicks (directory changes, app activation) bring the next poll forward
    /// but never poll more often than this: hooks write continuously while
    /// sessions work, and each poll spawns a `claude` process.
    private static let kickMinInterval: TimeInterval = activePollInterval
    private static let hiddenProjects: Set<String> = ["ClaudeProbe"]
    /// Entering WAITING from these is a finished turn: worth a badge.
    private static let badgeSources: Set<SessionStatus> = [.thinking, .executing, .background, .compacting, .permission]

    private let live = LiveSessions()
    @ObservationIgnored private var hookSessions: [Session] = []
    /// Latest live snapshot. A failed poll keeps the previous one: it ages
    /// out by itself (Merge falls back to hooks-only after 15 s).
    @ObservationIgnored private var snapshot: LiveSnapshot?
    @ObservationIgnored private var lastPollFailed = false
    /// File URL → (modDate, parsed session): only changed files are re-read.
    @ObservationIgnored private var sessionCache: [URL: (modDate: Date, session: Session)] = [:]
    /// usage.json is only re-read when its modDate changes.
    @ObservationIgnored private var usageModDate: Date?

    @ObservationIgnored private var previousStatuses: [String: SessionStatus] = [:]
    /// Transitions are detected only once a live poll set the baseline.
    @ObservationIgnored private var transitionsArmed = false
    @ObservationIgnored private var attentionRequests: [String: Int] = [:]

    @ObservationIgnored private var ideLockEntries: [(lockFile: IdeLockFile, modDate: Date)] = []
    @ObservationIgnored private var monitor: DirectoryMonitor?
    @ObservationIgnored private var ideMonitor: DirectoryMonitor?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var nextPollTask: Task<Void, Never>?
    @ObservationIgnored private var nextPollDue: Date = .distantFuture
    @ObservationIgnored private var lastPollStarted: Date = .distantPast

    private let sessionsURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: ".claude/monitor/sessions")
    }()

    private let usageURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: ".claude/monitor/usage.json")
    }()

    private let ideURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: ".claude/ide")
    }()

    init() {
        startMonitoring()
    }

    func startMonitoring() {
        // Guard against double-call: drop existing monitors and timers first.
        stopMonitoring()

        ensureDirectory()
        reloadIdeLockFiles()
        loadHookFiles()
        recompute()  // hooks-only until the first poll lands

        monitor = DirectoryMonitor(url: sessionsURL, interval: 1.0) { [weak self] in
            Task { @MainActor [weak self] in
                self?.sessionsDirectoryChanged()
            }
        }

        ideMonitor = DirectoryMonitor(url: ideURL) { [weak self] in
            Task { @MainActor [weak self] in
                self?.reloadIdeLockFiles()
                self?.matchSessionsToIdes()
            }
        }

        startPoll()
    }

    private func stopMonitoring() {
        cancelScheduledPoll()
        monitor = nil
        ideMonitor = nil
    }

    /// The app came to the front: clear the badge, poll at the fast cadence.
    func appDidBecomeActive() {
        resetWaitingCount()
        kickPoll()
    }

    func resetWaitingCount() {
        if !waitingSessions.isEmpty {
            waitingSessions.removeAll()
        }
        updateBadge()
    }

    private func updateBadge() {
        NSApp?.dockTile.badgeLabel = waitingSessions.isEmpty ? "" : "\(waitingSessions.count)"
    }

    // MARK: - Hook files

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
    }

    private func sessionsDirectoryChanged() {
        loadHookFiles()
        refreshRows()
        kickPoll()
    }

    /// Rebuild the rows now, unless the snapshot merely aged between
    /// idle-cadence polls: then poll first (its completion rebuilds), since a
    /// stale snapshot would flip every row to hooks-only mode and back and
    /// fire spurious badge/bounce transitions.
    private func refreshRows() {
        let now = Date().timeIntervalSince1970
        let stale = snapshot.map { now - $0.observedAt > Merge.snapshotMaxAge } ?? false
        if stale && !lastPollFailed {
            schedulePoll(after: 0)
        } else {
            recompute()  // fresh, not polled yet, or live data really unavailable
        }
    }

    /// Read every session file (re-parsing only changed ones). Pure read:
    /// files are never deleted here; the hooks garbage-collect them.
    private func loadHookFiles() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []

        var currentFiles = Set<URL>()
        var loaded: [String: Session] = [:]
        for file in files where file.pathExtension == "json" {
            // Modification date from the directory listing (no extra syscall).
            guard let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                continue
            }
            currentFiles.insert(file)

            let session: Session
            if let cached = sessionCache[file], cached.modDate == modDate {
                session = cached.session
            } else {
                guard let data = try? Data(contentsOf: file),
                      let decoded = try? Session.decode(data, fallbackId: file.deletingPathExtension().lastPathComponent)
                else {
                    sessionCache.removeValue(forKey: file)
                    continue
                }
                sessionCache[file] = (modDate: modDate, session: decoded)
                session = decoded
            }
            if let other = loaded[session.sessionId], other.activityTs >= session.activityTs {
                continue
            }
            loaded[session.sessionId] = session
        }

        // Evict cache entries for deleted files.
        if sessionCache.count > currentFiles.count + 10 {
            sessionCache = sessionCache.filter { currentFiles.contains($0.key) }
        }
        hookSessions = Array(loaded.values)
        readUsage()
    }

    private func readUsage() {
        guard let modDate = (try? usageURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              modDate != usageModDate else { return }
        usageModDate = modDate
        if let data = try? Data(contentsOf: usageURL),
           let decoded = try? JSONDecoder().decode(UsageResponse.self, from: data),
           decoded != usage {
            usage = decoded
        }
    }

    // MARK: - Rows

    /// Merge hook state with the latest live snapshot into display rows.
    private func recompute() {
        let now = Date().timeIntervalSince1970
        let observedAt = snapshot?.observedAt
        let entries = snapshot?.entries ?? [:]

        var built: [DisplayRow] = []
        var tracked = Set<String>()
        for session in hookSessions {
            tracked.insert(session.sessionId)
            let entry = entries[session.sessionId]
            let effective = Merge.effective(hook: session, live: entry, observedAt: observedAt, now: now)
            built.append(DisplayRow(session: session, live: entry, effective: effective))
        }
        for (sessionId, entry) in entries where !tracked.contains(sessionId) {
            let effective = Merge.effective(hook: nil, live: entry, observedAt: observedAt, now: now)
            built.append(DisplayRow(session: nil, live: entry, effective: effective))
        }
        built.removeAll { row in
            row.effective.hidden
                || (row.effective.staleIdle && !showAll)
                || Self.hiddenProjects.contains(row.project)
        }
        built.sort(by: DisplayRow.displayOrder)

        if transitionsArmed {
            detectTransitions(built)
        }
        previousStatuses = Dictionary(built.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        if hasPolledOnce {
            transitionsArmed = true  // the first poll's statuses are the baseline
        }

        // Only mutate observed state when something changed (no needless redraws).
        if built != rows {
            rows = built
        }

        // Always re-match IDEs: an IDE may have launched or quit without its
        // lock file changing. The equality guard inside avoids spurious writes.
        matchSessionsToIdes()
    }

    private func detectTransitions(_ newRows: [DisplayRow]) {
        var waiting = waitingSessions
        var present = Set<String>()
        for row in newRows {
            present.insert(row.id)
            let previous = previousStatuses[row.id]
            let status = row.status

            // Entering PERMISSION -> dock bounce; leaving it -> cancel the bounce.
            if status == .permission && previous != .permission {
                if let requestId = NSApp?.requestUserAttention(.criticalRequest) {
                    attentionRequests[row.id] = requestId
                }
            } else if status != .permission, let requestId = attentionRequests.removeValue(forKey: row.id) {
                NSApp?.cancelUserAttentionRequest(requestId)
            }

            // A turn finished (WAITING after real work) -> badge + highlight;
            // not on first appearance and not from STARTING.
            if status == .waiting {
                if let previous, Self.badgeSources.contains(previous) {
                    waiting.insert(row.id)
                }
            } else {
                waiting.remove(row.id)
            }
        }

        // Rows that disappeared no longer need attention.
        for (sessionId, requestId) in attentionRequests where !present.contains(sessionId) {
            NSApp?.cancelUserAttentionRequest(requestId)
            attentionRequests.removeValue(forKey: sessionId)
        }
        waiting.formIntersection(present)

        if waiting != waitingSessions {
            waitingSessions = waiting
            updateBadge()
        }
    }

    // MARK: - Live polling

    /// 5 s while something is active or the app is frontmost, else 30 s.
    private var pollInterval: TimeInterval {
        let frontmost = NSApp?.isActive ?? false
        let anyActive = rows.contains { $0.status.isActive }
        return frontmost || anyActive ? Self.activePollInterval : Self.idlePollInterval
    }

    /// Start a poll unless one is in flight (never more than one).
    private func startPoll() {
        guard pollTask == nil else { return }
        cancelScheduledPoll()
        lastPollStarted = .now
        let live = self.live
        pollTask = Task { [weak self] in
            let snapshot = await live.poll()  // runs off the main actor
            self?.finishPoll(snapshot)
        }
    }

    private func finishPoll(_ snapshot: LiveSnapshot?) {
        pollTask = nil
        lastPollFailed = snapshot == nil
        if let snapshot {
            self.snapshot = snapshot
            if liveSource != snapshot.source {
                liveSource = snapshot.source
            }
        }
        if !hasPolledOnce {
            hasPolledOnce = true
        }
        loadHookFiles()  // also a safety net for missed directory events
        recompute()
        schedulePoll(after: pollInterval)
    }

    /// Poll after `delay` unless a poll is already scheduled sooner.
    private func schedulePoll(after delay: TimeInterval) {
        let delay = max(0, delay)
        let due = Date.now.addingTimeInterval(delay)
        if nextPollTask != nil && nextPollDue <= due { return }
        nextPollTask?.cancel()
        nextPollDue = due
        nextPollTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            self.nextPollTask = nil
            self.nextPollDue = .distantFuture
            self.startPoll()  // if one is in flight, its completion schedules the next
        }
    }

    private func cancelScheduledPoll() {
        nextPollTask?.cancel()
        nextPollTask = nil
        nextPollDue = .distantFuture
    }

    /// Throttled "poll soon" (directory changes, app activation).
    private func kickPoll() {
        schedulePoll(after: Self.kickMinInterval - Date.now.timeIntervalSince(lastPollStarted))
    }

    /// A snapshot taken after this call (waits for any poll in flight, then
    /// polls); nil if that poll failed.
    private func pollNow() async -> LiveSnapshot? {
        while let inFlight = pollTask {
            await inFlight.value
        }
        startPoll()
        if let task = pollTask {
            await task.value
        }
        return lastPollFailed ? nil : snapshot
    }

    // MARK: - Actions

    /// The shell command that resumes a session.
    func resumeCommand(for sessionId: String) -> String {
        "claude --resume \(sessionId)"
    }

    /// Stop (`claude stop` for a background session), terminate (SIGTERM) or
    /// force-kill (SIGKILL) the session's process. A fresh poll must still
    /// list the session with the same pid (and job), else nothing is sent.
    func stop(sessionId: String, expected: LiveEntry, force: Bool) {
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.pollNow()
            guard let current = snapshot?.entries[sessionId],
                  current.pid == expected.pid,
                  current.jobId == expected.jobId else {
                log.notice("Not stopping \(sessionId, privacy: .public): its live entry changed")
                NSSound.beep()
                return
            }
            let result = await self.live.stop(entry: current, force: force)
            if case .failed(let message) = result {
                log.error("Stopping \(sessionId, privacy: .public) failed: \(message, privacy: .public)")
                NSSound.beep()
            }
            // Re-poll once the process had a moment to exit.
            try? await Task.sleep(for: .seconds(1))
            self.schedulePoll(after: 0)
        }
    }

    // MARK: - IDE Lock Files

    private func reloadIdeLockFiles() {
        let fm = FileManager.default
        let decoder = JSONDecoder()

        guard let files = try? fm.contentsOfDirectory(
            at: ideURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            ideLockEntries = []
            return
        }

        let lockFiles = files.filter { $0.pathExtension == "lock" }
        var entries: [(lockFile: IdeLockFile, modDate: Date)] = []

        for file in lockFiles {
            guard let data = try? Data(contentsOf: file),
                  let lockFile = try? decoder.decode(IdeLockFile.self, from: data) else {
                continue
            }
            let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            entries.append((lockFile: lockFile, modDate: modDate))
        }

        ideLockEntries = entries
    }

    private func matchSessionsToIdes() {
        var result: [String: IdeInfo] = [:]

        // Batch-cache NSRunningApplication lookups: one syscall per unique PID
        // instead of O(sessions × lockEntries × folders).
        var runningApps: [pid_t: NSRunningApplication] = [:]
        for entry in ideLockEntries {
            let pid = entry.lockFile.pid
            if runningApps[pid] == nil {
                runningApps[pid] = NSRunningApplication(processIdentifier: pid)
            }
        }

        // Cache icons by bundle path to avoid repeated NSWorkspace.icon(forFile:) disk reads
        var iconCache: [String: NSImage] = [:]

        for row in rows {
            let cwd = row.cwd
            guard !cwd.isEmpty else { continue }

            // Find all lock file entries whose workspace folder is a prefix of the cwd
            var candidates: [(lockFile: IdeLockFile, modDate: Date, folder: String, isRunning: Bool)] = []
            for entry in ideLockEntries {
                for folder in entry.lockFile.workspaceFolders {
                    if cwd == folder || cwd.hasPrefix(folder + "/") {
                        candidates.append((lockFile: entry.lockFile, modDate: entry.modDate, folder: folder, isRunning: runningApps[entry.lockFile.pid] != nil))
                    }
                }
            }

            guard let best = candidates.sorted(by: { a, b in
                // Prefer longest matching prefix (most specific)
                if a.folder.count != b.folder.count { return a.folder.count > b.folder.count }
                // Then most recently modified lock file
                if a.modDate != b.modDate { return a.modDate > b.modDate }
                // Then prefer running process
                return a.isRunning && !b.isRunning
            }).first else { continue }

            let runningApp = runningApps[best.lockFile.pid]
            let bundlePath = runningApp?.bundleURL?.path
            let icon: NSImage
            if let path = bundlePath {
                if let cached = iconCache[path] {
                    icon = cached
                } else {
                    icon = NSWorkspace.shared.icon(forFile: path)
                    iconCache[path] = icon
                }
            } else {
                icon = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
            }

            result[row.id] = IdeInfo(
                ideName: best.lockFile.ideName,
                pid: best.lockFile.pid,
                isRunning: best.isRunning,
                workspaceFolder: best.folder,
                appBundlePath: bundlePath,
                appIcon: icon
            )
        }

        if result != ideInfoBySessionId {
            ideInfoBySessionId = result
        }
    }

    // MARK: - IDE Window Activation

    func activateIdeWindow(for sessionId: String) {
        guard let ide = ideInfoBySessionId[sessionId] else {
            NSSound.beep()
            return
        }

        guard let app = NSRunningApplication(processIdentifier: ide.pid),
              let bundleURL = app.bundleURL else {
            NSSound.beep()
            return
        }

        // Open the workspace folder with the specific IDE app.
        // IDEs like VS Code focus the existing window for that folder
        // instead of opening a new one.
        let folderURL = URL(fileURLWithPath: ide.workspaceFolder)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([folderURL], withApplicationAt: bundleURL, configuration: config)
    }
}

private let showAllDefaultsKey = "showIdleSessions"
