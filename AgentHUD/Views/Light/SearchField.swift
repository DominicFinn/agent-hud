import AppKit
import SwiftUI

extension Notification.Name {
    /// ⌘F and `/`: put the cursor in the dashboard's search field. Posted on the main thread, the field
    /// takes the cursor before the next key is handled, so typing straight away loses nothing.
    static let focusSearch = Notification.Name("AgentHUD.focusSearch")
}

/// The header's search box, styled like the toolbar buttons beside it.
struct SearchField: View {
    enum Command { case up, down, submit, cancel }

    @Binding var text: String
    var onCommand: (Command) -> Void
    var onFocus: () -> Void
    @Environment(\.staticRendering) private var staticRendering
    @State private var focused = false
    static let prompt = "Search live sessions"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.mute)
            // ImageRenderer paints an AppKit view as a yellow "unsupported" slab, so snapshots get the text instead.
            if staticRendering {
                Text(text.isEmpty ? Self.prompt : text).font(Theme.ui(13)).foregroundStyle(text.isEmpty ? Theme.mute : Theme.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                FieldEditor(text: $text, onCommand: onCommand) { isFocused in
                    focused = isFocused
                    if isFocused { onFocus() }
                }
            }
            if text.isEmpty {
                Text("⌘F").font(Theme.ui(11)).foregroundStyle(Theme.mute)
            } else {
                Button { onCommand(.cancel) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.mute)
                }
                .buttonStyle(.plain)
                .help("Clear (esc)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(focused ? Theme.ink : Theme.borderStrong, lineWidth: 1))
    }
}

/// An AppKit text field underneath, because its delegate hears ↑ ↓ ↩ and esc before the field editor
/// acts on them, which is what moving through the results needs.
private struct FieldEditor: NSViewRepresentable {
    @Binding var text: String
    var onCommand: (SearchField.Command) -> Void
    var onFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = ReportingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.font = NSFont(name: "IBM Plex Sans", size: 13) ?? .systemFont(ofSize: 13)
        field.textColor = NSColor(Theme.ink)
        field.placeholderAttributedString = NSAttributedString(string: SearchField.prompt, attributes: [
            .foregroundColor: NSColor(Theme.mute), .font: field.font as Any,
        ])
        field.delegate = context.coordinator
        field.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocusChange(true) }
        context.coordinator.field = field
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.focus),
                                               name: .focusSearch, object: nil)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FieldEditor
        weak var field: NSTextField?

        init(_ parent: FieldEditor) { self.parent = parent }

        @objc func focus() {
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) { parent.onFocusChange(false) }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let command: SearchField.Command
            switch selector {
            case #selector(NSResponder.moveUp(_:)): command = .up
            case #selector(NSResponder.moveDown(_:)): command = .down
            case #selector(NSResponder.insertNewline(_:)): command = .submit
            case #selector(NSResponder.cancelOperation(_:)): command = .cancel
            default: return false
            }
            parent.onCommand(command)
            return true
        }
    }
}

/// Says when it gets the cursor, which a text field's delegate only hears about on the first keystroke.
private final class ReportingTextField: NSTextField {
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onBecomeFirstResponder?() }
        return became
    }
}
