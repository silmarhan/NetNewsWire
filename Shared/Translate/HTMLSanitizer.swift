//
//  HTMLSanitizer.swift
//  NetNewsWire
//
//  Strips a small set of dangerous HTML constructs from LLM-produced
//  translation output before the result is injected into the article
//  WKWebView. This is defense-in-depth — the WebView is sandboxed and
//  has no privileged JS bridges exposed to article content.
//

import Foundation

enum HTMLSanitizer {

    static func sanitize(_ html: String) -> String {
        var result = html
        result = stripTagBlocks(result, tag: "script")
        result = stripTagBlocks(result, tag: "iframe")
        result = stripOnEventAttributes(result)
        result = stripJavaScriptURLs(result)
        return result
    }

    private static func stripTagBlocks(_ html: String, tag: String) -> String {
        let pattern = "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>"
        return regexReplace(html, pattern: pattern, with: "")
    }

    private static func stripOnEventAttributes(_ html: String) -> String {
        let pattern = "\\s+on[a-zA-Z]+\\s*=\\s*(\"[^\"]*\"|'[^']*')"
        return regexReplace(html, pattern: pattern, with: "")
    }

    private static func stripJavaScriptURLs(_ html: String) -> String {
        let pattern = "(href|src)\\s*=\\s*([\"'])\\s*javascript:[^\"']*\\2"
        return regexReplace(html, pattern: pattern, with: "$1=$2#$2")
    }

    private static func regexReplace(_ input: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement)
    }
}
