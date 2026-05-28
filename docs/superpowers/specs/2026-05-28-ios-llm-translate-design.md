# iOS One-Tap LLM Translation — Design Spec

- **Date**: 2026-05-28
- **Owner**: @silmarhan
- **Scope**: iOS target only (macOS untouched for this iteration)
- **Fork**: https://github.com/silmarhan/NetNewsWire

## 1. Goal

Add a "translate" button to the iOS article reader that, on tap, replaces an
article's title and body with a Simplified-Chinese translation produced by a
user-configured LLM (OpenAI Chat-Completions–compatible API, e.g. DeepSeek).
Tap again to restore the original. Cache results so re-opening an article
serves the translation instantly.

## 2. Non-goals (this iteration)

- macOS support
- Streaming (typewriter) rendering
- Per-paragraph parallel translation
- Per-article language pair configuration (target is always zh-Hans)
- Translating timeline (article list) view
- Translating image alt text / captions / non-rendered metadata
- CI integration
- Mock LLM integration tests
- Cost / token usage UI

## 3. User-visible behavior

### 3.1 Settings

Navigation: **Settings → Translation**. New section in `SettingsViewController`
that pushes `TranslationSettingsViewController` (new). The screen has three
text cells and one action button:

| Field      | Default                              | Notes                            |
|------------|--------------------------------------|----------------------------------|
| Base URL   | `https://api.deepseek.com/v1`        | Must be `http(s)://…`, validated |
| API Key    | *(empty)*                            | Password-masked input            |
| Model      | `deepseek-chat`                      | Free-form text                   |
| Action     | **Test Connection**                  | Fires a 1-token request, toasts result |
| Action     | **Clear translation cache**          | Deletes all rows in cache DB     |

Base URL and Model are persisted in `UserDefaults`. API Key is persisted in
the iOS Keychain via the existing `Modules/Secrets` module.

### 3.2 Article view

A new toolbar button (`TranslateButton`) appears next to the existing Reader
View (`ArticleExtractorButton`) in `ArticleViewController`'s toolbar. States:

- **Idle**: line-art icon, untinted
- **Loading**: button shows a spinner (replace icon)
- **Translated**: icon tinted with `tintColor` (matches Reader View pattern)

Tap behavior:

- Idle → Loading → Translated: translation injected into DOM
- Translated → Idle: re-render the article via existing `ArticleRenderer`
- Loading → Idle: cancel in-flight `Task`

### 3.3 Error UX

| Situation                              | Behavior                                                          |
|----------------------------------------|-------------------------------------------------------------------|
| No API key configured                  | Alert: "Add an API key in Settings → Translation" + "Open Settings" button that deep-links to the Translation sub-page |
| Network failure / DNS / 30s timeout    | Toast: "Translation failed. Try again." Button returns to Idle    |
| HTTP 4xx (auth/quota)                  | Toast displaying provider's `error.message`. Button returns to Idle |
| HTTP 5xx                               | Toast: "Translation failed. Try again." Button returns to Idle    |
| Article body is empty / image-only     | Button briefly flashes grey, returns to Idle (no request fired)   |
| Same article tapped while in flight    | Reuse running `Task` (no duplicate request)                       |
| Different article opened mid-flight    | Cancel previous `Task`, new article has independent button state  |

## 4. Architecture

### 4.1 New module

Initial home: `Shared/Translate/` (not yet promoted to a Swift package; keep
the diff localized while iterating). If a second platform consumes it later,
promote to `Modules/Translate`.

Files:

```
Shared/Translate/
  LLMTranslationService.swift   # OpenAI-compatible chat client
  TranslationStore.swift         # SQLite cache
  TranslationSettings.swift      # UserDefaults + Keychain helpers
  HTMLSanitizer.swift            # script/iframe/on* stripper
```

### 4.2 iOS UI additions

```
iOS/Article/
  TranslateButton.swift          # mirrors ArticleExtractorButton
iOS/Settings/
  TranslationSettingsViewController.swift  # new screen + storyboard entry
```

`ArticleViewController` gets:

