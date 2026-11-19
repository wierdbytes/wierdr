import SwiftUI
import WierdrModel

/// Where a step happens. When the app isn't there as the step comes, or wanders off
/// while it's up, the tour takes it back (`Tutorial.prepare`).
enum TutorialPlace: Equatable {
    /// The host list (the tour starts there).
    case connect
    /// The demo's list screen.
    case list
    /// The demo's pane screen showing this terminal.
    case pane(String)
    /// A sub-agent shown on the pane screen in its parent's place (its address, its parent's).
    case peek(String, parent: String)
    /// Wherever the last step left the app (what it opened, the person closes).
    case anywhere
}

/// What the pointer shows a finger doing on the anchor.
enum TutorialGesture {
    case tap, hold, swipeLeft, swipeRight, pullUp

    var label: String {
        switch self {
        case .tap: return "Tap"
        case .hold: return "Touch and hold"
        case .swipeLeft: return "Swipe left"
        case .swipeRight: return "Swipe right"
        case .pullUp: return "Pull up"
        }
    }

    var symbol: String {
        switch self {
        case .tap: return "hand.tap.fill"
        case .hold: return "hand.point.up.left.fill"
        case .swipeLeft: return "arrow.left"
        case .swipeRight: return "arrow.right"
        case .pullUp: return "arrow.up"
        }
    }
}

/// What the tour's done conditions read.
@MainActor
struct TutorialContext {
    let app: AppModel
    let tour: Tutorial

    var controller: WorkspaceController? { app.session }
    var workspace: Workspace? { app.session?.workspace }
    var signals: TutorialSignals { tour.signals }
    /// The signals as the step came.
    var baseline: TutorialSignals { tour.baseline }

    func terminal(_ address: String) -> TerminalInfo? { workspace?.terminal(address) }

    /// The list screen, nothing over it.
    var onList: Bool {
        guard let c = controller else { return false }
        return c.compactColumn == .sidebar && !c.showSwitcher && !c.showSettings
    }

    /// The pane screen showing `address`'s pane (not a sub-agent in its place).
    func showing(_ address: String) -> Bool {
        guard let c = controller else { return false }
        return c.compactColumn == .detail && c.peek == nil && !c.showSwitcher && c.focusedPane?.terminal == address
    }

    /// The pane screen showing the sub-agent `address`.
    func peeking(_ address: String) -> Bool {
        guard let c = controller else { return false }
        return c.compactColumn == .detail && c.peek == address && !c.showSwitcher
    }

    func isIn(_ place: TutorialPlace) -> Bool {
        switch place {
        case .connect: return app.session == nil
        case .list: return onList && controller?.peek == nil
        case .pane(let address): return showing(address)
        case .peek(let address, _): return peeking(address)
        case .anywhere: return true
        }
    }
}

/// One step of the tour: a hint card, and (unless it's `free`) the screen dimmed but for
/// the anchor; with a `gesture`, the pointer shows it on the anchor and only the anchor
/// (and `also`) takes a finger, until `done` holds; without, Next.
struct TutorialStep: Identifiable {
    enum Kind { case normal, welcome, finish }
    enum Card { case auto, top, bottom, center }

    let id: String
    var place: TutorialPlace
    var title: String
    var text: String
    var anchor: TutorialAnchor? = nil
    var gesture: TutorialGesture? = nil
    /// More places a finger may use (a swipe anywhere on the terminal, the keys).
    var also: [TutorialAnchor] = []
    /// Nothing dimmed, nothing blocked: the person closes what the last step opened.
    var free = false
    var card: Card = .auto
    var kind: Kind = .normal
    /// Nil: an explanation, Next goes on.
    var done: (@MainActor (TutorialContext) -> Bool)? = nil
    /// The pointer rests meanwhile (the person is at it: typing a message).
    var quiet: (@MainActor (TutorialContext) -> Bool)? = nil

    /// The demo has to be open (else the person left it: the tour ends).
    var needsDemo: Bool { place != .connect }
}

/// What the app tells the tour that no observable state says: menus and panels opened
/// (`open`, and how many times since the tour began), messages sent in the demo.
struct TutorialSignals: Equatable {
    struct Toggle: Equatable {
        var open = false
        var opens = 0
    }

