import SwiftUI

// MARK: - Row Item

enum RowItem: Identifiable {
    case session(Session)
    case subagent(Subagent)

    var id: String {
        switch self {
        case .session(let s): s.id
        case .subagent(let a): a.id
        }
    }
}

// MARK: - Session Table View

struct SessionTableView: View {
    @Environment(SessionStore.self) private var store
    @State private var killTarget: (pid: pid_t, force: Bool)?

    private var rows: [RowItem] {
        var items: [RowItem] = []
        for session in store.sessions {
            items.append(.session(session))
            // Only show subagents for active sessions (not WAITING/ENDED)
            if session.parsedStatus != .waiting && session.parsedStatus != .ended {
                for agent in session.subagents {
                    items.append(.subagent(agent))
                }
            }
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.sessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "terminal",
                    description: Text("Waiting for Claude sessions...")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows) {
                    TableColumn("Status") { row in
                        cell(for: row, alignment: .center) { statusCell(for: row) }
                    }
                    .width(min: 85, ideal: 95, max: 110)

                    TableColumn("IDE") { row in
                        cell(for: row, alignment: .center) { ideCell(for: row) }
                    }
                    .width(min: 30, ideal: 35, max: 40)

                    TableColumn("Project") { row in
                        cell(for: row) { projectCell(for: row) }
                    }
                    .width(min: 70, ideal: 120, max: 200)

                    TableColumn("Tool") { row in
                        cell(for: row) { toolCell(for: row) }
                    }
                    .width(min: 50, ideal: 90, max: 160)

                    TableColumn("Model") { row in
                        cell(for: row, alignment: .center) { modelCell(for: row) }
                    }
                    .width(min: 45, ideal: 50, max: 60)

                    TableColumn("Mode") { row in
                        cell(for: row, alignment: .center) { modeCell(for: row) }
                    }
                    .width(min: 38, ideal: 45, max: 55)

                    TableColumn("Tools") { row in
                        cell(for: row, alignment: .center) { toolCountCell(for: row) }
                    }
                    .width(min: 35, ideal: 40, max: 50)

                    TableColumn("Duration") { row in
                        cell(for: row, alignment: .center) { durationCell(for: row) }
                    }
                    .width(min: 55, ideal: 65, max: 80)

                    TableColumn("Updated") { row in
                        cell(for: row, alignment: .center) { updatedCell(for: row) }
                    }
                    .width(min: 50, ideal: 60, max: 75)

                    TableColumn("Topic") { row in
                        cell(for: row) { topicCell(for: row) }
                    }
                    .width(min: 150, ideal: 400)
                }
                .background(
                    TableViewConfigurator(
                        rows: rows,
                        onSessionDoubleClick: { sessionId in
                            store.activateIdeWindow(for: sessionId)
                        }
                    )
                )

                StatusBarView()
            }
        }
        .frame(minWidth: 800, minHeight: 400)
        .navigationTitle("Claude Monitor")
        .alert("Kill Process?", isPresented: Binding(get: { killTarget != nil }, set: { if !$0 { killTarget = nil } })) {
            Button("Cancel", role: .cancel) { }
            Button(killTarget?.force == true ? "Force Kill" : "Terminate", role: .destructive) {
                if let target = killTarget {
                    store.killProcess(pid: target.pid, force: target.force)
                }
            }
        } message: {
            if let target = killTarget {
                Text("PID \(target.pid) — \(target.force ? "SIGKILL (force)" : "SIGTERM (graceful)")")
            }
        }
    }

    // MARK: - Row Background

    private func rowBackgroundColor(for row: RowItem) -> Color? {
        if case .session(let s) = row, store.waitingSessions.contains(s.sessionId) {
            return .red
        }
        return nil
    }

    @ViewBuilder
    private func cell(for row: RowItem, alignment: Alignment = .leading, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .background(rowBackgroundColor(for: row)?.opacity(0.15) ?? .clear)
            .contentShape(Rectangle())
            .contextMenu { sessionContextMenu(for: row) }
    }

    @ViewBuilder
    private func sessionContextMenu(for row: RowItem) -> some View {
        if case .session(let session) = row {
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.sessionId, forType: .string)
            }

            Divider()

            if let pids = store.pidsBySessionId[session.sessionId], !pids.isEmpty {
                ForEach(pids, id: \.self) { pid in
                    Section("PID \(pid)") {
                        Button("Terminate (SIGTERM)") {
                            killTarget = (pid, false)
                        }
                        Button("Force Kill (SIGKILL)") {
                            killTarget = (pid, true)
                        }
                    }
                }
            } else {
                Text("No process found")
            }
        }
    }

    // MARK: - Cell Views

    @ViewBuilder
    private func ideCell(for row: RowItem) -> some View {
        switch row {
        case .session(let session):
            if let ide = store.ideInfoBySessionId[session.sessionId] {
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
        case .subagent:
            Text("")
        }
    }

    @ViewBuilder
    private func statusCell(for row: RowItem) -> some View {
        switch row {
        case .session(let session):
            statusBadge(for: session.parsedStatus)
        case .subagent(let agent):
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                statusBadge(for: agent.parsedStatus)
            }
        }
    }

    @ViewBuilder
    private func projectCell(for row: RowItem) -> some View {
        switch row {
        case .session(let session):
            Text(session.project)
                .fontWeight(.medium)
                .lineLimit(1)
        case .subagent(let agent):
            Text(agent.agentType)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
        }
    }

    @ViewBuilder
    private func toolCell(for row: RowItem) -> some View {
        switch row {
        case .session(let session):
            Text(session.toolName ?? "-")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .subagent:
            Text("")
        }
    }

    @ViewBuilder
    private func modelCell(for row: RowItem) -> some View {
        switch row {
        case .session(let session):
            HStack(spacing: 2) {
                Text(session.shortModel)
                if session.hasLargeContext {
                    Text("1M")
                        .font(.system(size: 7, weight: .bold))
                        .padding(.horizontal, 2)
                        .padding(.vertical, 0.5)
                        .background(Color.secondary.opacity(0.25))
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(.secondary)
            .help(session.model)
        case .subagent:
            Text("")
        }
    }

    @ViewBuilder
    private func modeCell(for row: RowItem) -> some View {
        switch row {
        case .session(let session):
            Text(session.shortMode)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .subagent:
            Text("")
        }
    }

    @ViewBuilder
    private func toolCountCell(for row: RowItem) -> some View {
        switch row {
        case .session(let session):
            HStack(spacing: 2) {
                Image(systemName: "wrench.fill")
                    .font(.caption2)
                Text("\(session.toolCount)")
            }
            .foregroundStyle(.secondary)
        case .subagent:
            Text("")
        }
    }

    @ViewBuilder
    private func durationCell(for row: RowItem) -> some View {
        switch row {
        case .session(let session):
            Text(session.formattedDuration)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .subagent:
            Text("")
        }
    }

    @ViewBuilder
    private func updatedCell(for row: RowItem) -> some View {
        switch row {
        case .session(let session):
            Text(session.formattedLastUpdated)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .subagent:
            Text("")
        }
    }

    @ViewBuilder
    private func topicCell(for row: RowItem) -> some View {
        switch row {
        case .session(let session):
            Text(session.displayTopic)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(session.topic.isEmpty ? session.displayTopic : session.topic)
        case .subagent:
            Text("")
        }
    }

    private func statusBadge(for status: SessionStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon)
                .font(.caption)
            Text(status.label)
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
            ForEach(SessionStatus.allCases, id: \.self) { status in
                if let count = store.statusCounts[status], count > 0 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 8, height: 8)
                        Text("\(count) \(status.label)")
                            .font(.caption)
                    }
                }
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
                ForEach(limits) { limit in
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
            if let extra = usage.extraUsage, extra.isEnabled, let u = extra.utilization {
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
    let onSessionDoubleClick: (String) -> Void

    func makeNSView(context: Context) -> TableConfigView {
        TableConfigView()
    }

    func updateNSView(_ nsView: TableConfigView, context: Context) {
        nsView.rows = rows
        nsView.onSessionDoubleClick = onSessionDoubleClick
    }
}

private final class TableConfigView: NSView {
    var rows: [RowItem] = []
    var onSessionDoubleClick: ((String) -> Void)?

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
        if case .session(let session) = rows[clickedRow] {
            onSessionDoubleClick?(session.sessionId)
        }
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
