import Testing
import Foundation
import AppKit
@testable import ClipboardCore

@MainActor private final class FakeClipboard: ClipboardAccess {
    var accessAllowed = true
    var version = 1
    var text: String? = "!!! question A"
    var reads = 0
    var writes = 0
    var readMutation = false
    var writeSucceeds = true
    var localOnly: Bool?
    func readPlainText() -> String? {
        reads += 1
        if readMutation { version += 1 }
        return text
    }
    func writeAnswer(_ value: String, localOnly: Bool) -> Bool {
        guard writeSucceeds else { return false }
        text = value; version += 1; writes += 1; self.localOnly = localOnly
        return true
    }
    func copy(_ value: String) { text = value; version += 1 }
}

private actor ControlledClient: AnswerClient {
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private(set) var calls = [String]()
    func answer(text: String, key: String, configuration: Configuration) async throws -> String {
        calls.append(text)
        return try await withCheckedThrowingContinuation { pending[text] = $0 }
    }
    func has(_ text: String) -> Bool { pending[text] != nil }
    func finish(_ text: String, _ result: Result<String, Error>) { pending.removeValue(forKey: text)?.resume(with: result) }
}

@MainActor @Suite struct ClipboardTests {
    @Test func deniedNeverReadsOrWrites() {
        let clipboard = FakeClipboard(); clipboard.accessAllowed = false
        #expect(throws: PipelineError.permission) { try ClipboardTransaction.capture(clipboard, maxBytes: 100) }
        #expect(clipboard.reads == 0); #expect(clipboard.writes == 0)
    }
    @Test func snapshotDoesNotWriteAndPreservesWhitespace() throws {
        let clipboard = FakeClipboard(); clipboard.text = "  问题\n"
        let snapshot = try ClipboardTransaction.capture(clipboard, maxBytes: 100)
        #expect(snapshot.text == "  问题\n"); #expect(snapshot.version == 1)
        #expect(clipboard.writes == 0); #expect(clipboard.version == 1)
    }
    @Test func inconsistentReadIsRejected() {
        let clipboard = FakeClipboard(); clipboard.readMutation = true
        #expect(throws: PipelineError.clipboardChanged) { try ClipboardTransaction.capture(clipboard, maxBytes: 100) }
    }
    @Test(arguments: [nil, "", " \n\t"] as [String?]) func noTextIsRejected(text: String?) {
        let clipboard = FakeClipboard(); clipboard.text = text
        #expect(throws: PipelineError.noText) { try ClipboardTransaction.capture(clipboard, maxBytes: 100) }
    }
    @Test func inputLimitCountsUTF8() {
        let clipboard = FakeClipboard(); clipboard.text = "中文"
        #expect(throws: PipelineError.inputTooLarge) { try ClipboardTransaction.capture(clipboard, maxBytes: 5) }
        #expect(clipboard.writes == 0)
    }
    @Test func newCopyEvenSameTextPreventsCommit() throws {
        let clipboard = FakeClipboard()
        let snapshot = try ClipboardTransaction.capture(clipboard, maxBytes: 100)
        clipboard.copy("question A")
        #expect(throws: PipelineError.clipboardChanged) {
            try ClipboardTransaction.commit("answer", expectedVersion: snapshot.version, to: clipboard, localOnly: true)
        }
        #expect(clipboard.writes == 0)
    }
    @Test func permissionRevokedBeforeCommit() {
        let clipboard = FakeClipboard(); clipboard.accessAllowed = false
        #expect(throws: PipelineError.permission) {
            try ClipboardTransaction.commit("answer", expectedVersion: 1, to: clipboard, localOnly: true)
        }
        #expect(clipboard.writes == 0)
    }
    @Test func actualNamedPasteboardRoundTrip() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("test prompt 中文\n", forType: .string)
        let clipboard = SystemClipboard(pasteboard: board)
        let snapshot = try ClipboardTransaction.capture(clipboard, maxBytes: 100)
        #expect(snapshot.text == "test prompt 中文\n")
        #expect(board.changeCount == snapshot.version)
        try ClipboardTransaction.commit("answer ✅\n", expectedVersion: snapshot.version, to: clipboard, localOnly: true)
        #expect(board.string(forType: .string) == "answer ✅\n")
        #expect(board.types?.contains(.string) == true)
        #expect(board.types?.contains(.html) == false)
        #expect(board.types?.contains(.rtf) == false)
    }
    @Test func imageAndFilePasteboardsAreNotExpanded() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("file:///tmp/not-to-be-read", forType: .fileURL)
        let clipboard = SystemClipboard(pasteboard: board)
        #expect(throws: PipelineError.noText) { try ClipboardTransaction.capture(clipboard, maxBytes: 100) }
        board.clearContents(); board.setData(Data([1, 2, 3]), forType: .png)
        #expect(throws: PipelineError.noText) { try ClipboardTransaction.capture(clipboard, maxBytes: 100) }
    }
}

