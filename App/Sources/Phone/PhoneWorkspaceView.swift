import SwiftUI
import UIKit
import WierdrModel

/// The iPhone layout: one pane on the whole screen (`PhonePaneScreen`) and,
/// slid over it from the left, the list of agents/spaces (`PhoneHome`), as
/// wide as the screen. A swipe right on the terminal or from the left edge
/// (with the finger) or the bar's sidebar button brings it out; a swipe left
/// (anywhere on it) puts it back. Tapping a row shows its pane.
///
/// Whether the list is out is `controller.compactColumn` (`.sidebar` = out,
/// `.detail` = the pane alone), the same state the collapsed split view used,
/// so focusing a pane from anywhere (rows, quick switcher, status jumps) shows it.
struct PhoneWorkspaceView: View {
    @Environment(WorkspaceController.self) private var controller
    /// How much of the list shows while a finger moves it, 0...listWidth.
    @State private var dragged: CGFloat?
    @State private var size: CGSize = CGSize(width: 430, height: 900)
    @State private var leadingInset: CGFloat = 0

    /// The list's width: the screen's (fixed, unlike the iPad's).
    private var listWidth: CGFloat { max(1, size.width) }

    var body: some View {
        let open = controller.compactColumn == .sidebar
        let width = listWidth
        let progress = dragged.map { min(max($0, 0), width) / width } ?? (open ? 1 : 0)
        ZStack(alignment: .leading) {
            PhonePaneScreen(covered: open)
                .accessibilityHidden(open)
            // The pane dims as the list comes over it (out, it covers the pane).
            Color.black.opacity(0.35 * progress)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            PhoneHome()
                .frame(width: width)
                .ignoresSafeArea(.keyboard)
                .overlay(alignment: .trailing) {
                    // Its edge while it moves (out, its backing runs on into the safe area).
                    if progress < 1 { Hairline(axis: .vertical).ignoresSafeArea() }
                }
                .compositingGroup()
                .shadow(color: .black.opacity(progress > 0 ? 0.25 : 0), radius: 16)
                // Hidden: past the left edge, its backing (into the safe area) and shadow too.
                .offset(x: -(1 - progress) * (width + leadingInset + 24))
                .allowsHitTesting(open)
                .accessibilityHidden(!open)
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape) { controller.showPanel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.3), value: open)
        .overlay(alignment: .top) { AttentionBanner(showing: !open) }
        .background {
            PhoneListGestures(
                isOpen: open,
                width: width,
                onDrag: { dragged = min(max($0, 0), width) },
                onEnd: { projected in
                    withAnimation(.snappy(duration: 0.25)) {
                        controller.compactColumn = projected > width * 0.4 ? .sidebar : .detail
                        dragged = nil
                    }
                }
            )
            .frame(width: 0, height: 0)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.leading } action: { leadingInset = $0 }
        .onChange(of: open, initial: true) { _, open in
            if !open { controller.workspace.refreshLaunchers(machine: controller.activeSpace?.machine) }
        }
        .onChange(of: controller.workspace.spaces) { old, new in
            // The pane on screen was closed (here, on the desktop, or its program
            // exited): the list comes out rather than some other pane showing.
            guard !open, let id = Self.shownPane(controller.screen.snapshot, in: old),
                  !new.contains(where: { $0.tabs.contains { $0.panes.contains { $0.id == id } } }) else { return }
            controller.showSidebar()
        }
    }

    /// The pane the screen showed with these spaces (`ScreenState`'s resolution, fallbacks included).
    private static func shownPane(_ s: ScreenState.Snapshot, in spaces: [Space]) -> String? {
        guard let space = spaces.first(where: { $0.id == s.space }) ?? spaces.first else { return nil }
        guard let tab = space.tabs.first(where: { $0.id == s.tabBySpace[space.id] }) ?? space.tabs.first else { return nil }
        let panes = tab.panes
        return (panes.first { $0.id == s.focusByTab[tab.id] } ?? panes.first { $0.terminal != nil } ?? panes.first)?.id
    }
}

