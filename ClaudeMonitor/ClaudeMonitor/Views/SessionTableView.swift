import SwiftUI

// MARK: - Row Item

enum RowItem: Identifiable {
    case session(DisplayRow)
    /// A subagent of the session `parentId`; `waiting` = it waits on a prompt.
    case subagent(parentId: String, agent: Subagent, waiting: Bool)
    /// "+N more" subagents beyond the ones listed.
    case more(parentId: String, count: Int)

    var id: String {
        switch self {
        case .session(let row): row.id
        case .subagent(let parentId, let agent, _): "\(parentId)/\(agent.agentId)"
        case .more(let parentId, _): "\(parentId)/+more"
        }
    }

    /// The session this row belongs to.
    var sessionId: String {
        switch self {
        case .session(let row): row.id
        case .subagent(let parentId, _, _), .more(let parentId, _): parentId
        }
    }
}

/// A confirmed stop/terminate/kill of one session's process.
struct StopRequest {
    let sessionId: String
    let project: String
    let entry: LiveEntry
    let force: Bool

    /// Background sessions are stopped via `claude stop` (killed workers respawn).
    var usesClaudeStop: Bool {
        entry.kind == .background && !(entry.jobId ?? "").isEmpty && !force
    }

    var title: String {
        if usesClaudeStop { return "Stop Background Session?" }
        return force ? "Force Kill Process?" : "Terminate Process?"
    }

    var message: String {
        if usesClaudeStop {
            let pid = entry.pid.map { ", PID \($0)" } ?? ""
            return "\(project): claude stop \(entry.jobId ?? "")\(pid)"
        }
        let pid = entry.pid.map(String.init) ?? "?"
        return "\(project): PID \(pid) — \(force ? "SIGKILL (force)" : "SIGTERM (graceful)")"
    }

    var confirmLabel: String {
        if usesClaudeStop { return "Stop" }
        return force ? "Force Kill" : "Terminate"
    }
}

// MARK: - Session Table View

struct SessionTableView: View {
    @Environment(SessionStore.self) private var store
    @State private var stopRequest: StopRequest?

    /// Subagent rows listed per session before "+N more".
    private static let subagentRowLimit = 8

    private var items: [RowItem] {
        var items: [RowItem] = []
        for row in store.rows {
            items.append(.session(row))
            guard let session = row.session else { continue }
            // Subagents are listed whatever the session's status.
            let shown = session.subagents.prefix(Self.subagentRowLimit)
            for agent in shown {
                let waiting = agent.parsedStatus == .permission || session.pending[agent.agentId] != nil
                items.append(.subagent(parentId: row.id, agent: agent, waiting: waiting))
            }
            let extra = session.subagents.count - shown.count + session.subagentsOverflow
            if extra > 0 {
                items.append(.more(parentId: row.id, count: extra))
            }
        }
        return items
    }

