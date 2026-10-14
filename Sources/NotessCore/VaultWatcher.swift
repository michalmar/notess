import CoreServices
import Foundation

/// A batch of outside changes in the Vault reported by `VaultWatcher`.
public struct VaultChange: Equatable, Sendable {
    /// Vault-relative paths of the files and folders that changed; `""` is the
    /// Vault root. Hidden items (`.git`, `.DS_Store`, editor swap files) are left out.
    public let relativePaths: Set<String>
    /// Events were dropped or the Vault folder itself moved, so any file may have
    /// changed: rescan everything instead of trusting `relativePaths`.
    public let requiresFullRescan: Bool

    public init(relativePaths: Set<String>, requiresFullRescan: Bool = false) {
        self.relativePaths = relativePaths
        self.requiresFullRescan = requiresFullRescan
    }

    /// The Vault-relative form of an absolute event path, or `nil` if the path
    /// lies outside the Vault or inside a hidden item.
    static func relativePath(ofEventPath path: String, inRoot rootPath: String) -> String? {
        if path == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        let components = relative.split(separator: "/")
        guard !components.contains(where: { $0.hasPrefix(".") }) else { return nil }
        return components.joined(separator: "/")
    }
}

/// Watches a Vault folder recursively with FSEvents and reports outside changes,
/// coalesced over `latency` seconds, on `queue`.
///
/// The watcher reports *every* write, including the app's own saves; consumers
/// decide what changed by comparing content (see `NoteDocument.reconcileWithDisk()`).
/// Used to refresh open tabs and the sidebar, and to notice Brain Notes written
/// by the Agent.
public final class VaultWatcher: @unchecked Sendable {
    public struct StartError: Error, Equatable {}

    private let rootURL: URL
    private let latency: TimeInterval
    private let queue: DispatchQueue
    private let onChange: @Sendable (VaultChange) -> Void
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    public init(
        rootURL: URL,
        latency: TimeInterval = 0.3,
        queue: DispatchQueue = .main,
        onChange: @escaping @Sendable (VaultChange) -> Void
    ) {
        self.rootURL = rootURL
        self.latency = latency
        self.queue = queue
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// Starts watching; does nothing if already started.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }

        let rootPath = Self.realPath(of: rootURL)
        let receiver = EventReceiver(rootPath: rootPath, onChange: onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(receiver).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<EventReceiver>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<EventReceiver>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, eventFlags, _ in
                guard let info else { return }
                let receiver = Unmanaged<EventReceiver>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
                receiver.receive(paths: paths, flags: flags)
            },
            &context,
            [rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { throw StartError() }

        FSEventStreamSetDispatchQueue(newStream, queue)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            throw StartError()
        }
        stream = newStream
    }

    /// Stops watching; no change is reported after this returns.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// FSEvents reports resolved paths (e.g. `/private/var/…`), so compare against the real root.
    private static func realPath(of url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private final class EventReceiver: @unchecked Sendable {
    private let rootPath: String
    private let onChange: @Sendable (VaultChange) -> Void

    init(rootPath: String, onChange: @escaping @Sendable (VaultChange) -> Void) {
        self.rootPath = rootPath
        self.onChange = onChange
    }

    func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        let rescanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged
        )
        let requiresFullRescan = flags.contains { $0 & rescanFlags != 0 }
        let relativePaths = Set(paths.compactMap {
            VaultChange.relativePath(ofEventPath: $0, inRoot: rootPath)
        })
        guard requiresFullRescan || !relativePaths.isEmpty else { return }
        onChange(VaultChange(relativePaths: relativePaths, requiresFullRescan: requiresFullRescan))
    }
}
