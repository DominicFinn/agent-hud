import Foundation
import SQLite3

/// Text with the parts that matched a search marked, ready to draw.
public struct Highlighted: Sendable, Equatable {
    public struct Span: Sendable, Equatable {
        public var text: String
        public var isMatch: Bool

        public init(text: String, isMatch: Bool) {
            self.text = text
            self.isMatch = isMatch
        }
    }

    public var spans: [Span]

    public init(spans: [Span]) { self.spans = spans }

    public init(plain text: String) { spans = text.isEmpty ? [] : [Span(text: text, isMatch: false)] }

    /// `text` with every case-insensitive occurrence of any of `words` marked.
    public init(_ text: String, matching words: [String]) {
        let words = words.filter { !$0.isEmpty }
        var spans: [Span] = []
        var rest = text[...]
        while let hit = words.compactMap({ rest.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) })
            .min(by: { $0.lowerBound < $1.lowerBound }) {
            if hit.lowerBound > rest.startIndex { spans.append(Span(text: String(rest[..<hit.lowerBound]), isMatch: false)) }
            spans.append(Span(text: String(rest[hit]), isMatch: true))
            rest = rest[hit.upperBound...]
        }
        if !rest.isEmpty { spans.append(Span(text: String(rest), isMatch: false)) }
        self.spans = spans
    }

    /// SQLite's `snippet()` output, with each match between `SearchIndex.open` and `SearchIndex.close`.
    /// Line breaks become spaces: a snippet is read as one run of text.
    init(marked: String) {
        var spans: [Span] = [], current = "", isMatch = false
        for character in marked {
            if character == SearchIndex.open || character == SearchIndex.close {
                if !current.isEmpty { spans.append(Span(text: current, isMatch: isMatch)) }
                current = ""
                isMatch = character == SearchIndex.open
            } else {
                current.append(character.isNewline ? " " : character)
            }
        }
        if !current.isEmpty { spans.append(Span(text: current, isMatch: isMatch)) }
        self.spans = spans
    }

    public var plain: String { spans.map(\.text).joined() }
    public var hasMatch: Bool { spans.contains(where: \.isMatch) }
}

/// A prompt or reply found by a search.
public struct SearchMessage: Sendable, Equatable, Identifiable {
    public enum Role: Int, Sendable { case prompt, reply }

    public var id: Int64
    public var role: Role
    public var date: Date
    public var text: Highlighted

    public init(id: Int64, role: Role, date: Date, text: Highlighted) {
        self.id = id
        self.role = role
        self.date = date
        self.text = text
    }
}

/// A session's name, folder, title or branch, when that is what matched.
public struct NameMatch: Sendable, Equatable {
    /// "folder", "name", "title" or "branch".
    public var field: String
    public var text: Highlighted
}

/// One live session that matches a search.
public struct SearchResult: Sendable, Equatable, Identifiable {
    public var id: String { sessionId }
    public var sessionId: String
    /// Set when the session's name, folder, title or branch matched, not only something said in it.
    public var nameMatch: NameMatch?
    /// The message that matches best, as a short snippet.
    public var best: SearchMessage?
    /// How many messages in the session match.
    public var matches = 0
    /// The best message with the ones either side of it, for the preview.
    public var context: [SearchMessage] = []
}

/// Full-text search over what live sessions have said: the prompts people typed and Claude's replies.
///
/// It exists so the search bar can find the agent you're after, so it only keeps what that needs. The
/// index lives in memory and is never written to disk, so it goes when the app quits. It only holds live
/// sessions: the ingest engine drops a session's messages on the poll after it ends. Thinking, tool calls,
/// tool output, subagents and text Claude Code injects (skills, compaction summaries) are never added.
///
/// SQLite's FTS5 does the matching, ranking and snippets. SQLite ships with macOS, so it is not a dependency.
/// The engine writes and the UI reads from different threads, so every call takes the lock.
public final class SearchIndex: @unchecked Sendable {
    /// Something said in a session that is worth finding.
    public struct Message: Sendable, Equatable {
        public var role: SearchMessage.Role
        public var date: Date
        public var text: String

        public init(role: SearchMessage.Role, date: Date, text: String) {
            self.role = role
            self.date = date
            self.text = text
        }

