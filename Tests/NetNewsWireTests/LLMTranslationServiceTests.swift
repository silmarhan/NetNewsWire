//
//  LLMTranslationServiceTests.swift
//  NetNewsWireTests
//

import Foundation
import Testing
@testable import NetNewsWire

@Suite(.serialized) struct LLMTranslationServiceTests {

    // MARK: - Mock URLProtocol

    final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var stub: ((URLRequest) -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var lastBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            MockURLProtocol.lastRequest = request
            // URLSession may put the body on httpBodyStream when the body is large enough.
            if let body = request.httpBody {
                MockURLProtocol.lastBody = body
            } else if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buf.deallocate(); stream.close() }
                while stream.hasBytesAvailable {
                    let n = stream.read(buf, maxLength: 4096)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                MockURLProtocol.lastBody = data
            }
            guard let stub = MockURLProtocol.stub else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let (response, data) = stub(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    init() {
        MockURLProtocol.stub = nil
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.lastBody = nil
    }

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    // MARK: - Tests

    @Test func successPathParsesContent() async throws {
        MockURLProtocol.stub = { _ in
            let json = """
            {"choices":[{"message":{"role":"assistant","content":"<h1>译标题</h1><p>正文</p>"}}]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: URL(string: "https://example.com")!,
                                           statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, json)
        }
        let service = LLMTranslationService(session: mockSession())
        let html = try await service.translate(
            title: "Title",
            bodyHTML: "<p>body</p>",
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "sk-test"
        )
        #expect(html == "<h1>译标题</h1><p>正文</p>")
    }

    @Test func requestShape() async throws {
        MockURLProtocol.stub = { _ in
            let json = """
            {"choices":[{"message":{"content":"<h1>t</h1><p>b</p>"}}]}
            """.data(using: .utf8)!
            let r = HTTPURLResponse(url: URL(string: "https://example.com")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, json)
        }
        let service = LLMTranslationService(session: mockSession())
        _ = try await service.translate(
            title: "Hello",
            bodyHTML: "<p>World</p>",
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "deepseek-chat",
            apiKey: "sk-secret"
        )
        let req = try #require(MockURLProtocol.lastRequest)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let bodyData = try #require(MockURLProtocol.lastBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model"] as? String == "deepseek-chat")
        #expect(body["stream"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[1]["role"] == "user")
        let userContent = try #require(messages[1]["content"])
        #expect(userContent.contains("<h1>Hello</h1>"))
        #expect(userContent.contains("<p>World</p>"))
    }

    @Test func http401SurfacesProviderError() async {
        MockURLProtocol.stub = { _ in
            let json = """
            {"error":{"message":"Invalid API key","type":"invalid_request_error"}}
            """.data(using: .utf8)!
            let r = HTTPURLResponse(url: URL(string: "https://example.com")!,
                                     statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (r, json)
        }
        let service = LLMTranslationService(session: mockSession())
        await #expect(throws: LLMTranslationService.TranslationError.self) {
            _ = try await service.translate(title: "x", bodyHTML: "y",
                                             baseURL: URL(string: "https://api.example.com/v1")!,
                                             model: "m", apiKey: "bad")
        }
        do {
            _ = try await service.translate(title: "x", bodyHTML: "y",
                                             baseURL: URL(string: "https://api.example.com/v1")!,
                                             model: "m", apiKey: "bad")
            Issue.record("expected error")
        } catch let LLMTranslationService.TranslationError.providerError(message, status) {
            #expect(message == "Invalid API key")
            #expect(status == 401)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func http500GenericProviderError() async {
        MockURLProtocol.stub = { _ in
            let r = HTTPURLResponse(url: URL(string: "https://example.com")!,
                                     statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (r, Data())
        }
        let service = LLMTranslationService(session: mockSession())
        do {
            _ = try await service.translate(title: "x", bodyHTML: "y",
                                             baseURL: URL(string: "https://api.example.com/v1")!,
                                             model: "m", apiKey: "k")
            Issue.record("expected error")
        } catch LLMTranslationService.TranslationError.providerError(_, let status) {
            #expect(status == 500)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func networkFailurePropagates() async {
        MockURLProtocol.stub = nil  // → URLError(.notConnectedToInternet)
        let service = LLMTranslationService(session: mockSession())
        do {
            _ = try await service.translate(title: "x", bodyHTML: "y",
                                             baseURL: URL(string: "https://api.example.com/v1")!,
                                             model: "m", apiKey: "k")
            Issue.record("expected error")
        } catch LLMTranslationService.TranslationError.network {
            // ok
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func malformedJSONFailsClearly() async {
        MockURLProtocol.stub = { _ in
            let r = HTTPURLResponse(url: URL(string: "https://example.com")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, Data("not json".utf8))
        }
        let service = LLMTranslationService(session: mockSession())
        do {
            _ = try await service.translate(title: "x", bodyHTML: "y",
                                             baseURL: URL(string: "https://api.example.com/v1")!,
                                             model: "m", apiKey: "k")
            Issue.record("expected error")
        } catch LLMTranslationService.TranslationError.malformedResponse {
            // ok
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
