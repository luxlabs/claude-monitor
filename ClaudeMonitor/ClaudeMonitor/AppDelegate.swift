import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onBecomeActive: (() -> Void)?

    func applicationDidBecomeActive(_ notification: Notification) {
        onBecomeActive?()
    }
}
