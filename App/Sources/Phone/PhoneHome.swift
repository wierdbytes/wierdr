import SwiftUI
import WierdrModel

/// The iPhone's list, Telegram's chat list: a tab per space after "All"
/// (`PhoneSpaceTabs`), their pages side by side (`PhoneSpacePager`: a swipe in the
/// middle of the screen pages between them), and a header floating over the pages
/// (they scroll under it): settings, the title (or the connection's state), search
/// and +, the strip under them. At the bottom the subscription limits (not in
/// landscape, where the header leaves the list little room) and the status counts. No agent is "current" here: the list shows no focus and never scrolls to one.
///
/// The tab shown is remembered (`phone.tab`: "all" or the space's id); when its
/// space goes, its neighbour takes over. Without spaces the strip fades out and
/// swipes don't page.
struct PhoneHome: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    /// The tab last shown: "all" or a space's id.
    @AppStorage("phone.tab") private var savedTab = "all"
    /// Landscape on an iPhone: the limits give their room to the list.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var paging = PhoneSpacePaging()
    @State private var safeTop: CGFloat = 0

    var body: some View {
        let tabs = self.tabs
        let showsTabs = tabs.count > 1
        // The header's bottom from the screen's top: the pages' room for it.
        let headerHeight = safeTop + PhoneHomeHeader.height(showsTabs: showsTabs)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                PhoneSpacePager(paging: paging, topInset: headerHeight,
                                isEnabled: showsTabs && controller.compactColumn == .sidebar) { scope in
                    PhoneAgentList(scope: scope, topInset: headerHeight, edgeSwipesOnly: showsTabs,
                                   scrollToTop: paging.scrollToTop[scope] ?? 0)
                }
                PhoneHeaderEdge(height: headerHeight)
                PhoneHomeHeader(tabs: tabs, paging: paging, showsTabs: showsTabs)
                    .padding(.top, safeTop)
                if case .failed = controller.workspace.phase {
                    // The reason and Retry, under the header (its title says "Not Connected").
                    ConnectionBanner(top: headerHeight + 8)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .animation(PhonePagingMotion.relayout, value: showsTabs)
            .overlay(alignment: .bottom) {
                ToastStack().padding(.horizontal, 12).padding(.bottom, 10)
            }
            if verticalSizeClass != .compact { LimitsPanel(large: true) }
            PhoneHomeFooter()
        }
        .background(theme.chrome.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { safeTop = $0 }
        .onChange(of: tabs.map(\.scope), initial: true) { _, scopes in
            paging.update(scopes: scopes, keeping: Self.scope(savedTab))
        }
        .onChange(of: paging.selectedScope) { _, scope in savedTab = Self.id(scope) }
    }

    /// "All", then a tab per space in Herdr's order, with its waiting agents (done or needing you).
    private var tabs: [PhoneSpaceTab] {
        let ws = controller.workspace
        return [PhoneSpaceTab(scope: .all, title: "All")] + ws.spaces.map { space in
            let counts = ws.agentCounts(in: space.id)
            let urgent = counts[.blocked] ?? 0
            return PhoneSpaceTab(scope: .space(space.id), title: space.displayName,
                                 unread: urgent + (counts[.done] ?? 0), urgent: urgent > 0, space: space)
        }
    }

    private static func id(_ scope: PhoneListScope) -> String {
        switch scope {
        case .all: return "all"
        case .space(let id): return id
        }
    }

    private static func scope(_ id: String) -> PhoneListScope {
        id == "all" || id.isEmpty ? .all : .space(id)
    }
}

/// Telegram's chat-list header over the pages: a 44-pt row 10 pt under the status
/// bar (settings in a glass circle where Telegram has Edit, the title in the middle,
/// search and + in one glass pill, 16 pt from the sides), then the strip 10 pt
/// under it, 3 pt above the header's bottom.
private struct PhoneHomeHeader: View {
    var tabs: [PhoneSpaceTab]
    var paging: PhoneSpacePaging
    var showsTabs: Bool

    static let rowHeight: CGFloat = 44
    static let sideInset: CGFloat = 16

    /// The header's height under the status bar.
    static func height(showsTabs: Bool) -> CGFloat {
        10 + rowHeight + (showsTabs ? 10 + PhoneSpaceTabs.height : 0) + 3
    }

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            row
                .frame(height: Self.rowHeight)
                .padding(.top, 10)
            if showsTabs {
                PhoneSpaceTabs(tabs: tabs, paging: paging)
                    .padding(.horizontal, Self.sideInset)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var row: some View {
        let trailingWidth: CGFloat = 2 * Self.rowHeight + 8
        return ZStack {
            PhoneHomeTitle()
                // Centered on the screen, clear of the widest side.
                .padding(.horizontal, Self.sideInset + trailingWidth + 8)
            ComposerGlassGroup {
                HStack(spacing: 0) {
                    Button { controller.showSettings = true } label: {
                        Icon("settings", size: 21, color: theme.foreground)
                            .frame(width: Self.rowHeight, height: Self.rowHeight)
                            .contentShape(Circle())
                    }
                    .buttonStyle(AttachPressStyle())
                    .composerGlass(Circle(), theme: theme)
                    .accessibilityLabel("Settings")
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        Button { controller.showSwitcher = true } label: {
                            Icon("search", size: 21, color: theme.foreground)
                                .frame(width: Self.rowHeight, height: Self.rowHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(AttachPressStyle())
                        .accessibilityLabel("Go to")
                        PhoneNewSpaceMenu()
                    }
                    .padding(.horizontal, 4)
                    .composerGlass(Capsule(), theme: theme)
                }
            }
            .padding(.horizontal, Self.sideInset)
        }
    }
}

/// The header's title: "Agents"; while not live, Telegram's "Connecting…" in its place
/// (a spinner before it), "Not Connected" when it failed (`ConnectionBanner` says why).
private struct PhoneHomeTitle: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let (text, spinner, why) = state
        // The text centered, the spinner before it (and its twin, hidden, after it).
        HStack(spacing: 7) {
            if spinner { ProgressView().controlSize(.small) }
            Text(text)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
            if spinner { ProgressView().controlSize(.small).hidden() }
        }
        .animation(.easeInOut(duration: 0.2), value: text)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(why ?? "")
    }

