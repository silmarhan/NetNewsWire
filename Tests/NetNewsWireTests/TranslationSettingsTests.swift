//
//  TranslationSettingsTests.swift
//  NetNewsWireTests
//

import Foundation
import Testing
@testable import NetNewsWire

@Suite struct TranslationSettingsTests {

    private let suiteName: String
    private let suite: UserDefaults

    init() {
        let name = "TranslationSettingsTests-\(UUID().uuidString)"
        self.suiteName = name
        self.suite = UserDefaults(suiteName: name)!
    }

    @Test func defaultsAreDeepSeek() {
        let settings = TranslationSettings(defaults: suite, apiKey: { nil })
        #expect(settings.baseURL == URL(string: "https://api.deepseek.com/v1"))
        #expect(settings.model == "deepseek-chat")
    }

    @Test func baseURLRoundtrip() {
        let settings = TranslationSettings(defaults: suite, apiKey: { nil })
        settings.baseURL = URL(string: "https://api.example.com/v1")!
        let reloaded = TranslationSettings(defaults: suite, apiKey: { nil })
        #expect(reloaded.baseURL == URL(string: "https://api.example.com/v1"))
    }

    @Test func modelRoundtrip() {
        let settings = TranslationSettings(defaults: suite, apiKey: { nil })
        settings.model = "gpt-4o-mini"
        let reloaded = TranslationSettings(defaults: suite, apiKey: { nil })
        #expect(reloaded.model == "gpt-4o-mini")
    }

    @Test func modelFallsBackToDefaultWhenEmpty() {
        let settings = TranslationSettings(defaults: suite, apiKey: { nil })
        settings.model = ""
        let reloaded = TranslationSettings(defaults: suite, apiKey: { nil })
        #expect(reloaded.model == "deepseek-chat")
    }

    @Test func baseURLValidationRejectsNonHTTP() {
        #expect(!TranslationSettings.isValidBaseURLString("ftp://example.com"))
        #expect(!TranslationSettings.isValidBaseURLString("not a url"))
        #expect(!TranslationSettings.isValidBaseURLString(""))
        #expect(TranslationSettings.isValidBaseURLString("https://api.deepseek.com/v1"))
        #expect(TranslationSettings.isValidBaseURLString("http://localhost:1234/v1"))
    }

    @Test func apiKeyInjection() {
        let settings = TranslationSettings(defaults: suite, apiKey: { "sk-test-123" })
        #expect(settings.apiKey == "sk-test-123")
    }

    @Test func isConfigured() {
        #expect(!TranslationSettings(defaults: suite, apiKey: { nil }).isConfigured)
        #expect(!TranslationSettings(defaults: suite, apiKey: { "" }).isConfigured)
        #expect(TranslationSettings(defaults: suite, apiKey: { "sk-..." }).isConfigured)
    }
}
