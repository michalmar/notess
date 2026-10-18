import Foundation

/// Brings the open tabs and the sidebar tree in line with outside changes to
/// the Vault (git, other editors, the Agent), reported by `VaultWatcher`.
///
/// Changes are coalesced by a `CoalescingQueue`: at most one pass runs and one
/// waits, holding every change received meanwhile. A pass scans the tree and
/// reads the affected open notes off the main actor, then applies the results
/// on it: only notes whose file (or a folder containing it) changed are read,
/// all of them for a root or full-rescan change. Each read carries the note's
/// `DiskReadTicket`; a read overtaken by a save, reload or typing is not
/// applied but read again in a follow-up pass, and a closed tab is skipped.
@MainActor
public final class VaultReconciler {
    /// Where a pass reads the Vault; called off the main actor.
    public struct Environment: Sendable {
        public var scanTree: @Sendable (Vault) async -> VaultTree
        public var readNote: @Sendable (URL) async -> NoteDocument.DiskRead

        public init(
            scanTree: @escaping @Sendable (Vault) async -> VaultTree,
            readNote: @escaping @Sendable (URL) async -> NoteDocument.DiskRead
        ) {
            self.scanTree = scanTree
            self.readNote = readNote
        }

        public static let live = Environment(
            scanTree: { $0.scanTree() },
            readNote: { NoteDocument.readDiskState(at: $0) }
        )
    }

    private let vault: Vault
    private let tabSession: TabSession
    private let environment: Environment
    private let applyTree: @MainActor (VaultTree) -> Void
    private let rootPrefixes: [String]
    private var treeRevision = 0
    private var isCancelled = false
    private lazy var queue = CoalescingQueue<VaultChange>(
        merge: { $0 = $0.merging($1) },
        perform: { [weak self] change in await self?.reconcile(change) }
    )

    /// - Parameter applyTree: Receives every freshly scanned tree on the main actor.
    public init(
        vault: Vault,
        tabSession: TabSession,
        environment: Environment = .live,
        applyTree: @escaping @MainActor (VaultTree) -> Void
    ) {
        self.vault = vault
        self.tabSession = tabSession
        self.environment = environment
        self.applyTree = applyTree
        let standardized = vault.rootURL.standardizedFileURL.path(percentEncoded: false)
        let resolved = vault.rootURL.resolvingSymlinksInPath().path(percentEncoded: false)
        rootPrefixes = Array(Set([standardized, resolved])).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    /// How many passes have started.
    public var passCount: Int { queue.passCount }

    public func submit(_ change: VaultChange) {
        guard !isCancelled else { return }
        queue.submit(change)
    }

    /// The tree was just scanned on the main actor, so a scan already in
    /// progress is older and must not replace it.
    public func discardTreeScansInProgress() {
        treeRevision &+= 1
    }

    /// Stops for good (e.g. another Vault was opened); nothing in progress is applied.
    public func cancel() {
        isCancelled = true
        queue.cancel()
    }

    public func waitUntilIdle() async {
        await queue.waitUntilIdle()
    }

    private func reconcile(_ change: VaultChange) async {
        let tickets = tabSession.documents.compactMap { document -> NoteDocument.DiskReadTicket? in
            if !change.requiresFullRescan {
                guard let path = relativePath(of: document.fileURL),
                      change.affects(relativePath: path) else { return nil }
            }
            return document.diskReadTicket()
        }
        let vault = vault
        let environment = environment
        let revision = treeRevision
        let (tree, reads) = await Task.detached(priority: .userInitiated) {
            let tree = await environment.scanTree(vault)
            var reads: [NoteDocument.DiskRead] = []
            for ticket in tickets {
                reads.append(await environment.readNote(ticket.fileURL))
            }
            return (tree, reads)
        }.value

        guard !isCancelled else { return }
        if revision == treeRevision { applyTree(tree) }
        var stalePaths: Set<String> = []
        for (ticket, read) in zip(tickets, reads) {
            guard let document = tabSession.documents.first(where: { $0.id == ticket.documentID })
            else { continue }
            if document.applyDiskRead(read, ticket: ticket) == nil {
                stalePaths.insert(relativePath(of: document.fileURL) ?? "")
            }
        }
        if !stalePaths.isEmpty {
            queue.submit(VaultChange(relativePaths: stalePaths))
        }
    }

    private func relativePath(of fileURL: URL) -> String? {
        let path = fileURL.standardizedFileURL.path(percentEncoded: false)
        for prefix in rootPrefixes where path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return nil
    }
}