    private var state: (String, Bool, String?) {
        switch controller.workspace.phase {
        case .live: return ("Agents", false, nil)
        case .connecting: return ("Connecting…", true, nil)
        case .reconnecting(let why): return ("Reconnecting…", true, why)
        case .failed(let why): return ("Not Connected", false, why)
        }
    }
}

/// Telegram's edge effect behind the header: the list's background at 85 %, solid
/// to 54 pt above its end, then fading out (Telegram's curve); it runs 14 pt past
/// the header's bottom. The rows scroll under it.
private struct PhoneHeaderEdge: View {
    /// The header's bottom from the screen's top.
    var height: CGFloat
    @Environment(\.theme) private var theme

    /// Telegram's fade over its last 54 pt: (where, how much shows).
    private static let fade: [(CGFloat, CGFloat)] = [
        (0, 1), (0.132, 0.972), (0.233, 0.917), (0.314, 0.829), (0.394, 0.704), (0.47, 0.546),
        (0.547, 0.389), (0.606, 0.273), (0.659, 0.19), (0.728, 0.106), (0.791, 0.056), (1, 0),
    ]

    var body: some View {
        let total = height + 14
        let edge = min(54, total)
        let solid = (total - edge) / total
        Rectangle()
            .fill(theme.chrome.opacity(0.85))
            .mask {
                LinearGradient(stops: Self.fade.map { at, alpha in
                    Gradient.Stop(color: .black.opacity(alpha), location: solid + at * edge / total)
                }, startPoint: .top, endPoint: .bottom)
            }
            .frame(height: total)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Status counts (tap: the next agent with that status).
private struct PhoneHomeFooter: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let counts = controller.workspace.statusCounts
        HStack(spacing: 16) {
            ForEach([AgentStatus.blocked, .done, .working, .idle], id: \.self) { status in
                let n = counts[status] ?? 0
                if n > 0 || status == .working || status == .idle {
                    Button { controller.focusNext(status: status) } label: {
                        HStack(spacing: 6) {
                            StatusMark(status: status, tint: status == .working && n == 0 ? theme.dim : nil)
                            Text("\(n)")
                                .font(.ui(14, .medium))
                                .foregroundStyle(n == 0 ? theme.dim : (status == .blocked ? theme.blocked : theme.muted))
                        }
                        .frame(minWidth: 36, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(n == 0)
                    .accessibilityLabel("\(n) \(Format.statusWord(status))")
                    .accessibilityHint("Opens the next one")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: 54)
        .frame(maxWidth: .infinity)
        .background(theme.chrome.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Hairline().ignoresSafeArea(edges: .horizontal) }
    }
}

/// The header's +, Telegram's compose: a new space (shell or agent), in the folder of
/// the last pane you looked at (as the desktop's New Space), on its computer.
private struct PhoneNewSpaceMenu: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            PhoneNewSpaceItems()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: PhoneHomeHeader.rowHeight, height: PhoneHomeHeader.rowHeight)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("New Space")
        .onAppear { controller.workspace.refreshLaunchers(machine: controller.activeSpace?.machine) }
    }
}

/// The new-space menu's items: a terminal or an installed agent, in the folder of the
/// last pane you looked at, on its computer (the header's + and the "All" tab's menu).
struct PhoneNewSpaceItems: View {
    @Environment(WorkspaceController.self) private var controller

    var body: some View {
        let machine = controller.activeSpace?.machine
        let folder = controller.workspace.terminal(controller.focusedPane?.terminal)?.cwd
        Section(folder.map { "New space in \(Format.tilde($0, home: controller.workspace.home))" } ?? "New space") {
            LaunchMenuItems(machine: machine) { launch in controller.newSpace(launch: launch) }
        }
    }
}

/// Menu items to start a terminal or an installed agent (`New Tab` / `New Space`).
struct LaunchMenuItems: View {
    var machine: String?
    var action: (Launch) -> Void
    @Environment(WorkspaceController.self) private var controller

    var body: some View {
        let launchers = controller.workspace.launchers[machine ?? ""] ?? []
        Button { action(.shell) } label: {
            Label { Text("Terminal") } icon: { MenuIcon.image("program.shell") }
        }
        if launchers.isEmpty {
            Text("Checking installed agents…")
        }
        ForEach(launchers.filter { $0.installed == true }) { launcher in
            Button { action(.agent(launcher, task: nil)) } label: {
                Label { Text(launcher.program.name) } icon: { MenuIcon.image(launcher.program.iconAsset) }
            }
        }
    }
}