- a `@Published var translationState: TranslationState` (`.idle` / `.loading` /
  `.translated`)
- a `translateButtonTapped()` action wired to the new button
- a `currentTranslationTask: Task<Void, Never>?` for cancellation

### 4.3 Data flow (one translate tap)

```
Tap
  └─ ArticleViewController.translateButtonTapped()
       ├─ guard apiKey present → else alert + return
       ├─ ask WKWebView for current title and body HTML via evaluateJavaScript
       ├─ compute SHA256(title + body) → contentHash
       ├─ TranslationStore.get(articleID, model)
       │    ├─ row exists AND row.contentHash == contentHash → inject → .translated
       │    └─ otherwise → fall through to network
       ├─ LLMTranslationService.translate(title: ..., body: ...)   # 30s URLSession timeout
       │    POST {baseURL}/chat/completions  (Bearer apiKey)
       │    body: { model, temperature: 0.2, stream: false, messages: [system, user] }
       │    response: assistant content = "<h1>译标题</h1>\n译正文HTML"
       ├─ HTMLSanitizer.sanitize(response)
       ├─ TranslationStore.put(articleID, model, contentHash, sanitizedHTML)
       └─ inject into WKWebView via evaluateJavaScript → .translated
```

### 4.4 Prompt

System message:

> You are a professional translator. Translate the user's input into Simplified
> Chinese. Preserve all HTML tags, attributes, hyperlinks, code blocks, and
> inline formatting exactly. Do not translate text inside `<code>`, `<pre>`,
> or attributes. Do not add commentary. Output only the translated HTML.

User message: `<h1>{title}</h1>\n{bodyHTML}`

Response parsing: split on the first `</h1>`; left side is translated title
(strip the `<h1>` open/close tags), right side is translated body HTML.

### 4.5 Cache schema

Separate SQLite file `TranslationDatabase.sqlite` in the app's Application
Support directory. Does not touch `ArticlesDatabase`.

```sql
CREATE TABLE translations (
  article_id      TEXT NOT NULL,
  model           TEXT NOT NULL,
  content_hash    TEXT NOT NULL,
  translated_html TEXT NOT NULL,
  created_at      REAL NOT NULL,
  PRIMARY KEY (article_id, model)
);
```

- No automatic expiry. User clears via the Settings → Translation button.
- Mismatched `content_hash` is treated as a miss and overwritten on next save.

### 4.6 Keychain (Secrets module extension)

Add to `Modules/Secrets/Sources/Secrets/Secrets.swift` (or sibling file):

```swift
public extension Secrets {
    var translationAPIKey: String? {
        get { keychainItem(... service: "com.ranchero.NetNewsWire.translation",
                            account: "apiKey") }
        set { ... }
    }
}
```

### 4.7 DOM injection

- Extract: `evaluateJavaScript("document.querySelector('.articleTitle')?.innerHTML")`
  and same for `.articleBody` (exact selectors confirmed against
  `Shared/Article Rendering/template.html` during implementation).
- Inject: set `innerHTML` on the same selectors with the sanitized response.
- Restore: call existing `ArticleRenderer` to re-render the article from scratch
  (do not attempt reverse DOM replacement).

### 4.8 HTML sanitization

Before injection, strip:

- `<script>…</script>` blocks (case-insensitive, greedy across newlines)
- `<iframe>…</iframe>` blocks
- `on\w+="…"` and `on\w+='…'` attribute pairs
- `href`/`src` values starting with `javascript:`

This is defense-in-depth; WKWebView is sandboxed and has no privileged JS
bridge enabled for article content.

### 4.9 Concurrency

- All network and DB I/O is `async throws`.
- `LLMTranslationService.translate` runs on a background actor / detached task.
- DOM reads/writes hop back to `@MainActor`.
- Per-article in-flight task stored on `ArticleViewController`; cancellation
  driven by `Task.cancel()` on article switch or user toggle-off.

## 5. Testing

### 5.1 XCTest (matches existing project patterns)