/// The list's pans, on the window's root view so they see touches over the
/// terminal too: the swipe right that pulls the list out, from the left edge
/// or anywhere on the terminal (before the terminal's own pans; after the key
/// panel's, which closes the open panel that way), and, while it is out, the
/// swipe left that puts it back (anywhere on it, rows included: before a
/// row's own swipe). Both report how much of the list shows.
///
/// The edge one is a pan that only takes touches starting in the leftmost 24 pt
/// (rather than `UIScreenEdgePanGestureRecognizer`): same feel, and synthesized
/// touches (UI automation) drive it too.
private struct PhoneListGestures: UIViewRepresentable {
    var isOpen: Bool
    var width: CGFloat
    var onDrag: (CGFloat) -> Void
    /// Where the list's edge would come to rest at the finger's speed.
    var onEnd: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.coordinator = context.coordinator
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.open.isEnabled != !isOpen { c.open.isEnabled = !isOpen }
        if c.close.isEnabled != isOpen { c.close.isEnabled = isOpen }
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Anchor: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window?.rootViewController?.view)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        static let edgeWidth: CGFloat = 24
        var parent: PhoneListGestures?
        let open = UIPanGestureRecognizer()
        let close = UIPanGestureRecognizer()
        /// The current touch began at the edge: everything else waits for `open`.
        private var atEdge = false
        /// It began on the terminal (not at the edge): its pans wait for `open`, `open` for the key panel's.
        private var onTerminal = false

        override init() {
            super.init()
            for pan in [open, close] {
                pan.maximumNumberOfTouches = 1
                pan.delegate = self
            }
            open.addTarget(self, action: #selector(opening(_:)))
            close.addTarget(self, action: #selector(closing(_:)))
        }

        func attach(to view: UIView?) {
            guard let view, open.view !== view else { return }
            detach()
            view.addGestureRecognizer(open)
            view.addGestureRecognizer(close)
        }

        func detach() {
            open.view?.removeGestureRecognizer(open)
            close.view?.removeGestureRecognizer(close)
        }

        @objc private func opening(_ pan: UIPanGestureRecognizer) { track(pan, from: 0) }
        @objc private func closing(_ pan: UIPanGestureRecognizer) { track(pan, from: parent?.width ?? 0) }

        private func track(_ pan: UIPanGestureRecognizer, from start: CGFloat) {
            guard let parent, let view = pan.view else { return }
            let x = start + pan.translation(in: view).x
            switch pan.state {
            case .began, .changed: parent.onDrag(x)
            case .ended: parent.onEnd(x + pan.velocity(in: view).x * 0.25)
            case .cancelled, .failed: parent.onEnd(start)
            default: break
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard g === open else { return true }
            guard let view = g.view else { return false }
            atEdge = touch.location(in: view).x <= view.safeAreaInsets.left + Self.edgeWidth
            onTerminal = !atEdge && WierdrTerminalView.swipeable(touch)
            return atEdge || onTerminal
        }

        // On the terminal the key panel's pan goes first: open, the panel closes with a swipe right.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            g === open && onTerminal && other.name == PhoneKeyPanelGestures.panName
        }

        // Opening: only a rightward, mostly horizontal move; closing: a leftward one.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let view = g.view else { return false }
            let v = pan.velocity(in: view)
            return g === open ? v.x > 0 && v.x > abs(v.y) : v.x < 0 && -v.x > abs(v.y)
        }

        // From the edge it goes first, as the system's back swipe does; on the
        // terminal before its pans only (not the root view's own: the key panel's
        // goes first). Closing goes before a row's own swipe: leftward it closes
        // (the row's trailing actions are in its long-press menu), rightward it
        // fails and the row's leading ones come. Only before pans: a held finger
        // never fails a pan, so the long-press menu, a space's lift (or the
        // terminal's menu) waiting for it would never come.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            if g === open {
                return atEdge || (onTerminal && other is UIPanGestureRecognizer && other.view !== g.view)
            }
            return isRowSwipe(other)
        }

        // Scrolling may run along with closing.

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            g === close && isScrollPan(other)
        }

        private func isScrollPan(_ g: UIGestureRecognizer) -> Bool {
            (g.view as? UIScrollView)?.panGestureRecognizer === g
        }

        /// A row's swipe (its actions): a pan in the list that isn't its scrolling.
        private func isRowSwipe(_ g: UIGestureRecognizer) -> Bool {
            g is UIPanGestureRecognizer && !isScrollPan(g) && isInList(g)
        }

        private func isInList(_ g: UIGestureRecognizer) -> Bool {
            var view = g.view
            while let v = view {
                if v is UICollectionView { return true }
                view = v.superview
            }
            return false
        }
    }
}

// MARK: - Attention banner

