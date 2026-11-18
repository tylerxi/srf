import Foundation

public struct PipelineStatus: Codable, Sendable {
    public var state = "idle"
    public var error: String?
    public var requestID: UInt64 = 0
    public var completedCount = 0
    public var durationMilliseconds: Int?
    public var paused = false
    public var remainingCharacters = 0
    public init() {}
}

/// MainActor serializes capture, generation changes and the final check+write.
/// Network I/O suspends; no UI, process inspection, or clipboard polling is performed.
@MainActor public final class RequestCoordinator {
    public private(set) var status = PipelineStatus()
    public var configuration: Configuration
    /// Called on the main actor after a complete answer is accepted and stored in memory.
    /// Implementations must return immediately; long work belongs on their own queue.
    public var onAnswerReady: ((String) -> Void)?
    private let clipboard: any ClipboardAccess
    private let client: any AnswerClient
    private let credential: @MainActor () throws -> String
    private var requestTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var answerBuffer: [Character]?
    private var answerOffset = 0
    private var answerClipboardVersion: Int?

    public init(clipboard: any ClipboardAccess, client: any AnswerClient,
                configuration: Configuration = Configuration(),
                credential: @escaping @MainActor () throws -> String) {
        self.clipboard = clipboard; self.client = client
        self.configuration = configuration; self.credential = credential
    }

    public func trigger() {
        guard !status.paused else { return }
        invalidate()
        let id = generation
        status.requestID = id; status.error = nil; status.durationMilliseconds = nil
        status.state = "reading_clipboard"
        do {
            let snapshot = try ClipboardTransaction.capture(clipboard, maxBytes: configuration.maxInputBytes)
            let prefix = configuration.triggerPrefix
            guard snapshot.text.hasPrefix(prefix) else { status.state = "ignored"; return }
            let question = String(snapshot.text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { throw PipelineError.noText }
            let key = try credential()
            guard !key.isEmpty else { throw PipelineError.missingCredential }
            let config = configuration
            let client = client
            let started = ContinuousClock.now
            status.state = "requesting"
            requestTask = Task { [weak self] in
                do {
                    let answer = try await client.answer(text: question, key: key, configuration: config)
                    guard let self, self.generation == id, !Task.isCancelled else { return }
                    guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PipelineError.emptyResponse }
                    guard self.clipboard.accessAllowed else { throw PipelineError.permission }
                    guard self.clipboard.version == snapshot.version else { throw PipelineError.clipboardChanged }
                    self.answerBuffer = Array(answer); self.answerOffset = 0
                    self.answerClipboardVersion = snapshot.version
                    self.status.remainingCharacters = self.answerBuffer!.count
                    self.status.state = "ready"; self.status.completedCount += 1
                    self.onAnswerReady?(answer)
                    self.finish(started: started)
                } catch {
                    guard let self, self.generation == id, !Task.isCancelled else { return }
                    self.status.state = "failed"
                    self.status.error = (error as? PipelineError)?.code ?? "network_error"
                    self.finish(started: started)
                }
            }
            deadlineTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(config.timeoutSeconds)) } catch { return }
                guard let self, self.generation == id, self.status.state == "requesting" else { return }
                self.invalidate()
                self.status.state = "failed"; self.status.error = PipelineError.timedOut.code
                self.setDuration(started)
            }
        } catch {
            status.state = "failed"
            status.error = (error as? PipelineError)?.code ?? "keychain_unavailable"
        }
    }

    public func cancel(reason: String = "cancelled") {
        invalidate(); status.state = reason; status.error = nil
    }
    public func setPaused(_ value: Bool) {
        cancel(reason: value ? "paused" : "idle"); status.paused = value
    }

    /// The cursor moves only when the sink accepts dispatch. Never reads destination content.
    @discardableResult public func outputNext(using send: (String) -> Bool) -> Bool {
        guard !status.paused, let buffer = answerBuffer else { return false }
        guard clipboard.accessAllowed, clipboard.version == answerClipboardVersion else {
            cancel(reason: "clipboard_changed"); return false
        }
        let end = min(answerOffset + 2, buffer.count)
        let chunk = answerOffset < buffer.count ? String(buffer[answerOffset..<end]) : ".."
        guard send(chunk) else { return false }
        answerOffset = end
        status.remainingCharacters = buffer.count - end
        status.state = end == buffer.count ? "exhausted" : "ready"
        return true
    }
    private func invalidate() {
        generation &+= 1
        requestTask?.cancel(); requestTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        answerBuffer = nil; answerOffset = 0; answerClipboardVersion = nil
        status.remainingCharacters = 0
    }
    private func finish(started: ContinuousClock.Instant) {
        deadlineTask?.cancel(); deadlineTask = nil; requestTask = nil
        setDuration(started)
    }
    private func setDuration(_ started: ContinuousClock.Instant) {
        let components = started.duration(to: .now).components
        status.durationMilliseconds = Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