    /// The list's own menu (a row's or a card header's, `SpaceDrag.menuLifted`).
    var listMenu = Toggle()
    /// The pane screen's menu (`PhonePaneScreen`).
    var paneMenu = Toggle()
    /// The key panel (`PhonePaneScreen`).
    var keys = Toggle()
    /// The limits' popover (`PhoneLimits`).
    var limits = Toggle()
    /// Messages sent in the demo (`DemoAgents`).
    var messages = 0
}

// MARK: - The iPhone's tour

extension TutorialStep {
    /// The demo's actors: the first space's pi agent with its tree, its blocked scout.
    private static let space = "sp1", other = "sp2", agent = "t5w", scout = "t60"

    /// From the host list into the demo, across the list, an agent's screen, the status
    /// ring, a sub-agent that asks, Go to and the limits.
    static let phone: [TutorialStep] = [
        TutorialStep(
            id: "welcome", place: .connect, title: "Welcome to Wierdr",
            text: "Your Herdr spaces, tabs and agents on your iPhone. A short tour shows you around on sample agents: you try each thing yourself.",
            card: .center, kind: .welcome),
        TutorialStep(
            id: "hosts", place: .connect, title: "Your computers",
            text: "Add the Mac that runs Herdr here. Wierdr signs in over SSH and runs hc connect there, so you see what your desktop shows.",
            anchor: .addHost),
        TutorialStep(
            id: "try-demo", place: .connect, title: "Try it on the demo",
            text: "First, look around on sample agents. Tap Try the Demo.",
            anchor: .tryDemo, gesture: .tap,
            done: { $0.app.mode == .demo }),

        // The list.
        TutorialStep(
            id: "cards", place: .list, title: "Spaces are cards",
            text: "Each space of your desktop is a card: its header at the bottom, its agents over it, the newest lowest, near your thumb.",
            anchor: .card(space)),
        TutorialStep(
            id: "fold", place: .list, title: "Fold a card",
            text: "Tap a card's header to fold it. A folded card sums up its agents' statuses in its header.",
            anchor: .spaceHeader(other), gesture: .tap,
            done: { $0.controller?.closedSpaces.contains(other) == true }),
        TutorialStep(
            id: "agent", place: .list, title: "An agent",
            text: "What it's doing, and for how long on a pill in its status's color: red needs you, green is done, yellow is working. Under it, its context ring, model and effort.",
            anchor: .agentRow(agent)),
        TutorialStep(
            id: "sub-agents", place: .list, title: "Sub-agents",
            text: "The agents it started hang over it as a tree. Tap the chip to fold them; >_ shows the terminals it started.",
            anchor: .botChip(agent), gesture: .tap, card: .top,
            done: { $0.controller?.foldedAgents.contains(agent) == true }),
        TutorialStep(
            id: "pin", place: .list, title: "Swipe a row",
            text: "Swipe right for Unread and Pin, left to close. Swipe this row right and tap Pin.",
            anchor: .agentRow(agent), gesture: .swipeRight,
            done: { $0.terminal(agent)?.pinned == true }),
        TutorialStep(
            id: "row-menu", place: .list, title: "More in its menu",
            text: "Touch and hold a row for its menu.",
            anchor: .agentRow(agent), gesture: .hold,
            done: { $0.signals.listMenu.opens > $0.baseline.listMenu.opens }),
        TutorialStep(
            id: "row-menu-open", place: .anywhere, title: "The row's menu",
            text: "Pin, Mark Unread, Split Right, Close Pane. Pick one, or tap anywhere else to close it.",
            free: true, card: .top,
            done: { !$0.signals.listMenu.open }),
        TutorialStep(
            id: "open", place: .list, title: "Open an agent",
            text: "Tap the row: its terminal fills the screen.",
            anchor: .agentRow(agent), gesture: .tap,
            done: { $0.showing(agent) }),

        // An agent's screen.
        TutorialStep(
            id: "title", place: .pane(agent), title: "What runs here",
            text: "The title says what the agent is doing, ringed in its status's color. Tap it for the pane's menu.",
            anchor: .paneTitle, gesture: .tap,
            done: { $0.signals.paneMenu.opens > $0.baseline.paneMenu.opens }),
        TutorialStep(
            id: "pane-menu", place: .anywhere, title: "The pane's menu",
            text: "Pin, a new tab, a split, the text size, Close. Tap outside it to close it.",
            free: true, card: .bottom,
            done: { !$0.signals.paneMenu.open }),
        TutorialStep(
            id: "message", place: .pane(agent), title: "Message the agent",
            text: "Tap the field, type anything and send: it goes to the agent as if typed there. The paperclip attaches photos and files.",
            anchor: .composer, gesture: .tap,
            done: { $0.signals.messages > $0.baseline.messages },
            quiet: { $0.controller?.composing != nil }),
        TutorialStep(
            id: "back", place: .pane(agent), title: "Back to the list",
            text: "It answers in a moment. The badge counts the agents waiting for you elsewhere: tap \u{2039}, or swipe right anywhere, to go back.",
            anchor: .paneBack, gesture: .tap, also: [.terminal],
            done: { $0.onList }),

        // The status ring, a sub-agent that asks.
        TutorialStep(
            id: "ring", place: .list, title: "All statuses in one ring",
            text: "A dash per agent, the most urgent first: red needs you, green is done, yellow is working. The number counts the most urgent. Tap it to go to the first.",
            anchor: .statusRing, gesture: .tap,
            done: { $0.peeking(scout) }),
        TutorialStep(
            id: "keys", place: .peek(scout, parent: agent), title: "It needs you",
            text: "The scout, a sub-agent, asks to read ~/.ssh/config. Answer without the keyboard: swipe left on the terminal for keys.",
            anchor: .terminal, gesture: .swipeLeft,
            done: { $0.signals.keys.opens > $0.baseline.keys.opens }),
        TutorialStep(
            id: "answer", place: .peek(scout, parent: agent), title: "Answer it",
            text: "Keys go straight to the program: arrows, y and n, numbers. Tap \u{23CE} to allow.",
            anchor: .keyEnter, gesture: .tap, also: [.keys, .terminal],
            done: { $0.terminal(scout)?.status != .blocked }),
        TutorialStep(
            id: "peek-back", place: .peek(scout, parent: agent), title: "Back to work",
            text: "A sub-agent shows in its parent's place; its menu keeps it as a tab of its own. Tap \u{2039} to go back.",
            anchor: .paneBack, gesture: .tap, also: [.terminal, .keys],
            done: { $0.onList }),

        // Go to.
        TutorialStep(
            id: "pull", place: .list, title: "Go to",
            text: "Pull the list up past its end to search everything.",
            anchor: .list, gesture: .pullUp,
            done: { $0.controller?.showSwitcher == true }),
        TutorialStep(
            id: "go-to", place: .anywhere, title: "Find anything",
            text: "Type to search agents and spaces, try \u{201C}login\u{201D}. Tap a result to open it, or swipe right to close Go to.",
            free: true, card: .top,
            done: { $0.controller?.showSwitcher == false }),

        // The header.
        TutorialStep(
            id: "limits", place: .list, title: "Your limits",
            text: "Your Claude and Codex subscriptions as rings: the share used, colored by pace; the tick is how much of the window has gone. Tap them for details.",
            anchor: .limits, gesture: .tap,
            done: { $0.signals.limits.opens > $0.baseline.limits.opens }),
        TutorialStep(
            id: "limits-open", place: .anywhere, title: "Each limit",
            text: "How much is used and when it resets. Tap outside to close it.",
            free: true, card: .top,
            done: { !$0.signals.limits.open }),
        TutorialStep(
            id: "plus", place: .list, title: "New spaces, Settings",
            text: "+ starts a new space with a terminal or an agent, and opens Settings, where this tour waits if you want it again.",
            anchor: .plus),
        TutorialStep(
            id: "finish", place: .list, title: "You're all set",
            text: "Connect your Mac to see your own agents here. The demo stays on the host list, a tap away.",
            card: .center, kind: .finish),
    ]

    /// Every anchor the tour uses (other views never look at the tour).
    static let anchors: Set<TutorialAnchor> = Set(phone.flatMap { [$0.anchor].compactMap { $0 } + $0.also })
}
