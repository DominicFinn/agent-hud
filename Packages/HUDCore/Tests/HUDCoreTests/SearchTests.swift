import Foundation
import Testing
@testable import HUDCore

private let at = Date(timeIntervalSince1970: 1_792_000_000)

private func said(_ text: String, _ role: SearchMessage.Role = .prompt) -> SearchIndex.Message {
    SearchIndex.Message(role: role, date: at, text: text)
}

private func event(_ json: String) -> TranscriptEvent? { TranscriptParser.parse(line: Data(json.utf8)) }

private func marked(_ text: Highlighted?) -> String {
    (text?.spans ?? []).map { $0.isMatch ? "[\($0.text)]" : $0.text }.joined()
}

@Suite struct SearchIndexTests {
    @Test func findsPromptsAndRepliesByTheStartOfAWord() throws {
        let index = SearchIndex()
        index.add([said("Can we add a search bar to the header?"), said("I'll build it on FTS5.", .reply)], to: "a")

        let result = try #require(index.search("sear").first)
        #expect(result.sessionId == "a")
        #expect(result.best?.role == .prompt)
        #expect(marked(result.best?.text) == "Can we add a [search] bar to the header?")
        #expect(index.search("fts5").first?.best?.role == .reply)
    }

    @Test func matchesOtherFormsOfAWord() {
        let index = SearchIndex()
        index.add([said("The indexer reads each transcript once.")], to: "a")
        #expect(index.search("transcripts").count == 1)
        #expect(index.search("reading").count == 1)
    }

    @Test func onlyTheLastWordMatchesAsAPrefix() throws {
        let index = SearchIndex()
        index.add([said("a significant change to the build")], to: "prefix")
        index.add([said("the release is signed")], to: "word")

        #expect(index.search("signing").map(\.sessionId) == ["word", "prefix"])
        #expect(index.search("signing release").map(\.sessionId) == ["word"])
        #expect(index.search("release sig").map(\.sessionId) == ["word"])
        #expect(index.search("sig change").isEmpty)
    }

    @Test func everyWordHasToMatch() {
        let index = SearchIndex()
        index.add([said("fix the login retry")], to: "a")
        index.add([said("fix the deploy script")], to: "b")
        #expect(index.search("fix login").map(\.sessionId) == ["a"])
    }

    @Test func givesOneResultPerSessionWithItsCount() throws {
        let index = SearchIndex()
        index.add([said("deploy to staging"), said("the deploy failed", .reply), said("deploy again")], to: "a")
        index.add([said("we should deploy on Friday")], to: "b")

        let results = index.search("deploy")
        #expect(Set(results.map(\.sessionId)) == ["a", "b"])
        #expect(results.first { $0.sessionId == "a" }?.matches == 3)
        #expect(results.first { $0.sessionId == "b" }?.matches == 1)
    }

    @Test func aMatchingFolderComesBeforeWhatWasSaid() throws {
        let index = SearchIndex()
        index.add([said("look at the deploy tools")], to: "talk")
        index.describe("talk", as: .init(folder: "~/git/web", name: "web"))
        index.describe("folder", as: .init(folder: "~/git/deploy-tools", name: "deploy-tools"))

        let results = index.search("deploy")
        #expect(results.map(\.sessionId) == ["folder", "talk"])
        #expect(results[0].nameMatch?.field == "folder")
        #expect(marked(results[0].nameMatch?.text) == "~/git/[deploy]-tools")
        #expect(results[0].best == nil)
        #expect(results[1].nameMatch == nil)
    }

    @Test func nameWordsCanMatchDifferentFields() {
        let index = SearchIndex()
        index.describe("a", as: .init(folder: "~/git/agent-hud", name: "agent-hud", branch: "search-bar"))
        #expect(index.search("hud search").map(\.sessionId) == ["a"])
        #expect(index.search("hud nope").isEmpty)
    }

    @Test func showsTheMessagesEitherSideOfTheBestMatch() throws {
        let index = SearchIndex()
        index.add([said("first"), said("where is the retry logic?"), said("It's in Uploader.swift", .reply), said("later")], to: "a")

        let result = try #require(index.search("retry").first)
        #expect(result.context.map(\.text.plain) == ["first", "where is the retry logic?", "It's in Uploader.swift"])
        #expect(result.context[1].text.hasMatch)
        #expect(!result.context[0].text.hasMatch)
    }

    @Test func whatPeopleTypeIsNeverReadAsQuerySyntax() {
        let index = SearchIndex()
        index.add([said("key:value AND more (NEAR the end) - done*")], to: "a")
        for query in [#"""#, "AND", "NEAR(", "*", "-", "key:", #""unbalanced"#, "a OR", "^"] {
            _ = index.search(query)
        }
        #expect(index.search("key:").count == 1)
        #expect(index.search("near(").count == 1)
        #expect(index.search(#""value"#).count == 1)
    }