@MainActor @Suite struct CoordinatorTests {
    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for test state")
    }
    private func make(_ board: FakeClipboard, _ client: ControlledClient) -> RequestCoordinator {
        RequestCoordinator(clipboard: board, client: client, credential: { "fixture-key" })
    }
    @Test func successWritesOnlyAfterComplete() async throws {
        let board = FakeClipboard(); let client = ControlledClient(); let engine = make(board, client)
        engine.trigger()
        try await wait { await client.has("question A") }
        #expect(board.text == "!!! question A"); #expect(board.writes == 0)
        await client.finish("question A", .success("answer A"))
        try await wait { engine.status.state == "ready" }
        #expect(board.text == "!!! question A"); #expect(board.writes == 0)
        var chunk = ""
        #expect(engine.outputNext { chunk = $0; return true }); #expect(chunk == "an")
        #expect(engine.status.remainingCharacters == 6); #expect(engine.status.completedCount == 1)
    }
    @Test func answerReadyCallbackFiresOnceAfterAcceptedAnswer() async throws {
        let board = FakeClipboard(); let client = ControlledClient(); let engine = make(board, client)
        var answers = [String]()
        engine.onAnswerReady = { answers.append($0) }
        engine.trigger(); try await wait { await client.has("question A") }
        #expect(answers.isEmpty)
        await client.finish("question A", .success("callback answer"))
        try await wait { engine.status.state == "ready" }
        #expect(answers == ["callback answer"])
    }
    @Test func copyDuringRequestPreservesNewClipboard() async throws {
        let board = FakeClipboard(); let client = ControlledClient(); let engine = make(board, client)
        engine.trigger(); try await wait { await client.has("question A") }
        board.copy("new copy B")
        await client.finish("question A", .success("late A"))
        try await wait { engine.status.state == "failed" }
        #expect(engine.status.error == "clipboard_changed")
        #expect(board.text == "new copy B"); #expect(board.writes == 0)
    }
    @Test func outOfOrderIgnoringCancellationCannotWrite() async throws {
        let board = FakeClipboard(); let client = ControlledClient(); let engine = make(board, client)
        engine.trigger(); try await wait { await client.has("question A") }
        board.copy("!!! question B"); engine.trigger()
        try await wait { await client.has("question B") }
        await client.finish("question B", .success("answer B"))
        try await wait { engine.status.state == "ready" }
        await client.finish("question A", .success("late answer A"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(board.text == "!!! question B"); #expect(board.writes == 0)
        #expect(engine.status.remainingCharacters == 8)
        #expect(engine.status.completedCount == 1)
    }
    @Test func pauseAndSuspendInvalidateInFlightResult() async throws {
        let board = FakeClipboard(); let client = ControlledClient(); let engine = make(board, client)
        engine.trigger(); try await wait { await client.has("question A") }
        engine.setPaused(true); engine.trigger()
        await client.finish("question A", .success("late answer"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(board.writes == 0); #expect(engine.status.state == "paused")
        engine.setPaused(false); board.copy("!!! question B"); engine.trigger()
        try await wait { await client.has("question B") }
        engine.cancel(reason: "suspended")
        await client.finish("question B", .success("late answer"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(board.writes == 0); #expect(engine.status.state == "suspended")
    }
    @Test func deadlineRejectsLateResponseEvenIfClientIgnoresCancellation() async throws {
        let board = FakeClipboard(); let client = ControlledClient(); let engine = make(board, client)
        engine.configuration.timeoutSeconds = 0.05
        engine.trigger(); try await wait { await client.has("question A") }
        try await wait { engine.status.error == "timeout" }
        await client.finish("question A", .success("too late"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(board.writes == 0); #expect(engine.status.error == "timeout")
    }
    @Test(arguments: [PipelineError.http(401), .http(402), .http(429), .http(500), .network, .timedOut, .invalidResponse, .incompleteResponse, .emptyResponse])
    func errorsPreserveClipboard(error: PipelineError) async throws {
        let board = FakeClipboard(); let client = ControlledClient(); let engine = make(board, client)
        engine.trigger(); try await wait { await client.has("question A") }
        await client.finish("question A", .failure(error))
        try await wait { engine.status.state == "failed" }
        #expect(board.text == "!!! question A"); #expect(board.writes == 0)
        #expect(engine.status.error == error.code)
    }
    @Test func missingCredentialNeverStartsNetwork() async throws {
        let board = FakeClipboard(); let client = ControlledClient()
        let engine = RequestCoordinator(clipboard: board, client: client, credential: { throw PipelineError.missingCredential })
        engine.trigger()
        #expect(engine.status.error == "key_missing"); #expect(await client.calls.isEmpty)
        #expect(board.writes == 0)
    }
    @Test func newInvalidTriggerCancelsOldRequest() async throws {
        let board = FakeClipboard(); let client = ControlledClient(); let engine = make(board, client)
        engine.trigger(); try await wait { await client.has("question A") }
        board.text = nil; board.version += 1; engine.trigger()
        await client.finish("question A", .success("late"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(board.writes == 0); #expect(engine.status.error == "no_plain_text")
    }
    @Test(arguments: ["question without marker", "$C question", "普通中文问题"])
    func unmarkedTextNeverReadsCredentialOrCallsNetwork(text: String) async {
        let board = FakeClipboard(); board.text = text; let client = ControlledClient()
        var keyReads = 0
        let engine = RequestCoordinator(clipboard: board, client: client, credential: { keyReads += 1; return "fixture" })
        engine.trigger()
        #expect(engine.status.state == "ignored"); #expect(keyReads == 0)
        #expect(await client.calls.isEmpty); #expect(board.writes == 0)
        #expect(!engine.outputNext { _ in Issue.record("Must not output"); return true })
    }
    @Test func characterChunksRetryOddTailAndExhaustion() async throws {
        let board = FakeClipboard(); let client = ControlledClient(); let engine = make(board, client)
        engine.trigger(); try await wait { await client.has("question A") }
        #expect(!engine.outputNext { _ in true })
        await client.finish("question A", .success("中文👨‍👩‍👧‍👦e\u{301}末"))
        try await wait { engine.status.state == "ready" }
        #expect(engine.status.remainingCharacters == 5)
        #expect(!engine.outputNext { _ in false })
        #expect(engine.status.remainingCharacters == 5)
        var chunks = [String]()
        for _ in 0..<5 { #expect(engine.outputNext { chunks.append($0); return true }) }
        #expect(chunks == ["中文", "👨‍👩‍👧‍👦e\u{301}", "末", "..", ".."])
        #expect(board.writes == 0)
        board.copy("no marker"); engine.trigger()
        #expect(!engine.outputNext { _ in true })
        #expect(engine.status.state == "ignored")
    }
    @Test func copiedTextAfterReadyDisarmsOutputWithoutReadingIt() async throws {
        let board = FakeClipboard(); let client = ControlledClient(); let engine = make(board, client)
        engine.trigger(); try await wait { await client.has("question A") }
        await client.finish("question A", .success("answer"))
        try await wait { engine.status.state == "ready" }
        let reads = board.reads; board.copy("new text")
        #expect(!engine.outputNext { _ in true }); #expect(board.reads == reads)
        #expect(engine.status.remainingCharacters == 0)
    }
    @Test func markerOnlyCannotSubmit() async {
        let board = FakeClipboard(); board.text = "!!!   "; let client = ControlledClient(); let engine = make(board, client)
        engine.trigger(); #expect(engine.status.error == "no_plain_text")
        #expect(await client.calls.isEmpty)
    }
    @Test func configurablePrefixMustBeAtStartAndIsRemovedBeforeRequest() async throws {
        let board = FakeClipboard(); board.text = "ASK: question"; let client = ControlledClient()
        let engine = make(board, client); engine.configuration.triggerPrefix = "ASK:"
        engine.trigger(); try await wait { await client.has("question") }
        #expect(await client.calls == ["question"])
    }

}
