import SwiftUI
import UIKit
import WierdrModel

/// One pane on the whole iPhone screen: a bar with the list's button, what runs here and
/// the next agent waiting for you; the other panes of the space; the
/// terminal edge to edge, and over it, from the right edge, the key panel
/// (`PhoneKeyPanel`, with or without the keyboard). The keyboards come from
/// the edge swipe too: while it is under way, two icons beside the panel —
/// the terminal's keyboard above the finger, the message field below; let
/// go on one and it comes (`KeyboardChoice`). Under the terminal only the
/// message field while it is open, above the keyboard. Taps on the terminal
/// are clicks for the program; while a keyboard is up, a tap hides it.
/// The list (`PhoneHome`) slides over it; while it is out (`covered`), the
/// panel and the keyboards go and the edge swipes rest.
struct PhonePaneScreen: View {
    var covered = false

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.services) private var services
    @Environment(\.theme) private var theme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var panelOpen = false
    /// The finger's horizontal travel while it moves the panel.
    @State private var panelDrag: CGFloat?
    /// The window's height (the key panel's keys come to rest a third of it up from the bottom).
    @State private var screenHeight: CGFloat = 0
    /// The terminal's area (where the keyboard icons go).
    @State private var areaSize: CGSize = .zero
    /// A swipe from the edge is under way: where it began (the icons sit above and below).
    @State private var pickerStart: CGPoint?
    /// The icon under the finger.
    @State private var hovered: KeyboardChoice?

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
            .background {
                // Behind the terminal, its size: where the panel's swipes start.
                PhoneKeyPanelGestures(
                    enabled: pane?.terminal != nil && !covered,
                    isOpen: panelOpen,
                    keyboardUp: keyboardUp,
                    onDrag: { x, p in panelMoved(x, at: p) },
                    onEnd: { projected, p in panelReleased(projected: projected, at: p) },
                    // The panel first; then the keyboard (and the message field), at once.
                    onTap: {
                        if panelOpen { return setPanel(open: false) }
                        hideKeyboards()
                    }
                )
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { areaSize = $0 }
            .background(theme.background)
            .overlay(alignment: .trailing) {
                if let address = pane?.terminal {
                    keyPanel(address)
                }
            }
            .overlay {
                if let start = pickerStart {
                    KeyboardPickerIcons(centers: iconCenters(start), hovered: hovered)
                }
            }
            .sensoryFeedback(.selection, trigger: hovered)
            .overlay(alignment: .bottom) {
                // Above the panel, and beside it while it is out.
                ToastStack()
                    .padding(.leading, 12)
                    .padding(.trailing, panelOpen ? PhoneKeyPanel.width + 6 : 12)
                    .padding(.bottom, 10)
            }
            if let address = pane?.terminal, controller.composing == address {
                // No transition: it comes and goes with its keyboard, at once.
                PhoneComposeBar(address: address)
                    .id(address)
            }
        }
        // Another pane, or the list out: the message field closes (its draft stays).
        .onChange(of: pane?.terminal) { controller.composing = nil }
        .onChange(of: covered) { _, covered in
            guard covered else { return }
            setPanel(open: false)
            hideKeyboards()
        }
        .onDisappear { controller.composing = nil }
        .background(theme.chrome.ignoresSafeArea())
        // Safe area included: the keyboard's inset moves with it, so the sum is the window's height.
        .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom } action: {
            screenHeight = $0
        }
        // Under the list, its own banner shows.
        .overlay(alignment: .top) { if !covered { ConnectionBanner(top: 56) } }
        // Watching an agent work: the screen stays on (a locked iPhone drops the connection).
        .onChange(of: keepsAwake && !covered, initial: true) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// The terminal has the keyboard, or the message field is open.
    private var keyboardUp: Bool {
        guard let address = controller.focusedPane?.terminal else { return false }
        return controller.composing == address || services.terminalSession(address)?.hasKeyboardFocus == true
    }

    /// Hides the message field or the terminal's keyboard, at once.
    private func hideKeyboards() {
        if controller.composing != nil { return controller.closeCompose() }
        let session = services.terminalSession(controller.focusedPane?.terminal ?? "")
        UIView.performWithoutAnimation { session?.releaseKeyboard() }
    }

    // MARK: Swipe from the edge

    /// The finger moved the panel. A swipe that began with it hidden shows the keyboard icons.
    private func panelMoved(_ x: CGFloat, at p: CGPoint) {
        if panelDrag == nil, !panelOpen { pickerStart = p }
        panelDrag = x
        if let start = pickerStart { hovered = choice(at: p, start: start) }
    }

    /// Let go on an icon: that keyboard (the panel goes); elsewhere: the panel as usual.
    private func panelReleased(projected: CGFloat, at p: CGPoint) {
        let choice = pickerStart.flatMap { choice(at: p, start: $0) }
        pickerStart = nil
        hovered = nil
        guard let choice, let address = controller.focusedPane?.terminal else {
            return finishPanelDrag(projected: projected)
        }
        setPanel(open: false)
        switch choice {
        case .terminal:
            controller.closeCompose()
            guard let session = services.terminalSession(address) else {
                return controller.toast(controller.isDemo ? "Not available in the demo" : "The terminal is not connected yet")
            }
            session.takeKeyboard()
        case .message:
            controller.composing = address
        }
    }

    /// Left of the panel, one above the swipe's line and one below (in the terminal's area).
    private func iconCenters(_ start: CGPoint) -> [KeyboardChoice: CGPoint] {
        let x = areaSize.width - PhoneKeyPanel.width - KeyboardPickerIcons.size / 2 - 14
        let r = KeyboardPickerIcons.size / 2 + 6
        let gap = KeyboardPickerIcons.size / 2 + 26
        func y(_ v: CGFloat) -> CGFloat { min(max(v, r), max(r, areaSize.height - r)) }
        return [.terminal: CGPoint(x: x, y: y(start.y - gap)), .message: CGPoint(x: x, y: y(start.y + gap))]
    }

    private func choice(at p: CGPoint, start: CGPoint) -> KeyboardChoice? {
        let reach = KeyboardPickerIcons.size / 2 + 10
        return iconCenters(start).first { hypot($0.value.x - p.x, $0.value.y - p.y) <= reach }?.key
    }

    /// How far out the panel is: 0 hidden, 1 open.
    private var panelProgress: CGFloat {
        let w = PhoneKeyPanel.width
        guard let d = panelDrag else { return panelOpen ? 1 : 0 }
        return panelOpen ? 1 - min(max(d, 0), w) / w : min(max(-d, 0), w) / w
    }

    /// Always there while the terminal is (so it slides both ways and an
    /// upload goes on), just past the edge while hidden.
    private func keyPanel(_ address: String) -> some View {
        let progress = panelProgress
        return ZStack(alignment: .trailing) {
            if progress == 0 {
                PhoneKeyPanelGrip { setPanel(open: true) }
                    .transition(.opacity)
            }
            PhoneKeyPanel(address: address, shown: progress > 0, screenHeight: screenHeight,
                          close: { setPanel(open: false) })
                .id(address)
                .offset(x: (1 - progress) * PhoneKeyPanel.width)
                .allowsHitTesting(progress > 0)
                .accessibilityHidden(progress == 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .clipped()
    }

    private func setPanel(open: Bool) {
        withAnimation(.snappy(duration: 0.25)) {
            panelOpen = open
            panelDrag = nil
        }
    }

    private func finishPanelDrag(projected: CGFloat) {
        let threshold = PhoneKeyPanel.width * 0.4
        setPanel(open: panelOpen ? projected < threshold : projected < -threshold)
    }

    private var keepsAwake: Bool {
        controller.workspace.terminal(controller.focusedPane?.terminal)?.status == .working
    }

    /// The space's panes in tab order, then pane order (stable, unlike the
    /// sidebar's urgency order, so chips don't move under the finger).
    private func panes(of space: Space) -> [Pane] {
        space.tabs.flatMap(\.panes)
    }
}

/// Which keyboard a swipe from the edge brings.
enum KeyboardChoice: Hashable {
    /// The terminal's own (typing straight into it, with its key bar).
    case terminal
    /// The message field's (`PhoneComposeBar`).
    case message
}

/// The two icons shown beside the key panel while a swipe from the edge is
/// under way: the terminal's keyboard above, the message field below; the
/// one under the finger lights up. Only a picture: the swipe does the picking.
private struct KeyboardPickerIcons: View {
    var centers: [KeyboardChoice: CGPoint]
    var hovered: KeyboardChoice?

    static let size: CGFloat = 58

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            ForEach([KeyboardChoice.terminal, .message], id: \.self) { choice in
                if let c = centers[choice] { icon(choice).position(c) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func icon(_ choice: KeyboardChoice) -> some View {
        let on = hovered == choice
        return VStack(spacing: 2) {
            Image(systemName: choice == .terminal ? "keyboard" : "text.bubble")
                .font(.system(size: 20, weight: .semibold))
            Text(choice == .terminal ? "Terminal" : "Message")
                .font(.ui(9.5, .medium))
        }
        .foregroundStyle(on ? theme.accentForeground : theme.foreground)
        .frame(width: Self.size, height: Self.size)
        .background(on ? theme.accent : theme.raised.opacity(0.92), in: Circle())
        .overlay(Circle().strokeBorder(on ? .clear : theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 8)
        .scaleEffect(on ? 1.15 : 1)
        .animation(.snappy(duration: 0.15), value: on)
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
            Button("Show the List") { controller.showSidebar() }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
        }
    }
}

// MARK: - Top bar

/// The list's button, the space avatar, what runs here (title + model or folder), the
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
        .overlay(alignment: .bottom) { Hairline().ignoresSafeArea(edges: .horizontal) }
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
