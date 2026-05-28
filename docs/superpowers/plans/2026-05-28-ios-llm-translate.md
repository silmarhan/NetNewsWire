# iOS One-Tap LLM Translation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a toolbar button to NetNewsWire-iOS's article view that translates the article title + body into Simplified Chinese via an OpenAI Chat-Completions–compatible API (DeepSeek by default), with persistent SQLite caching and Keychain-stored API key.

**Architecture:** A new `Shared/Translate/` group holds pure logic (settings + sanitizer + cache + service). A new iOS-only `TranslateButton` mirrors `ArticleExtractorButton`. The orchestration lives on `WebViewController` (same pattern as the article extractor). A new `TranslationSettingsViewController` is added to the iOS Settings table.

**Tech Stack:** Swift 6.2, UIKit, WKWebView, Swift Concurrency (`async`/`await`), FMDB (via `Modules/RSDatabase` patterns), Security framework (Keychain), `URLSession` with mockable `URLProtocol` for tests, **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`).

**Source-of-truth spec:** `docs/superpowers/specs/2026-05-28-ios-llm-translate-design.md`

---

## Conventions Correction (applied 2026-05-28, post-plan)

After inspecting the existing test bodies, two conventions in this plan need correction. **All later tasks must follow the corrected conventions below; rewrite the in-plan code samples accordingly.**

1. **Test framework is Swift Testing, not XCTest.** Existing tests under `Tests/NetNewsWireTests/` and `Tests/NetNewsWire-iOSTests/` all use:
   ```swift
   import Testing
   @testable import NetNewsWire

   @MainActor @Suite struct MyTests {
       @Test func someBehavior() throws {
           #expect(actual == expected)
       }
   }
   ```
   Convert every XCTest snippet in this plan (e.g., `final class FooTests: XCTestCase { func test_x() { XCTAssertEqual(...) } }`) into the Swift Testing form above. `XCTAssertEqual(a, b)` → `#expect(a == b)`, `XCTAssertNil(x)` → `#expect(x == nil)`, `XCTAssertNotEqual(a, b)` → `#expect(a != b)`, `XCTAssertTrue(x)` → `#expect(x)`, `XCTAssertFalse(x)` → `#expect(!x)`, `XCTAssertThrowsError(try f())` → `#expect(throws: (any Error).self) { try f() }`, `XCTFail("msg")` → `Issue.record("msg")`. For async tests just use `@Test async`.

2. **Shared sources go into BOTH targets.** When using `scripts/superpowers/add_file_to_target.rb` for files under `Shared/Translate/`, pass BOTH targets: `NetNewsWire-iOS NetNewsWire`. This is required because tests `@testable import NetNewsWire` (the macOS app target) — the shared file must be a member of that target for tests to see it. The macOS app builds the file but never references it; no functional change to mac.

3. **Test setUp/tearDown** patterns: Swift Testing prefers initializers/deinitializers on the suite struct, or `init()` for setup and `deinit` for teardown. Convert `override func setUp()` → `init()` (no super calls). Convert `override func tearDown()` → `deinit` if needed.

4. **iOS-only files** (in `iOS/`) still go to `NetNewsWire-iOS` only.

5. **Tests in `Tests/NetNewsWireTests/`** are added to the `NetNewsWireTests` target only.

---

## File Plan

**New files:**

```
Shared/Translate/TranslationSettings.swift         # UserDefaults + Keychain facade
Shared/Translate/HTMLSanitizer.swift                # regex strip <script>/<iframe>/on*/javascript:
Shared/Translate/LLMTranslationService.swift        # POST /v1/chat/completions client
Shared/Translate/TranslationStore.swift             # SQLite cache
Shared/Translate/TranslatedHTML.swift               # title/body split helper

Modules/Secrets/Sources/Secrets/TranslationAPIKeyStore.swift  # kSecClassGenericPassword wrapper

iOS/Article/TranslateButton.swift                   # UIButton subclass (mirrors ArticleExtractorButton)
iOS/Settings/TranslationSettingsViewController.swift # static-table settings screen

Tests/NetNewsWireTests/HTMLSanitizerTests.swift
Tests/NetNewsWireTests/TranslationSettingsTests.swift
Tests/NetNewsWireTests/LLMTranslationServiceTests.swift
Tests/NetNewsWireTests/TranslationStoreTests.swift
Tests/NetNewsWireTests/TranslatedHTMLTests.swift

scripts/superpowers/add_file_to_target.rb          # one-off pbxproj helper
```

**Modified files:**

```
iOS/Article/ArticleViewController.swift            # add TranslateButton to toolbar, delegate
iOS/Article/WebViewController.swift                # translation state machine, DOM swap
iOS/Settings/SettingsViewController.swift          # add Translation row, segue
iOS/Settings/Settings.storyboard                   # add Translation cell + segue
NetNewsWire.xcodeproj/project.pbxproj              # add new files to iOS target + test target
```

---

## Pre-flight: Xcode project file helper

Adding source files to an Xcode project from the command line requires manipulating `project.pbxproj`. We use the `xcodeproj` Ruby gem. Each task that creates a new Swift source file will use the helper below.

- [ ] **Step P.1: Install xcodeproj gem (one-time, host-system)**

Run: `gem install xcodeproj` (you may need `sudo` or to use `--user-install`)
Expected: gem installs without error. If your environment cannot install gems, skip and add files manually via Xcode IDE — but commit pbxproj changes alongside source.

- [ ] **Step P.2: Create the helper script**

Create `scripts/superpowers/add_file_to_target.rb`:

```ruby
#!/usr/bin/env ruby
# Usage: ruby scripts/superpowers/add_file_to_target.rb <relative_file_path> <TargetName> [<TargetName> ...]
require 'xcodeproj'

file_path = ARGV[0]
targets = ARGV[1..]
abort "Usage: add_file_to_target.rb <path> <Target> [<Target> ...]" if file_path.nil? || targets.nil? || targets.empty?

project_path = File.expand_path('../../NetNewsWire.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

# Find or create the parent group along the file path
parts = file_path.split('/')
group = project.main_group
parts[0..-2].each do |part|
  child = group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == part }
  group = child || group.new_group(part, part)
end

# Add the file ref if not present
file_name = parts.last
existing = group.files.find { |f| f.path == file_name || f.display_name == file_name }
file_ref = existing || group.new_reference(file_name)

# Add to each target's sources build phase if not already there
targets.each do |target_name|
  target = project.targets.find { |t| t.name == target_name }
  abort "Target #{target_name} not found" unless target
  unless target.source_build_phase.files_references.include?(file_ref)
    target.add_file_references([file_ref])
  end
end

project.save
puts "Added #{file_path} to #{targets.join(', ')}"
```

- [ ] **Step P.3: Verify helper**

Run: `ruby scripts/superpowers/add_file_to_target.rb --help 2>&1 || true`
Expected: prints the usage line (`abort` triggers because no args).

- [ ] **Step P.4: Commit pre-flight**

```bash
git add scripts/superpowers/add_file_to_target.rb
git commit -m "tooling: add xcodeproj file-insertion helper"
```

---

### Task 1: HTMLSanitizer (pure function, test-first)

The simplest unit. Pure-Swift regex strip. Build this first so later tasks can depend on it.

**Files:**
- Create: `Shared/Translate/HTMLSanitizer.swift`
- Test: `Tests/NetNewsWireTests/HTMLSanitizerTests.swift`

- [ ] **Step 1.1: Write the failing tests**

Create `Tests/NetNewsWireTests/HTMLSanitizerTests.swift`:

```swift
import XCTest
@testable import NetNewsWire  // adjust @testable target if shared file ends up elsewhere

final class HTMLSanitizerTests: XCTestCase {

    func test_stripsScriptTag() {
        let dirty = "<p>hello</p><script>alert(1)</script><p>world</p>"
        XCTAssertEqual(HTMLSanitizer.sanitize(dirty), "<p>hello</p><p>world</p>")
    }

    func test_stripsScriptTagMultiline() {
        let dirty = "<p>a</p><script type=\"text/javascript\">\nvar x = 1;\nalert(x);\n</script><p>b</p>"
        XCTAssertEqual(HTMLSanitizer.sanitize(dirty), "<p>a</p><p>b</p>")
    }

    func test_stripsIframe() {
        let dirty = "<p>hi</p><iframe src=\"https://evil.example\"></iframe>"
        XCTAssertEqual(HTMLSanitizer.sanitize(dirty), "<p>hi</p>")
    }

    func test_stripsOnEventAttributes() {
        let dirty = "<a href=\"https://x\" onclick=\"steal()\" data-keep=\"yes\">click</a>"
        let result = HTMLSanitizer.sanitize(dirty)
        XCTAssertFalse(result.contains("onclick"))
        XCTAssertTrue(result.contains("data-keep=\"yes\""))
        XCTAssertTrue(result.contains("href=\"https://x\""))
    }

    func test_stripsJavascriptURLs() {
        let dirty = "<a href=\"javascript:alert(1)\">x</a><img src='JavaScript:foo()' />"
        let result = HTMLSanitizer.sanitize(dirty)
        XCTAssertFalse(result.lowercased().contains("javascript:"))
    }

    func test_passesNonMaliciousHTMLThrough() {
        let clean = "<h1>标题</h1><p>正文 <a href=\"https://example.com\">链接</a></p>"
        XCTAssertEqual(HTMLSanitizer.sanitize(clean), clean)
    }
}
```

- [ ] **Step 1.2: Run tests to verify they fail**

Run:
```bash
xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire-iOS \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -only-testing:NetNewsWireTests/HTMLSanitizerTests
```
Expected: build fails because `HTMLSanitizer` is undefined.

- [ ] **Step 1.3: Implement HTMLSanitizer**

Create `Shared/Translate/HTMLSanitizer.swift`:

```swift
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
        // Matches on<word>="..." or on<word>='...'  (case-insensitive)
        let pattern = "\\s+on[a-zA-Z]+\\s*=\\s*(\"[^\"]*\"|'[^']*')"
        return regexReplace(html, pattern: pattern, with: "")
    }

    private static func stripJavaScriptURLs(_ html: String) -> String {
        // Replace href/src that begin with javascript: (case-insensitive) with "#"
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
```

- [ ] **Step 1.4: Add new files to Xcode project**

Run:
```bash
ruby scripts/superpowers/add_file_to_target.rb Shared/Translate/HTMLSanitizer.swift NetNewsWire-iOS NetNewsWire
ruby scripts/superpowers/add_file_to_target.rb Tests/NetNewsWireTests/HTMLSanitizerTests.swift NetNewsWireTests
```
Expected: prints `Added ... to NetNewsWire-iOS, NetNewsWire` and `Added ... to NetNewsWireTests`.

- [ ] **Step 1.5: Run tests to verify they pass**

Run the same xcodebuild command as Step 1.2.
Expected: all 6 tests pass.

- [ ] **Step 1.6: Commit**

```bash
git add Shared/Translate/HTMLSanitizer.swift \
        Tests/NetNewsWireTests/HTMLSanitizerTests.swift \
        NetNewsWire.xcodeproj/project.pbxproj
git commit -m "translate: add HTMLSanitizer for LLM output strip

Strips <script>, <iframe>, on* event attributes, and javascript: URLs
from translation output before injection into the article WebView."
```

---

### Task 2: TranslatedHTML response splitter

Splits the LLM's `<h1>title</h1>body` response into separate title/body strings.

**Files:**
- Create: `Shared/Translate/TranslatedHTML.swift`
- Test: `Tests/NetNewsWireTests/TranslatedHTMLTests.swift`

- [ ] **Step 2.1: Write the failing tests**

Create `Tests/NetNewsWireTests/TranslatedHTMLTests.swift`:

```swift
import XCTest
@testable import NetNewsWire

final class TranslatedHTMLTests: XCTestCase {

    func test_splitsOnFirstClosingH1() {
        let raw = "<h1>译标题</h1>\n<p>第一段</p><p>第二段</p>"
        let split = try? TranslatedHTML.split(raw)
        XCTAssertEqual(split?.title, "译标题")
        XCTAssertEqual(split?.body, "<p>第一段</p><p>第二段</p>")
    }

    func test_titleMayContainInlineMarkup() {
        let raw = "<h1>第一篇 <em>重要</em> 文章</h1><p>正文</p>"
        let split = try? TranslatedHTML.split(raw)
        XCTAssertEqual(split?.title, "第一篇 <em>重要</em> 文章")
        XCTAssertEqual(split?.body, "<p>正文</p>")
    }

    func test_throwsWhenH1Missing() {
        let raw = "<p>没有标题的响应</p>"
        XCTAssertThrowsError(try TranslatedHTML.split(raw))
    }

    func test_trimsWhitespaceBetweenSections() {
        let raw = "  <h1>T</h1>  \n\n  <p>B</p>  "
        let split = try? TranslatedHTML.split(raw)
        XCTAssertEqual(split?.title, "T")
        XCTAssertEqual(split?.body, "<p>B</p>")
    }
}
```

- [ ] **Step 2.2: Run tests to verify they fail**

Run:
```bash
xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire-iOS \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -only-testing:NetNewsWireTests/TranslatedHTMLTests
```
Expected: build fails — `TranslatedHTML` undefined.

- [ ] **Step 2.3: Implement TranslatedHTML**

Create `Shared/Translate/TranslatedHTML.swift`:

```swift
//
//  TranslatedHTML.swift
//  NetNewsWire
//

import Foundation

struct TranslatedHTML: Equatable {
    let title: String
    let body: String

    enum SplitError: Error {
        case missingH1
    }

    static func split(_ raw: String) throws -> TranslatedHTML {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Locate the first <h1...> and its matching </h1> (case-insensitive).
        guard let openRange = trimmed.range(of: "<h1", options: [.caseInsensitive]),
              let openEnd = trimmed.range(of: ">", range: openRange.upperBound..<trimmed.endIndex),
              let closeRange = trimmed.range(of: "</h1>", options: [.caseInsensitive], range: openEnd.upperBound..<trimmed.endIndex) else {
            throw SplitError.missingH1
        }

        let titleHTML = String(trimmed[openEnd.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyHTML = String(trimmed[closeRange.upperBound..<trimmed.endIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return TranslatedHTML(title: titleHTML, body: bodyHTML)
    }
}
```

- [ ] **Step 2.4: Add files to Xcode project**

Run:
```bash
ruby scripts/superpowers/add_file_to_target.rb Shared/Translate/TranslatedHTML.swift NetNewsWire-iOS NetNewsWire
ruby scripts/superpowers/add_file_to_target.rb Tests/NetNewsWireTests/TranslatedHTMLTests.swift NetNewsWireTests
```

- [ ] **Step 2.5: Run tests to verify they pass**

Same xcodebuild command as 2.2.
Expected: all 4 tests pass.

- [ ] **Step 2.6: Commit**

