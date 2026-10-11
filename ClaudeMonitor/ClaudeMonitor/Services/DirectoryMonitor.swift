import Foundation

/// Watches one directory (entries added, removed or renamed) and calls
/// `handler` at most once per `interval`.
///
/// Throttle, not debounce: the first event schedules a fire after `interval`
/// and later events inside that window don't reschedule it. (A debounce never
/// fires while hooks keep writing, i.e. exactly when sessions are busiest.)
final class DirectoryMonitor: Sendable {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, interval: TimeInterval = 0.3, handler: @escaping @Sendable () -> Void) {
        let fd = open(url.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else { return nil }

        // Serial: the event handler and the delayed fire share `throttle`.
        let queue = DispatchQueue(label: "com.mitobit.ClaudeMonitor.DirectoryMonitor", qos: .utility)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue
        )
        self.source = source

        let throttle = ThrottleState()
        source.setEventHandler {
            guard !throttle.scheduled else { return }
            throttle.scheduled = true
            queue.asyncAfter(deadline: .now() + interval) {
                throttle.scheduled = false
                handler()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

/// Whether a fire is pending. Only touched on the monitor's serial queue.
private final class ThrottleState: @unchecked Sendable {
    var scheduled = false
}
