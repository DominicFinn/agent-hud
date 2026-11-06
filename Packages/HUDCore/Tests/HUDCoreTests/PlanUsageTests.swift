import Foundation
import Testing
@testable import HUDCore

/// Shaped like Claude Code's `cachedUsageUtilization`, with made-up figures.
private let cached = #"""
{
  "numStartups": 12,
  "cachedUsageUtilization": {
    "fetchedAtMs": 1793983816635,
    "accountUuid": "00000000-0000-0000-0000-000000000000",
    "utilization": {
      "five_hour": null,
      "seven_day": { "utilization": 65, "resets_at": "2026-11-08T16:59:59.607274+00:00" },
      "limits": [
        { "kind": "weekly_all", "group": "weekly", "percent": 65, "severity": "normal",
          "resets_at": "2026-11-08T16:59:59.607274+00:00", "scope": null, "is_active": true },
        { "kind": "weekly_scoped", "group": "weekly", "percent": 0, "severity": "normal",
          "resets_at": "2026-11-08T17:00:00+00:00", "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
          "is_active": false },
        { "kind": "five_hour", "group": "session", "percent": 92.4, "severity": "warning",
          "resets_at": "2026-11-06T19:00:00+00:00", "scope": null, "is_active": true }
      ],
      "seven_day_breakdown": {
        "rows": [
          { "key": "chat", "display_name": "Chats", "percent": 3 },
          { "key": "claude_code", "display_name": "Claude Code", "percent": 85 },
          { "key": "cowork", "display_name": "Cowork", "percent": 12 },
          { "key": "other", "display_name": "Other", "percent": 0 }
        ]
      }
    }
  }
}
"""#

@Suite struct PlanUsageTests {
    @Test func readsTheLimitsClaudeCodeCached() throws {
        let plan = try #require(PlanUsage.parse(Data(cached.utf8)))
        #expect(plan.limits.map(\.title) == ["Weekly", "Weekly · Fable", "Session"])

        let weekly = plan.limits[0]
        #expect(weekly.percentUsed == 65)
        #expect(weekly.percentLeft == 35)
        let reset = try Date.ISO8601FormatStyle().parse("2026-11-08T16:59:59Z")
        #expect(abs((weekly.resetsAt ?? .distantPast).timeIntervalSince(reset) - 0.607) < 0.01)
        #expect(weekly.isActive)
        #expect(!plan.limits[1].isActive)
        #expect(plan.limits[2].percentUsed == 92)
        #expect(plan.limits[2].severity == "warning")
        #expect(plan.fetchedAt == Date(timeIntervalSince1970: 1_793_983_816.635))
    }

    @Test func theTightestLimitIsTheActiveOneWithLeastLeft() throws {
        let plan = try #require(PlanUsage.parse(Data(cached.utf8)))
        #expect(plan.tightest?.title == "Session")
    }

    @Test func splitsTheWeekByProductBiggestFirst() throws {
        let plan = try #require(PlanUsage.parse(Data(cached.utf8)))
        #expect(plan.breakdown == [.init(name: "Claude Code", percent: 85), .init(name: "Cowork", percent: 12), .init(name: "Chats", percent: 3)])
    }

    @Test func fallsBackToTheWindowObjectsWithoutALimitsList() throws {
        let older = #"{"cachedUsageUtilization":{"utilization":{"five_hour":{"utilization":20,"resets_at":"2026-11-06T19:00:00Z"},"seven_day":{"utilization":40.6,"resets_at":"2026-11-08T17:00:00Z"},"seven_day_opus":null}}}"#
        let plan = try #require(PlanUsage.parse(Data(older.utf8)))
        #expect(plan.limits.map(\.title) == ["Session", "Weekly"])
        #expect(plan.limits.map(\.percentUsed) == [20, 41])
        #expect(plan.breakdown.isEmpty)
        #expect(plan.fetchedAt == nil)
    }

    @Test func nothingCachedIsNoPlan() {
        #expect(PlanUsage.parse(Data(#"{"numStartups":3}"#.utf8)) == nil)
        #expect(PlanUsage.parse(Data(#"{"cachedUsageUtilization":{"utilization":{"five_hour":null,"seven_day":null}}}"#.utf8)) == nil)
        #expect(PlanUsage.parse(Data("not json".utf8)) == nil)
        #expect(PlanUsage.read(from: URL(fileURLWithPath: "/nonexistent/.claude.json")) == nil)
    }
}
