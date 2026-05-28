//
//  TranslationStoreTests.swift
//  NetNewsWireTests
//

import Foundation
import Testing
@testable import NetNewsWire

@Suite struct TranslationStoreTests {

    private let tempDB: URL
    private let store: TranslationStore

    init() {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("translation-\(UUID().uuidString).sqlite")
        store = TranslationStore(databaseURL: tempDB)
    }

    @Test func missByDefault() {
        #expect(store.fetch(articleID: "a1", model: "m", contentHash: "h") == nil)
    }

    @Test func putThenGetReturnsRow() {
        store.put(articleID: "a1", model: "m", contentHash: "h", translatedHTML: "<p>译</p>")
        #expect(store.fetch(articleID: "a1", model: "m", contentHash: "h") == "<p>译</p>")
    }

    @Test func contentHashMismatchIsMiss() {
        store.put(articleID: "a1", model: "m", contentHash: "h-old", translatedHTML: "<p>old</p>")
        #expect(store.fetch(articleID: "a1", model: "m", contentHash: "h-new") == nil)
    }

    @Test func differentModelsDoNotCollide() {
        store.put(articleID: "a1", model: "deepseek-chat", contentHash: "h", translatedHTML: "A")
        store.put(articleID: "a1", model: "gpt-4o-mini",   contentHash: "h", translatedHTML: "B")
        #expect(store.fetch(articleID: "a1", model: "deepseek-chat", contentHash: "h") == "A")
        #expect(store.fetch(articleID: "a1", model: "gpt-4o-mini",   contentHash: "h") == "B")
    }

    @Test func putOverwritesSameKey() {
        store.put(articleID: "a1", model: "m", contentHash: "h1", translatedHTML: "v1")
        store.put(articleID: "a1", model: "m", contentHash: "h2", translatedHTML: "v2")
        #expect(store.fetch(articleID: "a1", model: "m", contentHash: "h1") == nil)
        #expect(store.fetch(articleID: "a1", model: "m", contentHash: "h2") == "v2")
    }

    @Test func clearAllEmpties() {
        store.put(articleID: "a1", model: "m", contentHash: "h", translatedHTML: "v")
        store.clearAll()
        #expect(store.fetch(articleID: "a1", model: "m", contentHash: "h") == nil)
    }

    @Test func sha256Helper() {
        let h1 = TranslationStore.contentHash(title: "T", bodyHTML: "<p>B</p>")
        let h2 = TranslationStore.contentHash(title: "T", bodyHTML: "<p>B</p>")
        let h3 = TranslationStore.contentHash(title: "T", bodyHTML: "<p>B!</p>")
        #expect(h1 == h2)
        #expect(h1 != h3)
        #expect(h1.count == 64) // hex SHA-256
    }
}
