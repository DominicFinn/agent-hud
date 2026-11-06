import Foundation

/// How much of your Claude plan you have used, as Claude Code last fetched it. Claude Code keeps a copy
/// under `cachedUsageUtilization` in `~/.claude.json`; this reads that copy and nothing else from the
/// file, so the HUD shows the real figures without a network call of its own.
public struct PlanUsage: Sendable, Equatable {
    /// One usage limit: the 5-hour session one, the weekly one, a per-model weekly one.
    public struct Limit: Sendable, Equatable, Identifiable {
        public var id: String { "\(kind)·\(title)" }
        /// Claude Code's name for it: "weekly_all", "weekly_scoped", "five_hour"…
        public var kind: String
        /// "Session" (the 5-hour window), "Weekly", "Weekly · Fable".
        public var title: String
        public var percentUsed: Int
        public var resetsAt: Date?
        /// "normal" until the limit gets close.
        public var severity: String
        /// False for a limit that doesn't currently apply, like a per-model one for a model you aren't using.
        public var isActive: Bool

        public init(kind: String, title: String, percentUsed: Int, resetsAt: Date?, severity: String = "normal", isActive: Bool = true) {
            self.kind = kind
            self.title = title
            self.percentUsed = percentUsed
            self.resetsAt = resetsAt
            self.severity = severity
            self.isActive = isActive
        }

        public var percentLeft: Int { max(0, 100 - percentUsed) }
    }

    /// A product's share of this week's usage: Claude Code, Chats, Cowork.
    public struct Share: Sendable, Equatable {
        public var name: String
        public var percent: Int

        public init(name: String, percent: Int) {
            self.name = name
            self.percent = percent
        }
    }

    public var limits: [Limit]
    /// Products with any share of the week, biggest first.
    public var breakdown: [Share]
    /// When Claude Code fetched these figures.
    public var fetchedAt: Date?

    public init(limits: [Limit], breakdown: [Share] = [], fetchedAt: Date? = nil) {
        self.limits = limits
        self.breakdown = breakdown
        self.fetchedAt = fetchedAt
    }

    /// The limit you'll run into first: the active one with the least left.
    public var tightest: Limit? { limits.filter(\.isActive).max { $0.percentUsed < $1.percentUsed } }

    public static func read(from url: URL) -> PlanUsage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> PlanUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any]
        else { return nil }

        var limits = (utilization["limits"] as? [[String: Any]] ?? []).compactMap(limit)
        // Older copies only have the per-window objects.
        if limits.isEmpty {
            let windows = [("five_hour", "Session"), ("seven_day", "Weekly"),
                           ("seven_day_opus", "Weekly · Opus"), ("seven_day_sonnet", "Weekly · Sonnet")]
            limits = windows.compactMap { key, title in
                guard let window = utilization[key] as? [String: Any], let percent = number(window["utilization"]) else { return nil }
                return Limit(kind: key, title: title, percentUsed: percent, resetsAt: date(window["resets_at"]))
            }
        }
        guard !limits.isEmpty else { return nil }

        let rows = (utilization["seven_day_breakdown"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
        let breakdown = rows.compactMap { row -> Share? in
            guard let name = row["display_name"] as? String, let percent = number(row["percent"]), percent > 0 else { return nil }
            return Share(name: name, percent: percent)
        }
        let fetched = number(cached["fetchedAtMs"]).map { Date(timeIntervalSince1970: Double($0) / 1000) }
        return PlanUsage(limits: limits, breakdown: breakdown.sorted { $0.percent > $1.percent }, fetchedAt: fetched)
    }

    private static func limit(_ entry: [String: Any]) -> Limit? {
        guard let kind = entry["kind"] as? String, let percent = number(entry["percent"]) else { return nil }
        let scope = entry["scope"] as? [String: Any]
        let scoped = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
            ?? ((scope?["surface"] as? [String: Any])?["display_name"] as? String)
        let group = entry["group"] as? String ?? kind
        var title = switch group {
        case "weekly": "Weekly"
        case "session", "five_hour": "Session"
        default: group.replacingOccurrences(of: "_", with: " ").capitalized
        }
        if let scoped { title += " · \(scoped)" }
        return Limit(kind: kind, title: title, percentUsed: percent, resetsAt: date(entry["resets_at"]),
                     severity: entry["severity"] as? String ?? "normal", isActive: entry["is_active"] as? Bool ?? true)
    }

    private static func number(_ value: Any?) -> Int? { (value as? NSNumber).map { Int($0.doubleValue.rounded()) } }

    private static func date(_ value: Any?) -> Date? { (value as? String).flatMap(TranscriptParser.parseDate) }
}
