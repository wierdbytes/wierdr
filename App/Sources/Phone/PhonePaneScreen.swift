import SwiftUI
import WierdrModel

/// One pane on the whole iPhone screen: a bar with back, what runs here and
/// the next agent waiting for you; the other panes of the space; the
/// terminal edge to edge; the input bar (quick keys + compose).
struct PhonePaneScreen: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let space = controller.activeSpace
        let tab = controller.activeTab
        let pane = controller.focusedPane
        VStack(spacing: 0) {
            PhonePaneTopBar(space: space, tab: tab, pane: pane)
            if let space, verticalSizeClass != .compact, panes(of: space).count > 1 {
                PhonePaneStrip(space: space, current: pane?.id, panes: panes(of: space))
            }
            Group {
                if let pane, let tab {
                    PhonePaneContent(pane: pane, tab: tab)
                        .id(pane.id)
                } else {
                    PhoneEmptyPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)
            .overlay(alignment: .bottom) {
                ToastStack().padding(.horizontal, 12).padding(.bottom, 10)
            }
            if let address = pane?.terminal {
                PhoneInputBar(address: address)
                    .id(address)
            }
        }
        .background(theme.chrome.ignoresSafeArea())
        .overlay(alignment: .top) { ConnectionBanner(top: 56) }
    }

    /// The space's panes in tab order, then pane order (stable, unlike the
    /// sidebar's urgency order, so chips don't move under the finger).
    private func panes(of space: Space) -> [Pane] {
        space.tabs.flatMap(\.panes)
    }
}

/// The terminal (or the desktop-only panel note) filling the screen.
private struct PhonePaneContent: View {
    var pane: Pane
    var tab: Tab

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @Environment(\.terminalViewProvider) private var provider
    @AppStorage(TerminalFonts.sizeKey) private var fontSize = Double(TerminalFonts.defaultSize)

