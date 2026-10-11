import SwiftUI

struct MenuBarView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        if store.rows.isEmpty {
            Text("No active sessions")
                .foregroundStyle(.secondary)
        } else {
            ForEach(store.rows) { row in
                let status = row.status
                Button {
                    store.activateIdeWindow(for: row.id)
                } label: {
                    Label {
                        Text("\(row.project) — \(status.label)")
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