    var body: some View {
        let items = self.items
        VStack(spacing: 0) {
            if store.rows.isEmpty {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "terminal",
                    description: Text(store.showAll
                        ? "Waiting for Claude sessions..."
                        : "Waiting for Claude sessions... (idle sessions are hidden)")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(items) {
                    Group {
                        TableColumn("Status") { item in
                            cell(for: item, alignment: .center, dimsUntracked: false) { statusCell(for: item) }
                        }
                        .width(min: 85, ideal: 100, max: 180)

                        TableColumn("IDE") { item in
                            cell(for: item, alignment: .center) { ideCell(for: item) }
                        }
                        .width(min: 30, ideal: 35, max: 40)

                        TableColumn("Project") { item in
                            cell(for: item) { projectCell(for: item) }
                        }
                        .width(min: 70, ideal: 130, max: 220)

                        TableColumn("Tool") { item in
                            cell(for: item) { toolCell(for: item) }
                        }
                        .width(min: 50, ideal: 90, max: 180)

                        TableColumn("Model") { item in
                            cell(for: item, alignment: .center) { modelCell(for: item) }
                        }
                        .width(min: 50, ideal: 95, max: 140)
                    }
                    Group {
                        TableColumn("Mode") { item in
                            cell(for: item, alignment: .center) { modeCell(for: item) }
                        }
                        .width(min: 38, ideal: 52, max: 70)

                        TableColumn("Ctx") { item in
                            cell(for: item, alignment: .center) { contextCell(for: item) }
                        }
                        .width(min: 35, ideal: 45, max: 60)

                        TableColumn("Tools") { item in
                            cell(for: item, alignment: .center) { toolCountCell(for: item) }
                        }
                        .width(min: 35, ideal: 45, max: 55)

                        TableColumn("Duration") { item in
                            cell(for: item, alignment: .center) { durationCell(for: item) }
                        }
                        .width(min: 55, ideal: 65, max: 80)

                        TableColumn("Updated") { item in
                            cell(for: item, alignment: .center) { updatedCell(for: item) }
                        }
                        .width(min: 50, ideal: 70, max: 90)

                        TableColumn("Topic") { item in
                            cell(for: item) { topicCell(for: item) }
                        }
                        .width(min: 150, ideal: 380)
                    }
                }
                .background(
                    TableViewConfigurator(
                        rows: items,
                        onRowDoubleClick: { sessionId in
                            store.activateIdeWindow(for: sessionId)
                        }
                    )
                )
            }

            StatusBarView()
        }
        .frame(minWidth: 900, minHeight: 400)
        .navigationTitle("Claude Monitor")
        .toolbar {
            ToolbarItem {
                Toggle(isOn: Binding(get: { store.showAll }, set: { store.showAll = $0 })) {
                    Label("Show idle", systemImage: "moon.zzz")
                }
                .toggleStyle(.button)
                .labelStyle(.titleAndIcon)
                .help("Also show sessions idle for more than 4 hours")
            }
        }
        .alert(
            stopRequest?.title ?? "",
            isPresented: Binding(get: { stopRequest != nil }, set: { if !$0 { stopRequest = nil } }),
            presenting: stopRequest
        ) { request in
            Button("Cancel", role: .cancel) { }
            Button(request.confirmLabel, role: .destructive) {
                store.stop(sessionId: request.sessionId, expected: request.entry, force: request.force)
            }
        } message: { request in
            Text(request.message)
        }
    }

    // MARK: - Cell Chrome

    private func rowBackgroundColor(for item: RowItem) -> Color? {
        if case .session(let row) = item, store.waitingSessions.contains(row.id) {
            return .red
        }
        return nil
    }

