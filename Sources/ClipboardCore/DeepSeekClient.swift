import Foundation

public protocol AnswerClient: Sendable {
    func answer(text: String, key: String, configuration: Configuration) async throws -> String
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward the Authorization header to another endpoint.
    }
}

public final class DeepSeekClient: AnswerClient, Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: Self.sessionConfiguration(), delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    public static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return config
    }

    public static func request(text: String, key: String, configuration: Configuration) throws -> URLRequest {
        struct Message: Encodable { let role: String; let content: String }
        struct Thinking: Encodable { let type = "disabled" }
        struct Body: Encodable {
            let model: String
            let messages: [Message]
            let stream = false
            let thinking: Thinking?
            let max_tokens: Int
        }
        try configuration.validate()
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else {
            throw PipelineError.missingCredential
        }
        var request = URLRequest(url: URL(string: configuration.apiEndpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Body(model: configuration.model, messages: [
            Message(role: "system", content: configuration.systemPrompt), Message(role: "user", content: text)
        ], thinking: request.url?.host == "api.deepseek.com" ? Thinking() : nil,
        max_tokens: configuration.maxOutputTokens))
        return request
    }

    public func answer(text: String, key: String, configuration: Configuration) async throws -> String {
        do {
            let request = try Self.request(text: text, key: key, configuration: configuration)
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw PipelineError.invalidResponse }
            guard http.statusCode == 200 else {
                bytes.task.cancel()
                if (300..<400).contains(http.statusCode) { throw PipelineError.redirectRefused }
                throw PipelineError.http(http.statusCode)
            }
            var body = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < 1_048_576 else { bytes.task.cancel(); throw PipelineError.responseTooLarge }
                body.append(byte)
            }
            return try Self.decode(body)
        } catch is CancellationError { throw CancellationError() }
        catch let error as PipelineError { throw error }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw PipelineError.timedOut }
            throw PipelineError.network
        } catch { throw PipelineError.network }
    }

    public static func decode(_ data: Data) throws -> String {
        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let role: String
                    let content: String?
                    let tool_calls: [Tool]?
                    struct Tool: Decodable {}
                }
                let finish_reason: String?
                let message: Message
            }
            let choices: [Choice]
        }
        guard data.count <= 1_048_576 else { throw PipelineError.responseTooLarge }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              reply.choices.count == 1, let choice = reply.choices.first,
              choice.message.role == "assistant" else { throw PipelineError.invalidResponse }
        guard choice.finish_reason == "stop", choice.message.tool_calls?.isEmpty != false
        else { throw PipelineError.incompleteResponse }
        guard let content = choice.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PipelineError.emptyResponse }
        return content // Deliberately no reasoning_content, trimming or markdown rewriting.
    }
}
