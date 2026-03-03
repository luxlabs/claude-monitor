import Foundation

final class DirectoryMonitor: Sendable {
    private let url: URL
    private let source: DispatchSourceFileSystemObject
    private let fileDescriptor: Int32

    init?(url: URL, queue: DispatchQueue = .global(qos: .utility), debounce: TimeInterval = 0.3, handler: @escaping @Sendable () -> Void) {
        self.url = url

        let fd = open(url.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else { return nil }
        self.fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue
        )
        self.source = source

        // Debounce: coalesce rapid FS events into a single callback
        let pending = DispatchWorkItemBox()
        source.setEventHandler {
            pending.item?.cancel()
            let work = DispatchWorkItem(block: handler)
            pending.item = work
            queue.asyncAfter(deadline: .now() + debounce, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

/// Thread-safe mutable box for the pending work item.
/// Access is confined to the DirectoryMonitor's serial queue.
private final class DispatchWorkItemBox: @unchecked Sendable {
    var item: DispatchWorkItem?
}