    @ViewBuilder
    private func cell(
        for item: RowItem,
        alignment: Alignment = .leading,
        dimsUntracked: Bool = true,
        @ViewBuilder content: () -> some View
    ) -> some View {
        content()
            .opacity(dimsUntracked && isUntracked(item) ? 0.55 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .background(rowBackgroundColor(for: item)?.opacity(0.15) ?? .clear)
            .contentShape(Rectangle())
            .contextMenu { contextMenu(for: item) }
    }

    private func isUntracked(_ item: RowItem) -> Bool {
        if case .session(let row) = item { return row.effective.untracked }
        return false
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for item: RowItem) -> some View {
        if case .session(let row) = item {
            Button("Copy Session ID") {
                copyToPasteboard(row.id)
            }
            Button("Copy Resume Command") {
                copyToPasteboard(store.resumeCommand(for: row.id))
            }

            Divider()

            Section(processTitle(for: row)) {
                if let entry = row.live, entry.kind == .background, let jobId = entry.jobId, !jobId.isEmpty {
                    Button("Stop (claude stop \(jobId))") {
                        stopRequest = StopRequest(sessionId: row.id, project: row.project, entry: entry, force: false)
                    }
                } else {
                    Button("Terminate (SIGTERM)") {
                        if let entry = row.live {
                            stopRequest = StopRequest(sessionId: row.id, project: row.project, entry: entry, force: false)
                        }
                    }
                    .disabled(row.pid == nil)
                }
                Button("Force Kill (SIGKILL)") {
                    if let entry = row.live {
                        stopRequest = StopRequest(sessionId: row.id, project: row.project, entry: entry, force: true)
                    }
                }
                .disabled(row.pid == nil)
            }
        }
    }

    private func processTitle(for row: DisplayRow) -> String {
        if let pid = row.pid { return "PID \(pid)" }
        if let jobId = row.live?.jobId, !jobId.isEmpty { return "Background job \(jobId)" }
        return "No live process"
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Cell Views

    @ViewBuilder
    private func statusCell(for item: RowItem) -> some View {
        switch item {
        case .session(let row):
            HStack(spacing: 4) {
                statusBadge(for: row.status)
                if let error = row.session?.lastError, !error.isEmpty {
                    Text("⚠ \(error)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.12))
                        .clipShape(Capsule())
                        .help("The last turn ended with an API error: \(error)")
                }
            }
            .help(statusTooltip(for: row))
        case .subagent(_, _, let waiting):
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                statusBadge(for: waiting ? .permission : .executing, label: waiting ? "PERMISSION" : "RUNNING")
            }
        case .more:
            Text("")
        }
    }

    private func statusTooltip(for row: DisplayRow) -> String {
        var lines: [String] = []
        if let detail = row.effective.detail ?? row.live?.waitingFor, !detail.isEmpty {
            lines.append("Waiting for: \(detail)")
        }
        if let session = row.session, !session.pending.isEmpty {
            for (agent, prompt) in session.pending.sorted(by: { $0.key < $1.key }) {
                let who = agent == "main"
                    ? "main agent"
                    : (session.subagents.first { $0.agentId == agent }?.agentType ?? "subagent")
                lines.append("Prompt (\(who)): \(prompt.tool.isEmpty ? "?" : prompt.tool)")
            }
        }
        if let live = row.live {
            if live.kind == .background {
                lines.append("Background job \(live.jobId ?? "?")\(live.state.map { ": \($0)" } ?? "")")
            }
            if let status = live.status {
                lines.append("Claude Code: \(status)")
            }
        }
        if row.effective.legacy {
            lines.append("Live status unavailable: hook data only")
        }
        if row.effective.untracked {
            lines.append("No hook data for this session")
        }
        if let error = row.session?.lastError, !error.isEmpty {
            lines.append("Last error: \(error)")
        }
        return lines.isEmpty ? row.status.label : lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func ideCell(for item: RowItem) -> some View {
        switch item {
        case .session(let row):
            if let ide = store.ideInfoBySessionId[row.id] {
                Image(nsImage: ide.appIcon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .opacity(ide.isRunning ? 1.0 : 0.4)
                    .help(ide.isRunning
                        ? "\(ide.ideName) (PID \(ide.pid))"
                        : "\(ide.ideName) (not running)")
            } else {
                Image(systemName: "terminal.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Terminal")
            }
        case .subagent, .more:
            Text("")
        }
    }

    @ViewBuilder
    private func projectCell(for item: RowItem) -> some View {
        switch item {
        case .session(let row):
            HStack(spacing: 4) {
                Text(row.project)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if row.effective.untracked {
                    Text("untracked")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18))
                        .clipShape(Capsule())
                }
            }
            .help(projectTooltip(for: row))
        case .subagent(_, let agent, _):
            Text(agent.agentType.isEmpty ? String(agent.agentId.prefix(12)) : agent.agentType)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 16)
                .help(agent.description.isEmpty ? agent.agentId : "\(agent.description)\n\(agent.agentId)")
        case .more(_, let count):
            Text("+\(count) more")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 16)
        }
    }

