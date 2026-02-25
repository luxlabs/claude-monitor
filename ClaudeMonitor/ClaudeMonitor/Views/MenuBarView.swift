import SwiftUI

struct MenuBarView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        if store.sessions.isEmpty {
            Text("No active sessions")
                .foregroundStyle(.secondary)
        } else {
            ForEach(store.sessions) { session in
                let status = session.parsedStatus
                Button {
                    store.activateIdeWindow(for: session.sessionId)
                } label: {
                    Label {
                        Text("\(session.project) — \(status.label)")
                    } icon: {
                        Image(systemName: status.icon)
                    }
                }
                .tint(status.color)
            }
        }

        Divider()

        Button("Open Monitor") {
            NSApp.activate()
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        .keyboardShortcut("o")

        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
