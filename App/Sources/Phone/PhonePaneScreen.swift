import SwiftUI
import UIKit
import WierdrModel

/// One pane on the whole iPhone screen: a bar with the list's button, what runs here and
/// the next agent waiting for you; the other panes of the space; the
/// terminal edge to edge, and over it the key panel and the ways the
/// keyboards come (`KeyPanelLayer`: a swipe to the left on the terminal).
/// Under the terminal, always, the message field (`ComposerBar`); hidden
/// while the terminal has the keyboard itself. Taps on the terminal are
/// clicks for the program, with a keyboard up too; a double tap brings the
/// terminal's keyboard or hides the one that is up.
/// The list (`PhoneHome`) slides over it; while it is out (`covered`), the
/// panel and the keyboards go and the swipes rest. A sub-agent opened from the
/// list (`controller.peek`) shows here in its parent's place, as any agent
/// would; its menu keeps it as a tab or goes back to the parent.
struct PhonePaneScreen: View {
    var covered = false

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.services) private var services
    @Environment(\.theme) private var theme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var keys = KeyPanelState()
    /// The terminal's and the field's height: how tall the field may grow.
    @State private var room: CGFloat = 0

    var body: some View {
        let space = controller.activeSpace
        let tab = controller.activeTab
        let pane = controller.focusedPane
        let peek = controller.peek
        // What the screen shows: the sub-agent opened from the list, else the pane's terminal.
        let address = peek ?? pane?.terminal
        VStack(spacing: 0) {
            PhonePaneTopBar(space: space, tab: tab, pane: pane, peek: peek)
            if let space, verticalSizeClass != .compact, panes(of: space).count > 1 {
                PhonePaneStrip(space: space, current: pane?.id, panes: panes(of: space))
            }
            VStack(spacing: 0) {
                Group {
                    if let peek {
                        PhonePaneContent(pane: Pane(id: "peek:\(peek)", terminal: peek, mod: nil))
                            .id("peek:\(peek)")
                    } else if let pane {
                        PhonePaneContent(pane: pane)
                            .id(pane.id)
                    } else {
                        PhoneEmptyPane()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.background)
                .keyPanel(address: address, covered: covered, state: $keys)
                .overlay(alignment: .bottom) {
                    // Above the panel, and beside it while it is out.
                    ToastStack()
                        .padding(.leading, 12)
                        .padding(.trailing, keys.trailingInset > 0 ? keys.trailingInset + 6 : 12)
                        .padding(.bottom, 10)
                }
                if let address, services.terminalSession(address)?.hasKeyboardFocus != true {
                    ComposerBar(address: address, placement: .screen, room: room)
                        .id(address)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { room = $0 }
        }
        // Another pane, or the list out: the keyboard goes (the draft stays with its terminal).
        .onChange(of: address) { controller.closeCompose() }
        .onDisappear { controller.composing = nil }
        .background(theme.chrome.ignoresSafeArea())
        // Under the list, its own banner shows.
        .overlay(alignment: .top) { if !covered { ConnectionBanner(top: 56) } }
        // Watching an agent work: the screen stays on (a locked iPhone drops the connection).
        .onChange(of: keepsAwake && !covered, initial: true) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var keepsAwake: Bool {
        controller.workspace.terminal(controller.peek ?? controller.focusedPane?.terminal)?.status == .working
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
            Button("Show the List") { controller.showSidebar() }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
        }
    }
}

// MARK: - Top bar

/// The list's button, the space avatar, what runs here (title + model or folder), the
/// next agent waiting for you, the pane menu. 52 pt. A sub-agent shown here (`peek`)
/// reads as under its parent in the list (never done), from whom.
private struct PhonePaneTopBar: View {
    var space: Space?
    var tab: Tab?
    var pane: Pane?
    var peek: String? = nil

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let terminal = controller.workspace.terminal(peek ?? pane?.terminal)
        HStack(spacing: 0) {
            Button { controller.showSidebar() } label: {
                Icon("sidebar", size: 20, color: theme.foreground)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show the List")
            if let space {
                SpaceAvatar(space: space, size: 26)
                    .padding(.trailing, 10)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if let status = peek != nil ? terminal?.kidStatus : terminal?.status { StatusMark(status: status) }
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
            PhonePaneMenu(space: space, tab: tab, pane: pane, terminal: terminal, peek: peek)
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(theme.chrome)
        .overlay(alignment: .bottom) { Hairline().ignoresSafeArea(edges: .horizontal) }
    }

    private func title(_ t: TerminalInfo?) -> String {
        if let peek { return t.map { Format.kidTitle($0) } ?? peek }
        guard let pane else { return space?.displayName ?? "" }
        guard let t else { return pane.mod ?? "terminal" }
        return t.isAgent ? Format.agentTitle(t, tab: tab) : Format.processName(t)
    }

    /// "space · Opus 5.5 @high · 59.4k" for agents, "space · ~/folder" for terminals.
    private func subtitle(_ t: TerminalInfo?) -> Text {
        var out = Text(space?.displayName ?? "").foregroundColor(theme.muted)
        func dot() { out = out + Text("  ·  ").foregroundColor(theme.dim) }
        if peek != nil, let parent = controller.workspace.terminal(t?.parent) {
            out = Text("from \(Format.kidTitle(parent))").foregroundColor(theme.muted)
        }
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
        .overlay(alignment: .bottom) { Hairline().ignoresSafeArea(edges: .horizontal) }
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
/// A sub-agent shown here (`peek`): Keep as Tab, back to its parent's pane.
private struct PhonePaneMenu: View {
    var space: Space?
    var tab: Tab?
    var pane: Pane?
    var terminal: TerminalInfo?
    var peek: String? = nil

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @AppStorage(TerminalFonts.sizeKey) private var fontSize = Double(TerminalFonts.defaultSize)

    var body: some View {
        Menu {
            if let peek {
                Section {
                    Button { controller.keep(peek) } label: { Label("Keep as Tab", image: "ui.plus") }
                        .disabled(controller.keepTarget(for: peek) == nil)
                    if let pane {
                        Button { controller.focus(pane: pane.id) } label: {
                            Label("Back to \(parentTitle)", image: "ui.chevron-left")
                        }
                    }
                }
            } else {
                paneSections
            }
            Section {
                ControlGroup {
                    Button { step(-1) } label: { Label("Smaller Text", systemImage: "minus") }
                        .disabled(fontSize <= Double(TerminalFonts.sizeRange.lowerBound))
                    Button {} label: { Text("\(Int(fontSize)) pt") }
                        .disabled(true)
                    Button { step(1) } label: { Label("Larger Text", systemImage: "plus") }
                        .disabled(fontSize >= Double(TerminalFonts.sizeRange.upperBound))
                }
                .controlGroupStyle(.compactMenu)
                Button { controller.showSettings = true } label: { Label("Settings…", image: "ui.settings") }
            }
            if peek == nil {
                closeSection
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

    /// The pane the sub-agent shows in place of (its parent's row).
    private var parentTitle: String {
        let ws = controller.workspace
        guard let t = ws.terminal(pane?.terminal) else { return "the Parent" }
        return t.isAgent ? Format.agentTitle(t, tab: tab) : Format.processName(t)
    }

    @ViewBuilder
    private var paneSections: some View {
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
    }

    @ViewBuilder
    private var closeSection: some View {
        Section {
            if let pane {
                Button(role: .destructive) { controller.closePane(pane.id) } label: { Label("Close Pane", image: "ui.x") }
            }
            if let tab, tab.panes.count > 1 {
                Button(role: .destructive) { controller.closeTab(tab.id) } label: { Label("Close Tab", image: "ui.x") }
            }
        }
    }

    private func step(_ delta: Double) {
        let r = TerminalFonts.sizeRange
        fontSize = min(Double(r.upperBound), max(Double(r.lowerBound), fontSize + delta))
    }
}
