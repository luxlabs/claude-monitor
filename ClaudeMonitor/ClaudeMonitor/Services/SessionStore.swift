import Foundation
import AppKit

@Observable
@MainActor
final class SessionStore {
    private(set) var sessions: [Session] = []
    private(set) var waitingCount: Int = 0
    private(set) var waitingSessions: Set<String> = []
    private(set) var usage: UsageResponse?
    private(set) var ideInfoBySessionId: [String: IdeInfo] = [:]
    private(set) var pidsBySessionId: [String: [pid_t]] = [:]

    private var previousStates: [String: String] = [:]
    private var attentionRequests: [String: Int] = [:]
    private var ideLockEntries: [(lockFile: IdeLockFile, modDate: Date)] = []
    private var ideMonitor: DirectoryMonitor?

    /// Cache: file URL → (modDate, parsed session). Only re-read files whose modDate changed.
    private var sessionCache: [URL: (modDate: Date, session: Session)] = [:]

    /// Cache for usage.json — only re-read when file modDate changes.
    private var usageModDate: Date?

    var statusCounts: [SessionStatus: Int] {
        var counts: [SessionStatus: Int] = [:]
        for session in sessions {
            counts[session.parsedStatus, default: 0] += 1
        }
        return counts
    }
    private var didInitialLoad = false
    private var monitor: DirectoryMonitor?
    private var zombieTimer: Timer?

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

    /// After this interval in PERMISSION with no file updates,
    /// override to WAITING (handles ExitPlanMode dismissed without Stop event).
    private static let permissionOverrideInterval: TimeInterval = 90

    private func staleThreshold(for session: Session) -> TimeInterval {
        switch session.parsedStatus {
        case .waiting:
            return 4 * 60 * 60   // 4 ore — l'utente deve rispondere, teniamo visibile
        case .permission, .thinking, .executing, .starting:
            return 15 * 60       // 15 min — processo quasi certamente morto
        case .ended:
            return 24 * 60 * 60  // invariato — Claude scrive ENDED esplicitamente
        }
    }

    init() {
        startMonitoring()
    }

