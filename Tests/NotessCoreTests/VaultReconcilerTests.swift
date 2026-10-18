import Foundation
import Synchronization
import Testing
@testable import NotessCore

/// Lets a test hold work running off the main actor until it opens the gate.
private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    private var arrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func pass() async {
        arrivals += 1
        let ready = arrivalWaiters.filter { $0.count <= arrivals }
        arrivalWaiters.removeAll { $0.count <= arrivals }
        for waiter in ready { waiter.continuation.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func waitForArrivals(_ count: Int) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }

    func open() {
        isOpen = true
        let continuations = waiting
        waiting = []
        for continuation in continuations { continuation.resume() }
    }
}

/// Records what the reconciler read and where.
private final class Recorder: Sendable {
    private let state = Mutex<(reads: [String], scans: Int, offMain: Bool)>(([], 0, true))

    var reads: [String] { state.withLock { $0.reads } }
    var scans: Int { state.withLock { $0.scans } }
    var everythingRanOffMain: Bool { state.withLock { $0.offMain } }

    func recordRead(_ url: URL) {
        let offMain = !Thread.isMainThread
        state.withLock {
            $0.reads.append(url.lastPathComponent)
            $0.offMain = $0.offMain && offMain
        }
    }

    func recordScan() {
        let offMain = !Thread.isMainThread
        state.withLock {
            $0.scans += 1
            $0.offMain = $0.offMain && offMain
        }
    }
}

@MainActor
@Suite("Reconciling the Vault after outside changes")
struct VaultReconcilerTests {
    @MainActor
    private struct Fixture {
        let temp: TemporaryVault
        let session = TabSession()
        let recorder = Recorder()
        let gate: Gate?

        func environment() -> VaultReconciler.Environment {
            let recorder = recorder
            let gate = gate
            return VaultReconciler.Environment(
                scanTree: { vault in
                    recorder.recordScan()
                    return vault.scanTree()
                },
                readNote: { url in
                    recorder.recordRead(url)
                    await gate?.pass()
                    return NoteDocument.readDiskState(at: url)
                }
            )
        }
    }

    private final class TreeSink {
        var trees: [VaultTree] = []
    }

    private func makeReconciler(
        _ fixture: Fixture,
        sink: TreeSink = TreeSink()
    ) -> VaultReconciler {
        VaultReconciler(
            vault: fixture.temp.vault,
            tabSession: fixture.session,
            environment: fixture.environment(),
            applyTree: { sink.trees.append($0) }
        )
    }

    private func fixture(
        notes: [String: String],
        gated: Bool = false
    ) throws -> Fixture {
        let temp = try TemporaryVault()
        for (path, text) in notes { try temp.write(text, to: path) }
        let fixture = Fixture(temp: temp, gate: gated ? Gate() : nil)
        for path in notes.keys.sorted() {
            try fixture.session.openNote(at: temp.vault.rootURL.appendingPathComponent(path))
        }
        return fixture
    }

    private func document(_ path: String, in fixture: Fixture) -> NoteDocument {
        fixture.session.documents.first { $0.fileURL.lastPathComponent == (path as NSString).lastPathComponent }!
    }

    @Test("the tree scan and note reads run off the main actor")
    func readsOffMain() async throws {
        let fixture = try fixture(notes: ["A.md": "a\n", "B.md": "b\n"])
        let sink = TreeSink()
        let reconciler = makeReconciler(fixture, sink: sink)
        try fixture.temp.write("a2\n", to: "A.md")

        reconciler.submit(VaultChange(relativePaths: [], requiresFullRescan: true))
        await reconciler.waitUntilIdle()

        #expect(fixture.recorder.scans == 1)
        #expect(fixture.recorder.reads.sorted() == ["A.md", "B.md"])
        #expect(fixture.recorder.everythingRanOffMain)
        #expect(sink.trees.count == 1)
        #expect(document("A.md", in: fixture).text == "a2\n")
    }

