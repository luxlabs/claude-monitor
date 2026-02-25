import Foundation

final class DirectoryMonitor: Sendable {
    private let url: URL
    private let source: DispatchSourceFileSystemObject
    private let fileDescriptor: Int32

    init?(url: URL, queue: DispatchQueue = .global(qos: .utility), handler: @escaping @Sendable () -> Void) {
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

        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
