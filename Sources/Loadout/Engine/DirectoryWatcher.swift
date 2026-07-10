import Foundation
import CoreServices

/// Watches a set of directory trees via FSEvents and invokes a debounced
/// callback on the main actor whenever anything beneath them changes.
///
/// Watching paths that do not yet exist is safe: FSEvents delivers events once
/// they appear. The instance stops watching on `stop()` and on deinit.
@MainActor
final class DirectoryWatcher {
    private let paths: [String]
    private let onChange: @MainActor () -> Void
    private let latency: CFTimeInterval = 0.5
    private let debounce: DispatchTimeInterval = .milliseconds(500)

    /// The live stream. `nonisolated(unsafe)` so `deinit` can tear it down;
    /// all mutation happens on the main actor and the pointer is only released
    /// once, so this is race-free in practice.
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private var pendingWork: DispatchWorkItem?

    /// - Parameters:
    ///   - paths: directory paths to watch recursively.
    ///   - onChange: invoked on the main actor after changes settle.
    init(paths: [String], onChange: @escaping @MainActor () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// Begins watching. A no-op if already started or if `paths` is empty.
    func start() {
        guard stream == nil, !paths.isEmpty else { return }

        // Pass an unretained pointer to self through the FSEvents context; the
        // stream lifetime is bounded by this object, so the pointer stays valid.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    /// Stops watching and releases the stream. Safe to call repeatedly.
    func stop() {
        pendingWork?.cancel()
        pendingWork = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Coalesces event bursts into a single trailing invocation of `onChange`.
    fileprivate func handleEvents() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.onChange()
            }
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}

/// FSEvents C callback. Recovers the watcher from the context `info` pointer
/// and forwards to the debouncer. The stream is dispatched on the main queue,
/// so this runs on the main thread.
private func eventCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
    MainActor.assumeIsolated {
        watcher.handleEvents()
    }
}