    @Test func retainDropsEverySessionThatIsNotLive() {
        let index = SearchIndex()
        index.add([said("alpha one"), said("alpha two")], to: "live")
        index.add([said("bravo secret")], to: "ended")
        index.describe("ended", as: .init(folder: "~/git/bravo", name: "bravo"))

        index.retain(only: ["live"])
        #expect(index.sessions == ["live"])
        #expect(index.messageCount == 2)
        #expect(index.search("bravo").isEmpty)
        #expect(index.search("secret").isEmpty)
        #expect(index.search("alpha").count == 1)
    }

    @Test func keepsOnlyWhatWasSaid() throws {
        let typed = try #require(event(#"{"type":"user","timestamp":"2026-10-28T09:00:00.000Z","message":{"role":"user","content":"fix the login retry"}}"#))
        #expect(SearchIndex.Message(typed)?.role == .prompt)

        let reply = try #require(event(#"{"type":"assistant","timestamp":"2026-10-28T09:01:00.000Z","message":{"id":"m","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Done."}]}}"#))
        #expect(SearchIndex.Message(reply)?.text == "Done.")

        let unsaid = [
            #"{"type":"assistant","message":{"id":"m","content":[{"type":"thinking","thinking":"private reasoning"}]}}"#,
            #"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"file list"}]}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"skill instructions"}}"#,
            #"{"type":"user","message":{"role":"user","content":"Base directory for this skill: /x"}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"id":"m","content":[{"type":"text","text":"subagent reply"}]}}"#,
            #"{"type":"ai-title","aiTitle":"A title"}"#,
        ]
        for line in unsaid { #expect(SearchIndex.Message(try #require(event(line))) == nil, "\(line)") }
    }

    @Test func highlightsEveryWordInAName() {
        let text = Highlighted("~/git/Agent-HUD", matching: ["hud", "agent"])
        #expect(marked(text) == "~/git/[Agent]-[HUD]")
        #expect(Highlighted("nothing here", matching: ["zzz"]).spans == [.init(text: "nothing here", isMatch: false)])
    }
}

/// A throwaway ~/.claude holding one session registered to this test process, so it reads as running.
private struct Home {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hud-search-\(UUID().uuidString)")
    var registryFile: URL { url.appendingPathComponent("sessions/s1.json") }

    init(lines: [String]) throws {
        let project = url.appendingPathComponent("projects/-x-repo")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: project.appendingPathComponent("s1.jsonl"))
        try register()
    }

    func register() throws {
        let entry = #"{"pid":\#(getpid()),"sessionId":"s1","cwd":"/x/repo","startedAt":1792000000000,"status":"idle"}"#
        try Data(entry.utf8).write(to: registryFile)
    }

    func end() throws { try FileManager.default.removeItem(at: registryFile) }
}

@Suite struct SearchLifecycleTests {
    /// A minute old, so the ended card is still inside the history window.
    static var lines: [String] {
        let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date().addingTimeInterval(-60))
        return [
            #"{"type":"user","cwd":"/x/repo","timestamp":"\#(stamp)","message":{"role":"user","content":"rotate the signing key"}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp)","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":5},"content":[{"type":"text","text":"The key is rotated."}]}}"#,
        ]
    }

    @Test func aSessionLeavesTheIndexWhenItEnds() async throws {
        let home = try Home(lines: Self.lines)
        defer { try? FileManager.default.removeItem(at: home.url) }
        let engine = IngestEngine(claudeHome: home.url)

        _ = await engine.poll()
        #expect(engine.search.search("signing").map(\.sessionId) == ["s1"])
        #expect(engine.search.search("repo").first?.nameMatch?.field == "folder")

        try home.end()
        let after = await engine.poll()
        #expect(engine.search.sessions.isEmpty)
        #expect(engine.search.messageCount == 0)
        #expect(engine.search.search("signing").isEmpty)

        // Its card is still there, but carries nothing that was said.
        let card = try #require(after.first { $0.sessionId == "s1" })
        #expect(card.isEnded)
        #expect(card.recap == SessionRecap())
        #expect(card.ticker.isEmpty)
        #expect(card.steps.isEmpty)
        #expect(card.usage.output == 5)
    }

    @Test func forgettingKeepsOnlyTheNumbers() throws {
        var state = SessionState()
        for line in Self.lines { state.apply(try #require(TranscriptParser.parse(line: Data(line.utf8)))) }
        #expect(state.firstPrompt != nil)

        state.forget()
        #expect(state.recap == SessionRecap())
        #expect(state.ticker.isEmpty)
        #expect(state.steps.isEmpty)
        #expect(state.brain().isEmpty)
        #expect(state.usage.output == 5)
        #expect(state.cwd == "/x/repo")
    }

    @Test func aResumedSessionIsReadAgainOnce() async throws {
        let home = try Home(lines: Self.lines)
        defer { try? FileManager.default.removeItem(at: home.url) }
        let engine = IngestEngine(claudeHome: home.url)

        _ = await engine.poll()
        try home.end()
        _ = await engine.poll()
        try home.register()
        let resumed = await engine.poll()

        #expect(resumed.first?.isEnded == false)
        #expect(resumed.first?.recap.firstPrompt?.text == "rotate the signing key")
        #expect(engine.search.search("signing").first?.matches == 1)
        #expect(engine.search.messageCount == 2)
    }
}