    func startMonitoring() {
        // Guard against double-call: invalidate existing timers/monitors first
        stopMonitoring()

        ensureDirectory()
        cleanupStaleFiles()
        reloadIdeLockFiles()
        reload()
        refreshProcessMappings()

        // File system monitors (debounced at 2s — with many active sessions,
        // shorter debounce causes too-frequent reloads)
        monitor = DirectoryMonitor(url: sessionsURL, debounce: 2.0) { [weak self] in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }

        ideMonitor = DirectoryMonitor(url: ideURL) { [weak self] in
            Task { @MainActor [weak self] in
                self?.reloadIdeLockFiles()
                self?.matchSessionsToIdes()
            }
        }

        // Slow timer for zombie cleanup, permission override, and process discovery.
        // Covers cases where the session file is NOT updated (so DirectoryMonitor won't fire).
        zombieTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reload()
                self?.refreshProcessMappings()
            }
        }
    }

    private func stopMonitoring() {
        zombieTimer?.invalidate()
        zombieTimer = nil
        monitor = nil
        ideMonitor = nil
    }

    func resetWaitingCount() {
        waitingCount = 0
        waitingSessions.removeAll()
        updateBadge()
    }

    private func updateBadge() {
        NSApp?.dockTile.badgeLabel = waitingCount > 0 ? "\(waitingCount)" : ""
    }

    // MARK: - Private

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
    }

    /// Delete session files older than 24h from disk.
    /// Keeps the directory small so contentsOfDirectory is fast.
    private func cleanupStaleFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let cutoff: TimeInterval = 24 * 60 * 60
        let now = Date.now
        for file in files where file.pathExtension == "json" {
            guard let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                continue
            }
            if now.timeIntervalSince(modDate) > cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    private func reload() {
        let fm = FileManager.default
        let decoder = JSONDecoder()

        guard let files = try? fm.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let maxStaleAge: TimeInterval = 24 * 60 * 60
        let now = Date.now

        // Build a set of current file URLs for cache cleanup
        var currentFiles = Set<URL>()

        var loaded: [Session] = []
        for file in files {
            guard file.pathExtension == "json" else { continue }

            // Get modification date from directory listing (free — no extra syscall)
            guard let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                continue
            }

            // Skip files older than max stale threshold without reading them
            if now.timeIntervalSince(modDate) > maxStaleAge { continue }

            currentFiles.insert(file)

            // Use cached session if file hasn't changed
            if let cached = sessionCache[file], cached.modDate == modDate {
                let session = cached.session
                if let updated = session.lastUpdatedDate,
                   now.timeIntervalSince(updated) > staleThreshold(for: session) {
                    continue
                }
                loaded.append(session)
                continue
            }

            // File is new or changed — read, parse, cache
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(Session.self, from: data) else {
                sessionCache.removeValue(forKey: file)
                continue
            }

            sessionCache[file] = (modDate: modDate, session: session)

            // Skip stale sessions (finer-grained per-status threshold)
            if let updated = session.lastUpdatedDate,
               now.timeIntervalSince(updated) > staleThreshold(for: session) {
                continue
            }

            loaded.append(session)
        }

        // Evict cache entries for deleted files
        if sessionCache.count > currentFiles.count + 10 {
            sessionCache = sessionCache.filter { currentFiles.contains($0.key) }
        }

        // Override stale PERMISSION → WAITING (handles ExitPlanMode
        // dismissed via Esc or "keep planning" without Stop event)
        for i in loaded.indices {
            guard loaded[i].parsedStatus == .permission,
                  let updated = loaded[i].lastUpdatedDate,
                  now.timeIntervalSince(updated) > Self.permissionOverrideInterval
            else { continue }
            loaded[i].status = SessionStatus.waiting.rawValue
        }

        // Hide ClaudeProbe sessions
        loaded.removeAll { $0.project == "ClaudeProbe" }

        // Sort: active first, then by lastUpdated descending
        loaded.sort { a, b in
            if a.isActive != b.isActive { return a.isActive }
            return a.lastUpdated > b.lastUpdated
        }

        // Detect transitions (skip on first load to avoid false positives)
        if didInitialLoad {
            detectTransitions(newSessions: loaded)
        }

        // Update previous states
        var newStates: [String: String] = [:]
        for session in loaded {
            newStates[session.sessionId] = session.status
        }
        previousStates = newStates
        didInitialLoad = true

        // Only mutate @Observable properties if data actually changed.
        // This prevents unnecessary SwiftUI view invalidation.
        if loaded.count != sessions.count || loaded != sessions {
            sessions = loaded
        }

        // Always re-match IDEs: even when sessions are unchanged, an IDE process
        // may have launched or crashed without its lock file being updated.
        // The equality guard inside matchSessionsToIdes() prevents spurious SwiftUI writes.
        matchSessionsToIdes()

        // Read usage data (only when file has changed)
        if let modDate = (try? usageURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           modDate != usageModDate {
            usageModDate = modDate
            if let data = try? Data(contentsOf: usageURL),
               let decoded = try? JSONDecoder().decode(UsageResponse.self, from: data) {
                if decoded != usage {
                    usage = decoded
                }
            }
        }

    }

    // MARK: - Process Discovery

    private func refreshProcessMappings() {
        let newMapping = ProcessDiscovery.pidsBySession(for: sessions)
        if newMapping != pidsBySessionId {
            pidsBySessionId = newMapping
        }
    }

    func killProcess(pid: pid_t, force: Bool) {
        kill(pid, force ? SIGKILL : SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshProcessMappings()
        }
    }

    private func detectTransitions(newSessions: [Session]) {
        for session in newSessions {
            let prev = previousStates[session.sessionId]

            // PERMISSION transition -> dock bounce + store request ID
            if session.status == SessionStatus.permission.rawValue && prev != SessionStatus.permission.rawValue {
                let requestId = NSApp?.requestUserAttention(.criticalRequest) ?? 0
                attentionRequests[session.sessionId] = requestId
            }

            // Exit PERMISSION -> cancel bounce
            if prev == SessionStatus.permission.rawValue && session.status != SessionStatus.permission.rawValue {
                if let requestId = attentionRequests.removeValue(forKey: session.sessionId) {
                    NSApp?.cancelUserAttentionRequest(requestId)
                }
            }

            // WAITING transition -> increment badge + highlight row
            if session.status == SessionStatus.waiting.rawValue && prev != SessionStatus.waiting.rawValue {
                waitingCount += 1
                waitingSessions.insert(session.sessionId)
                updateBadge()
            }

            // Exit WAITING -> decrement badge + remove highlight
            if prev == SessionStatus.waiting.rawValue && session.status != SessionStatus.waiting.rawValue {
                waitingCount = max(0, waitingCount - 1)
                waitingSessions.remove(session.sessionId)
                updateBadge()
            }
        }

        // Clean up attention requests for sessions that disappeared
        let currentIds = Set(newSessions.map(\.sessionId))
        for (sessionId, requestId) in attentionRequests where !currentIds.contains(sessionId) {
            NSApp?.cancelUserAttentionRequest(requestId)
            attentionRequests.removeValue(forKey: sessionId)
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

        for session in sessions {
            guard !session.cwd.isEmpty else { continue }

            // Find all lock file entries whose workspace folder is a prefix of session.cwd
            var candidates: [(lockFile: IdeLockFile, modDate: Date, folder: String, isRunning: Bool)] = []
            for entry in ideLockEntries {
                for folder in entry.lockFile.workspaceFolders {
                    if session.cwd == folder || session.cwd.hasPrefix(folder + "/") {
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

            result[session.sessionId] = IdeInfo(
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
