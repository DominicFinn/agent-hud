import Foundation
import Testing
@testable import HUDCore

/// A throwaway ~/.claude with `count` live sessions, all registered to this test process so they read as running.
private func claudeHome(sessions count: Int) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("hud-load-\(UUID().uuidString)")
    let sessions = home.appendingPathComponent("sessions"), project = home.appendingPathComponent("projects/-x-repo")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    for index in 0..<count {
        let id = "session-\(index)"
        let entry = #"{"pid":\#(getpid()),"sessionId":"\#(id)","cwd":"/x/repo","startedAt":\#(1_792_000_000_000 + index),"status":"idle"}"#
        try Data(entry.utf8).write(to: sessions.appendingPathComponent("\(id).json"))
        let prompt = #"{"type":"user","timestamp":"2026-10-28T09:00:00.000Z","message":{"role":"user","content":"task \#(index)"}}"#
        try Data((prompt + "\n").utf8).write(to: project.appendingPathComponent("\(id).jsonl"))
    }
    return home
}

@Suite struct LoadingTests {
    @Test func aBudgetSpreadsFirstReadsOverPolls() async throws {
        let home = try claudeHome(sessions: 3)
        defer { try? FileManager.default.removeItem(at: home) }
        let engine = IngestEngine(claudeHome: home)

        // A zero budget still reads one transcript per poll, so loading always moves forward.
        var shown = await engine.poll(budget: .zero)
        #expect(shown.count == 1)
        #expect(await engine.progress == LoadProgress(read: 1, total: 3))

        shown = await engine.poll(budget: .zero)
        #expect(shown.count == 2)
        #expect(await !engine.progress.isComplete)

        shown = await engine.poll(budget: .zero)
        #expect(shown.count == 3)
        #expect(await engine.progress == LoadProgress(read: 3, total: 3))
        #expect(await engine.progress.isComplete)
    }

    @Test func newestSessionsAreReadFirst() async throws {
        let home = try claudeHome(sessions: 3)
        defer { try? FileManager.default.removeItem(at: home) }
        let engine = IngestEngine(claudeHome: home)

        let first = await engine.poll(budget: .zero)
        #expect(first.map(\.sessionId) == ["session-2"])
        #expect(first.first?.recap.firstPrompt?.text == "task 2")
    }

    @Test func withoutABudgetEverythingIsReadAtOnce() async throws {
        let home = try claudeHome(sessions: 3)
        defer { try? FileManager.default.removeItem(at: home) }
        let engine = IngestEngine(claudeHome: home)

        #expect(await engine.poll().count == 3)
        #expect(await engine.progress == LoadProgress(read: 3, total: 3))
    }

    @Test func noSessionsIsLoadedNotLoading() async throws {
        let home = try claudeHome(sessions: 0)
        defer { try? FileManager.default.removeItem(at: home) }
        let engine = IngestEngine(claudeHome: home)

        #expect(await engine.poll(budget: .zero).isEmpty)
        #expect(await engine.progress.isComplete)
    }

    @Test func aGenerousBudgetReadsEverythingInOnePoll() async throws {
        let home = try claudeHome(sessions: 4)
        defer { try? FileManager.default.removeItem(at: home) }
        let engine = IngestEngine(claudeHome: home)

        #expect(await engine.poll(budget: .seconds(30)).count == 4)
        #expect(await engine.progress.isComplete)
    }
}
