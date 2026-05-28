//
//  TranslationSettings.swift
//  NetNewsWire
//

import Foundation
import Secrets

struct TranslationSettings {

    static let defaultBaseURL = URL(string: "https://api.deepseek.com/v1")!
    static let defaultModel = "deepseek-chat"

    private let defaults: UserDefaults
    private let apiKeyProvider: () -> String?

    init(defaults: UserDefaults = .standard,
         apiKey: @escaping () -> String? = { TranslationAPIKeyStore.load() }) {
        self.defaults = defaults
        self.apiKeyProvider = apiKey
    }

    private enum Key {
        static let baseURL = "translation.baseURL"
        static let model = "translation.model"
    }

    var baseURL: URL {
        get {
            if let raw = defaults.string(forKey: Key.baseURL),
               let url = URL(string: raw) {
                return url
            }
            return Self.defaultBaseURL
        }
        nonmutating set {
            defaults.set(newValue.absoluteString, forKey: Key.baseURL)
        }
    }

    var model: String {
        get {
            let stored = defaults.string(forKey: Key.model) ?? ""
            return stored.isEmpty ? Self.defaultModel : stored
        }
        nonmutating set {
            defaults.set(newValue, forKey: Key.model)
        }
    }

    var apiKey: String? { apiKeyProvider() }

    var isConfigured: Bool {
        guard let key = apiKey, !key.isEmpty else { return false }
        return true
    }

    static func isValidBaseURLString(_ s: String) -> Bool {
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return false }
        return true
    }
}
