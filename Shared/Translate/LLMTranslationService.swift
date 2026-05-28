//
//  LLMTranslationService.swift
//  NetNewsWire
//

import Foundation

struct LLMTranslationService {

    enum TranslationError: Error {
        case network(URLError)
        case providerError(message: String, status: Int)
        case malformedResponse
    }

    private static let systemPrompt = """
    You are a professional translator. Translate the user's input into \
    Simplified Chinese. Preserve all HTML tags, attributes, hyperlinks, \
    code blocks, and inline formatting exactly. Do not translate text \
    inside <code>, <pre>, or attributes. Do not add commentary. Output \
    only the translated HTML.
    """

    private let session: URLSession
    private let timeout: TimeInterval

    init(session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.session = session
        self.timeout = timeout
    }

    func translate(title: String,
                   bodyHTML: String,
                   baseURL: URL,
                   model: String,
                   apiKey: String) async throws -> String {

        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let userContent = "<h1>\(title)</h1>\n\(bodyHTML)"
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "stream": false,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user",   "content": userContent]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw TranslationError.network(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.malformedResponse
        }

        if !(200..<300).contains(http.statusCode) {
            let message = Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw TranslationError.providerError(message: message, status: http.statusCode)
        }

        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.malformedResponse
        }
        return content
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any],
              let msg = err["message"] as? String else { return nil }
        return msg
    }
}