```bash
git add Shared/Translate/TranslatedHTML.swift \
        Tests/NetNewsWireTests/TranslatedHTMLTests.swift \
        NetNewsWire.xcodeproj/project.pbxproj
git commit -m "translate: add TranslatedHTML title/body splitter"
```

---

### Task 3: TranslationAPIKeyStore (Keychain wrapper)

Adds a generic-password Keychain helper to `Modules/Secrets`. Distinct from the existing `CredentialsManager` because that uses `kSecClassInternetPassword` (server+username) which doesn't fit a single API-key-per-app scheme.

**Files:**
- Create: `Modules/Secrets/Sources/Secrets/TranslationAPIKeyStore.swift`
- Test: deferred (no test target exists for the Secrets package; tests would require new Package.swift target. Use manual smoke test via the settings screen in Task 8.)

- [ ] **Step 3.1: Implement TranslationAPIKeyStore**

Create `Modules/Secrets/Sources/Secrets/TranslationAPIKeyStore.swift`:

```swift
//
//  TranslationAPIKeyStore.swift
//  Secrets
//
//  Keychain-backed storage for the user's LLM-translation API key.
//  Uses kSecClassGenericPassword with a fixed service + account.
//

import Foundation
import Security

public enum TranslationAPIKeyStore {

    private static let service = "com.ranchero.NetNewsWire.translation"
    private static let account = "apiKey"

    public static func save(_ key: String) throws {
        try delete()  // overwrite semantics

        let data = key.data(using: .utf8) ?? Data()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        if let group = appAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public static func load() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if let group = appAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    public static func delete() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let group = appAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private static let appAccessGroup: String? = {
        guard let appGroup = Bundle.main.object(forInfoDictionaryKey: "AppGroup") as? String,
              let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String else {
            return nil
        }
        let groupSuffix = appGroup.suffix(appGroup.count - 6)
        return "\(prefix)\(groupSuffix)"
    }()

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { "Keychain error: \(status)" }
    }
}
```

- [ ] **Step 3.2: Build the Secrets module**

Run:
```bash
xcodebuild -project NetNewsWire.xcodeproj -scheme NetNewsWire-iOS \
  -destination "platform=iOS Simulator,name=iPhone 17" build
```
Expected: build succeeds. New file is automatically picked up because Swift package adds all `.swift` files in `Sources/Secrets/` by default.

- [ ] **Step 3.3: Commit**

```bash
git add Modules/Secrets/Sources/Secrets/TranslationAPIKeyStore.swift
git commit -m "secrets: add TranslationAPIKeyStore (generic-password keychain)"
```

---

### Task 4: TranslationSettings facade

Combines UserDefaults (baseURL, model) and Keychain (apiKey) behind a single facade.

**Files:**
- Create: `Shared/Translate/TranslationSettings.swift`
- Test: `Tests/NetNewsWireTests/TranslationSettingsTests.swift`

- [ ] **Step 4.1: Write the failing tests**

Create `Tests/NetNewsWireTests/TranslationSettingsTests.swift`:

```swift
import XCTest
@testable import NetNewsWire

final class TranslationSettingsTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        let suiteName = "TranslationSettingsTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suite.dictionaryRepresentation().keys.first ?? "")
        super.tearDown()
    }

    func test_defaultsAreDeepSeek() {
        let settings = TranslationSettings(defaults: suite, apiKey: { nil })
        XCTAssertEqual(settings.baseURL, URL(string: "https://api.deepseek.com/v1"))
        XCTAssertEqual(settings.model, "deepseek-chat")
    }

    func test_baseURLRoundtrip() {
        var settings = TranslationSettings(defaults: suite, apiKey: { nil })
        settings.baseURL = URL(string: "https://api.example.com/v1")!
        let reloaded = TranslationSettings(defaults: suite, apiKey: { nil })
        XCTAssertEqual(reloaded.baseURL, URL(string: "https://api.example.com/v1"))
    }

    func test_modelRoundtrip() {
        var settings = TranslationSettings(defaults: suite, apiKey: { nil })
        settings.model = "gpt-4o-mini"
        let reloaded = TranslationSettings(defaults: suite, apiKey: { nil })
        XCTAssertEqual(reloaded.model, "gpt-4o-mini")
    }

    func test_modelFallsBackToDefaultWhenEmpty() {
        var settings = TranslationSettings(defaults: suite, apiKey: { nil })
        settings.model = ""
        let reloaded = TranslationSettings(defaults: suite, apiKey: { nil })
        XCTAssertEqual(reloaded.model, "deepseek-chat")
    }

    func test_baseURLValidationRejectsNonHTTP() {
        XCTAssertFalse(TranslationSettings.isValidBaseURLString("ftp://example.com"))
        XCTAssertFalse(TranslationSettings.isValidBaseURLString("not a url"))
        XCTAssertFalse(TranslationSettings.isValidBaseURLString(""))
        XCTAssertTrue(TranslationSettings.isValidBaseURLString("https://api.deepseek.com/v1"))
        XCTAssertTrue(TranslationSettings.isValidBaseURLString("http://localhost:1234/v1"))
    }

    func test_apiKeyInjection() {
        let settings = TranslationSettings(defaults: suite, apiKey: { "sk-test-123" })
        XCTAssertEqual(settings.apiKey, "sk-test-123")
    }

    func test_isConfigured() {
        XCTAssertFalse(TranslationSettings(defaults: suite, apiKey: { nil }).isConfigured)
        XCTAssertFalse(TranslationSettings(defaults: suite, apiKey: { "" }).isConfigured)
        XCTAssertTrue(TranslationSettings(defaults: suite, apiKey: { "sk-..." }).isConfigured)
    }
}
```

- [ ] **Step 4.2: Run tests to verify they fail**

Run:
```bash
xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire-iOS \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -only-testing:NetNewsWireTests/TranslationSettingsTests
```
Expected: build fails — `TranslationSettings` undefined.

- [ ] **Step 4.3: Implement TranslationSettings**

Create `Shared/Translate/TranslationSettings.swift`:

```swift
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
```

- [ ] **Step 4.4: Add files to Xcode project**

Run:
```bash
ruby scripts/superpowers/add_file_to_target.rb Shared/Translate/TranslationSettings.swift NetNewsWire-iOS NetNewsWire
ruby scripts/superpowers/add_file_to_target.rb Tests/NetNewsWireTests/TranslationSettingsTests.swift NetNewsWireTests
```

- [ ] **Step 4.5: Run tests to verify they pass**

Same as Step 4.2.
Expected: all 7 tests pass.

- [ ] **Step 4.6: Commit**

```bash
git add Shared/Translate/TranslationSettings.swift \
        Tests/NetNewsWireTests/TranslationSettingsTests.swift \
        NetNewsWire.xcodeproj/project.pbxproj
git commit -m "translate: add TranslationSettings (UserDefaults + Keychain facade)"
```

---

### Task 5: LLMTranslationService

OpenAI-Chat-Completions–compatible client. Mockable via `URLSession.configuration.protocolClasses`.

**Files:**
- Create: `Shared/Translate/LLMTranslationService.swift`
- Test: `Tests/NetNewsWireTests/LLMTranslationServiceTests.swift`

- [ ] **Step 5.1: Write the failing tests**

Create `Tests/NetNewsWireTests/LLMTranslationServiceTests.swift`:

```swift
import XCTest
@testable import NetNewsWire

final class LLMTranslationServiceTests: XCTestCase {

    // MARK: - Mock URLProtocol

    final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var stub: ((URLRequest) -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var lastBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            MockURLProtocol.lastRequest = request
            MockURLProtocol.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open()
                var data = Data()
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buf.deallocate(); stream.close() }
                while stream.hasBytesAvailable {
                    let n = stream.read(buf, maxLength: 4096)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                return data
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

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override func tearDown() {
        MockURLProtocol.stub = nil
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.lastBody = nil
        super.tearDown()
    }

    // MARK: - Tests

    func test_successPathParsesContent() async throws {
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
        XCTAssertEqual(html, "<h1>译标题</h1><p>正文</p>")
    }

    func test_requestShape() async throws {
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
        let req = MockURLProtocol.lastRequest!
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-secret")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.lastBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "deepseek-chat")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let messages = body["messages"] as! [[String: String]]
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertTrue(messages[1]["content"]!.contains("<h1>Hello</h1>"))
        XCTAssertTrue(messages[1]["content"]!.contains("<p>World</p>"))
    }

    func test_http401SurfacesProviderError() async {
        MockURLProtocol.stub = { _ in
            let json = """
            {"error":{"message":"Invalid API key","type":"invalid_request_error"}}
            """.data(using: .utf8)!
            let r = HTTPURLResponse(url: URL(string: "https://example.com")!,
                                     statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (r, json)
        }
        let service = LLMTranslationService(session: mockSession())
        do {
            _ = try await service.translate(title: "x", bodyHTML: "y",
                                             baseURL: URL(string: "https://api.example.com/v1")!,
                                             model: "m", apiKey: "bad")
            XCTFail("expected error")
        } catch let LLMTranslationService.TranslationError.providerError(message, status) {
            XCTAssertEqual(message, "Invalid API key")
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_http500GenericNetworkError() async {
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
            XCTFail("expected error")
        } catch LLMTranslationService.TranslationError.providerError(_, let status) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_networkFailurePropagates() async {
        MockURLProtocol.stub = nil  // → URLError(.notConnectedToInternet)
        let service = LLMTranslationService(session: mockSession())
        do {
            _ = try await service.translate(title: "x", bodyHTML: "y",
                                             baseURL: URL(string: "https://api.example.com/v1")!,
                                             model: "m", apiKey: "k")
            XCTFail("expected error")
        } catch LLMTranslationService.TranslationError.network {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_malformedJSONFailsClearly() async {
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
            XCTFail("expected error")
        } catch LLMTranslationService.TranslationError.malformedResponse {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
```

- [ ] **Step 5.2: Run tests to verify they fail**

Run:
```bash
xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire-iOS \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -only-testing:NetNewsWireTests/LLMTranslationServiceTests
```
Expected: build fails — `LLMTranslationService` undefined.

- [ ] **Step 5.3: Implement LLMTranslationService**

Create `Shared/Translate/LLMTranslationService.swift`:

```swift
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
```

- [ ] **Step 5.4: Add files to Xcode project**

Run:
```bash
ruby scripts/superpowers/add_file_to_target.rb Shared/Translate/LLMTranslationService.swift NetNewsWire-iOS NetNewsWire
ruby scripts/superpowers/add_file_to_target.rb Tests/NetNewsWireTests/LLMTranslationServiceTests.swift NetNewsWireTests
```

- [ ] **Step 5.5: Run tests to verify they pass**

Same as Step 5.2.
Expected: all 6 tests pass.

- [ ] **Step 5.6: Commit**

```bash
git add Shared/Translate/LLMTranslationService.swift \
        Tests/NetNewsWireTests/LLMTranslationServiceTests.swift \
        NetNewsWire.xcodeproj/project.pbxproj
git commit -m "translate: add LLMTranslationService (OpenAI chat-completions client)"
```

---

### Task 6: TranslationStore (SQLite cache)

Persistent cache keyed by `(articleID, model)` with content-hash invalidation. Uses FMDB directly (the project already vends it via `Modules/RSDatabase`). New DB file in Application Support to avoid touching `ArticlesDatabase`.

**Files:**
- Create: `Shared/Translate/TranslationStore.swift`
- Test: `Tests/NetNewsWireTests/TranslationStoreTests.swift`

- [ ] **Step 6.1: Write the failing tests**

Create `Tests/NetNewsWireTests/TranslationStoreTests.swift`:

```swift
import XCTest
@testable import NetNewsWire

final class TranslationStoreTests: XCTestCase {

    private var tempDB: URL!
    private var store: TranslationStore!

    override func setUp() {
        super.setUp()
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("translation-\(UUID().uuidString).sqlite")
        store = TranslationStore(databaseURL: tempDB)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDB)
        super.tearDown()
    }

    func test_missByDefault() {
        XCTAssertNil(store.fetch(articleID: "a1", model: "m", contentHash: "h"))
    }

    func test_putThenGetReturnsRow() {
        store.put(articleID: "a1", model: "m", contentHash: "h", translatedHTML: "<p>译</p>")
        XCTAssertEqual(store.fetch(articleID: "a1", model: "m", contentHash: "h"), "<p>译</p>")
    }

    func test_contentHashMismatchIsMiss() {
        store.put(articleID: "a1", model: "m", contentHash: "h-old", translatedHTML: "<p>old</p>")
        XCTAssertNil(store.fetch(articleID: "a1", model: "m", contentHash: "h-new"))
    }

    func test_differentModelsDoNotCollide() {
        store.put(articleID: "a1", model: "deepseek-chat", contentHash: "h", translatedHTML: "A")
        store.put(articleID: "a1", model: "gpt-4o-mini",   contentHash: "h", translatedHTML: "B")
        XCTAssertEqual(store.fetch(articleID: "a1", model: "deepseek-chat", contentHash: "h"), "A")
        XCTAssertEqual(store.fetch(articleID: "a1", model: "gpt-4o-mini",   contentHash: "h"), "B")
    }

    func test_putOverwritesSameKey() {
        store.put(articleID: "a1", model: "m", contentHash: "h1", translatedHTML: "v1")
        store.put(articleID: "a1", model: "m", contentHash: "h2", translatedHTML: "v2")
        XCTAssertNil(store.fetch(articleID: "a1", model: "m", contentHash: "h1"))
        XCTAssertEqual(store.fetch(articleID: "a1", model: "m", contentHash: "h2"), "v2")
    }

    func test_clearAllEmpties() {
        store.put(articleID: "a1", model: "m", contentHash: "h", translatedHTML: "v")
        store.clearAll()
        XCTAssertNil(store.fetch(articleID: "a1", model: "m", contentHash: "h"))
    }

    func test_sha256Helper() {
        let h1 = TranslationStore.contentHash(title: "T", bodyHTML: "<p>B</p>")
        let h2 = TranslationStore.contentHash(title: "T", bodyHTML: "<p>B</p>")
        let h3 = TranslationStore.contentHash(title: "T", bodyHTML: "<p>B!</p>")
        XCTAssertEqual(h1, h2)
        XCTAssertNotEqual(h1, h3)
        XCTAssertEqual(h1.count, 64) // hex SHA-256
    }
}
```

- [ ] **Step 6.2: Run tests to verify they fail**

Run:
```bash
xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire-iOS \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -only-testing:NetNewsWireTests/TranslationStoreTests
```
Expected: build fails — `TranslationStore` undefined.

- [ ] **Step 6.3: Implement TranslationStore**

Create `Shared/Translate/TranslationStore.swift`:

```swift
//
//  TranslationStore.swift
//  NetNewsWire
//

import Foundation
import CryptoKit
import FMDB

final class TranslationStore {

    private let queue: FMDatabaseQueue

    init(databaseURL: URL) {
        // Ensure parent directory exists
        try? FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        guard let q = FMDatabaseQueue(path: databaseURL.path) else {
            fatalError("Failed to open translation DB at \(databaseURL.path)")
        }
        self.queue = q
        createSchemaIfNeeded()
    }

    static func defaultDatabaseURL() -> URL {
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return support.appendingPathComponent("TranslationDatabase.sqlite")
    }

    private func createSchemaIfNeeded() {
        queue.inDatabase { db in
            db.executeStatements("""
            CREATE TABLE IF NOT EXISTS translations (
              article_id      TEXT NOT NULL,
              model           TEXT NOT NULL,
              content_hash    TEXT NOT NULL,
              translated_html TEXT NOT NULL,
              created_at      REAL NOT NULL,
              PRIMARY KEY (article_id, model)
            );
            """)
        }
    }

    func fetch(articleID: String, model: String, contentHash: String) -> String? {
        var result: String?
        queue.inDatabase { db in
            let rs = try? db.executeQuery(
                "SELECT translated_html FROM translations WHERE article_id = ? AND model = ? AND content_hash = ? LIMIT 1",
                values: [articleID, model, contentHash])
            if rs?.next() == true {
                result = rs?.string(forColumn: "translated_html")
            }
            rs?.close()
        }
        return result
    }

    func put(articleID: String, model: String, contentHash: String, translatedHTML: String) {
        queue.inDatabase { db in
            try? db.executeUpdate(
                """
                INSERT OR REPLACE INTO translations
                  (article_id, model, content_hash, translated_html, created_at)
                  VALUES (?, ?, ?, ?, ?)
                """,
                values: [articleID, model, contentHash, translatedHTML, Date().timeIntervalSince1970])
        }
    }

    func clearAll() {
        queue.inDatabase { db in
            try? db.executeUpdate("DELETE FROM translations", values: [])
        }
    }

    static func contentHash(title: String, bodyHTML: String) -> String {
        let combined = title + "\n" + bodyHTML
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 6.4: Add files to Xcode project**

Run:
```bash
ruby scripts/superpowers/add_file_to_target.rb Shared/Translate/TranslationStore.swift NetNewsWire-iOS NetNewsWire
ruby scripts/superpowers/add_file_to_target.rb Tests/NetNewsWireTests/TranslationStoreTests.swift NetNewsWireTests
```

- [ ] **Step 6.5: Run tests to verify they pass**

Same as Step 6.2.
Expected: all 7 tests pass.

> If FMDB import fails: confirm the iOS target already links `RSDatabase` (which re-exports FMDB). If not, add `import RSDatabase` and use `RSDatabase.FMDatabaseQueue` instead, or add the FMDB SPM dep to the iOS target.

- [ ] **Step 6.6: Commit**

```bash
git add Shared/Translate/TranslationStore.swift \
        Tests/NetNewsWireTests/TranslationStoreTests.swift \
        NetNewsWire.xcodeproj/project.pbxproj
git commit -m "translate: add TranslationStore (FMDB cache by article+model)"
```

---

### Task 7: TranslateButton (UI component)

Mirrors `ArticleExtractorButton`. No logic — pure UIButton subclass with state-driven image + spinner.

**Files:**
- Create: `iOS/Article/TranslateButton.swift`
- New SF Symbol or asset names: reuse system symbols (`character.book.closed` for off, `character.book.closed.fill` for on) — no asset additions required.

- [ ] **Step 7.1: Implement TranslateButton**

Create `iOS/Article/TranslateButton.swift`:

```swift
//
//  TranslateButton.swift
//  NetNewsWire-iOS
//

import UIKit

enum TranslateButtonState {
    case off
    case animated
    case on
    case error
}

final class TranslateButton: UIButton {

    private let activityIndicator: UIActivityIndicatorView = {
        let i = UIActivityIndicatorView(style: .medium)
        i.hidesWhenStopped = true
        i.translatesAutoresizingMaskIntoConstraints = false
        return i
    }()

    private static let offImage = UIImage(systemName: "character.book.closed")
    private static let onImage  = UIImage(systemName: "character.book.closed.fill")
    private static let errorImage = UIImage(systemName: "exclamationmark.triangle")

    var buttonState: TranslateButtonState = .off {
        didSet {
            guard buttonState != oldValue else { return }
            switch buttonState {
            case .off:
                activityIndicator.stopAnimating()
                isUserInteractionEnabled = true
                setImage(Self.offImage, for: .normal)
            case .animated:
                setImage(nil, for: .normal)
                activityIndicator.startAnimating()
                isUserInteractionEnabled = false
            case .on:
                activityIndicator.stopAnimating()
                isUserInteractionEnabled = true
                setImage(Self.onImage, for: .normal)
            case .error:
                activityIndicator.stopAnimating()
                isUserInteractionEnabled = true
                setImage(Self.errorImage, for: .normal)
            }
        }
    }

    override var accessibilityLabel: String? {
        get {
            switch buttonState {
            case .off:      return NSLocalizedString("Translate", comment: "Translate")
            case .animated: return NSLocalizedString("Translating", comment: "Translating")
            case .on:       return NSLocalizedString("Translated", comment: "Translated")
            case .error:    return NSLocalizedString("Translation error", comment: "Translation error")
            }
        }
        set { super.accessibilityLabel = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Match ArticleExtractorButton's expanded hit area.
        let expanded = bounds.insetBy(dx: -20, dy: -20)
        return expanded.contains(point)
    }

    private func commonInit() {
        addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44),
            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setImage(Self.offImage, for: .normal)
    }
}
```

- [ ] **Step 7.2: Add to Xcode project**

Run:
```bash
ruby scripts/superpowers/add_file_to_target.rb iOS/Article/TranslateButton.swift NetNewsWire-iOS
```

- [ ] **Step 7.3: Build to verify**

Run:
```bash
xcodebuild -project NetNewsWire.xcodeproj -scheme NetNewsWire-iOS \
  -destination "platform=iOS Simulator,name=iPhone 17" build
```
Expected: build succeeds.

- [ ] **Step 7.4: Commit**

```bash
git add iOS/Article/TranslateButton.swift NetNewsWire.xcodeproj/project.pbxproj
git commit -m "translate: add TranslateButton (mirrors ArticleExtractorButton)"
```

---

### Task 8: TranslationSettingsViewController (settings screen)

Programmatic UITableViewController (avoid storyboard surgery for the inner cells; we still need one storyboard scene to be pushable from the existing Settings, but the cells are driven by code).

**Files:**
- Create: `iOS/Settings/TranslationSettingsViewController.swift`

- [ ] **Step 8.1: Implement TranslationSettingsViewController**

Create `iOS/Settings/TranslationSettingsViewController.swift`:

```swift
//
//  TranslationSettingsViewController.swift
//  NetNewsWire-iOS
//

import UIKit
import Secrets

final class TranslationSettingsViewController: UITableViewController, UITextFieldDelegate {

    private let baseURLField = UITextField()
    private let apiKeyField = UITextField()
    private let modelField = UITextField()
    private let testButton = UIButton(type: .system)
    private let clearCacheButton = UIButton(type: .system)
    private let statusLabel = UILabel()

    private var settings = TranslationSettings()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Translation", comment: "Translation settings screen title")
        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsSelection = false

        baseURLField.placeholder = "https://api.deepseek.com/v1"
        baseURLField.text = settings.baseURL.absoluteString
        baseURLField.autocorrectionType = .no
        baseURLField.autocapitalizationType = .none
        baseURLField.keyboardType = .URL
        baseURLField.delegate = self