    @Test("a precise file change reads only that note")
    func preciseChangeReadsOneNote() async throws {
        let fixture = try fixture(notes: ["A.md": "a\n", "B.md": "b\n", "Sub/C.md": "c\n"])
        let reconciler = makeReconciler(fixture)
        try fixture.temp.write("b2\n", to: "B.md")

        reconciler.submit(VaultChange(relativePaths: ["B.md"]))
        await reconciler.waitUntilIdle()

        #expect(fixture.recorder.reads == ["B.md"])
        #expect(document("B.md", in: fixture).text == "b2\n")
    }

    @Test("a folder change reads the notes inside it; a root change reads every note")
    func folderAndRootChanges() async throws {
        let fixture = try fixture(notes: ["A.md": "a\n", "Sub/C.md": "c\n", "Sub/Deep/D.md": "d\n"])
        let reconciler = makeReconciler(fixture)

        reconciler.submit(VaultChange(relativePaths: ["Sub"]))
        await reconciler.waitUntilIdle()
        #expect(fixture.recorder.reads.sorted() == ["C.md", "D.md"])

        reconciler.submit(VaultChange(relativePaths: [""]))
        await reconciler.waitUntilIdle()
        #expect(fixture.recorder.reads.count == 5)
    }

    @Test("a change outside the open notes reads nothing but still rescans the tree")
    func unrelatedChangeReadsNothing() async throws {
        let fixture = try fixture(notes: ["A.md": "a\n"])
        let reconciler = makeReconciler(fixture)
        try fixture.temp.write("x\n", to: "Other.md")

        reconciler.submit(VaultChange(relativePaths: ["Other.md"]))
        await reconciler.waitUntilIdle()

        #expect(fixture.recorder.reads.isEmpty)
        #expect(fixture.recorder.scans == 1)
    }

    @Test("a burst of changes during a pass coalesces into one more pass without losing any")
    func burstCoalesces() async throws {
        let fixture = try fixture(notes: ["A.md": "a\n", "B.md": "b\n", "C.md": "c\n"], gated: true)
        let reconciler = makeReconciler(fixture)

        reconciler.submit(VaultChange(relativePaths: ["A.md"]))
        await fixture.gate!.waitForArrivals(1)
        try fixture.temp.write("b2\n", to: "B.md")
        try fixture.temp.write("c2\n", to: "C.md")
        for _ in 0..<20 {
            reconciler.submit(VaultChange(relativePaths: ["B.md"]))
            reconciler.submit(VaultChange(relativePaths: ["C.md"]))
        }
        await fixture.gate!.open()
        await reconciler.waitUntilIdle()

        #expect(reconciler.passCount == 2)
        #expect(fixture.recorder.scans == 2)
        #expect(fixture.recorder.reads.sorted() == ["A.md", "B.md", "C.md"])
        #expect(document("B.md", in: fixture).text == "b2\n")
        #expect(document("C.md", in: fixture).text == "c2\n")
    }

    @Test("a read overtaken by a save is not applied, and the file is read again")
    func saveDuringReadWins() async throws {
        let fixture = try fixture(notes: ["A.md": "old\n"], gated: true)
        let reconciler = makeReconciler(fixture)
        let note = document("A.md", in: fixture)

        reconciler.submit(VaultChange(relativePaths: ["A.md"]))
        await fixture.gate!.waitForArrivals(1)
        note.text = "saved\n"
        try note.save()
        await fixture.gate!.open()
        await reconciler.waitUntilIdle()

        #expect(reconciler.passCount == 2)
        #expect(note.text == "saved\n")
        #expect(note.hasUnsavedChanges == false)
        #expect(note.externalChange == nil)
        #expect(try fixture.temp.read("A.md") == "saved\n")
    }

    @Test("typing during a read keeps the typed text and shows the outside change as a conflict")
    func typingDuringReadConflicts() async throws {
        let fixture = try fixture(notes: ["A.md": "old\n"], gated: true)
        let reconciler = makeReconciler(fixture)
        let note = document("A.md", in: fixture)
        try fixture.temp.write("theirs\n", to: "A.md")

        reconciler.submit(VaultChange(relativePaths: ["A.md"]))
        await fixture.gate!.waitForArrivals(1)
        note.text = "mine\n"
        await fixture.gate!.open()
        await reconciler.waitUntilIdle()

        #expect(note.text == "mine\n")
        #expect(note.externalChange == .modified("theirs\n"))
    }

