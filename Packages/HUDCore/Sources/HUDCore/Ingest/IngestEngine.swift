import Foundation

/// Owns the tailers and per-session state. All file IO happens on this actor.
public actor IngestEngine {
    private struct Tracked {
        var tailer: TranscriptTailer
        var subagents: SubagentTracker
        var state = SessionState()
        var diskChanges: [String: DirectoryScanner.Hit] = [:]
        var lastScan = Date.distantPast
        /// Last known registry entry; kept so an ended session can still be described.
        var entry: RegistryEntry?
        var endedAt: Date?
        /// False until the transcript has been read once. The first read is the whole file, which for
        /// a long session is hundreds of megabytes, so first reads are spread over several polls.
        var hasRead = false

        init(url: URL) {
            tailer = TranscriptTailer(url: url)
            subagents = SubagentTracker(sessionTranscript: url)
        }
    }

    /// Walking a repo is cheap but not free; changes on disk do not need sub-second latency.
    static let scanInterval: TimeInterval = 10
    /// Finished sessions stay in the dashboard this long, newest first, up to `historyLimit`.
    public static let historyWindow: TimeInterval = 3 * 24 * 3600
    public static let historyLimit = 8

    private let registry: SessionRegistry
    private let projectsDirectory: URL
    /// What live sessions have said, for the search bar. Ended sessions are dropped from it on every poll.
    public nonisolated let search: SearchIndex
    private var tracked: [String: Tracked] = [:]
    /// Transcripts of sessions that ended before the app launched, loaded one per poll so startup stays snappy.
    private var backlog: [URL]?
    /// How many live sessions have been read, after the last poll.
    public private(set) var progress = LoadProgress(read: 0, total: 0)

    public init(claudeHome: URL = SessionRegistry.defaultClaudeHome, search: SearchIndex = SearchIndex()) {
        registry = SessionRegistry(claudeHome: claudeHome)
        projectsDirectory = claudeHome.appendingPathComponent("projects")
        self.search = search
    }

    /// Reads whatever was appended since the last call. Returns live agents first, then recently ended sessions.
    ///
    /// With a `budget`, transcripts not read yet are read only until it runs out (at least one per poll),
    /// and sessions still unread are left out of the result; `progress` says how many are left.
    /// Without one, everything is read before returning.
    public func poll(now: Date = Date(), budget: Duration? = nil) -> [AgentSnapshot] {
        let clock = ContinuousClock(), started = clock.now
        let entries = registry.liveEntries()
        let liveIds = Set(entries.map(\.sessionId))

        for entry in entries {
            // A resumed session comes back to life. What it said was dropped when it ended, so it is read again from the start.
            if tracked[entry.sessionId]?.endedAt != nil { tracked[entry.sessionId] = nil }
            if tracked[entry.sessionId] == nil, let url = transcriptURL(sessionId: entry.sessionId) { tracked[entry.sessionId] = Tracked(url: url) }
            tracked[entry.sessionId]?.entry = entry
        }
        for id in tracked.keys where !liveIds.contains(id) && tracked[id]?.endedAt == nil {
            // Read before writing: an optional-chained assignment holds a modify access on
            // `tracked` while its right-hand side runs, so reading it there is an exclusivity trap.
            let lastEvent = tracked[id]?.state.lastEventAt
            tracked[id]?.endedAt = lastEvent ?? now
        }
        loadNextFromBacklog(excluding: liveIds, now: now)
        tracked = tracked.filter { $0.value.endedAt.map { now.timeIntervalSince($0) < Self.historyWindow } ?? true }

        var live: [(snapshot: AgentSnapshot, busy: Bool, recency: Date)] = [], ended: [AgentSnapshot] = []
        var firstReads = 0
        for id in Self.readOrder(tracked) {
            guard var session = tracked[id] else { continue }
            let isLive = session.endedAt == nil
            if !session.hasRead, let budget, firstReads > 0, clock.now - started > budget { continue }
            if !session.hasRead { firstReads += 1 }
            var subagents: [SubagentInfo]?
            if isLive || session.lastScan == .distantPast || !session.hasRead {
                var said: [SearchIndex.Message] = []
                for event in session.tailer.poll() {
                    session.state.apply(event)
                    if isLive, let message = SearchIndex.Message(event) { said.append(message) }
                }
                search.add(said, to: id)
                if isLive { subagents = session.subagents.poll() }
                session.hasRead = true
            }
            if !isLive {
                // Nothing behind an ended session's card can be opened, so the engine stops holding what it said.
                session.state.forget()
                session.diskChanges = [:]
            }
            let busy = session.entry?.isBusy ?? false
            // Idle sessions change nothing, so they are only scanned once. Ended ones show no files, so they never are.
            // The registry's start time resets when a session is resumed; the transcript remembers the real one.
            if let started = [session.entry?.startedAt, session.state.firstEventAt].compactMap({ $0 }).min(),
               isLive, now.timeIntervalSince(session.lastScan) > Self.scanInterval, busy || session.lastScan == .distantPast,
               let root = session.entry?.cwd ?? session.state.cwd {
                session.diskChanges = DirectoryScanner.changedFiles(in: root, since: started)
                session.lastScan = now
            }
            var snapshot = Self.snapshot(id: id, session: &session, now: now)
            if isLive { snapshot.subagents = subagents ?? session.subagents.poll() }
            tracked[id] = session
            if isLive {
                search.describe(id, as: SearchIndex.Names(
                    folder: Self.tildePath(snapshot.cwd), name: snapshot.name, title: snapshot.recap.headline,
                    branch: snapshot.gitBranch, lastActive: session.state.lastEventAt))
                // A working agent ranks by the prompt that started its turn, so it does not jump
                // around mid-turn; an idle one by when it last did anything.
                let recency = busy ? session.state.promptTicks.last ?? session.state.lastEventAt : session.state.lastEventAt
                live.append((snapshot, busy, recency ?? snapshot.startedAt ?? .distantPast))
            }
            // A transcript that never got an answer (opened and quit) is noise in the history.
            else if snapshot.usage.total > 0 { ended.append(snapshot) }
        }
        let liveSessions = tracked.filter { $0.value.endedAt == nil }
        progress = LoadProgress(read: liveSessions.values.filter(\.hasRead).count, total: liveSessions.count)
        // The search index is only for finding live agents, so a session that has ended leaves it now.
        search.retain(only: Set(liveSessions.keys))
        // Working agents on top, then the rest by recency; history stays below, newest first.
        live.sort { a, b in a.busy != b.busy ? a.busy : a.recency > b.recency }
        ended.sort { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
        return live.map(\.snapshot) + ended.prefix(Self.historyLimit)
    }

    /// Live sessions first, busy ones before idle, newest first, so the top of the list fills in first.
    private static func readOrder(_ tracked: [String: Tracked]) -> [String] {
        tracked.sorted { a, b in
            let (x, y) = (a.value, b.value)
            if (x.endedAt == nil) != (y.endedAt == nil) { return x.endedAt == nil }
            if (x.entry?.isBusy ?? false) != (y.entry?.isBusy ?? false) { return x.entry?.isBusy ?? false }
            return (x.entry?.startedAt ?? .distantPast) > (y.entry?.startedAt ?? .distantPast)
        }.map(\.key)
    }

    /// The project slug is a lossy encoding of the cwd, so locate the file by session id instead.
    private func transcriptURL(sessionId: String) -> URL? {
        let projects = (try? FileManager.default.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil)) ?? []
        return projects
            .map { $0.appendingPathComponent("\(sessionId).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Sessions that finished before launch: the newest transcripts touched inside the history window.
    private func loadNextFromBacklog(excluding liveIds: Set<String>, now: Date) {
        if backlog == nil {
            let projects = (try? FileManager.default.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil)) ?? []
            let recent = projects.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url -> (URL, Date)? in
                    guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                          now.timeIntervalSince(modified) < Self.historyWindow else { return nil }
                    return (url, modified)
                }
                .sorted { $0.1 > $1.1 }
            backlog = recent.prefix(Self.historyLimit + liveIds.count).map(\.0)
        }
        guard let url = backlog?.first else { return }
        backlog?.removeFirst()
        let id = url.deletingPathExtension().lastPathComponent
        guard tracked[id] == nil, !liveIds.contains(id) else { return }
        var session = Tracked(url: url)
        session.endedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
        tracked[id] = session
    }

    private static func snapshot(id: String, session: inout Tracked, now: Date) -> AgentSnapshot {
        let entry = session.entry
        let isLive = session.endedAt == nil
        let busy = isLive && entry?.isBusy == true
        let heartbeat = session.state.heartbeat(now: now)
        // Output tokens land when a message completes, so the trailing minute lags; an idle agent burns nothing.
        let tokensPerMinute = busy ? session.state.tokensPerMinute(now: now) : 0
        let eta = busy ? session.state.etaMinutes(now: now) : nil
        let state = session.state
        let cwd = entry?.cwd ?? state.cwd ?? ""
        let repo = (cwd as NSString).lastPathComponent

        // The registry is the authority on busy/idle; the transcript says what "busy" means.
        var activity = state.activity
        if !busy {
            activity = isLive && state.activity == .waiting ? .waiting : .idle
        } else if activity == .idle || activity == .waiting {
            activity = .thinking
        }

        var snapshot = AgentSnapshot(
            sessionId: id, pid: entry?.pid ?? 0,
            name: entry?.name ?? state.title ?? repo, repo: repo.isEmpty ? "session" : repo, cwd: cwd,
            gitBranch: state.gitBranch, model: state.model,
            activity: activity, activitySince: state.activitySince,
            usage: state.usage, contextTokens: state.contextTokens,
            tokensPerMinute: tokensPerMinute, heartbeat: heartbeat,
            toolCounts: state.toolCounts, errorCount: state.errorCount,
            startedAt: entry?.startedAt ?? state.firstEventAt, ticker: state.ticker,
            contextMax: contextWindow(model: state.model, peak: state.peakContextTokens),
            turnIndex: state.turnIndex, steps: state.steps,
            lanes: lanes(state, busy: busy, now: now),
            promptTicks: state.promptTicks.filter { $0 > now.addingTimeInterval(-SessionState.laneWindow) },
            plan: state.plan, loops: state.loops, brain: state.brain(),
            contextSplit: state.contextSplit, etaMinutes: eta
        )
        snapshot.files = mergeFiles(transcript: state.fileChanges, disk: session.diskChanges)
        snapshot.endedAt = session.endedAt
        snapshot.recap = state.recap
        if !isLive { forget(&snapshot) }
        return snapshot
    }

    /// An ended session can't be opened, so its card gets the folder and the numbers and nothing that was
    /// said or worked on: no prompts or replies, titles, steps, plan, file paths or errors. The engine has
    /// already dropped these from the session's state; this makes sure none reach the UI either.
    static func forget(_ snapshot: inout AgentSnapshot) {
        snapshot.name = snapshot.repo
        snapshot.recap = SessionRecap()
        snapshot.ticker = []
        snapshot.steps = []
        snapshot.plan = []
        snapshot.loops = []
        snapshot.brain = []
        snapshot.files = []
        snapshot.subagents = []
    }

    static func tildePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Claude Code runs the Claude 5 family on a 1M window, and older models when opted in with `[1m]`.
    static func contextWindow(model: String?, peak: Int) -> Int {
        let name = model ?? ""
        // Sessions that have ever held more than 200k tokens must be on a 1M window.
        if peak > 200_000 || name.hasSuffix("[1m]") { return 1_000_000 }
        // "claude-opus-5-5", "claude-sonnet-5", "claude-fable-5-1": the family's major version follows the name.
        let parts = name.split(separator: "-")
        if parts.count >= 3, parts[0] == "claude", let major = Int(parts[2]), major >= 5 { return 1_000_000 }
        return 200_000
    }

    /// The transcript cannot tell an interrupted turn from a running one; the registry can. Once it
    /// says the agent is not working, its last segment stops at the last thing it wrote.
    static func lanes(_ state: SessionState, busy: Bool, now: Date) -> [LaneSegment] {
        var lanes = state.lanes(since: now.addingTimeInterval(-SessionState.laneWindow))
        if !busy, let last = lanes.indices.last, lanes[last].end == nil, lanes[last].kind.isActive {
            lanes[last].end = state.lastEventAt ?? lanes[last].start
        }
        return lanes
    }

    /// The transcript knows intent (read / edit / write, line counts); the disk knows what really changed.
    static func mergeFiles(transcript: [String: FileChange], disk: [String: DirectoryScanner.Hit], limit: Int = 80) -> [FileChange] {
        var merged = transcript
        for (path, hit) in disk {
            if var known = merged[path] {
                // Read by the agent, yet modified on disk: something other than Edit/Write changed it.
                if known.kind == .read { known.kind = .edited; known.viaShell = true }
                known.lastTouched = max(known.lastTouched, hit.modified)
                merged[path] = known
            } else {
                var change = FileChange(path: path, kind: hit.created ? .created : .edited, lastTouched: hit.modified)
                change.viaShell = true
                merged[path] = change
            }
        }
        return Array(merged.values.sorted { $0.lastTouched > $1.lastTouched }.prefix(limit))
    }
}