- **`LLMTranslationServiceTests`** (mock `URLProtocol`):
  - 200 + valid JSON → returns expected HTML; title/body split correctly
  - 401 / 429 → error surfaces provider's `error.message`
  - 500 → generic network error
  - request timeout (30 s) → cancellation error
  - request body sanity: `model`, `messages`, `stream: false`, auth header

- **`TranslationStoreTests`** (in-memory SQLite):
  - put then get returns the row
  - mismatched `content_hash` returns nil (treated as miss)
  - different `model` does not collide with same `article_id`
  - `clearAll()` empties the table

- **`HTMLSanitizerTests`**:
  - `<script>` stripped (with and without attributes, multi-line, nested cases)
  - `<iframe>` stripped
  - `on*=` attributes stripped from arbitrary tags
  - `javascript:` URLs stripped from `href` and `src`
  - non-malicious HTML passes through unchanged

- **`TranslationSettingsTests`**:
  - Valid `http(s)://` URLs accepted; others rejected
  - Empty model name rejected

### 5.2 Manual checklist (run before declaring done)

- [ ] First launch: open a fresh build, configure DeepSeek key + default
      model, save
- [ ] Open an English article (Hacker News feed) → tap translate → see Chinese
- [ ] Tap again → restored to English
- [ ] Re-open the same article → tap translate → renders **instantly** (cache hit)
- [ ] Turn off Wi-Fi + cellular → tap translate → see error toast, button
      returns to idle
- [ ] Clear settings + open article + tap translate → see alert with "Open
      Settings" deep-link
- [ ] Open a Chinese article → tap translate → content roughly unchanged
      (acceptable)
- [ ] Translate article → force-quit app → relaunch → reopen same article →
      tap translate → cache hit (instant)
- [ ] Tap translate, immediately tap again before result arrives → no crash,
      no duplicate request
- [ ] Tap translate, swipe to next article before result arrives → previous
      request cancels, new article button is idle

## 6. Out-of-scope risks (acknowledged, deferred)

- **Cost runaway**: a careless user could burn through quota by repeatedly
  translating very long articles. Cache mitigates re-translation but not the
  first. Future: token estimate preview before sending.
- **Prompt injection**: a malicious feed could craft article text that asks
  the LLM to output dangerous HTML. Sanitizer handles the worst (`<script>`,
  `javascript:`), but social-engineering output (e.g., a fake "click here"
  phishing link in the translated body) is not detectable. Mitigation in
  future: render through a stricter HTML allowlist instead of regex strip.
- **Provider variance**: not every "OpenAI-compatible" endpoint is bug-for-bug
  compatible. We use only the minimal request shape (`messages` + `model` +
  `temperature` + `stream:false`) and tolerate JSON shape variations only on
  the success path. Errors that don't follow the OpenAI error envelope will
  surface as a generic message — acceptable.
- **Rename / rebrand**: the fork is `silmarhan/NetNewsWire`; the app keeps
  the NetNewsWire name and bundle ID. Renaming for distribution is a separate
  decision and out of scope here.

## 7. Files changed (preview)

```
Shared/Translate/                         (new dir, 4 files)
iOS/Article/TranslateButton.swift         (new)
iOS/Article/ArticleViewController.swift   (modified: button wiring, state)
iOS/Settings/TranslationSettingsViewController.swift  (new)
iOS/Settings/SettingsViewController.swift (modified: new row + segue)
iOS/Settings/Settings.storyboard          (modified: new entry)
Modules/Secrets/.../Secrets.swift         (modified: translationAPIKey accessor)
Tests/                                    (new test files)
NetNewsWire.xcodeproj/                    (modified: add new sources to target)
```

## 8. Open questions deferred to implementation

- Exact CSS selectors for title/body in `template.html` — confirm during
  implementation.
- Whether `RSWeb` already has an SSE-friendly fetcher (we don't need SSE this
  iteration, but using `RSWeb`'s shared session for plain POST is preferable
  to a fresh `URLSession` if it exists).
- Storyboard vs SwiftUI for `TranslationSettingsViewController` — match
  whichever style the surrounding settings screens use (likely storyboard;
  confirm).
