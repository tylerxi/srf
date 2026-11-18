import Testing
import Foundation
@testable import ClipboardCore

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "X-Test-Scenario") ?? "success"
        if scenario == "offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let code = Int(scenario) ?? 200
        let reply = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        let body = scenario == "bad-json" ? "not json" : """
        {"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"答复\\n","reasoning_content":"PRIVATE REASONING"}}]}
        """
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct NetworkTests {
    @Test func requestUsesOnlyExplicitSnapshot() throws {
        let config = Configuration()
        let request = try DeepSeekClient.request(text: "https://example.com/not-fetched", key: "fixture", configuration: config)
        #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["stream"] as? Bool == false)
        #expect((json["thinking"] as? [String: String])?["type"] == "disabled")
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[1] == ["role": "user", "content": "https://example.com/not-fetched"])
        #expect(json["tools"] == nil)
    }
    @Test func sessionHasNoPersistentStores() {
        let config = DeepSeekClient.sessionConfiguration()
        #expect(config.urlCache == nil); #expect(config.httpCookieStorage == nil)
        #expect(config.urlCredentialStorage == nil); #expect(!config.httpShouldSetCookies)
    }
    @Test func responseKeepsAnswerFormattingAndDiscardsReasoning() throws {
        let data = Data(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"  答案\n","reasoning_content":"not the answer"}}]}"#.utf8)
        #expect(try DeepSeekClient.decode(data) == "  答案\n")
    }
    @Test(arguments: ["length", "content_filter", "tool_calls", "aborted", "insufficient_system_resource"])
    func incompleteResultsAreRejected(reason: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": reason,
            "message": ["role": "assistant", "content": "partial"]]]])
        #expect(throws: PipelineError.incompleteResponse) { try DeepSeekClient.decode(data) }
    }
    @Test(arguments: ["null", "\"\"", "\"  \\n\""])
    func emptyAnswersAreRejected(content: String) {
        let data = Data("{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"role\":\"assistant\",\"content\":\(content)}}]}".utf8)
        #expect(throws: PipelineError.emptyResponse) { try DeepSeekClient.decode(data) }
    }
    @Test func malformedJSONIsRejected() {
        #expect(throws: PipelineError.invalidResponse) { try DeepSeekClient.decode(Data("bad".utf8)) }
    }
    @Test func toolCallCannotSneakThroughStop() {
        let data = Data(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"answer","tool_calls":[{}]}}]}"#.utf8)
        #expect(throws: PipelineError.incompleteResponse) { try DeepSeekClient.decode(data) }
    }
    @Test(arguments: ["success", "401", "402", "429", "500", "bad-json", "offline"])
    func actualURLSessionDecodingAndFailures(scenario: String) async throws {
        let config = DeepSeekClient.sessionConfiguration()
        config.protocolClasses = [StubProtocol.self]
        config.httpAdditionalHeaders = ["X-Test-Scenario": scenario]
        let client = DeepSeekClient(session: URLSession(configuration: config))
        do {
            let answer = try await client.answer(text: "test", key: "fixture", configuration: Configuration())
            #expect(scenario == "success"); #expect(answer == "答复\n")
        } catch {
            let expected: PipelineError = Int(scenario).map(PipelineError.http) ?? (scenario == "bad-json" ? .invalidResponse : .network)
            #expect(error as? PipelineError == expected)
            #expect(scenario != "success")
        }
    }
    @Test func configRejectsUnsafeShortcutAndInvalidModel() {
        var config = Configuration(); config.hotKeyModifiers = 0
        #expect(throws: PipelineError.invalidConfiguration) { try config.validate() }
        config = Configuration(); config.model = "bad\r\nmodel"
        #expect(throws: PipelineError.invalidConfiguration) { try config.validate() }
        config = Configuration(); config.timeoutSeconds = .infinity
        #expect(throws: PipelineError.invalidConfiguration) { try config.validate() }
    }
    @Test func legacyShortcutDefaultsMigrateToControlC() throws {
        let old = try JSONDecoder().decode(Configuration.self, from: Data(#"{"hotKeyCode":38,"hotKeyModifiers":6400}"#.utf8))
        #expect(old.hotKeyCode == 8); #expect(old.hotKeyModifiers == 4096); #expect(old.triggerPrefix == "!!!")
    }
    @Test func oldConfigurationMigratesAndCustomEndpointUsesSystemPrompt() throws {
        let old = try JSONDecoder().decode(Configuration.self, from: Data(#"{"model":"deepseek-flash"}"#.utf8))
        #expect(old.apiEndpoint == "https://api.deepseek.com/chat/completions")
        var config = old; config.apiEndpoint = "https://example.com/v1/chat/completions"
        config.model = "vendor/model:1.0"; config.systemPrompt = "角色资料。答案不超过30个字符。"
        let request = try DeepSeekClient.request(text: "question", key: "fixture", configuration: config)
        #expect(request.url?.absoluteString == config.apiEndpoint)
        let json = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(json["thinking"] == nil)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages[0]["content"] == config.systemPrompt)
    }
    @Test(arguments: ["http://example.com/chat", "https://user:pass@example.com/chat", "https://example.com/chat?token=secret", "https://example.com/chat#fragment"])
    func endpointValidation(endpoint: String) {
        var config = Configuration(); config.apiEndpoint = endpoint
        #expect(throws: PipelineError.invalidConfiguration) { try config.validate() }
    }

}
