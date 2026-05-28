//
//  TranslatedHTMLTests.swift
//  NetNewsWireTests
//

import Testing
@testable import NetNewsWire

@Suite struct TranslatedHTMLTests {

    @Test func splitsOnFirstClosingH1() throws {
        let raw = "<h1>译标题</h1>\n<p>第一段</p><p>第二段</p>"
        let split = try TranslatedHTML.split(raw)
        #expect(split.title == "译标题")
        #expect(split.body == "<p>第一段</p><p>第二段</p>")
    }

    @Test func titleMayContainInlineMarkup() throws {
        let raw = "<h1>第一篇 <em>重要</em> 文章</h1><p>正文</p>"
        let split = try TranslatedHTML.split(raw)
        #expect(split.title == "第一篇 <em>重要</em> 文章")
        #expect(split.body == "<p>正文</p>")
    }

    @Test func throwsWhenH1Missing() {
        let raw = "<p>没有标题的响应</p>"
        #expect(throws: (any Error).self) {
            _ = try TranslatedHTML.split(raw)
        }
    }

    @Test func trimsWhitespaceBetweenSections() throws {
        let raw = "  <h1>T</h1>  \n\n  <p>B</p>  "
        let split = try TranslatedHTML.split(raw)
        #expect(split.title == "T")
        #expect(split.body == "<p>B</p>")
    }
}