        /// What a transcript line said, if it was a prompt a person typed or a reply from Claude.
        public init?(_ event: TranscriptEvent) {
            guard !event.isSidechain else { return nil }
            let text = event.blocks.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
            guard !text.allSatisfy(\.isWhitespace) else { return nil }
            switch event.role {
            case .user:
                guard event.isUserPrompt, !event.isInjected, !SessionState.isSystemNoise(text) else { return nil }
                role = .prompt
            case .assistant:
                role = .reply
            default:
                return nil
            }
            self.text = text
            date = event.timestamp ?? Date()
        }
    }

    /// What a session is called and where it runs, so it can be found by name as well as by what was said.
    public struct Names: Sendable, Equatable {
        /// The working directory, with the home directory as `~`.
        public var folder: String
        public var name: String
        public var title: String?
        public var branch: String?
        public var lastActive: Date?

        public init(folder: String, name: String, title: String? = nil, branch: String? = nil, lastActive: Date? = nil) {
            self.folder = folder
            self.name = name
            self.title = title
            self.branch = branch
            self.lastActive = lastActive
        }

        /// Every word has to appear in one field or another: "hud main" finds agent-hud on main.
        /// The match shown is the first field that has any of them.
        func match(_ words: [String]) -> NameMatch? {
            let fields = [("folder", folder), ("name", name), ("title", title ?? ""), ("branch", branch ?? "")]
            func has(_ text: String, _ word: String) -> Bool {
                text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            guard words.allSatisfy({ word in fields.contains { has($0.1, word) } }),
                  let (field, text) = fields.first(where: { field in words.contains { has(field.1, $0) } })
            else { return nil }
            return NameMatch(field: field, text: Highlighted(text, matching: words))
        }
    }

    static let open: Character = "\u{2}", close: Character = "\u{3}"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var db: OpaquePointer?
    private let lock = NSLock()
    /// The next message number in each session, so the preview can find a match's neighbours.
    private var nextSeq: [String: Int] = [:]
    private var names: [String: Names] = [:]

