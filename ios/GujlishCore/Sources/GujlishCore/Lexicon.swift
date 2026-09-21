// Read-only access to gujlish.db (built by build_db.py). The database
// stays on disk: a keyboard extension is killed around 60 MB, so nothing
// here loads a table into memory. Queries have the same shape as the
// ones in engine.py, which is the reference.

import SQLite3

public struct LexiconError: Error, CustomStringConvertible {
    public let description: String
}

public final class Lexicon {
    public struct Word {
        public let id: Int
        public let surface: String
        public let strictK: String
        public let looseK: String
        public let freq: Int
    }

    public enum KeyColumn: String {
        case strict = "strict_k"
        case loose = "loose_k"
    }

    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(db)
            throw LexiconError(description: "cannot open \(path): \(msg)")
        }
    }

    deinit {
        for s in statements.values { sqlite3_finalize(s) }
        sqlite3_close(db)
    }

    // Prepared once, reused for the life of the keyboard session.
    private func statement(_ sql: String) -> OpaquePointer {
        if let s = statements[sql] {
            sqlite3_reset(s)
            return s
        }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let stmt = s else {
            fatalError("bad SQL (\(String(cString: sqlite3_errmsg(db)))): \(sql)")
        }
        statements[sql] = stmt
        return stmt
    }

    private func bind(_ s: OpaquePointer, _ i: Int32, _ text: String) {
        sqlite3_bind_text(s, i, text, -1, Lexicon.transient)
    }

    private func text(_ s: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(s, col).map { String(cString: $0) } ?? ""
    }

    private func word(_ s: OpaquePointer) -> Word {
        Word(id: Int(sqlite3_column_int64(s, 0)), surface: text(s, 1),
             strictK: text(s, 2), looseK: text(s, 3), freq: Int(sqlite3_column_int64(s, 4)))
    }

    private func words(_ s: OpaquePointer) -> [Word] {
        var out: [Word] = []
        while sqlite3_step(s) == SQLITE_ROW { out.append(word(s)) }
        sqlite3_reset(s)
        return out
    }

    private func pairs(_ s: OpaquePointer) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        while sqlite3_step(s) == SQLITE_ROW {
            out.append((Int(sqlite3_column_int64(s, 0)), Int(sqlite3_column_int64(s, 1))))
        }
        sqlite3_reset(s)
        return out
    }

    // ---------- lookup ----------

    public func byPrefix(_ keyPrefix: String, column: KeyColumn, limit: Int = 60) -> [Word] {
        let c = column.rawValue
        let s = statement("SELECT id, surface, strict_k, loose_k, freq FROM words "
            + "WHERE \(c) >= ? AND \(c) < ? ORDER BY freq DESC, surface LIMIT ?")
        bind(s, 1, keyPrefix)
        bind(s, 2, keyPrefix + "\u{FFFF}")
        sqlite3_bind_int64(s, 3, Int64(limit))
        return words(s)
    }

    /// The most frequent words whose loose key has a length in lo...hi;
    /// the engine checks edit distance over this pool.
    public func fuzzyPool(minLength lo: Int, maxLength hi: Int, limit: Int = 400) -> [Word] {
        let s = statement("SELECT id, surface, strict_k, loose_k, freq FROM words "
            + "WHERE LENGTH(loose_k) BETWEEN ? AND ? ORDER BY freq DESC, surface LIMIT ?")
        sqlite3_bind_int64(s, 1, Int64(lo))
        sqlite3_bind_int64(s, 2, Int64(hi))
        sqlite3_bind_int64(s, 3, Int64(limit))
        return words(s)
    }

    public func word(surface: String) -> Word? {
        let s = statement("SELECT id, surface, strict_k, loose_k, freq FROM words WHERE surface = ? LIMIT 1")
        bind(s, 1, surface)
        return words(s).first
    }

    public func words(looseKey: String) -> [Word] {
        let s = statement("SELECT id, surface, strict_k, loose_k, freq FROM words WHERE loose_k = ?")
        bind(s, 1, looseKey)
        return words(s)
    }

    public func surface(id: Int) -> String? {
        let s = statement("SELECT surface FROM words WHERE id = ?")
        sqlite3_bind_int64(s, 1, Int64(id))
        defer { sqlite3_reset(s) }
        return sqlite3_step(s) == SQLITE_ROW ? text(s, 0) : nil
    }

    /// Gujarati-script form of a word, for script mode.
    public func native(surface: String) -> String? {
        let s = statement("SELECT native FROM words WHERE surface = ? AND native IS NOT NULL LIMIT 1")
        bind(s, 1, surface)
        defer { sqlite3_reset(s) }
        return sqlite3_step(s) == SQLITE_ROW ? text(s, 0) : nil
    }

    /// (next_id, weight) for every word that sounds like prev1.
    public func bigramRows(prevLooseKey: String) -> [(Int, Int)] {
        let s = statement("SELECT b.next_id, b.weight FROM bigrams b "
            + "JOIN words w ON w.id = b.prev_id WHERE w.loose_k = ?")
        bind(s, 1, prevLooseKey)
        return pairs(s)
    }

    public func trigramRows(prev2LooseKey: String, prev1LooseKey: String) -> [(Int, Int)] {
        let s = statement("SELECT t.next_id, t.weight FROM trigrams t "
            + "JOIN words w2 ON w2.id = t.prev2_id "
            + "JOIN words w1 ON w1.id = t.prev1_id "
            + "WHERE w2.loose_k = ? AND w1.loose_k = ?")
        bind(s, 1, prev2LooseKey)
        bind(s, 2, prev1LooseKey)
        return pairs(s)
    }

    /// Every word whose surface length is in lo...hi, for the correction
    /// scan. The surface is handed over as raw UTF-8 so that no String is
    /// made for the thousands of rows that do not match.
    public func scanSurfaces(minLength lo: Int, maxLength hi: Int,
                             _ body: (_ id: Int, _ surface: UnsafeBufferPointer<UInt8>, _ freq: Int) -> Void) {
        let s = statement("SELECT id, surface, freq FROM words WHERE LENGTH(surface) BETWEEN ? AND ?")
        sqlite3_bind_int64(s, 1, Int64(lo))
        sqlite3_bind_int64(s, 2, Int64(hi))
        while sqlite3_step(s) == SQLITE_ROW {
            guard let p = sqlite3_column_text(s, 1) else { continue }
            let n = Int(sqlite3_column_bytes(s, 1))
            body(Int(sqlite3_column_int64(s, 0)), UnsafeBufferPointer(start: p, count: n),
                 Int(sqlite3_column_int64(s, 2)))
        }
        sqlite3_reset(s)
    }

    // ---------- English list (mixed mode) ----------

    public func englishByPrefix(_ typed: String, limit: Int = 20) -> [(word: String, freq: Int)] {
        let s = statement("SELECT word, freq FROM english WHERE word >= ? AND word < ? "
            + "ORDER BY freq DESC, word LIMIT ?")
        bind(s, 1, typed)
        bind(s, 2, typed + "\u{FFFF}")
        sqlite3_bind_int64(s, 3, Int64(limit))
        var out: [(word: String, freq: Int)] = []
        while sqlite3_step(s) == SQLITE_ROW {
            out.append((text(s, 0), Int(sqlite3_column_int64(s, 1))))
        }
        sqlite3_reset(s)
        return out
    }

    public func englishFreq(_ word: String) -> Int? {
        let s = statement("SELECT freq FROM english WHERE word = ?")
        bind(s, 1, word)
        defer { sqlite3_reset(s) }
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int64(s, 0)) : nil
    }
}
