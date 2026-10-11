import SwiftUI

/// Display status of a session. Declaration order is the status-bar order.
enum SessionStatus: String, CaseIterable, Sendable {
    case permission = "PERMISSION"
    case thinking = "THINKING"
    case executing = "EXECUTING"
    case compacting = "COMPACTING"
    case background = "BACKGROUND"  // turn ended, background agents/workflows still running
    case starting = "STARTING"
    case waiting = "WAITING"
    case ended = "ENDED"  // legacy: SessionEnd now removes the file instead

    /// Lenient parse: an unknown value (a status added by a newer hook) reads
    /// as STARTING, never ENDED, so the row stays visible and "alive".
    init(lenient raw: String) {
        self = SessionStatus(rawValue: raw) ?? .starting
    }

    var color: Color {
        switch self {
        case .starting: .cyan
        case .thinking: .yellow
        case .executing: .blue
        case .compacting: .orange
        case .background: .purple
        case .permission: .red
        case .waiting: .green
        case .ended: .gray
        }
    }

    var icon: String {
        switch self {
        case .starting: "bolt.fill"
        case .thinking: "brain.head.profile.fill"
        case .executing: "gearshape.fill"
        case .compacting: "arrow.down.right.and.arrow.up.left"
        case .background: "square.stack.3d.down.right.fill"
        case .permission: "lock.fill"
        case .waiting: "checkmark.circle.fill"
        case .ended: "stop.circle.fill"
        }
    }

    var label: String {
        rawValue
    }

    /// Something is happening (or about to): drives the fast poll cadence.
    var isActive: Bool {
        switch self {
        case .waiting, .ended: false
        default: true
        }
    }

    /// Row order: PERMISSION, then THINKING/EXECUTING/COMPACTING, BACKGROUND,
    /// STARTING, WAITING (ENDED last).
    var sortRank: Int {
        switch self {
        case .permission: 0
        case .thinking, .executing, .compacting: 1
        case .background: 2
        case .starting: 3
        case .waiting: 4
        case .ended: 5
        }
    }
}
