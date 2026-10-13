import CoreServices
import Foundation

/// Watches a folder with FSEvents (the macOS file-system change feed) and calls `onChange`
/// when anything inside it changes. FSEvents groups bursts of events over `latency` seconds,
/// so a download that writes hundreds of times triggers one rescan, not hundreds.
public final class FolderWatcher: @unchecked Sendable {
    public let url: URL
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "io.github.n1soryu.directory-organizer.watcher")
    private var stream: FSEventStreamRef?

    public init(url: URL, latency: TimeInterval = 3, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    /// Returns false if the folder can't be watched (missing, no permission).
    @discardableResult
    public func start() -> Bool {
        stop()
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    public var isRunning: Bool { stream != nil }
}
