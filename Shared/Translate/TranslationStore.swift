//
//  TranslationStore.swift
//  NetNewsWire
//

import Foundation
import CryptoKit
import RSDatabase
import RSDatabaseObjC

final class TranslationStore {

    private let queue: DatabaseQueue

    init(databaseURL: URL) {
        // Ensure parent directory exists
        try? FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        self.queue = DatabaseQueue(databasePath: databaseURL.path)
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
        queue.runInDatabaseSync { result in
            guard let db = result.database else { return }
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
        nonisolated(unsafe) var result: String?
        queue.runInDatabaseSync { databaseResult in
            guard let db = databaseResult.database else { return }
            guard let rs = db.executeQuery(
                "SELECT translated_html FROM translations WHERE article_id = ? AND model = ? AND content_hash = ? LIMIT 1",
                withArgumentsIn: [articleID, model, contentHash]
            ) else { return }
            if rs.next() {
                result = rs.string(forColumn: "translated_html")
            }
            rs.close()
        }
        return result
    }

    func put(articleID: String, model: String, contentHash: String, translatedHTML: String) {
        queue.runInDatabaseSync { databaseResult in
            guard let db = databaseResult.database else { return }
            db.executeUpdate(
                """
                INSERT OR REPLACE INTO translations
                  (article_id, model, content_hash, translated_html, created_at)
                  VALUES (?, ?, ?, ?, ?)
                """,
                withArgumentsIn: [articleID, model, contentHash, translatedHTML, Date().timeIntervalSince1970])
        }
    }

    func clearAll() {
        queue.runInDatabaseSync { databaseResult in
            guard let db = databaseResult.database else { return }
            db.executeUpdate("DELETE FROM translations", withArgumentsIn: [])
        }
    }

    static func contentHash(title: String, bodyHTML: String) -> String {
        let combined = title + "\n" + bodyHTML
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