        apiKeyField.placeholder = "sk-..."
        apiKeyField.text = TranslationAPIKeyStore.load() ?? ""
        apiKeyField.isSecureTextEntry = true
        apiKeyField.autocorrectionType = .no
        apiKeyField.autocapitalizationType = .none
        apiKeyField.delegate = self

        modelField.placeholder = "deepseek-chat"
        modelField.text = settings.model
        modelField.autocorrectionType = .no
        modelField.autocapitalizationType = .none
        modelField.delegate = self

        testButton.setTitle(NSLocalizedString("Test Connection", comment: ""), for: .normal)
        testButton.addTarget(self, action: #selector(testTapped), for: .touchUpInside)

        clearCacheButton.setTitle(NSLocalizedString("Clear Translation Cache", comment: ""), for: .normal)
        clearCacheButton.setTitleColor(.systemRed, for: .normal)
        clearCacheButton.addTarget(self, action: #selector(clearCacheTapped), for: .touchUpInside)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        save()
    }

    // MARK: - Table

    private enum Row: Int, CaseIterable {
        case baseURL = 0, apiKey, model, test, clearCache, status
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        guard let row = Row(rawValue: indexPath.row) else { return cell }

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(label)

        let trailing: UIView
        switch row {
        case .baseURL:    label.text = NSLocalizedString("Base URL", comment: ""); trailing = baseURLField
        case .apiKey:     label.text = NSLocalizedString("API Key", comment: "");  trailing = apiKeyField
        case .model:      label.text = NSLocalizedString("Model", comment: "");    trailing = modelField
        case .test:       return makeButtonRow(testButton)
        case .clearCache: return makeButtonRow(clearCacheButton)
        case .status:     return makeButtonRow(statusLabel)
        }

        trailing.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(trailing)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 100),
            trailing.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            trailing.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        return cell
    }

    private func makeButtonRow(_ view: UIView) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12)
        ])
        return cell
    }

    // MARK: - Save

    private func save() {
        if let s = baseURLField.text, TranslationSettings.isValidBaseURLString(s), let url = URL(string: s) {
            settings.baseURL = url
        }
        settings.model = modelField.text ?? ""
        if let key = apiKeyField.text, !key.isEmpty {
            try? TranslationAPIKeyStore.save(key)
        } else {
            try? TranslationAPIKeyStore.delete()
        }
    }

    // MARK: - Actions

    @objc private func testTapped() {
        save()
        guard let key = TranslationAPIKeyStore.load(), !key.isEmpty else {
            statusLabel.text = NSLocalizedString("Enter an API key first.", comment: "")
            return
        }
        statusLabel.text = NSLocalizedString("Testing…", comment: "")
        let service = LLMTranslationService()
        let base = settings.baseURL
        let model = settings.model
        Task { @MainActor in
            do {
                let html = try await service.translate(
                    title: "Hello",
                    bodyHTML: "<p>Test.</p>",
                    baseURL: base,
                    model: model,
                    apiKey: key
                )
                statusLabel.text = NSLocalizedString("OK: ", comment: "") +
                    String(html.prefix(80))
                statusLabel.textColor = .systemGreen
            } catch LLMTranslationService.TranslationError.providerError(let msg, let status) {
                statusLabel.text = "HTTP \(status): \(msg)"
                statusLabel.textColor = .systemRed
            } catch {
                statusLabel.text = error.localizedDescription
                statusLabel.textColor = .systemRed
            }
        }
    }

    @objc private func clearCacheTapped() {
        TranslationStore(databaseURL: TranslationStore.defaultDatabaseURL()).clearAll()
        let alert = UIAlertController(
            title: NSLocalizedString("Cache Cleared", comment: ""),
            message: nil,
            preferredStyle: .alert)
        alert.addAction(.init(title: NSLocalizedString("OK", comment: ""), style: .default))
        present(alert, animated: true)
    }
}
```

- [ ] **Step 8.2: Add to Xcode project**

Run:
```bash
ruby scripts/superpowers/add_file_to_target.rb iOS/Settings/TranslationSettingsViewController.swift NetNewsWire-iOS
```

- [ ] **Step 8.3: Build**

Run the iOS build command. Expected: succeeds.

- [ ] **Step 8.4: Commit**

```bash
git add iOS/Settings/TranslationSettingsViewController.swift \
        NetNewsWire.xcodeproj/project.pbxproj
git commit -m "translate: add iOS Translation settings screen"
```

---

### Task 9: Wire Translation row into SettingsViewController

Add a new section "Translation" with a single row that pushes `TranslationSettingsViewController`.

**Files:**
- Modify: `iOS/Settings/SettingsViewController.swift`

> The existing Settings table is **static** (driven by storyboard). We add the row in code rather than fight the storyboard. We override the section count and intercept the new section's row.

- [ ] **Step 9.1: Modify SettingsViewController.swift**

Open `iOS/Settings/SettingsViewController.swift`. Locate the `Section` enum (around line 19-28):

```swift
private enum Section: Int {
    case notifications = 0
    case accounts = 1
    case feeds = 2
    case timeline = 3
    case articles = 4
    case appearance = 5
    case troubleshooting = 6
    case help = 7
}
```

We will not modify this enum (static table sections are tied to storyboard). Instead, append the new section at the end via `numberOfSections(in:)` and `tableView(_:cellForRowAt:)` overrides.

Add the following methods to the class body (place them after the existing data-source overrides; if none exist for this static table — since the storyboard handles them — add new ones):

```swift
// MARK: - Translation section (appended)

private let translationSectionIndex = 8  // immediately after the static .help (=7)

override func numberOfSections(in tableView: UITableView) -> Int {
    super.numberOfSections(in: tableView) + 1
}

override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    if section == translationSectionIndex { return 1 }
    return super.tableView(tableView, numberOfRowsInSection: section)
}

override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    if section == translationSectionIndex {
        return NSLocalizedString("Translation", comment: "Translation settings section header")
    }
    return super.tableView(tableView, titleForHeaderInSection: section)
}

override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    if indexPath.section == translationSectionIndex {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "translationRow")
        cell.textLabel?.text = NSLocalizedString("LLM Translation", comment: "")
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    return super.tableView(tableView, cellForRowAt: indexPath)
}

override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    if indexPath.section == translationSectionIndex {
        let vc = TranslationSettingsViewController()
        navigationController?.pushViewController(vc, animated: true)
        return
    }
    super.tableView(tableView, didSelectRowAt: indexPath)
}
```

> **Static table caveat:** UITableViewController with a storyboard static cells has a different default `dataSource` (the storyboard). If the calls above are intercepted by the storyboard's `_UIStaticTableViewSource`, you may need to either (a) convert the table to dynamic, or (b) instead expose the entry via Help section. **Pragmatic fallback** if (a) is too disruptive: skip this task as a code change and instead modify `Settings.storyboard` to add a static cell — see fallback step.

- [ ] **Step 9.2 (fallback only if storyboard intercepts the overrides): Storyboard edit**

If at runtime the new section doesn't appear:

1. Open `iOS/Settings/Settings.storyboard` in Xcode
2. In the existing static `Settings` scene, add a new section after "Help" with one cell:
   - Title: `LLM Translation`
   - Accessory: Disclosure Indicator
   - Identifier: `translationRow`
3. Wire the cell's `Selection` segue (`Show`) to a new view controller scene
4. Set the new scene's custom class to `TranslationSettingsViewController`
5. Remove the code added in Step 9.1
6. Confirm `SettingsViewController.tableView(_:didSelectRowAt:)` is **not** intercepting this row

> Either path is acceptable; choose whichever runs cleanly in the simulator.

- [ ] **Step 9.3: Build + smoke test**

Run the iOS build command (Step 7.3). Then in the simulator:

1. Launch app
2. Tap the gear icon → Settings
3. Scroll down — confirm a "Translation" section with "LLM Translation" cell appears
4. Tap it — TranslationSettingsViewController pushes onto the nav stack
5. Enter `https://api.deepseek.com/v1`, a real DeepSeek API key, `deepseek-chat`
6. Tap "Test Connection" → expect green "OK: ..." status
7. Pop back, push again → confirm fields persist (URL/model from UserDefaults, API key from Keychain)

