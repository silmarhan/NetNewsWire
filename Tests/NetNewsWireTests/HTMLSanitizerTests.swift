//
//  HTMLSanitizerTests.swift
//  NetNewsWireTests

import Testing
@testable import NetNewsWire

@Suite struct HTMLSanitizerTests {

    @Test func stripsScriptTag() {
        let dirty = "<p>hello</p><script>alert(1)</script><p>world</p>"
        #expect(HTMLSanitizer.sanitize(dirty) == "<p>hello</p><p>world</p>")
    }

    @Test func stripsScriptTagMultiline() {
        let dirty = "<p>a</p><script type=\"text/javascript\">\nvar x = 1;\nalert(x);\n</script><p>b</p>"
        #expect(HTMLSanitizer.sanitize(dirty) == "<p>a</p><p>b</p>")
    }

    @Test func stripsIframe() {
        let dirty = "<p>hi</p><iframe src=\"https://evil.example\"></iframe>"
        #expect(HTMLSanitizer.sanitize(dirty) == "<p>hi</p>")
    }

    @Test func stripsOnEventAttributes() {
        let dirty = "<a href=\"https://x\" onclick=\"steal()\" data-keep=\"yes\">click</a>"
        let result = HTMLSanitizer.sanitize(dirty)
        #expect(!result.contains("onclick"))
        #expect(result.contains("data-keep=\"yes\""))
        #expect(result.contains("href=\"https://x\""))
    }

    @Test func stripsJavaScriptURLs() {
        let dirty = "<a href=\"javascript:alert(1)\">x</a><img src='JavaScript:foo()' />"
        let result = HTMLSanitizer.sanitize(dirty)
        #expect(!result.lowercased().contains("javascript:"))
    }

    @Test func passesNonMaliciousHTMLThrough() {
        let clean = "<h1>标题</h1><p>正文 <a href=\"https://example.com\">链接</a></p>"
        #expect(HTMLSanitizer.sanitize(clean) == clean)
    }
}
