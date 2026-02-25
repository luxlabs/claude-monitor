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

    private var previousStates: [String: String] = [:]
    private var attentionRequests: [String: Int] = [:]
    private var ideLockEntries: [(lockFile: IdeLockFile, modDate: Date)] = []
    private var ideMonitor: DirectoryMonitor?

    var statusCounts: [SessionStatus: Int] {
        var counts: [SessionStatus: Int] = [:]
        for session in sessions {
            counts[session.parsedStatus, default: 0] += 1
        }
        return counts
    }
    private var didInitialLoad = false
    private var monitor: DirectoryMonitor?
    private var timer: Timer?

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
        ensureDirectory()
        reloadIdeLockFiles()
        reload()

        monitor = DirectoryMonitor(url: sessionsURL) { [weak self] in
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

        // Periodic refresh for duration timers and zombie cleanup
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
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

    private func reload() {
        let fm = FileManager.default
        let decoder = JSONDecoder()

        guard let files = try? fm.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let jsonFiles = files.filter { $0.pathExtension == "json" }

        var loaded: [Session] = []
        for file in jsonFiles {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(Session.self, from: data) else {
                continue
            }

            // Skip stale sessions
            if let updated = session.lastUpdatedDate,
               Date.now.timeIntervalSince(updated) > staleThreshold(for: session) {
                continue
            }

            loaded.append(session)
        }

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

        sessions = loaded
        matchSessionsToIdes()

        // Read usage data
        if let data = try? Data(contentsOf: usageURL),
           let decoded = try? JSONDecoder().decode(UsageResponse.self, from: data) {
            usage = decoded
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

        for session in sessions {
            guard !session.cwd.isEmpty else { continue }

            // Find all lock file entries whose workspace folder is a prefix of session.cwd
            var candidates: [(lockFile: IdeLockFile, modDate: Date, folder: String)] = []
            for entry in ideLockEntries {
                for folder in entry.lockFile.workspaceFolders {
                    if session.cwd == folder || session.cwd.hasPrefix(folder + "/") {
                        candidates.append((lockFile: entry.lockFile, modDate: entry.modDate, folder: folder))
                    }
                }
            }

            guard let best = candidates.sorted(by: { a, b in
                // Prefer longest matching prefix (most specific)
                if a.folder.count != b.folder.count { return a.folder.count > b.folder.count }
                // Then most recently modified lock file
                if a.modDate != b.modDate { return a.modDate > b.modDate }
                // Then prefer running process
                let aRunning = NSRunningApplication(processIdentifier: a.lockFile.pid) != nil
                let bRunning = NSRunningApplication(processIdentifier: b.lockFile.pid) != nil
                return aRunning && !bRunning
            }).first else { continue }

            let runningApp = NSRunningApplication(processIdentifier: best.lockFile.pid)
            result[session.sessionId] = IdeInfo(
                ideName: best.lockFile.ideName,
                pid: best.lockFile.pid,
                isRunning: runningApp != nil,
                workspaceFolder: best.folder,
                appBundlePath: runningApp?.bundleURL?.path
            )
        }

        ideInfoBySessionId = result
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