    public init() {
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return
        }
        // Temporary tables stay in memory too, and deleted text is overwritten rather than left in free pages.
        run("PRAGMA temp_store = MEMORY")
        run("PRAGMA secure_delete = ON")
        run("""
            CREATE VIRTUAL TABLE messages USING fts5(
                body, session UNINDEXED, seq UNINDEXED, role UNINDEXED, at UNINDEXED,
                tokenize = 'porter unicode61 remove_diacritics 2')
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: Writing

    public func add(_ messages: [Message], to sessionId: String) {
        guard !messages.isEmpty else { return }
        lock.withLock {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO messages (body, session, seq, role, at) VALUES (?, ?, ?, ?, ?)",
                                     -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            var seq = nextSeq[sessionId, default: 0]
            run("BEGIN")
            for message in messages {
                sqlite3_bind_text(statement, 1, message.text, -1, Self.transient)
                sqlite3_bind_text(statement, 2, sessionId, -1, Self.transient)
                sqlite3_bind_int64(statement, 3, Int64(seq))
                sqlite3_bind_int64(statement, 4, Int64(message.role.rawValue))
                sqlite3_bind_double(statement, 5, message.date.timeIntervalSince1970)
                sqlite3_step(statement)
                sqlite3_reset(statement)
                seq += 1
            }
            run("COMMIT")
            nextSeq[sessionId] = seq
        }
    }

    public func describe(_ sessionId: String, as names: Names) {
        lock.withLock { self.names[sessionId] = names }
    }

    /// Drops every session that is not in `live`, what it said and its names both.
    public func retain(only live: Set<String>) {
        lock.withLock {
            let gone = Set(nextSeq.keys).union(names.keys).subtracting(live)
            guard !gone.isEmpty else { return }
            for id in gone {
                run("DELETE FROM messages WHERE session = ?", [id])
                nextSeq[id] = nil
                names[id] = nil
            }
            // A delete only marks the rows in the full-text index; merging it takes their words out as well.
            run("INSERT INTO messages (messages) VALUES ('optimize')")
        }
    }

    // MARK: Reading

    /// Sessions in the index, for tests and `hudctl`.
    public var sessions: Set<String> { lock.withLock { Set(nextSeq.keys).union(names.keys) } }

    /// Rows in the full-text table, for tests and `hudctl`.
    public var messageCount: Int {
        lock.withLock {
            var count = 0
            run("SELECT count(*) FROM messages") { count = Int(sqlite3_column_int64($0, 0)) }
            return count
        }
    }

    /// Live sessions matching `query`, one result each. Name matches come first, most recently active
    /// first, then sessions where only something said matched, best match first.
    public func search(_ query: String, limit: Int = 20) -> [SearchResult] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return lock.withLock {
            var results: [String: SearchResult] = [:]
            for (id, names) in names {
                if let match = names.match(words) { results[id] = SearchResult(sessionId: id, nameMatch: match) }
            }

            let expression = Self.expression(for: query)
            var bySaid: [String] = []
            var seqs: [String: Int] = [:]
            if let expression {
                run("""
                    SELECT rowid, session, seq, role, at, snippet(messages, 0, ?, ?, '…', 14)
                    FROM messages WHERE messages MATCH ? ORDER BY rank LIMIT 500
                    """, [String(Self.open), String(Self.close), expression]) { row in
                    let session = Self.text(row, 1)
                    // Rows come best first, so the first one seen for a session is its best.
                    guard results[session]?.best == nil else { return }
                    if results[session] == nil {
                        results[session] = SearchResult(sessionId: session)
                        bySaid.append(session)
                    }
                    results[session]?.best = Self.message(row, text: Highlighted(marked: Self.text(row, 5)))
                    seqs[session] = Int(sqlite3_column_int64(row, 2))
                }
            }

            let byName = results.values.filter { $0.nameMatch != nil }
                .sorted { (names[$0.sessionId]?.lastActive ?? .distantPast) > (names[$1.sessionId]?.lastActive ?? .distantPast) }
                .map(\.sessionId)
            let order = Array((byName + bySaid.filter { results[$0]?.nameMatch == nil }).prefix(limit))

            if let expression {
                run("SELECT session, count(*) FROM messages WHERE messages MATCH ? GROUP BY session", [expression]) { row in
                    results[Self.text(row, 0)]?.matches = Int(sqlite3_column_int64(row, 1))
                }
                for id in order {
                    guard let best = results[id]?.best, let seq = seqs[id] else { continue }
                    results[id]?.context = context(around: best, seq: seq, session: id, expression: expression)
                }
            }
            return order.compactMap { results[$0] }
        }
    }

    /// The best message with a longer snippet, and the messages either side of it cut to a few lines.
    private func context(around best: SearchMessage, seq: Int, session: String, expression: String) -> [SearchMessage] {
        var messages: [SearchMessage] = []
        run("SELECT rowid, session, seq, role, at, body FROM messages WHERE session = ? AND seq BETWEEN ? AND ? ORDER BY seq",
            [session, seq - 1, seq + 1]) { row in
            messages.append(Self.message(row, text: Highlighted(plain: TranscriptParser.snippet(Self.text(row, 5), limit: 280))))
        }
        run("SELECT snippet(messages, 0, ?, ?, '…', 48) FROM messages WHERE messages MATCH ? AND rowid = ?",
            [String(Self.open), String(Self.close), expression, best.id]) { row in
            if let index = messages.firstIndex(where: { $0.id == best.id }) {
                messages[index].text = Highlighted(marked: Self.text(row, 0))
            }
        }
        return messages
    }

    /// The query's words as FTS5 terms, all of them required. The last word is still being typed, so it
    /// also matches as a prefix, with whole-word matches ranked first; the earlier ones match whole words
    /// (and their other forms: "signing" finds "signed" but not "significant"). Only letters and digits
    /// are kept, so nothing typed can be read as FTS5 syntax.
    static func expression(for query: String) -> String? {
        let words = query.lowercased().split { !($0.isLetter || $0.isNumber) }.map { "\"\($0)\"" }
        guard let last = words.last else { return nil }
        return (words.dropLast() + ["(\(last) OR \(last)*)"]).joined(separator: " AND ")
    }

    // MARK: SQLite

    /// Runs one statement, calling `row` for each result row. Callers hold the lock.
    private func run(_ sql: String, _ bindings: [any Sendable] = [], row: (OpaquePointer) -> Void = { _ in }) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case let number as Int: sqlite3_bind_int64(statement, index, Int64(number))
            case let number as Int64: sqlite3_bind_int64(statement, index, number)
            default: sqlite3_bind_null(statement, index)
            }
        }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }

    /// A row laid out as rowid, session, seq, role, at.
    private static func message(_ row: OpaquePointer, text: Highlighted) -> SearchMessage {
        SearchMessage(id: sqlite3_column_int64(row, 0),
                      role: SearchMessage.Role(rawValue: Int(sqlite3_column_int64(row, 3))) ?? .reply,
                      date: Date(timeIntervalSince1970: sqlite3_column_double(row, 4)), text: text)
    }
}
