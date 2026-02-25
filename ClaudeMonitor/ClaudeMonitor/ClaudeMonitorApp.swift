import SwiftUI

@main
struct ClaudeMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var store = SessionStore()

    var body: some Scene {
        WindowGroup {
            SessionTableView()
                .environment(store)
                .onAppear {
                    appDelegate.onBecomeActive = { [store] in
                        store.resetWaitingCount()
                    }
                }
        }

        MenuBarExtra("Claude Monitor", systemImage: "terminal.fill") {
            MenuBarView()
                .environment(store)
        }
    }
}
