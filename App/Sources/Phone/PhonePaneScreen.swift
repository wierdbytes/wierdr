import SwiftUI
import UIKit
import WierdrModel

/// One pane on the whole iPhone screen: a bar with the list's button and what runs here
/// (a tap on it: the pane's menu, `PhonePaneMenu`, dropping down under it); the
/// terminal edge to edge, and over it the key panel and the ways the
/// keyboards come (`KeyPanelLayer`: a swipe to the left on the terminal).
/// Under the terminal, always, the message field (`ComposerBar`); hidden
/// while the terminal has the keyboard itself. Taps on the terminal are
/// clicks for the program, with a keyboard up too; a double tap brings the
/// terminal's keyboard or hides the one that is up.
/// It is pushed over the list (`SidebarView`, `PhoneWorkspaceView`); popped (`covered`),
/// the panel and the keyboards go and the swipes rest. A sub-agent opened from the
/// list (`controller.peek`) shows here in its parent's place, as any agent
/// would; its menu keeps it as a tab or goes back to the parent.
struct PhonePaneScreen: View {
    var covered = false

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.services) private var services
    @Environment(\.theme) private var theme
    @State private var keys = KeyPanelState()
    /// The terminal's and the field's height: how tall the field may grow.
    @State private var room: CGFloat = 0
    /// The pane's menu is out, under the title capsule (grown to the whole title).
    @State private var menuOpen = false

    var body: some View {
        let space = controller.activeSpace
        let tab = controller.activeTab
        let pane = controller.focusedPane
        let peek = controller.peek
        // What the screen shows: the sub-agent opened from the list, else the pane's terminal.
        let address = peek ?? pane?.terminal
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // The bar's place: it floats over the terminal, which keeps its size when the title grows.
                Color.clear.frame(height: PhonePaneTopBar.collapsedHeight)
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
                    .tutorialAnchor(.terminal)
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
            if menuOpen {
                // Any tap but the menu's closes it (and doesn't reach the terminal).
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(PhonePaneTopBar.motion) { menuOpen = false } }
                    .accessibilityHidden(true)
            }
            PhonePaneTopBar(space: space, tab: tab, pane: pane, peek: peek, menuOpen: $menuOpen)
        }
        // Another pane, or the list out: the keyboard goes (the draft stays with its terminal), the menu too.
        .onChange(of: address) {
            controller.closeCompose()
            menuOpen = false
        }
        .onChange(of: covered) { if covered { menuOpen = false } }
        // The tour waits for these.
        .onChange(of: menuOpen) { _, open in Tutorial.shared.report(\.paneMenu, open: open) }
        .onChange(of: keys.open) { _, open in Tutorial.shared.report(\.keys, open: open) }
        .onDisappear {
            controller.composing = nil
            Tutorial.shared.report(\.paneMenu, open: false)
            Tutorial.shared.report(\.keys, open: false)
        }
        // One ground for the bar, the terminal and the field: the glass floats on the terminal's background.
        .background(theme.background.ignoresSafeArea())
        // Under the list, its own banner shows.
        .overlay(alignment: .top) { if !covered { ConnectionBanner(inset: PhonePaneTopBar.collapsedHeight) } }
        // Watching an agent work: the screen stays on (a locked iPhone drops the connection).
        .onChange(of: keepsAwake && !covered, initial: true) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var keepsAwake: Bool {
        controller.workspace.terminal(controller.peek ?? controller.focusedPane?.terminal)?.status == .working
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
            Button("Back to the List") { controller.showSidebar() }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
        }
    }
}

// MARK: - Top bar

/// Telegram's chat header, on the terminal's background with no line under it: two
/// 44-pt glass pills on one line, the field's side insets, one glass container. The
/// back button (a circle with "‹"; while other agents aren't idle, "‹" and a badge
/// with how many have the most urgent status)
/// and what runs here (a capsule ringed with the agent's status: its title, 15 pt
/// semibold, and under it the space, 12 pt gray, centered). A sub-agent shown here
/// (`peek`) reads as under its parent in the list (never done).
///
/// A tap on the capsule: the pane's menu (`PhonePaneMenu`) under it, sliding down.
/// Meanwhile the capsule grows left over the list's button (which goes) and, for a title
/// cut on one line, down over the terminal (up to 4 lines of title, then the space); back
/// when the menu goes. The bar floats over the terminal (`PhonePaneScreen` keeps its
/// collapsed place), so the terminal keeps its size.
private struct PhonePaneTopBar: View {
    var space: Space?
    var tab: Tab?
    var pane: Pane?
    var peek: String? = nil
    @Binding var menuOpen: Bool

