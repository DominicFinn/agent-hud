import Foundation
import HUDCore
import Observation

enum WidgetMood: Equatable { case empty, idle, busy, alert }

/// Polls the ingest engine and history index and publishes the results to SwiftUI.
@MainActor
@Observable
final class AgentMonitor {
    /// Live sessions. The widget, the Dock tile and every counter are about these.
    private(set) var agents: [AgentSnapshot] = []
    /// Sessions that ended in the last few days. Their cards stay in the rail, greyed out, but can't be opened.
    private(set) var recent: [AgentSnapshot] = []
    private(set) var stats = StatsSnapshot()
    var selectedId: String?
    /// When the ingest last produced new data, for the header's "last refreshed" line.
    private(set) var lastRefresh = Date()
    /// How far the first read of the live transcripts has got. Nil until the first poll comes back.
    private(set) var progress: LoadProgress?

    /// What live sessions have said. The demo swaps in one of its own.
    @ObservationIgnored private var searchIndex: SearchIndex
    @ObservationIgnored private let engine: IngestEngine
    private let history = HistoryIndex()
    private var liveTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?

    /// Long transcripts take seconds to read, so for a while after launch an empty list means "not yet", not "none".
    var isLoading: Bool { demo == nil && !(progress?.isComplete ?? false) }

    /// "Reading sessions…" until the session count is known, then "Reading 7 of 23 sessions…".
    var loadingText: String {
        guard let progress, progress.total > 0 else { return "Reading sessions…" }
        return "Reading \(progress.read) of \(progress.total) sessions…"
    }

    var loadingFraction: Double {
        guard let progress, progress.total > 0 else { return 0 }
        return Double(progress.read) / Double(progress.total)
    }

    /// Time spent on first reads per poll: long enough to make progress, short enough that sessions
    /// already read show up and the progress line moves.
    static let firstReadBudget: Duration = .milliseconds(300)

    var tokensPerMinute: Int { agents.reduce(0) { $0 + $1.tokensPerMinute } }
    var activeCount: Int { agents.filter(\.activity.isActive).count }
    var loopingAgents: [AgentSnapshot] { agents.filter(\.isLooping) }
    /// Live sessions only: an ended one keeps its card but can't be opened.
    var selected: AgentSnapshot? { agents.first { $0.id == selectedId } ?? focus ?? agents.first }

    /// The agent worth watching: a looping one first, otherwise whoever burns the most tokens.
    var focus: AgentSnapshot? {
        loopingAgents.first ?? agents.filter(\.activity.isActive).max { $0.tokensPerMinute < $1.tokensPerMinute }
    }

    /// "a few seconds ago" / "3 min ago" — deliberately vague, like the prototype's copy.
    var lastRefreshedText: String {
        let seconds = Date().timeIntervalSince(lastRefresh)
        if seconds < 45 { return "Last refreshed a few seconds ago" }
        return "Last refreshed \(Int(seconds / 60)) min ago"
    }

    var mood: WidgetMood {
        if agents.isEmpty { return .empty }
        if !loopingAgents.isEmpty { return .alert }
        return activeCount > 0 ? .busy : .idle
    }

    /// Non-nil when showing the prototype's sample fleet instead of real sessions (`--demo busy|idle|alert`).
    var demo: DemoData.Scenario?

    init() {
        let index = SearchIndex()
        searchIndex = index
        engine = IngestEngine(search: index)
    }

    func start() {
        if let demo {
            agents = DemoData.agents(demo)
            recent = DemoData.recent()
            stats = DemoData.stats()
            searchIndex = DemoData.search(agents)
            return
        }
        guard liveTask == nil else { return }
        liveTask = Task { [weak self, engine] in
            while !Task.isCancelled {
                let snapshots = await engine.poll(budget: AgentMonitor.firstReadBudget)
                let progress = await engine.progress
                let live = snapshots.filter { !$0.isEnded }, ended = snapshots.filter(\.isEnded)
                if self?.agents != live { self?.agents = live; self?.lastRefresh = Date() }
                if self?.recent != ended { self?.recent = ended }
                if self?.progress != progress { self?.progress = progress }
                // While transcripts are still being read for the first time, go straight back for more.
                try? await Task.sleep(for: progress.isComplete ? .seconds(1) : .milliseconds(20))
            }
        }
        statsTask = Task { [weak self, history] in
            while !Task.isCancelled {
                let snapshot = await history.refresh()
                if self?.stats != snapshot { self?.stats = snapshot }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// The header's Refresh button: re-index history now instead of waiting for the next pass.
    func refreshNow() {
        lastRefresh = Date()
        guard demo == nil else { return }
        Task { [history] in
            let snapshot = await history.refresh()
            if self.stats != snapshot { self.stats = snapshot }
        }
    }

    /// Live sessions matching `query`. Off the main thread, since the engine may be holding the index
    /// while it reads a long transcript.
    func search(_ query: String) async -> [SearchResult] {
        let index = searchIndex
        return await Task.detached { index.search(query) }.value
    }

    /// The same, straight away, for `--snapshot`, which has to have the results before it draws.
    func searchNow(_ query: String) -> [SearchResult] { searchIndex.search(query) }

    func stop() {
        liveTask?.cancel()
        statsTask?.cancel()
        liveTask = nil
        statsTask = nil
    }
}