- [ ] **Step 9.4: Commit**

```bash
git add iOS/Settings/SettingsViewController.swift \
        iOS/Settings/Settings.storyboard \
        NetNewsWire.xcodeproj/project.pbxproj
git commit -m "translate: wire Translation settings into iOS Settings"
```

---

### Task 10: Add TranslateButton to ArticleViewController toolbar

Following the existing extractor pattern (`ArticleViewController.swift:43-46, 128-132`).

**Files:**
- Modify: `iOS/Article/ArticleViewController.swift`

- [ ] **Step 10.1: Add property + factory**

In `ArticleViewController.swift`, just below the existing `articleExtractorButton` declaration (around line 43-46), add:

```swift
private var translateButton: TranslateButton = {
    let button = TranslateButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setImage(UIImage(systemName: "character.book.closed"), for: .normal)
    return button
}()
```

- [ ] **Step 10.2: Wire to toolbar**

Locate the block around line 128-142 where `articleExtractorBarButtonItem` is inserted into `toolbarItems`. Immediately after that block, add:

```swift
translateButton.addTarget(self, action: #selector(toggleTranslation(_:)), for: .touchUpInside)
let translateBarButtonItem = UIBarButtonItem(customView: translateButton)
toolbarItems?.insert(translateBarButtonItem, at: 6)  // adjacent to extractor at 5
```

> If `toolbarItems` is nil or the index is out of range at runtime, fall back to `toolbarItems?.append(translateBarButtonItem)`.

- [ ] **Step 10.3: Add the action method**

Anywhere in the `ArticleViewController` class body, add:

```swift
@objc func toggleTranslation(_ sender: Any?) {
    currentWebViewController?.toggleTranslation()
}
```

- [ ] **Step 10.4: Reflect WebViewController state on the button**

Find the existing `webViewController(_:articleExtractorButtonStateDidUpdate:)` delegate method (around line 471-474). Add a sibling method below it:

```swift
func webViewController(_ webViewController: WebViewController, translateButtonStateDidUpdate buttonState: TranslateButtonState) {
    if webViewController === currentWebViewController {
        translateButton.buttonState = buttonState
    }
}
```

Also find the `articleExtractorButton.buttonState = currentWebViewController?.articleExtractorButtonState ?? .off` line (around line 523) and add directly below it:

```swift
translateButton.buttonState = currentWebViewController?.translateButtonState ?? .off
```