    /// Every pill's height (the capsule's while collapsed).
    static let height: CGFloat = 44
    /// The bar's height with the capsule collapsed: 4 above the pills, 8 under them.
    static let collapsedHeight: CGFloat = 4 + height + 8
    /// The capsule growing and shrinking, the list's button going and coming, the menu.
    static let motion = Animation.snappy(duration: 0.32)

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let terminal = controller.workspace.terminal(peek ?? pane?.terminal)
        let status = status(terminal)
        let shape = RoundedRectangle(cornerRadius: Self.height / 2, style: .circular)
        // The capsules' row and, while it's out, the menu under it: centered under the grown
        // capsule (the row's width), it only moves down, following the capsule's edge.
        VStack(spacing: 8) {
            ComposerGlassGroup {
                HStack(alignment: .top, spacing: 6) {
                    if !menuOpen {
                        PhoneListButton(current: peek ?? pane?.terminal)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Button {
                        withAnimation(Self.motion) { menuOpen.toggle() }
                    } label: {
                        VStack(spacing: 1) {
                            Text(title(terminal))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(theme.foreground)
                                .lineLimit(menuOpen ? 4 : 1)
                                .multilineTextAlignment(.center)
                            if let subtitle {
                                Text(subtitle)
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.muted)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, menuOpen ? 6 : 0)
                        .frame(maxWidth: .infinity, minHeight: Self.height)
                        .contentShape(shape)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityValue(Format.statusWord(status))
                    }
                    .buttonStyle(AttachPressStyle())
                    .accessibilityHint(menuOpen ? "Hides the pane's menu" : "Shows the pane's menu")
                    // The status as a keyline in its color (the Dynamic Island's), on the glass,
                    // not through it: the glass stays the list button's, so the button's glass
                    // merges into it and comes back out of it whatever the status (tinted glass
                    // doesn't merge, it showed through and was cut off). Only the color
                    // animates, not the capsule growing or shrinking.
                    .overlay {
                        shape.strokeBorder(lineWidth: Self.keylineWidth)
                            .animation(.easeInOut(duration: 0.25)) { $0.foregroundStyle(keyline(status) ?? .clear) }
                            .allowsHitTesting(false)
                    }
                    .composerGlass(shape, theme: theme)
                    .tutorialAnchor(.paneTitle)
                }
            }
            if menuOpen {
                PhonePaneMenu(space: space, tab: tab, pane: pane, terminal: terminal, peek: peek) {
                    withAnimation(Self.motion) { menuOpen = false }
                }
                .transition(.offset(y: -24).combined(with: .scale(scale: 0.9, anchor: .top)).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Self.sideInset)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    /// The field's side inset with the keyboard down: in by 18 pt beside the
    /// screen's rounded corners (a home indicator), else 8.
    private static var sideInset: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return (scene?.keyWindow?.safeAreaInsets.bottom ?? 0) > 0 ? 26 : 8
    }

    /// An agent's status (a sub-agent's as in the list); a terminal has none.
    private func status(_ t: TerminalInfo?) -> AgentStatus? {
        guard let t else { return nil }
        if peek != nil { return t.kidStatus }
        return t.isAgent ? t.status : nil
    }

    /// The status's keyline's width.
    static let keylineWidth: CGFloat = 1.5

    /// The status's color around the capsule's glass; idle (or none): the glass alone.
    private func keyline(_ status: AgentStatus?) -> Color? {
        guard let status, status != .idle else { return nil }
        return theme.color(for: status)
    }

    private func title(_ t: TerminalInfo?) -> String {
        if let peek { return t.map { Format.kidTitle($0) } ?? peek }
        guard let pane else { return space?.displayName ?? "" }
        guard let t else { return pane.mod ?? "terminal" }
        return t.isAgent ? Format.agentTitle(t, tab: tab) : Format.processName(t)
    }

    /// The space's name under the title (none when the space is the title: nothing runs).
    private var subtitle: String? {
        guard pane != nil || peek != nil, let name = space?.displayName, !name.isEmpty else { return nil }
        return name
    }
}

/// Telegram's back button, a 44-pt glass pill: a circle with "‹"; while other agents
/// aren't idle, "‹" and a round badge with how many have the most urgent status (needs
/// you, then done, then working), filled with its color. A tap pops back to the list.
private struct PhoneListButton: View {
    /// The terminal on screen: not counted.
    var current: String?

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let waiting = controller.attention(excluding: current)
        let height = PhonePaneTopBar.height
        Button { controller.showSidebar() } label: {
            Group {
                if let waiting {
                    HStack(spacing: 7) {
                        chevron
                        Text("\(waiting.count)")
                            .font(.system(size: 14, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(theme.background)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(theme.color(for: waiting.status), in: Capsule())
                    }
                    .padding(.leading, 13)
                    .padding(.trailing, 11)
                } else {
                    chevron
                        .frame(width: height)
                }
            }
            .frame(minWidth: height, minHeight: height)
            .contentShape(Capsule())
        }
        .buttonStyle(AttachPressStyle())
        // A capsule as wide as it is tall is the circle: one shape, it stretches when the count comes.
        .composerGlass(Capsule(), theme: theme)
        .tutorialAnchor(.paneBack)
        .animation(.snappy(duration: 0.3), value: waiting?.status)
        .animation(.snappy(duration: 0.3), value: waiting?.count)
        .accessibilityLabel("Back")
        .accessibilityValue(waiting.map { Format.summary([$0.status: $0.count]) } ?? "")
    }

    private var chevron: some View {
        Image(systemName: "chevron.left")
            .font(.system(size: 21, weight: .regular))
            .foregroundStyle(theme.foreground)
    }
}
