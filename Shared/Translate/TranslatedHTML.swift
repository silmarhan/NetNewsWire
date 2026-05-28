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