- [ ] **Step 10.5: Build to verify (will still fail until Task 11 because `WebViewController.toggleTranslation()` and `translateButtonState` don't exist yet)**

Run the iOS build. Expected: build **fails** with "Value of type 'WebViewController' has no member 'toggleTranslation'" — that's fine; Task 11 adds it. Do not commit yet.

> **Why not TDD?** Toolbar wiring isn't unit-testable without UI tests, which this project doesn't have. We rely on manual verification in Task 12 instead.

---

### Task 11: WebViewController orchestration

The core glue. Adds:
- A delegate method on `WebViewControllerDelegate`
- `translateButtonState` property (mirrors `articleExtractorButtonState`)
- `toggleTranslation()` action
- Private extract → translate → inject pipeline
- Cancellation handling

**Files:**
- Modify: `iOS/Article/WebViewController.swift`

- [ ] **Step 11.1: Extend the delegate protocol**

Near line 19 of `WebViewController.swift`, locate:

```swift
func webViewController(_: WebViewController, articleExtractorButtonStateDidUpdate: ArticleExtractorButtonState)
```

Add immediately below:

```swift
func webViewController(_: WebViewController, translateButtonStateDidUpdate: TranslateButtonState)
```

- [ ] **Step 11.2: Add state property + task handle**

Near the existing `articleExtractorButtonState` declaration (line 61-65), add:

```swift
var translateButtonState: TranslateButtonState = .off {
    didSet {
        delegate?.webViewController(self, translateButtonStateDidUpdate: translateButtonState)
    }
}

private var translationTask: Task<Void, Never>?
```

- [ ] **Step 11.3: Add toggleTranslation**

Anywhere in `WebViewController` (suggest placing it near `toggleArticleExtractor()` around line 262 for grouping):

```swift
func toggleTranslation() {
    guard let article = article else { return }

    switch translateButtonState {
    case .animated:
        translationTask?.cancel()
        translationTask = nil
        translateButtonState = .off
        return
    case .on:
        // Restore by re-rendering the original article
        translateButtonState = .off
        reloadArticleAfterTranslationToggleOff()
        return
    case .off, .error:
        break
    }

    let settings = TranslationSettings()
    guard settings.isConfigured else {
        presentMissingAPIKeyAlert()
        return
    }

    translateButtonState = .animated
    translationTask = Task { [weak self] in
        await self?.runTranslation(article: article, settings: settings)
    }
}

private func reloadArticleAfterTranslationToggleOff() {
    // The simplest correct path: ask the renderer to redraw the article
    // from scratch. NetNewsWire already supports this via the existing
    // article reload pipeline used by the extractor toggle.
    if let article = article {
        renderPage(article: article)  // Use the controller's existing render method.
    }
}
```

> **If `renderPage` doesn't exist by that name**: search `WebViewController.swift` for the method that produces the WebView HTML from an article (it calls into `ArticleRenderer`). Use that method's actual name. Likely candidates: `renderPage()`, `loadHTML()`, or the call inside `startArticleExtractor()` that re-renders the page after extraction. Update the call site accordingly.

- [ ] **Step 11.4: Add the translation pipeline**

In the same file, add a private extension at the bottom:

```swift
// MARK: - Translation

private extension WebViewController {

    @MainActor
    func runTranslation(article: Article, settings: TranslationSettings) async {
        do {
            // 1. Extract title + body HTML from the live DOM.
            async let titleHTMLValue = evaluateJavaScript("document.querySelector('.articleTitle h1')?.innerHTML ?? ''")
            async let bodyHTMLValue  = evaluateJavaScript("document.getElementById('bodyContainer')?.innerHTML ?? ''")
            let titleHTML = (try await titleHTMLValue as? String) ?? ""
            let bodyHTML  = (try await bodyHTMLValue as? String) ?? ""

            if titleHTML.isEmpty && bodyHTML.isEmpty {
                translateButtonState = .off
                return
            }

            // 2. Cache lookup
            let articleID = article.articleID
            let contentHash = TranslationStore.contentHash(title: titleHTML, bodyHTML: bodyHTML)
            let store = TranslationStore(databaseURL: TranslationStore.defaultDatabaseURL())

            let payload: String
            if let cached = store.fetch(articleID: articleID, model: settings.model, contentHash: contentHash) {
                payload = cached
            } else {
                // 3. Network
                guard let apiKey = settings.apiKey else {
                    presentMissingAPIKeyAlert()
                    translateButtonState = .off
                    return
                }
                let raw = try await LLMTranslationService().translate(
                    title: titleHTML,
                    bodyHTML: bodyHTML,
                    baseURL: settings.baseURL,
                    model: settings.model,
                    apiKey: apiKey
                )
                let sanitized = HTMLSanitizer.sanitize(raw)
                store.put(articleID: articleID, model: settings.model,
                          contentHash: contentHash, translatedHTML: sanitized)
                payload = sanitized
            }

            if Task.isCancelled {
                translateButtonState = .off
                return
            }

            // 4. Split + inject
            let split = try TranslatedHTML.split(payload)
            try await injectTranslation(title: split.title, body: split.body)
            translateButtonState = .on

        } catch is CancellationError {
            translateButtonState = .off
        } catch let LLMTranslationService.TranslationError.providerError(message, _) {
            presentTranslationErrorToast(message: message)
            translateButtonState = .error
        } catch let LLMTranslationService.TranslationError.network(urlError) {
            presentTranslationErrorToast(message: urlError.localizedDescription)
            translateButtonState = .error
        } catch {
            presentTranslationErrorToast(message: NSLocalizedString("Translation failed. Try again.", comment: ""))
            translateButtonState = .error
        }
    }

    @MainActor
    func injectTranslation(title: String, body: String) async throws {
        let titleJS = encodeForJS(title)
        let bodyJS  = encodeForJS(body)
        let script = """
        (function(){
          var t = document.querySelector('.articleTitle h1');
          if (t) t.innerHTML = \(titleJS);
          var b = document.getElementById('bodyContainer');
          if (b) b.innerHTML = \(bodyJS);
        })();
        """
        _ = try await evaluateJavaScript(script)
    }

    func encodeForJS(_ s: String) -> String {
        // Encode arbitrary string as a JS string literal using JSON.
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
        let arrayLiteral = String(data: data, encoding: .utf8) ?? "[\"\"]"
        // arrayLiteral is something like ["..."]. Strip the brackets.
        let inner = arrayLiteral.dropFirst().dropLast()
        return String(inner)
    }

    func presentMissingAPIKeyAlert() {
        let alert = UIAlertController(
            title: NSLocalizedString("API Key Required", comment: ""),
            message: NSLocalizedString("Add an API key in Settings → Translation.", comment: ""),
            preferredStyle: .alert)
        alert.addAction(.init(title: NSLocalizedString("OK", comment: ""), style: .default))
        // Best-effort: present from the topmost VC.
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first?.topPresented.present(alert, animated: true)
    }

    func presentTranslationErrorToast(message: String) {
        // NetNewsWire doesn't have a toast framework. Use a transient alert
        // with auto-dismiss after 2 seconds. Acceptable per the spec.
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first?.topPresented.present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            alert.dismiss(animated: true)
        }
    }
}

private extension UIViewController {
    var topPresented: UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController { top = next }
        return top
    }
}
```

> **`evaluateJavaScript` signature:** if the existing `WebViewController` already wraps `WKWebView.evaluateJavaScript`, use that wrapper. Otherwise expose a small async wrapper:

```swift
@MainActor
func evaluateJavaScript(_ script: String) async throws -> Any? {
    try await withCheckedThrowingContinuation { continuation in
        webView.evaluateJavaScript(script) { result, error in
            if let error = error { continuation.resume(throwing: error) } else { continuation.resume(returning: result) }
        }
    }
}
```

Confirm the webview property is named `webView` (search the file). If different, adjust.

- [ ] **Step 11.5: Cancellation on article change**

Search `WebViewController.swift` for places where the article changes — typically `stopArticleExtractor()` is called, or `article` is set. Add a `translationTask?.cancel()` call in the same spot to abort an in-flight translation. Example:

```swift
// near stopArticleExtractor()
translationTask?.cancel()
translationTask = nil
translateButtonState = .off
```

- [ ] **Step 11.6: Build**

Run the iOS build command. Expected: build succeeds (with possible warnings).

- [ ] **Step 11.7: Run the full test suite to confirm no regression**

Run:
```bash
xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire-iOS \
  -destination "platform=iOS Simulator,name=iPhone 17"
```
Expected: all existing + new tests pass.

- [ ] **Step 11.8: Commit**

```bash
git add iOS/Article/WebViewController.swift \
        iOS/Article/ArticleViewController.swift \
        NetNewsWire.xcodeproj/project.pbxproj
git commit -m "translate: wire translation flow into WebViewController

Adds toggleTranslation, runTranslation pipeline (extract DOM → cache
lookup → LLM call → sanitize → cache write → inject), error UX with
auto-dismiss alert, and Task cancellation on article switch and
toggle-off. Restores original on toggle-off by re-rendering."
```

---

### Task 12: Manual verification + final cleanup

Per the design spec section 5.2, run the manual checklist on a real iOS simulator with a real DeepSeek key.

- [ ] **Step 12.1: Boot the simulator + configure**

```bash
xcodebuild -project NetNewsWire.xcodeproj -scheme NetNewsWire-iOS \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -configuration Debug build
xcrun simctl launch booted com.ranchero.NetNewsWire-Evergreen 2>/dev/null || true
```

In the simulator:
1. Settings → Translation → enter `https://api.deepseek.com/v1`, real key, `deepseek-chat`
2. Tap "Test Connection" → expect green "OK: ..."

- [ ] **Step 12.2: Verify each manual checklist item**

Go through the spec's checklist; mark each line as you verify:

- [ ] Open an English article → tap translate → see Chinese
- [ ] Tap again → restored to English
- [ ] Re-open same article → tap translate → renders **instantly** (cache hit)
- [ ] Turn off Wi-Fi + cellular → tap translate → see error alert, button returns to idle
- [ ] Clear API key → tap translate → see "API Key Required" alert
- [ ] Open a Chinese article → tap translate → content roughly unchanged (acceptable)
- [ ] Translate article → force-quit app → relaunch → reopen same article → tap translate → cache hit (instant)
- [ ] Tap translate, immediately tap again before result arrives → no crash, no duplicate request
- [ ] Tap translate, swipe to next article before result arrives → previous request cancels, new article button is idle

If any item fails, do **not** mark this task complete — go fix the underlying issue and re-run.

- [ ] **Step 12.3: Final commit (if any fixups landed during manual testing)**

```bash
git add -A
git status
git commit -m "translate: post-manual-test fixups" || true  # tolerate empty
```

- [ ] **Step 12.4: Push the branch to the fork**

```bash
git push -u origin feature/ios-llm-translate
```

---

## Verification matrix

| Spec section                          | Implementing task(s)        |
|--------------------------------------|-----------------------------|
| 3.1 Settings screen                   | Tasks 4, 8, 9               |
| 3.2 Article view button + states      | Tasks 7, 10, 11             |
| 3.3 Error UX                          | Task 11 (presentMissingAPIKeyAlert, presentTranslationErrorToast) |
| 4.1 New module layout                 | Tasks 1, 2, 4, 5, 6         |
| 4.2 iOS UI additions                  | Tasks 7, 8, 9, 10           |
| 4.3 Data flow                         | Task 11 runTranslation      |
| 4.4 Prompt                            | Task 5 LLMTranslationService.systemPrompt |
| 4.5 Cache schema                      | Task 6 TranslationStore     |
| 4.6 Keychain                          | Task 3                      |
| 4.7 DOM injection                     | Task 11 injectTranslation, runTranslation extraction |
| 4.8 HTML sanitization                 | Task 1                      |
| 4.9 Concurrency                       | Task 11 (@MainActor, Task cancellation) |
| 5.1 XCTest coverage                   | Tasks 1, 2, 4, 5, 6         |
| 5.2 Manual checklist                  | Task 12                     |
