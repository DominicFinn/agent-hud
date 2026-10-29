import HUDCore
import SwiftUI

/// Hero card, "Recap" tab: what the session is about, for telling apart sessions that share a terminal
/// name or a folder. Claude Code's title and the prompts on the left, where it is and what it has done on the right.
struct RecapView: View {
    let agent: AgentSnapshot
    /// Nil when the session has no terminal to show (ended, or the demo fleet).
    var onShowTerminal: (() -> Void)?
    static let factsWidth: CGFloat = 240

    var body: some View {
        let recap = agent.recap
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recap.headline ?? agent.name).font(Theme.ui(18, .semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    // The terminal's name is what the rail and the window list show, so keep it next to the real one.
                    if recap.headline != nil, recap.headline != agent.name {
                        Text(agent.name).font(Theme.ui(12)).foregroundStyle(Theme.mute).lineLimit(1)
                    }
                }
                note("Started with", recap.firstPrompt, lines: 3)
                if recap.lastPrompt != recap.firstPrompt { note("Latest prompt", recap.lastPrompt, lines: 3) }
                note("Last reply", recap.lastReply, lines: 4)
                if recap.firstPrompt == nil, recap.lastReply == nil {
                    Text("Nothing said yet").font(Theme.ui(13)).foregroundStyle(Theme.mute)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(Theme.divider).frame(width: 1)

            facts(recap).frame(width: Self.factsWidth, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func note(_ label: String, _ note: SessionNote?, lines: Int) -> some View {
        Group {
            if let note {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(label.uppercased()).font(Theme.ui(10, .semibold)).foregroundStyle(Theme.mute)
                        Text(Self.when(note.date)).font(Theme.ui(10)).foregroundStyle(Theme.mute)
                    }
                    Text(note.text).font(Theme.ui(13)).foregroundStyle(Theme.ink)
                        .lineLimit(lines).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func facts(_ recap: SessionRecap) -> some View {
        let edited = agent.files.filter { $0.kind != .read }
        return VStack(alignment: .leading, spacing: 6) {
            fact("Folder", Self.tildePath(agent.cwd), truncation: .head)
            fact("Branch", agent.gitBranch ?? "—")
            if let started = agent.startedAt {
                fact("Started", "\(Self.when(started)) · \((agent.endedAt ?? Date()).timeIntervalSince(started).elapsedText)")
            }
            fact("Prompts", "\(agent.turnIndex)")
            fact("Edited", edited.isEmpty ? "nothing yet"
                 : "\(edited.count) file\(edited.count == 1 ? "" : "s") · " + edited.prefix(3).map { ($0.path as NSString).lastPathComponent }.joined(separator: ", "))
            fact("Commands", "\(agent.toolCounts["Bash", default: 0])")
            if agent.errorCount > 0 { fact("Errors", "\(agent.errorCount)", color: Theme.error) }
            ForEach(recap.pullRequests) { link in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    label("PR")
                    if let url = URL(string: link.url) {
                        Link(Self.prName(link), destination: url).font(Theme.ui(12, .medium)).foregroundStyle(Theme.reading)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 4)
            if let onShowTerminal {
                ToolbarButton(title: "Show in Terminal", symbol: "terminal", action: onShowTerminal)
                    .help("Show in terminal (t)")
            }
        }
    }

    private func fact(_ name: String, _ value: String, truncation: Text.TruncationMode = .tail,
                      color: Color = Theme.ink) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            label(name)
            Text(value).font(Theme.ui(12)).foregroundStyle(color)
                .lineLimit(1).truncationMode(truncation)
                .help(value)
        }
    }

    private func label(_ name: String) -> some View {
        Text(name).font(Theme.ui(11)).foregroundStyle(Theme.mute).frame(width: 64, alignment: .leading)
    }

    /// "09:42" today, "Tue 09:42" within the week, "3 Oct" before that.
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.shortClockText }
        if now.timeIntervalSince(date) < 6 * 24 * 3600 {
            return date.formatted(.dateTime.weekday(.abbreviated)) + " " + date.shortClockText
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func tildePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// "locoaware-backend #2083", or the URL's last two parts when the line had no number.
    static func prName(_ link: PullRequestLink) -> String {
        let repo = link.repository.map { ($0 as NSString).lastPathComponent } ?? ""
        if let number = link.number { return repo.isEmpty ? "#\(number)" : "\(repo) #\(number)" }
        return link.url.split(separator: "/").suffix(2).joined(separator: "/")
    }
}