    private func projectTooltip(for row: DisplayRow) -> String {
        var lines: [String] = []
        if let name = row.live?.name, !name.isEmpty {
            lines.append(name)
        }
        if !row.cwd.isEmpty {
            lines.append(row.cwd)
        }
        if row.effective.untracked {
            lines.append("Untracked: live session without hook data")
        }
        return lines.isEmpty ? row.project : lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func toolCell(for item: RowItem) -> some View {
        switch item {
        case .session(let row):
            Text(toolText(for: row))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .subagent(_, let agent, _):
            Text(agent.toolName ?? "-")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .more:
            Text("")
        }
    }

    /// What the session is on: the prompt it waits on, its background work, or its tool.
    private func toolText(for row: DisplayRow) -> String {
        guard let session = row.session else {
            return row.effective.detail ?? "-"
        }
        switch row.status {
        case .permission:
            let pendingTool = session.pending.sorted { $0.key < $1.key }.first { !$0.value.tool.isEmpty }?.value.tool
            return row.effective.detail ?? pendingTool ?? session.toolName ?? "-"
        case .background:
            return "\(session.background.active) in background"
        default:
            return session.toolName ?? "-"
        }
    }

    @ViewBuilder
    private func modelCell(for item: RowItem) -> some View {
        switch item {
        case .session(let row):
            if let session = row.session {
                Text(modelText(for: session))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(session.model.isEmpty ? "Model unknown" : session.model)
            } else {
                Text("-").foregroundStyle(.secondary)
            }
        case .subagent, .more:
            Text("")
        }
    }

    /// "opus 5.5 · max"
    private func modelText(for session: Session) -> String {
        let model = Labels.shortModel(session.model)
        guard !session.effort.isEmpty else { return model }
        return session.model.isEmpty ? session.effort : "\(model) · \(session.effort)"
    }

    @ViewBuilder
    private func modeCell(for item: RowItem) -> some View {
        switch item {
        case .session(let row):
            Text(Labels.shortMode(row.session?.permissionMode ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(row.session?.permissionMode ?? "")
        case .subagent, .more:
            Text("")
        }
    }

    @ViewBuilder
    private func contextCell(for item: RowItem) -> some View {
        switch item {
        case .session(let row):
            let tokens = row.session?.contextTokens ?? 0
            Text(Labels.formatTokens(tokens))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(tokens > 0 ? "\(tokens.formatted()) tokens in context" : "Context size unknown")
        case .subagent, .more:
            Text("")
        }
    }

    @ViewBuilder
    private func toolCountCell(for item: RowItem) -> some View {
        switch item {
        case .session(let row):
            if let session = row.session {
                HStack(spacing: 2) {
                    Image(systemName: "wrench.fill")
                        .font(.caption2)
                    Text("\(session.toolCount)")
                }
                .foregroundStyle(.secondary)
            } else {
                Text("-").foregroundStyle(.secondary)
            }
        case .subagent(_, let agent, _):
            Text(agent.toolCount > 0 ? "\(agent.toolCount)" : "-")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .more:
            Text("")
        }
    }

    @ViewBuilder
    private func durationCell(for item: RowItem) -> some View {
        switch item {
        case .session(let row):
            Text(formattedDuration(since: row.startDate))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .subagent, .more:
            Text("")
        }
    }

    @ViewBuilder
    private func updatedCell(for item: RowItem) -> some View {
        switch item {
        case .session(let row):
            Text(formattedRelative(row.session?.activityDate))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .subagent(_, let agent, _):
            Text(formattedRelative(agent.ts > 0 ? Date(timeIntervalSince1970: agent.ts) : nil))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .more:
            Text("")
        }
    }

    @ViewBuilder
    private func topicCell(for item: RowItem) -> some View {
        switch item {
        case .session(let row):
            if let session = row.session {
                Text(session.displayTopic)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(topicTooltip(for: session))
            } else {
                let name = row.live?.name ?? ""
                Text(name.isEmpty ? "untracked" : "untracked · \(name)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .subagent(_, let agent, _):
            Text(agent.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(agent.description)
        case .more:
            Text("")
        }
    }

    private func topicTooltip(for session: Session) -> String {
        if session.title.isEmpty || session.topic.isEmpty || session.title == session.topic {
            return session.topic.isEmpty ? session.displayTopic : session.topic
        }
        return "\(session.title)\n\n\(session.topic)"
    }

    private func statusBadge(for status: SessionStatus, label: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon)
                .font(.caption)
            Text(label ?? status.label)
                .font(.caption)
                .fontWeight(.semibold)
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Status Bar

private struct StatusBarView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        HStack(spacing: 16) {
            let counts = store.statusCounts
            ForEach(SessionStatus.allCases, id: \.self) { status in
                if let count = counts[status], count > 0 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 8, height: 8)
                        Text("\(count) \(status.label)")
                            .font(.caption)
                    }
                }
            }

            if store.isLiveOff {
                Label("live off", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("No fresh live data from `claude agents --json` or the session registry: statuses come from hooks only and may lag (e.g. after Esc).")
            } else if store.liveSource == .registry {
                Text("live: registry")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("`claude agents --json` is unavailable: live data comes from Claude Code's session registry.")
            }

            Spacer()

            if let usage = store.usage {
                UsageBarView(usage: usage)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Usage Bar

private struct UsageBarView: View {
    let usage: UsageResponse

    var body: some View {
        HStack(spacing: 12) {
            if let limits = usage.limits, !limits.isEmpty {
                // Modern canonical source: one label per limit, binding one bold.
                ForEach(Array(limits.enumerated()), id: \.offset) { _, limit in
                    usageLabel(limit.label,
                               percent: limit.percent,
                               reset: limit.formattedResetTime,
                               emphasized: limit.isActive == true)
                }
            } else {
                // Fallback to the legacy flat windows.
                if let w = usage.fiveHour {
                    usageLabel("Session", percent: Int(w.utilization), reset: w.formattedResetTime, emphasized: false)
                }
                if let w = usage.sevenDay {
                    usageLabel("Week", percent: Int(w.utilization), reset: w.formattedResetTime, emphasized: false)
                }
            }
            if let spend = usage.spend, spend.enabled == true, let percent = spend.percent {
                usageLabel("Credits", percent: percent, reset: nil, emphasized: false)
            } else if let extra = usage.extraUsage, extra.isEnabled, let u = extra.utilization {
                usageLabel("Extra", percent: Int(u), reset: nil, emphasized: false)
            }
        }
    }

    private func usageLabel(_ label: String, percent: Int, reset: String?, emphasized: Bool) -> some View {
        HStack(spacing: 3) {
            Text("\(label):")
                .foregroundStyle(.white)
            Text("\(percent)%")
                .foregroundStyle(utilizationColor(Double(percent)))
            if let reset {
                Text("·")
                    .foregroundStyle(.white)
                Text(reset)
                    .foregroundStyle(.white)
            }
        }
        .font(.caption)
        .fontWeight(emphasized ? .semibold : .regular)
    }

    private func utilizationColor(_ value: Double) -> Color {
        if value > 90 { return .red }
        if value > 70 { return .yellow }
        return .green
    }
}

// MARK: - Table View Configurator

private struct TableViewConfigurator: NSViewRepresentable {
    let rows: [RowItem]
    let onRowDoubleClick: (String) -> Void

    func makeNSView(context: Context) -> TableConfigView {
        TableConfigView()
    }

    func updateNSView(_ nsView: TableConfigView, context: Context) {
        nsView.rows = rows
        nsView.onRowDoubleClick = onRowDoubleClick
    }
}

private final class TableConfigView: NSView {
    var rows: [RowItem] = []
    var onRowDoubleClick: ((String) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleApply()
    }

    private func scheduleApply() {
        // Try multiple times to catch the NSTableView after SwiftUI sets it up
        for delay in [0.1, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.apply()
            }
        }
    }

    private func apply() {
        guard let window else { return }
        Self.configureTableViews(in: window.contentView, configurator: self)
    }

    private static func configureTableViews(in view: NSView?, configurator: TableConfigView) {
        guard let view else { return }
        if let tableView = view as? NSTableView {
            // Install centered headers
            if !(tableView.headerView is CenteredTableHeaderView) {
                let centered = CenteredTableHeaderView()
                centered.frame = tableView.headerView?.frame ?? .zero
                tableView.headerView = centered
            }
            // Install double-click action
            tableView.target = configurator
            tableView.doubleAction = #selector(tableViewDoubleClick(_:))
            return
        }
        for sub in view.subviews {
            configureTableViews(in: sub, configurator: configurator)
        }
    }

    @objc func tableViewDoubleClick(_ sender: NSTableView) {
        let clickedRow = sender.clickedRow
        guard clickedRow >= 0, clickedRow < rows.count else { return }
        // Subagent rows open their session's IDE too.
        onRowDoubleClick?(rows[clickedRow].sessionId)
    }
}

private final class CenteredTableHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        guard let tableView else {
            super.draw(dirtyRect)
            return
        }

        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.headerTextColor,
            .paragraphStyle: centered,
        ]

        // Draw background
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        // Draw bottom separator
        NSColor.separatorColor.setStroke()
        let bottom = NSBezierPath()
        bottom.move(to: NSPoint(x: bounds.minX, y: bounds.minY + 0.5))
        bottom.line(to: NSPoint(x: bounds.maxX, y: bounds.minY + 0.5))
        bottom.lineWidth = 0.5
        bottom.stroke()

        for (i, column) in tableView.tableColumns.enumerated() {
            let colRect = headerRect(ofColumn: i)
            guard dirtyRect.intersects(colRect) else { continue }

            // Draw column separator
            NSColor.separatorColor.setStroke()
            let sep = NSBezierPath()
            sep.move(to: NSPoint(x: colRect.maxX - 0.5, y: colRect.minY + 4))
            sep.line(to: NSPoint(x: colRect.maxX - 0.5, y: colRect.maxY - 4))
            sep.lineWidth = 0.5
            sep.stroke()

            // Draw centered text
            let textRect = colRect.insetBy(dx: 4, dy: 0)
            let title = column.headerCell.stringValue
            let str = NSAttributedString(string: title, attributes: attrs)
            let size = str.size()
            let y = colRect.midY - size.height / 2
            str.draw(in: NSRect(x: textRect.minX, y: y, width: textRect.width, height: size.height))
        }
    }
}
