import SwiftUI
import UIKit
import WierdrModel

/// The iPhone layout: the list of agents/spaces (`PhoneHome`) and, pushed over
/// it, one pane at a time (`PhonePaneScreen`). Tapping a row pushes its pane;
/// the back button or a swipe from the left edge (with the finger) goes back.
///
/// Which one shows is `controller.compactColumn` (`.sidebar` = the list,
/// `.detail` = the pane), the same state the collapsed split view used, so
/// focusing a pane from anywhere (rows, quick switcher, status jumps) opens it.
struct PhoneWorkspaceView: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    /// How far a back swipe has moved the pane screen to the right.
    @State private var backDrag: CGFloat?
    @State private var width: CGFloat = 430

    var body: some View {
        let showing = controller.compactColumn == .detail
        let progress = showing ? 1 - (backDrag ?? 0) / max(width, 1) : 0
        ZStack {
            PhoneHome()
                .offset(x: -width * 0.28 * progress)
                .overlay {
                    Color.black.opacity(0.18 * progress)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                .allowsHitTesting(!showing)
                .accessibilityHidden(showing)
            if showing {
                PhonePaneScreen()
                    .offset(x: backDrag ?? 0)
                    .shadow(color: .black.opacity(backDrag == nil ? 0 : 0.25), radius: 14)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.3), value: showing)
        .overlay(alignment: .top) { AttentionBanner(showing: showing) }
        .background {
            BackSwipeGesture(
                enabled: showing,
                onDrag: { backDrag = max(0, $0) },
                onEnd: { projected in finishBackSwipe(projected: projected) }
            )
            .frame(width: 0, height: 0)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: showing, initial: true) { _, showing in
            if showing { controller.workspace.refreshLaunchers(machine: controller.activeSpace?.machine) }
        }
        .onChange(of: controller.workspace.spaces) { old, new in
            // The pane on screen was closed (here, on the desktop, or its program
            // exited): back to the list rather than showing some other pane.
            guard showing, let id = Self.shownPane(controller.screen.snapshot, in: old),
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

    private func finishBackSwipe(projected: CGFloat) {
        if projected > width * 0.4 {
            withAnimation(.easeOut(duration: 0.2)) {
                backDrag = width
            } completion: {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    controller.showSidebar()
                    backDrag = nil
                }
            }
        } else {
            withAnimation(.snappy(duration: 0.25)) { backDrag = nil }
        }
    }
}

/// A swipe from the left edge, on the window's root view so it sees touches
/// over the terminal too; it goes before the terminal's own pans.
///
/// A pan that only takes touches starting in the leftmost 24 pt (rather than
/// `UIScreenEdgePanGestureRecognizer`): same feel, and synthesized touches
/// (UI automation) drive it too.
private struct BackSwipeGesture: UIViewRepresentable {
    var enabled: Bool
    var onDrag: (CGFloat) -> Void
    /// Where the screen would come to rest at the finger's speed.
    var onEnd: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.coordinator = context.coordinator
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.pan.isEnabled != enabled { context.coordinator.pan.isEnabled = enabled }
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
        var parent: BackSwipeGesture?
        let pan = UIPanGestureRecognizer()
        /// The current touch began at the edge (only then do others wait for us).
        private var atEdge = false

        override init() {
            super.init()
            pan.maximumNumberOfTouches = 1
            pan.addTarget(self, action: #selector(moved(_:)))
            pan.delegate = self
        }

        func attach(to view: UIView?) {
            guard let view, pan.view !== view else { return }
            detach()
            view.addGestureRecognizer(pan)
        }

        func detach() {
            pan.view?.removeGestureRecognizer(pan)
        }

        @objc private func moved(_ g: UIPanGestureRecognizer) {
            guard let parent, let view = g.view else { return }
            let x = g.translation(in: view).x
            switch g.state {
            case .began, .changed: parent.onDrag(x)
            case .ended: parent.onEnd(x + g.velocity(in: view).x * 0.25)
            case .cancelled, .failed: parent.onEnd(0)
            default: break
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = g.view else { return false }
            let p = touch.location(in: view)
            atEdge = p.x <= view.safeAreaInsets.left + Self.edgeWidth
            return atEdge
        }

        // Only a rightward, mostly horizontal move.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let view = g.view else { return false }
            let v = pan.velocity(in: view)
            return v.x > 0 && v.x > abs(v.y)
        }

        // From the edge it goes first, as the system's back swipe does.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            atEdge
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