/// While you are in a pane, another agent that starts waiting for you
/// ("needs you") or finishes ("done") slides a banner in from the top, with
/// a tap to go there. The list shows these changes by itself, so no banner there.
private struct AttentionBanner: View {
    var showing: Bool

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @State private var last: [String: AgentStatus] = [:]
    /// The connection was live at the last update (a reconnect's refill is not news).
    @State private var wasLive = false
    @State private var banner: Banner?
    @State private var hide: Task<Void, Never>?

    struct Banner: Equatable {
        var id = UUID()
        var paneID: String
        var status: AgentStatus
        var title: String
        var space: Space
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let banner {
                card(banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(banner.id)
            }
        }
        .animation(.snappy(duration: 0.3), value: banner)
        .sensoryFeedback(trigger: banner?.id) { _, _ in
            guard let banner else { return nil }
            return banner.status == .blocked ? .warning : .success
        }
        .onChange(of: statusKey, initial: true) { _, _ in update() }
        .onChange(of: controller.workspace.phase) { _, phase in
            guard phase == .live else { wasLive = false; return }
            // Back live without any status change: news count again after the refill.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if controller.workspace.phase == .live { wasLive = true }
            }
        }
        .onChange(of: showing) { _, showing in if !showing { banner = nil } }
        #if DEBUG
        .task(id: showing) {
            // `-open banner`: show one for the first agent that needs you (screenshots).
            guard showing, UserDefaults.standard.string(forKey: "open") == "banner" else { return }
            try? await Task.sleep(for: .seconds(1))
            let ws = controller.workspace
            if let t = ws.terminals.values.first(where: { $0.status == .blocked }), let l = ws.pane(showing: t.address) {
                show(Banner(paneID: l.pane.id, status: .blocked, title: Format.agentTitle(t, tab: l.tab), space: l.space))
            }
        }
        #endif
    }

    /// Changes when any agent's status changes.
    private var statusKey: String {
        controller.workspace.terminals.values
            .compactMap { t in t.status.map { "\(t.address)=\($0.rawValue)" } }
            .sorted().joined(separator: ",")
    }

    private func update() {
        let ws = controller.workspace
        var now: [String: AgentStatus] = [:]
        for (address, t) in ws.terminals { if let s = t.status { now[address] = s } }
        let live = ws.phase == .live
        defer {
            last.merge(now) { _, new in new }
            wasLive = live
        }
        // Only fresh changes on a live connection (not the first snapshot or a reconnect's refill).
        guard live, wasLive, !last.isEmpty, showing else { return }
        let onScreen = Set(controller.onScreenPanes.compactMap(\.terminal))
        let fresh = now.filter { address, status in
            (status == .blocked || status == .done) && last[address].map { $0 != status } == true
                && !onScreen.contains(address) && ws.pane(showing: address) != nil
        }
        // Needs you beats done; then the most recent.
        guard let pick = fresh.max(by: { a, b in
            if a.value != b.value { return a.value < b.value }
            let ta = ws.terminals[a.key]?.statusChangedAt ?? .distantPast
            let tb = ws.terminals[b.key]?.statusChangedAt ?? .distantPast
            return ta < tb
        }), let location = ws.pane(showing: pick.key), let t = ws.terminals[pick.key] else { return }
        show(Banner(paneID: location.pane.id, status: pick.value,
                    title: Format.agentTitle(t, tab: location.tab), space: location.space))
    }

    private func show(_ b: Banner) {
        banner = b
        hide?.cancel()
        hide = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            banner = nil
        }
    }

    private func card(_ b: Banner) -> some View {
        Button {
            banner = nil
            controller.focus(pane: b.paneID)
        } label: {
            HStack(spacing: 10) {
                SpaceAvatar(space: b.space, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        StatusMark(status: b.status)
                        Text(b.status == .blocked ? "Needs you" : "Done")
                            .font(.ui(12, .semibold))
                            .foregroundStyle(b.status == .blocked ? theme.blocked : theme.done)
                        Text(b.space.displayName)
                            .font(.ui(12))
                            .foregroundStyle(theme.dim)
                            .lineLimit(1)
                    }
                    Text(b.title)
                        .font(.ui(14.5, .medium))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Icon("chevron-right", size: 14, color: theme.dim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.popover, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.15), radius: 14, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(PressStyle())
        .simultaneousGesture(DragGesture(minimumDistance: 8).onEnded { v in
            if v.translation.height < -10 { banner = nil }
        })
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .accessibilityLabel("\(b.status == .blocked ? "Needs you" : "Done"): \(b.title), \(b.space.displayName)")
        .accessibilityHint("Opens it")
    }
}