    var body: some View {
        if let address = pane.terminal {
            let p = TerminalContainerView.padding
            provider.makeView(TerminalViewContext(
                address: address, terminal: controller.workspace.terminal(address), focused: true,
                palette: theme.terminal, fontSize: fontSize,
                padding: EdgeInsets(top: p.top, leading: p.left, bottom: p.bottom, trailing: p.right),
                requestFocus: {}))
            .id(address)
        } else {
            VStack(spacing: 8) {
                Icon("file-text", size: 26, color: theme.dim)
                Text("\(pane.mod ?? "This panel") is only shown in Herdr on the desktop")
                    .font(.ui(14)).foregroundStyle(theme.dim)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PhoneEmptyPane: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Text("Nothing here").font(.ui(16, .semibold)).foregroundStyle(theme.foreground)
            Button("Back to the List") { controller.showSidebar() }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
        }
    }
}

// MARK: - Top bar

/// Back, the space avatar, what runs here (title + model or folder), the
/// next agent waiting for you, the pane menu. 52 pt.
private struct PhonePaneTopBar: View {
    var space: Space?
    var tab: Tab?
    var pane: Pane?

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let terminal = controller.workspace.terminal(pane?.terminal)
        HStack(spacing: 0) {
            Button { controller.showSidebar() } label: {
                Icon("chevron-left", size: 22, color: theme.foreground)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            if let space {
                SpaceAvatar(space: space, size: 26)
                    .padding(.trailing, 10)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if let status = terminal?.status { StatusMark(status: status) }
                    Text(title(terminal))
                        .font(.ui(15.5, .semibold))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                }
                subtitle(terminal)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            AttentionButton(current: pane?.id)
                .padding(.leading, 6)
            PhonePaneMenu(space: space, tab: tab, pane: pane, terminal: terminal)
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(theme.chrome)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func title(_ t: TerminalInfo?) -> String {
        guard let pane else { return space?.displayName ?? "" }
        guard let t else { return pane.mod ?? "terminal" }
        return t.isAgent ? Format.agentTitle(t, tab: tab) : Format.processName(t)
    }

    /// "space · Opus 5.5 @high · 59.4k" for agents, "space · ~/folder" for terminals.
    private func subtitle(_ t: TerminalInfo?) -> Text {
        var out = Text(space?.displayName ?? "").foregroundColor(theme.muted)
        func dot() { out = out + Text("  ·  ").foregroundColor(theme.dim) }
        if let t, t.isAgent {
            dot()
            out = out + Text(t.meta?.model ?? t.program.name).foregroundColor(theme.muted)
            if let effort = t.meta?.effort, !effort.isEmpty {
                out = out + Text(" @" + effort).foregroundColor(theme.effortColor(effort))
            }
            if let ctx = Format.context(t.meta?.ctx) {
                dot()
                out = out + Text(ctx).foregroundColor(theme.contextNumberColor(cacheUntil: t.meta?.cacheUntil, now: Date()))
            }
        } else if let t {
            let folder = Format.folder(t, home: controller.workspace.home)
            if !folder.isEmpty {
                dot()
                out = out + Text(folder).foregroundColor(theme.dim)
            }
        }
        return out.font(.ui(12))
    }
}

/// "! 2 ›" / "● 3 ›": how many other agents wait for you; tap: the next one
/// (needs you first, then done), across all spaces.
private struct AttentionButton: View {
    var current: String?
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let waiting = controller.attention(excluding: current)
        let status: AgentStatus? = waiting.blocked > 0 ? .blocked : (waiting.done > 0 ? .done : nil)
        if let status {
            let n = status == .blocked ? waiting.blocked : waiting.done
            let color = status == .blocked ? theme.blocked : theme.done
            Button { controller.focusNext(status: status) } label: {
                HStack(spacing: 5) {
                    StatusMark(status: status)
                    Text("\(n)")
                        .font(.ui(13.5, .semibold))
                        .foregroundStyle(color)
                    Icon("chevron-right", size: 11, color: color)
                }
                .padding(.leading, 8)
                .padding(.trailing, 9)
                .frame(height: 30)
                .background(color.opacity(0.14), in: Capsule())
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(status == .blocked ? "\(n) need you" : "\(n) done")
            .accessibilityHint("Opens the next one")
            .transition(.scale.combined(with: .opacity))
        }
    }
}

// MARK: - Strip of the space's panes

/// The other panes of this space (all its tabs) as chips; tap to switch.
private struct PhonePaneStrip: View {
    var space: Space
    var current: String?
    var panes: [Pane]

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(panes) { pane in
                        chip(pane, selected: pane.id == current)
                            .id(pane.id)
                    }
                }
                .padding(.horizontal, 10)
            }
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            .onChange(of: current) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: 42)
        .background(theme.chrome)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func chip(_ pane: Pane, selected: Bool) -> some View {
        let ws = controller.workspace
        let t = ws.terminal(pane.terminal)
        let tab = ws.location(ofPane: pane.id)?.tab
        let label: String = {
            guard let t else { return pane.mod ?? "panel" }
            return t.isAgent ? Format.agentTitle(t, tab: tab) : Format.processName(t)
        }()
        return Button {
            controller.focus(pane: pane.id)
        } label: {
            HStack(spacing: 6) {
                if let t {
                    if t.isAgent {
                        StatusMark(status: t.status)
                    } else {
                        ProgramIcon(program: t.program, size: 13, color: theme.muted)
                    }
                } else {
                    Icon("file-text", size: 13, color: theme.muted)
                }
                Text(label)
                    .font(.ui(13, selected ? .medium : .regular))
                    .foregroundStyle(selected ? theme.foreground : theme.muted)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(selected ? theme.raised : theme.hover, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? theme.border : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Pane menu

/// Everything else about the pane, its tab and space; text size; settings.
private struct PhonePaneMenu: View {
    var space: Space?
    var tab: Tab?
    var pane: Pane?
    var terminal: TerminalInfo?

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @AppStorage(TerminalFonts.sizeKey) private var fontSize = Double(TerminalFonts.defaultSize)

    var body: some View {
        Menu {
            if let t = terminal, t.isAgent {
                Section {
                    Button { controller.setPinned(t.address, !t.pinned) } label: {
                        Label(t.pinned ? "Unpin" : "Pin", image: t.pinned ? "ui.pin-off" : "ui.pin")
                    }
                    switch t.status {
                    case .idle:
                        Button { controller.markUnread(t.address) } label: { Label("Mark Unread", systemImage: "circle.fill") }
                    case .done:
                        Button { controller.markRead(t.address) } label: { Label("Mark Idle", systemImage: "circle") }
                    default:
                        EmptyView()
                    }
                }
            }
            Section {
                if let space {
                    Menu {
                        LaunchMenuItems(machine: space.machine) { controller.newTab(launch: $0, in: space) }
                    } label: { Label("New Tab", image: "ui.plus") }
                }
                if let pane {
                    Menu {
                        Button { controller.split(.right, pane: pane.id) } label: { Label("Split Right", image: "ui.split-right") }
                        Button { controller.split(.down, pane: pane.id) } label: { Label("Split Down", image: "ui.split-down") }
                    } label: { Label("Split", image: "ui.split-right") }
                }
            }
            Section {
                if let tab {
                    Button { controller.beginRename(tab: tab.id) } label: { Label("Rename Tab…", image: "ui.square-pen") }
                }
                if let space {
                    Button { controller.beginRename(space: space.id) } label: { Label("Rename Space…", image: "ui.square-pen") }
                }
            }
            Section("Text Size \(Int(fontSize)) pt") {
                ControlGroup {
                    Button { step(-1) } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                        .disabled(fontSize <= Double(TerminalFonts.sizeRange.lowerBound))
                    Button { step(1) } label: { Label("Larger", systemImage: "textformat.size.larger") }
                        .disabled(fontSize >= Double(TerminalFonts.sizeRange.upperBound))
                }
                .controlGroupStyle(.compactMenu)
                Button { controller.showSettings = true } label: { Label("Settings…", image: "ui.settings") }
            }
            Section {
                if let pane {
                    Button(role: .destructive) { controller.closePane(pane.id) } label: { Label("Close Pane", image: "ui.x") }
                }
                if let tab, tab.panes.count > 1 {
                    Button(role: .destructive) { controller.closeTab(tab.id) } label: { Label("Close Tab", image: "ui.x") }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("More")
    }

    private func step(_ delta: Double) {
        let r = TerminalFonts.sizeRange
        fontSize = min(Double(r.upperBound), max(Double(r.lowerBound), fontSize + delta))
    }
}
