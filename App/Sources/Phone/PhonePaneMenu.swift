import SwiftUI
import WierdrModel

/// The pane's menu on the iPhone, dropping down from under the title capsule (a tap
/// on it), the capsule staying in place: our own rather than a system `Menu`, which on
/// iOS 26+ grows out of its button and hides it. The pills' glass; rows as a system
/// menu's (17 pt, 44 tall, the icon on the right). The agent's Pin and Unread/Idle; New
/// Tab and Split, which open in place; the text size (− / + leave the menu out); Close
/// Pane / Tab. A sub-agent shown here (`peek`): Keep as Tab, back to its parent's pane.
/// A tap anywhere else closes it (`PhonePaneScreen`'s layer, not passed on).
struct PhonePaneMenu: View {
    var space: Space?
    var tab: Tab?
    var pane: Pane?
    var terminal: TerminalInfo?
    var peek: String?
    var close: () -> Void

    static let width: CGFloat = 250

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @AppStorage(TerminalFonts.sizeKey) private var fontSize = Double(TerminalFonts.defaultSize)
    /// The row open in place (New Tab or Split).
    @State private var expanded: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, rows in
                if index > 0 {
                    // Between sections: a band, as in a system menu.
                    theme.foreground.opacity(theme.isDark ? 0.07 : 0.06).frame(height: 7)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { separator }
                    rowView(row)
                }
            }
        }
        .frame(width: Self.width)
        .clipShape(shape)
        .menuPanel(shape, theme: theme)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close() }
    }

    // MARK: Content

    private struct Row: Identifiable {
        enum Kind {
            case action(() -> Void)
            /// Opens its children in place.
            case expand([Row])
            case textSize
            case note
        }

        var id: String
        var title: String = ""
        var glyph: Glyph? = nil
        var destructive = false
        var disabled = false
        var kind: Kind
    }

    enum Glyph {
        case asset(String)
        case system(String)
        /// A program's picture, in its colors.
        case program(String)
    }

    private var sections: [[Row]] {
        var out: [[Row]] = []
        if let peek {
            var rows = [Row(id: "keep", title: "Keep as Tab", glyph: .asset("plus"),
                            disabled: controller.keepTarget(for: peek) == nil,
                            kind: .action { controller.keep(peek) })]
            if let pane {
                rows.append(Row(id: "back", title: "Back to \(parentTitle)", glyph: .asset("chevron-left"),
                                kind: .action { controller.focus(pane: pane.id) }))
            }
            out.append(rows)
        } else {
            if let t = terminal, t.isAgent {
                var rows = [Row(id: "pin", title: t.pinned ? "Unpin" : "Pin", glyph: .asset(t.pinned ? "pin-off" : "pin"),
                                kind: .action { controller.setPinned(t.address, !t.pinned) })]
                switch t.status {
                case .idle:
                    rows.append(Row(id: "unread", title: "Mark Unread", glyph: .system("circle.fill"),
                                    kind: .action { controller.markUnread(t.address) }))
                case .done:
                    rows.append(Row(id: "idle", title: "Mark Idle", glyph: .system("circle"),
                                    kind: .action { controller.markRead(t.address) }))
                default:
                    break
                }
                out.append(rows)
            }
            var make: [Row] = []
            if let space { make.append(Row(id: "new", title: "New Tab", glyph: .asset("plus"), kind: .expand(launchRows(space)))) }
            if let pane {
                make.append(Row(id: "split", title: "Split", glyph: .asset("split-right"), kind: .expand([
                    Row(id: "split.right", title: "Split Right", glyph: .asset("split-right"),
                        kind: .action { controller.split(.right, pane: pane.id) }),
                    Row(id: "split.down", title: "Split Down", glyph: .asset("split-down"),
                        kind: .action { controller.split(.down, pane: pane.id) }),
                ])))
            }
            if !make.isEmpty { out.append(make) }
        }
        out.append([Row(id: "size", kind: .textSize)])
        if peek == nil {
            var rows: [Row] = []
            if let pane {
                rows.append(Row(id: "close.pane", title: "Close Pane", glyph: .asset("x"), destructive: true,
                                kind: .action { controller.closePane(pane.id) }))
            }
            if let tab, tab.panes.count > 1 {
                rows.append(Row(id: "close.tab", title: "Close Tab", glyph: .asset("x"), destructive: true,
                                kind: .action { controller.closeTab(tab.id) }))
            }
            if !rows.isEmpty { out.append(rows) }
        }
        return out
    }

    /// A terminal, then the agents installed on the space's machine (`LaunchMenuItems`'s list).
    private func launchRows(_ space: Space) -> [Row] {
        let launchers = (controller.workspace.launchers[space.machine ?? ""] ?? []).filter { $0.installed == true }
        var rows = [Row(id: "new.shell", title: "Terminal", glyph: .program("program.shell"),
                        kind: .action { controller.newTab(launch: .shell, in: space) })]
        if controller.workspace.launchers[space.machine ?? ""]?.isEmpty ?? true {
            rows.append(Row(id: "new.checking", title: "Checking installed agents…", kind: .note))
        }
        for launcher in launchers {
            rows.append(Row(id: "new.\(launcher.id)", title: launcher.program.name, glyph: .program(launcher.program.iconAsset),
                            kind: .action { controller.newTab(launch: .agent(launcher, task: nil), in: space) }))
        }
        return rows
    }

    /// The pane the sub-agent shows in place of (its parent's row).
    private var parentTitle: String {
        guard let t = controller.workspace.terminal(pane?.terminal) else { return "the Parent" }
        return t.isAgent ? Format.agentTitle(t, tab: tab) : Format.processName(t)
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row.kind {
        case .action:
            actionRow(row)
        case .expand(let children):
            let open = expanded == row.id
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded = open ? nil : row.id }
            } label: {
                label(row, chevron: open ? 90 : 0)
            }
            .buttonStyle(MenuRowStyle(theme: theme))
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                VStack(spacing: 0) {
                    ForEach(children) { child in
                        separator
                        actionRow(child, indent: 16)
                    }
                }
                .background(theme.foreground.opacity(0.04))
                .transition(.opacity)
            }
        case .textSize:
            textSize
        case .note:
            label(row, muted: true)
        }
    }

    /// A row that does something (and closes the menu); a note (no action) stays muted.
    @ViewBuilder
    private func actionRow(_ row: Row, indent: CGFloat = 0) -> some View {
        if case .action(let run) = row.kind {
            Button {
                close()
                run()
            } label: {
                label(row, indent: indent)
            }
            .buttonStyle(MenuRowStyle(theme: theme))
            .disabled(row.disabled)
        } else {
            label(row, indent: indent, muted: true)
        }
    }

    /// Title on the left, the icon on the right; `chevron`: an opening row's angle.
    private func label(_ row: Row, indent: CGFloat = 0, chevron: Double? = nil, muted: Bool = false) -> some View {
        let color = row.destructive ? Color(uiColor: .systemRed) : (muted ? theme.muted : theme.foreground)
        return HStack(spacing: 10) {
            if let chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.muted)
                    .rotationEffect(.degrees(chevron))
            }
            Text(row.title)
                .font(.system(size: 17))
                .foregroundStyle(color)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let glyph = row.glyph { image(glyph, color: color) }
        }
        .padding(.leading, 16 + indent)
        .padding(.trailing, 16)
        .frame(height: 44)
        .contentShape(Rectangle())
        .opacity(row.disabled ? 0.4 : 1)
    }

    @ViewBuilder
    private func image(_ glyph: Glyph, color: Color) -> some View {
        switch glyph {
        case .asset(let name):
            Icon(name, size: 19, color: color)
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 15))
                .foregroundStyle(color)
                .frame(width: 19, height: 19)
        case .program(let name):
            MenuIcon.image(name, size: 19)
                .foregroundStyle(color)
        }
    }

    /// − 12 pt +: the terminal's text size; the menu stays out.
    private var textSize: some View {
        let range = TerminalFonts.sizeRange
        return HStack(spacing: 0) {
            step(-1, glyph: "minus", disabled: fontSize <= Double(range.lowerBound))
                .accessibilityLabel("Smaller Text")
            Text("\(Int(fontSize)) pt")
                .font(.system(size: 17))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(theme.muted)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Text size \(Int(fontSize)) points")
            step(1, glyph: "plus", disabled: fontSize >= Double(range.upperBound))
                .accessibilityLabel("Larger Text")
        }
        .frame(height: 44)
    }

    private func step(_ delta: Double, glyph: String, disabled: Bool) -> some View {
        Button {
            let r = TerminalFonts.sizeRange
            withAnimation(.snappy(duration: 0.2)) {
                fontSize = min(Double(r.upperBound), max(Double(r.lowerBound), fontSize + delta))
            }
        } label: {
            Image(systemName: glyph)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.foreground)
                .frame(width: 72, height: 44)
                .contentShape(Rectangle())
                .opacity(disabled ? 0.3 : 1)
        }
        .buttonStyle(MenuRowStyle(theme: theme))
        .disabled(disabled)
    }

    private var separator: some View {
        theme.foreground.opacity(0.1)
            .frame(height: 1 / UIScreen.main.scale)
            .padding(.leading, 16)
    }
}

extension View {
    /// The menu's ground: the pills' glass, denser (the popover's color through it) so the
    /// terminal under it doesn't show through the rows; before iOS 26, the popover's color.
    @ViewBuilder
    fileprivate func menuPanel<S: InsettableShape>(_ shape: S, theme: Theme) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(theme.popover.opacity(theme.isDark ? 0.6 : 0.7)), in: shape)
        } else {
            background {
                shape.fill(theme.popover)
                    .overlay(shape.strokeBorder(theme.border, lineWidth: 1))
                    .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.15), radius: 18, y: 6)
            }
        }
    }
}

/// A menu row: its background lights up under the finger.
private struct MenuRowStyle: ButtonStyle {
    var theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(theme.foreground.opacity(configuration.isPressed ? 0.1 : 0))
    }
}