    @Test("a reload never replaces text typed during the read; it reads again first")
    func typingBackToCleanRereads() async throws {
        let fixture = try fixture(notes: ["A.md": "old\n"], gated: true)
        let reconciler = makeReconciler(fixture)
        let note = document("A.md", in: fixture)
        try fixture.temp.write("theirs\n", to: "A.md")

        reconciler.submit(VaultChange(relativePaths: ["A.md"]))
        await fixture.gate!.waitForArrivals(1)
        note.text = "old\n!"
        note.text = "old\n"
        await fixture.gate!.open()
        await reconciler.waitUntilIdle()

        #expect(reconciler.passCount == 2)
        #expect(fixture.recorder.reads == ["A.md", "A.md"])
        #expect(note.text == "theirs\n")
        #expect(note.hasUnsavedChanges == false)
    }

    @Test("an outside deletion is signalled and restoring the file clears it")
    func deletionAndRecreation() async throws {
        let fixture = try fixture(notes: ["A.md": "old\n"])
        let reconciler = makeReconciler(fixture)
        let note = document("A.md", in: fixture)

        try FileManager.default.removeItem(at: fixture.temp.vault.rootURL.appendingPathComponent("A.md"))
        reconciler.submit(VaultChange(relativePaths: ["A.md"]))
        await reconciler.waitUntilIdle()
        #expect(note.externalChange == .deleted)
        #expect(note.text == "old\n")

        try fixture.temp.write("old\n", to: "A.md")
        reconciler.submit(VaultChange(relativePaths: ["A.md"]))
        await reconciler.waitUntilIdle()
        #expect(note.externalChange == nil)
        #expect(note.hasUnsavedChanges == false)
    }

    @Test("the app's own save reported by the watcher changes nothing")
    func ownSaveIsQuiet() async throws {
        let fixture = try fixture(notes: ["A.md": "old\n"])
        let reconciler = makeReconciler(fixture)
        let note = document("A.md", in: fixture)
        note.text = "saved\n"
        try note.save()
        let revision = note.revision

        reconciler.submit(VaultChange(relativePaths: ["A.md"]))
        await reconciler.waitUntilIdle()

        #expect(note.externalChange == nil)
        #expect(note.revision == revision)
        #expect(reconciler.passCount == 1)
    }

    @Test("a tab closed during a read is left alone")
    func closedTabSkipped() async throws {
        let fixture = try fixture(notes: ["A.md": "old\n"], gated: true)
        let reconciler = makeReconciler(fixture)
        let note = document("A.md", in: fixture)
        try fixture.temp.write("theirs\n", to: "A.md")

        reconciler.submit(VaultChange(relativePaths: ["A.md"]))
        await fixture.gate!.waitForArrivals(1)
        fixture.session.closeTab(documentID: note.id)
        await fixture.gate!.open()
        await reconciler.waitUntilIdle()

        #expect(note.text == "old\n")
        #expect(reconciler.passCount == 1)
    }

    @Test("after cancel (another Vault opened) nothing in progress is applied")
    func cancelAppliesNothing() async throws {
        let fixture = try fixture(notes: ["A.md": "old\n"], gated: true)
        let sink = TreeSink()
        let reconciler = makeReconciler(fixture, sink: sink)
        try fixture.temp.write("theirs\n", to: "A.md")

        reconciler.submit(VaultChange(relativePaths: ["A.md"]))
        await fixture.gate!.waitForArrivals(1)
        reconciler.cancel()
        reconciler.submit(VaultChange(relativePaths: ["A.md"]))
        await fixture.gate!.open()
        await reconciler.waitUntilIdle()

        #expect(sink.trees.isEmpty)
        #expect(document("A.md", in: fixture).text == "old\n")
        #expect(reconciler.passCount == 1)
    }

