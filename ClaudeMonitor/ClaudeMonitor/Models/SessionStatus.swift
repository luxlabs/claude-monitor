import SwiftUI

enum SessionStatus: String, CaseIterable {
    case starting = "STARTING"
    case thinking = "THINKING"
    case executing = "EXECUTING"
    case permission = "PERMISSION"
    case waiting = "WAITING"
    case ended = "ENDED"

    var color: Color {
        switch self {
        case .starting: .cyan
        case .thinking: .yellow
        case .executing: .blue
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
        case .permission: "lock.fill"
        case .waiting: "checkmark.circle.fill"
        case .ended: "stop.circle.fill"
        }
    }

    var label: String {
        rawValue
    }
}
