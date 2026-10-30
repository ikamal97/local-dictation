import AppKit
import SQLite3

struct HistoryEntry: Identifiable, Hashable {
    enum Source: String { case local, wispr }
    let id: Int64
    let date: Date
    let text: String
    let appName: String?
    let words: Int
    let audioSeconds: Double
    let latencyMs: Int?
    let source: Source
}

/// Dictation history in SQLite (Application Support/LocalDictation/history.sqlite).
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    /// Saved take audio, named by history id and deleted along with its entry.
    let recordings = RecordingStore()

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL = Paths.support.appendingPathComponent("history.sqlite")) {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            Log.info("history: could not open \(url.path)")
            return
        }
        exec("""
            CREATE TABLE IF NOT EXISTS dictations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                text TEXT NOT NULL,
                app_name TEXT,
                words INTEGER NOT NULL,
                audio_seconds REAL NOT NULL DEFAULT 0,
                latency_ms INTEGER,
                source TEXT NOT NULL DEFAULT 'local'
            );
            CREATE INDEX IF NOT EXISTS dictations_time ON dictations(timestamp DESC);
            """)
        reload()
        recordings.prune()
    }

    // MARK: - Writing

    /// Returns the new entry's id.
    @discardableResult
    func add(text: String, appName: String?, audioSeconds: Double, latencyMs: Int) -> Int64? {
        let id = insert(date: Date(), text: text, appName: appName, audioSeconds: audioSeconds, latencyMs: latencyMs, source: .local)
        reload()
        return id
    }

    func delete(_ entry: HistoryEntry) {
        exec("DELETE FROM dictations WHERE id = \(entry.id)")
        recordings.delete(id: entry.id)
        reload()
    }

    func clear() {
        exec("DELETE FROM dictations")
        recordings.deleteAll()
        reload()
    }

    var hasWisprImport: Bool { entries.contains { $0.source == .wispr } }

    /// Copies dictations from Wispr Flow's local database (opened read-only). Returns the count imported.
    func importFromWispr() -> Int {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite").path
        var source: OpaquePointer?
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?immutable=1"
        guard sqlite3_open_v2(uri, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(source) }

        var stmt: OpaquePointer?
        let query = """
            SELECT timestamp, formattedText, app, duration, e2eLatency FROM History
            WHERE length(formattedText) > 0 AND coalesce(isArchived, 0) = 0
            """
        guard sqlite3_prepare_v2(source, query, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        exec("DELETE FROM dictations WHERE source = 'wispr'")
        exec("BEGIN")
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        var names: [String: String] = [:]
        var count = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let stamp = string(stmt, 0), let date = parser.date(from: stamp),
                  let text = string(stmt, 1) else { continue }
            let bundle = string(stmt, 2) ?? ""
            if names[bundle] == nil { names[bundle] = Self.appName(forBundleID: bundle) ?? "" }
            let latency = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_double(stmt, 4))
            insert(date: date, text: text, appName: names[bundle].flatMap { $0.isEmpty ? nil : $0 },
                   audioSeconds: sqlite3_column_double(stmt, 3),
                   latencyMs: latency.flatMap { $0 > 0 && $0 < 60_000 ? $0 : nil }, source: .wispr)
            count += 1
        }
        exec("COMMIT")
        reload()
        Log.info("history: imported \(count) dictations from Wispr Flow")
        return count
    }

    // MARK: - Reading

    private func reload() {
        var stmt: OpaquePointer?
        let query = "SELECT id, timestamp, text, app_name, words, audio_seconds, latency_ms, source FROM dictations ORDER BY timestamp DESC"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        var rows: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(HistoryEntry(
                id: sqlite3_column_int64(stmt, 0),
                date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                text: string(stmt, 2) ?? "",
                appName: string(stmt, 3),
                words: Int(sqlite3_column_int(stmt, 4)),
                audioSeconds: sqlite3_column_double(stmt, 5),
                latencyMs: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6)),
                source: HistoryEntry.Source(rawValue: string(stmt, 7) ?? "") ?? .local))
        }
        entries = rows
    }

    // MARK: - SQLite helpers

    @discardableResult
    private func insert(date: Date, text: String, appName: String?, audioSeconds: Double, latencyMs: Int?, source: HistoryEntry.Source) -> Int64? {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO dictations (timestamp, text, app_name, words, audio_seconds, latency_ms, source) VALUES (?, ?, ?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, text, -1, Self.transient)
        if let appName { sqlite3_bind_text(stmt, 3, appName, -1, Self.transient) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_int(stmt, 4, Int32(text.split(whereSeparator: \.isWhitespace).count))
        sqlite3_bind_double(stmt, 5, audioSeconds)
        if let latencyMs { sqlite3_bind_int(stmt, 6, Int32(latencyMs)) } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_bind_text(stmt, 7, source.rawValue, -1, Self.transient)
        return sqlite3_step(stmt) == SQLITE_DONE ? sqlite3_last_insert_rowid(db) : nil
    }

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            Log.info("history: sqlite error \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func string(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }

    static func appName(forBundleID bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