    @Test("a tree scanned on the main actor meanwhile is not replaced by an older scan")
    func discardsOlderTreeScan() async throws {
        let fixture = try fixture(notes: ["A.md": "a\n"], gated: true)
        let sink = TreeSink()
        let reconciler = makeReconciler(fixture, sink: sink)

        reconciler.submit(VaultChange(relativePaths: ["A.md"]))
        await fixture.gate!.waitForArrivals(1)
        reconciler.discardTreeScansInProgress()
        await fixture.gate!.open()
        await reconciler.waitUntilIdle()

        #expect(sink.trees.isEmpty)
    }

    @Test("the live environment reconciles a real Vault")
    func liveEnvironment() async throws {
        let temp = try TemporaryVault()
        try temp.write("old\n", to: "Notes/A.md")
        let session = TabSession()
        let note = try session.openNote(at: temp.vault.rootURL.appendingPathComponent("Notes/A.md"))
        let sink = TreeSink()
        let reconciler = VaultReconciler(vault: temp.vault, tabSession: session) { sink.trees.append($0) }
        try temp.write("new\n", to: "Notes/A.md")
        try temp.write("x\n", to: "Notes/B.md")

        reconciler.submit(VaultChange(relativePaths: ["Notes/A.md", "Notes/B.md"]))
        await reconciler.waitUntilIdle()

        #expect(note.text == "new\n")
        #expect(sink.trees.last == temp.vault.scanTree())
    }
}

@Suite("Vault changes")
struct VaultChangeTests {
    @Test("merging unions the paths and keeps a full rescan")
    func merging() {
        let merged = VaultChange(relativePaths: ["A.md"])
            .merging(VaultChange(relativePaths: ["B.md"], requiresFullRescan: true))
        #expect(merged.relativePaths == ["A.md", "B.md"])
        #expect(merged.requiresFullRescan)
        #expect(!VaultChange(relativePaths: ["A.md"]).merging(VaultChange(relativePaths: [])).requiresFullRescan)
    }

    @Test("a change affects the changed file, notes inside a changed folder and everything at the root")
    func affects() {
        let change = VaultChange(relativePaths: ["Notes/Idea.md", "Daily"])
        #expect(change.affects(relativePath: "Notes/Idea.md"))
        #expect(change.affects(relativePath: "notes/idea.md"))
        #expect(change.affects(relativePath: "Daily/2026/2026-01-01.md"))
        #expect(!change.affects(relativePath: "Notes/Other.md"))
        #expect(!change.affects(relativePath: "DailyLog.md"))
        #expect(VaultChange(relativePaths: [""]).affects(relativePath: "Any/Note.md"))
        #expect(VaultChange(relativePaths: [], requiresFullRescan: true).affects(relativePath: "Any/Note.md"))
    }
}

@MainActor
@Suite("Coalescing queue")
struct CoalescingQueueTests {
    @Test("work submitted during a pass is merged into one next pass")
    func coalesces() async {
        var performed: [Set<Int>] = []
        var release: CheckedContinuation<Void, Never>?
        var started: CheckedContinuation<Void, Never>?
        let queue = CoalescingQueue<Set<Int>>(
            merge: { $0.formUnion($1) },
            perform: { work in
                performed.append(work)
                if performed.count == 1 {
                    started?.resume()
                    await withCheckedContinuation { release = $0 }
                }
            }
        )

        await withCheckedContinuation { continuation in
            started = continuation
            queue.submit([1])
        }
        for value in 2...10 { queue.submit([value]) }
        release?.resume()
        await queue.waitUntilIdle()

        #expect(queue.passCount == 2)
        #expect(performed == [[1], Set(2...10)])
        #expect(queue.isIdle)
    }

    @Test("work submitted by a pass runs next")
    func followUp() async {
        var performed: [Int] = []
        var queue: CoalescingQueue<Int>!
        queue = CoalescingQueue<Int>(
            merge: { $0 += $1 },
            perform: { work in
                performed.append(work)
                if work == 1 { queue.submit(2) }
            }
        )
        queue.submit(1)
        await queue.waitUntilIdle()
        #expect(performed == [1, 2])
    }
}
