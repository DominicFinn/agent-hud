import HUDCore
import SwiftUI

/// Drops down under the header while there is a query: matching live sessions on the left, what was said
/// around the best match on the right. Styled like the flow graph's popover: ink border, hard 2px shadow.
struct SearchPanel: View {
    let query: String
    let results: [SearchResult]
    let agents: [String: AgentSnapshot]
    @Binding var selection: String?
    /// The thought stream's Blur thoughts: what was said is blurred, names and folders are not.
    let blur: Bool
    var onChoose: (String) -> Void
    @Environment(\.staticRendering) private var staticRendering
    static let listWidth: CGFloat = 340

    private var selected: SearchResult? { results.first { $0.id == selection } ?? results.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            if results.isEmpty {
                empty
            } else {
                HStack(spacing: 0) {
                    list.frame(width: Self.listWidth)
                    Rectangle().fill(Theme.divider).frame(width: 1)
                    preview.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.card))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.ink, lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink).offset(x: 2, y: 2))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(results.isEmpty ? "No matches" : "\(results.count) live session\(results.count == 1 ? "" : "s")")
                .font(Theme.ui(13, .semibold)).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            Text("↑ ↓ move · ↩ open · esc close").font(Theme.ui(11)).foregroundStyle(Theme.mute)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("Nothing in a live session matches “\(query)”").font(Theme.ui(13)).foregroundStyle(Theme.ink)
            Text("Search covers the sessions running now. When a session ends, what it said is dropped from the index.")
                .font(Theme.ui(12)).foregroundStyle(Theme.mute)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Results

    /// Live, a scroll view that follows the selection. ImageRenderer cannot draw a ScrollView, so
    /// `--snapshot` gets the rows that fit.
    @ViewBuilder
    private var list: some View {
        if staticRendering {
            VStack(spacing: 0) {
                ForEach(results.prefix(5)) { row($0) }
                Spacer(minLength: 0)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { row($0).id($0.id) }
                    }
                }
                .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
    }

    private func row(_ result: SearchResult) -> some View {
        let agent = agents[result.sessionId]
        let isSelected = result.id == selected?.id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.color(for: agent?.activity ?? .idle)).frame(width: 8, height: 8)
                Text(agent?.repo ?? "session").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                if let title = agent?.recap.headline {
                    Text(title).font(Theme.ui(12)).foregroundStyle(Theme.mute).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if let best = result.best {
                text(best.text, size: 12, said: true).lineLimit(2)
            } else if let match = result.nameMatch {
                HStack(spacing: 6) {
                    Text(match.field).font(Theme.ui(12)).foregroundStyle(Theme.mute)
                    text(match.text, size: 12, said: false).lineLimit(1).truncationMode(.head)
                }
            }
            Text(footer(result)).font(Theme.ui(11)).foregroundStyle(Theme.mute).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.cardSelected : Theme.card)
        .overlay(alignment: .leading) { if isSelected { Rectangle().fill(Theme.ink).frame(width: 2) } }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { if $0 { selection = result.id } }
        .onTapGesture { onChoose(result.id) }
    }

    /// "You · 09:42 · 3 matches · folder matches"
    private func footer(_ result: SearchResult) -> String {
        var parts: [String] = []
        if let best = result.best { parts.append("\(Self.who(best.role)) · \(RecapView.when(best.date))") }
        if result.matches > 1 { parts.append("\(result.matches) matches") }
        if let match = result.nameMatch { parts.append(result.best == nil ? "matched its \(match.field)" : "\(match.field) matches") }
        return parts.joined(separator: " · ")
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let result = selected, let agent = agents[result.sessionId] {
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.recap.headline ?? agent.name).font(Theme.ui(15, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text("\(RecapView.tildePath(agent.cwd)) · \(agent.gitBranch ?? "—") · \(agent.activity.word)")
                        .font(Theme.ui(12)).foregroundStyle(Theme.mute).lineLimit(1).truncationMode(.middle)
                }
                if result.context.isEmpty {
                    // Only the name matched, so show where the session has got to instead.
                    note(.prompt, agent.recap.lastPrompt.map { ($0.date, Highlighted(plain: $0.text)) }, lines: 3)
                    note(.reply, agent.recap.lastReply.map { ($0.date, Highlighted(plain: $0.text)) }, lines: 5)
                } else {
                    ForEach(result.context) { message in
                        let isBest = message.id == result.best?.id
                        note(message.role, (message.date, message.text), lines: isBest ? 8 : 3)
                            .opacity(isBest ? 1 : 0.7)
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    ToolbarButton(title: "Open session", symbol: "return", filled: true) { onChoose(result.id) }
                }
            }
        }
        .padding(14)
    }

    private func note(_ role: SearchMessage.Role, _ said: (date: Date, text: Highlighted)?, lines: Int) -> some View {
        Group {
            if let said {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(Self.who(role).uppercased()).font(Theme.ui(10, .semibold)).foregroundStyle(Theme.mute)
                        Text(RecapView.when(said.date)).font(Theme.ui(10)).foregroundStyle(Theme.mute)
                    }
                    text(said.text, size: 13, said: true).lineLimit(lines).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func who(_ role: SearchMessage.Role) -> String { role == .prompt ? "You" : "Claude" }

    /// Matches in semibold on the amber chip colour.
    private func text(_ text: Highlighted, size: CGFloat, said: Bool) -> some View {
        var string = AttributedString()
        for span in text.spans {
            var part = AttributedString(span.text)
            part.font = Theme.ui(size, span.isMatch ? .semibold : .regular)
            part.foregroundColor = Theme.ink
            if span.isMatch { part.backgroundColor = Theme.chipAmber }
            string += part
        }
        let hidden = said && blur
        return Text(string).blur(radius: hidden ? 4 : 0).opacity(hidden ? 0.7 : 1)
    }
}
