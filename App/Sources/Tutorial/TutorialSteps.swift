import SwiftUI
import WierdrModel

/// Where a step happens. When the app isn't there as the step comes, or wanders off
/// while it's up, the tour takes it back (`Tutorial.prepare`). The iPad's split view reads
/// them its way (`TutorialContext.isIn`): the list is the sidebar beside the panes, a pane
/// is the focused one, a sub-agent is in its window over them.
enum TutorialPlace: Equatable {
    /// The host list (the tour starts there).
    case connect
    /// The demo's list screen (the iPad: the sidebar shows).
    case list
    /// The agents panel over the list screen's spaces.
    case agents
    /// The demo's pane screen showing this terminal (the iPad: its pane focused).
    case pane(String)
    /// A sub-agent shown on the pane screen in its parent's place (its address, its parent's);
    /// the iPad's window over the panes.
    case peek(String, parent: String)
    /// The iPad: this terminal's pane focused, the sidebar hidden (slid over the panes or not).
    case bare(String)
    /// Wherever the last step left the app (what it opened, the person closes).
    case anywhere
}

/// What the pointer shows a finger doing on the anchor (and the symbol by the card's action).
enum TutorialGesture {
    case tap, hold, swipeLeft, swipeRight

    var symbol: String {
        switch self {
        case .tap: return "hand.tap.fill"
        case .hold: return "hand.point.up.left.fill"
        case .swipeLeft: return "arrow.left"
        case .swipeRight: return "arrow.right"
        }
    }
}

/// A part of the tour, for the card's progress ("Someone needs you · 2 of 4", a segment each).
/// Each scenario has its own (`Tutorial.chapters`).
enum TutorialChapter: Int, CaseIterable, Identifiable {
    case list, needsYou, talk, tidy, room, limits

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .list: return "First look"
        case .needsYou: return "Someone needs you"
        case .talk: return "Talk to an agent"
        case .tidy: return "Tidy and find"
        case .room: return "Make room"
        case .limits: return "Your limits"
        }
    }
}

/// A line of a card's list: a mark and what it says, and the statuses' colors under it
/// (`legend`: ● needs you ● done ● working).
struct TutorialBullet {
    enum Mark {
        /// An SF Symbol.
        case symbol(String)
        /// One of the app's icons (`Icon`: bot, terminal), as the list draws them.
        case icon(String)
        /// A short text (5 · 7, ››).
        case text(String)
    }

    var mark: Mark
    var text: String
    var legend = false
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
    /// The tour is the iPhone layout's (else the iPad's split view).
    var phone: Bool { tour.phone }

    func terminal(_ address: String) -> TerminalInfo? { workspace?.terminal(address) }

    /// The iPad's sidebar shows: docked beside the panes, or slid over them.
    var sidebarShown: Bool {
        guard let c = controller else { return false }
        return c.columnVisibility != .detailOnly || c.sidebarOverlay
    }

    /// The iPad's sidebar is hidden (`detailOnly`): only its overlay brings it.
    var sidebarHidden: Bool { controller?.columnVisibility == .detailOnly }

    /// The list screen, its spaces, nothing over them (the iPad: the sidebar shows them).
    var onList: Bool {
        guard let c = controller, !c.showAgents, !c.showSettings else { return false }
        return phone ? c.compactColumn == .sidebar : sidebarShown
    }

    /// The list screen with the agents panel over its spaces (the iPad: in the sidebar).
    var onAgents: Bool {
        guard let c = controller, c.showAgents, !c.showSettings else { return false }
        return phone ? c.compactColumn == .sidebar : sidebarShown
    }

    /// The pane screen showing `address`'s pane, not a sub-agent in its place (the iPad:
    /// its pane focused, no sub-agent's window over the panes).
    func showing(_ address: String) -> Bool {
        guard let c = controller else { return false }
        return (!phone || c.compactColumn == .detail) && c.peek == nil && c.focusedPane?.terminal == address
    }

    /// The pane screen showing the sub-agent `address` (the iPad: its window).
    func peeking(_ address: String) -> Bool {
        guard let c = controller else { return false }
        return (!phone || c.compactColumn == .detail) && c.peek == address
    }

    func isIn(_ place: TutorialPlace) -> Bool {
        switch place {
        case .connect: return app.session == nil
        case .list: return onList && controller?.peek == nil
        case .agents: return onAgents && controller?.peek == nil
        case .pane(let address): return showing(address)
        case .peek(let address, _): return peeking(address)
        case .bare(let address): return showing(address) && sidebarHidden
        case .anywhere: return true
        }
    }
}

/// A later part of a step, which the card's action and the pointer follow: the Pin
/// button once the swipe uncovered it, the keyboard once the field is tapped. The last
/// phase that holds is shown, else the step itself.
struct TutorialPhase {
    var action: String
    /// The pointer goes there (else on the step's anchor).
    var pointer: TutorialAnchor? = nil
    /// Nil: the pointer rests (the person is at it, or waits).
    var gesture: TutorialGesture? = nil
    /// By the action, else the gesture's.
    var symbol: String? = nil
    /// It's this phase while this holds; without it, while `pointer` shows.
    var when: (@MainActor (TutorialContext) -> Bool)? = nil
}

/// One step of the tour: a hint card, and (unless it's `free`) the screen dimmed but for
/// the anchor and the `spotlight`; with a `gesture`, the pointer shows it on the anchor and
/// only the anchor (and `also`) takes a finger, until `done` holds; without, Next (or a
/// tap on the anchor). The card says what it is (`text`, `bullets`) and, apart, what to do
/// (`action`).
struct TutorialStep: Identifiable {
    enum Kind { case normal, welcome, finish }
    /// Where the card goes: by what the step shows (`auto`: under it in the screen's upper
    /// half, else over it; `below` and `above` try that side first), or at the top, the
    /// bottom or the middle.
    enum Card { case auto, below, above, top, bottom, center }

    let id: String
    /// Nil: the welcome and the end, outside the chapters.
    var chapter: TutorialChapter? = nil
    var place: TutorialPlace
    var title: String
    /// What it is and why: a sentence or two.
    var text = ""
    var bullets: [TutorialBullet] = []
    /// Small print under them.
    var note: String? = nil
    /// What to do: "Tap the ring" (by its gesture's symbol).
    var action: String? = nil
    var anchor: TutorialAnchor? = nil
    var gesture: TutorialGesture? = nil
    /// More places a finger may use (a swipe anywhere on the terminal, the keys): lightly dimmed.
    var also: [TutorialAnchor] = []
    /// More places shown with the anchor, not dimmed (a card with its header, an agent's tree),
    /// which the card keeps clear of; a finger doesn't go through them.
    var spotlight: [TutorialAnchor] = []
    /// What the card goes by in a free step (the popover the last step opened).
    var near: TutorialAnchor? = nil
    var phases: [TutorialPhase] = []
    /// Nothing dimmed, nothing blocked: the person closes what the last step opened.
    var free = false
    var card: Card = .auto
    var kind: Kind = .normal
    /// Only when needed (it's already done otherwise: a detour back); not counted in its chapter.
    var extra = false
    /// Nil: an explanation, Next goes on.
    var done: (@MainActor (TutorialContext) -> Bool)? = nil
    /// How long its result shows (the card's ✓, the screen held) before the next step.
    var settle: Double = 0.6

    /// The demo has to be open (else the person left it: the tour ends).
    var needsDemo: Bool { place != .connect }

    /// Something shown, nothing to do but read: Next.
    var isExplanation: Bool { kind == .normal && gesture == nil && !free }

    /// Every anchor it looks at.
    var anchorsUsed: [TutorialAnchor] {
        [anchor, near].compactMap { $0 } + also + spotlight + phases.compactMap(\.pointer)
    }
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
    /// The key panel (`PhonePaneScreen`, the iPad's `KeyLayerHost`).
    var keys = Toggle()
    /// The limits' popover (`PhoneLimits`).
    var limits = Toggle()
    /// The iPad's sidebar slid over the panes (`SidebarOverlay`).
    var overlay = Toggle()
    /// Messages sent in the demo (`DemoAgents`).
    var messages = 0
}

// MARK: - The iPhone's tour

extension TutorialStep {
    /// The demo's actors: the first space's pi agent with its tree, its blocked scout, and
    /// the space folded (its agent is done: the folded header shows it).
    private static let agent = "t5w", scout = "t60", folded = "sp3"

    /// From the host list into the demo: the list, someone who needs you found in the
    /// agents panel and answered, a message to an agent, a row's swipe, the panel's search
    /// and the limits; at the end what to remember.
    static let phone: [TutorialStep] = [
        TutorialStep(
            id: "welcome", place: .connect, title: "Welcome to Wierdr",
            text: "Herdr's agents keep working on your Mac. Wierdr puts them in your pocket.",
            bullets: [
                TutorialBullet(mark: .symbol("exclamationmark.bubble.fill"), text: "See who needs you"),
                TutorialBullet(mark: .symbol("hand.tap.fill"), text: "Answer in a tap"),
                TutorialBullet(mark: .symbol("lock.fill"), text: "Straight to your Mac over SSH: no server, no account"),
            ],
            note: "A tour on sample agents, about 2 minutes: you try each thing yourself.",
            card: .center, kind: .welcome),
        TutorialStep(
            id: "try-demo", chapter: .list, place: .connect, title: "Start with sample agents",
            text: "Your Mac comes later: Add Host connects to it over SSH.",
            action: "Tap Try the Demo",
            anchor: .tryDemo, gesture: .tap, spotlight: [.addHost],
            done: { $0.app.mode == .demo }, settle: 0.3),

        // The list.
        TutorialStep(
            id: "fold", chapter: .list, place: .list, title: "One card per space",
            text: "The list runs bottom up: the newest rows and the header stay by your thumb. Folded, a card sums up its agents.",
            action: "Tap the header to fold it",
            anchor: .spaceHeader(folded), gesture: .tap, spotlight: [.card(folded)], card: .below,
            done: { $0.controller?.closedSpaces.contains(folded) == true }, settle: 1.4),
        TutorialStep(
            id: "agent", chapter: .list, place: .list, title: "An agent at a glance",
            bullets: [
                TutorialBullet(mark: .symbol("text.alignleft"), text: "What it's working on"),
                TutorialBullet(mark: .symbol("timer"), text: "For how long, in its status's color", legend: true),
                TutorialBullet(mark: .symbol("chart.pie"), text: "Context used, model and effort"),
                TutorialBullet(mark: .icon("bot"), text: "Its sub-agents, in the tree above it"),
            ],
            anchor: .agentRow(agent), spotlight: [.tree(agent)]),

        // Someone needs you.
        TutorialStep(
            id: "ring", chapter: .needsYou, place: .list, title: "The status ring",
            text: "The ring has a dash per agent, the most urgent first. The number counts those who need you.",
            action: "Tap the ring",
            anchor: .statusRing, gesture: .tap,
            done: { $0.onAgents }, settle: 0.3),
        TutorialStep(
            id: "agents", chapter: .needsYou, place: .agents, title: "Every agent",
            text: "By status: whoever needs you is lowest, by your thumb, its sub-agents over it. The field at the bottom searches them.",
            action: "Tap the one that needs you",
            anchor: .panelRow(scout), gesture: .tap, spotlight: [.panelRow(agent)],
            done: { $0.peeking(scout) }, settle: 0.4),
        TutorialStep(
            id: "keys", chapter: .needsYou, place: .peek(scout, parent: agent), title: "Answer without the keyboard",
            text: "The scout, one of its sub-agents, asks to read ~/.ssh/config. The keys stay off-screen, so they never cover the terminal.",
            action: "Swipe left on the terminal",
            anchor: .terminal, gesture: .swipeLeft,
            done: { $0.signals.keys.opens > $0.baseline.keys.opens }, settle: 0.4),
        TutorialStep(
            id: "answer", chapter: .needsYou, place: .peek(scout, parent: agent), title: "Allow it",
            text: "Keys go straight to the program: arrows, y and n, numbers, esc.",
            action: "Tap \u{23CE}",
            anchor: .keyEnter, gesture: .tap, also: [.keys, .terminal],
            phases: [TutorialPhase(action: "Swipe left for the keys again", pointer: .terminal, gesture: .swipeLeft,
                                   when: { !$0.signals.keys.open })],
            done: { $0.terminal(scout)?.status != .blocked }, settle: 1.0),
        TutorialStep(
            id: "back", chapter: .needsYou, place: .peek(scout, parent: agent), title: "Back to the agents",
            text: "The badge on \u{2039} tells how many others need you (or are done), in their status's color.",
            action: "Tap \u{2039}, or swipe right anywhere",
            anchor: .paneBack, gesture: .tap, also: [.terminal, .keys],
            done: { $0.onAgents || $0.onList }, settle: 0.3),
        TutorialStep(
            id: "spaces", chapter: .needsYou, place: .agents, title: "Back to your spaces",
            text: "The panel waits where you left it, until you put it away.",
            action: "Swipe right anywhere",
            anchor: .agentsPanel, gesture: .swipeRight,
            done: { $0.onList }, settle: 0.3),

        // Talk to an agent.
        TutorialStep(
            id: "open", chapter: .talk, place: .list, title: "Open an agent",
            text: "Its terminal fills the screen, sized for the phone; a click on your Mac sizes it back.",
            action: "Tap the row",
            anchor: .agentRow(agent), gesture: .tap,
            done: { $0.showing(agent) }, settle: 0.3),
        TutorialStep(
            id: "message", chapter: .talk, place: .pane(agent), title: "Message it",
            text: "It arrives as if typed on your Mac. The paperclip adds photos and files.",
            action: "Tap the field",
            anchor: .composer, gesture: .tap,
            phases: [TutorialPhase(action: "Type anything, then send", symbol: "keyboard",
                                   when: { $0.controller?.composing != nil })],
            done: { $0.signals.messages > $0.baseline.messages }, settle: 0.3),
        TutorialStep(
            id: "reply", chapter: .talk, place: .pane(agent), title: "It's on it",
            text: "The ring round the title shows its status. Tap the title for tabs, splits and the text size.",
            action: "Tap \u{2039}, or swipe right, to go back",
            anchor: .paneBack, gesture: .tap, also: [.terminal, .paneTitle], spotlight: [.terminal],
            phases: [TutorialPhase(action: "It's answering\u{2026}", symbol: "hourglass",
                                   when: { $0.terminal(agent)?.status == .working })],
            done: { $0.onList }, settle: 0.3),

        // Tidy and find.
        TutorialStep(
            id: "pin", chapter: .tidy, place: .list, title: "Swipe a row",
            bullets: [
                TutorialBullet(mark: .symbol("arrow.right"), text: "Right: Pin and Unread"),
                TutorialBullet(mark: .symbol("arrow.left"), text: "Left: Close"),
                TutorialBullet(mark: .symbol("hand.point.up.left.fill"), text: "Touch and hold: everything else"),
            ],
            note: "Pinned rows stay at the bottom of their card, on your Mac too.",
            action: "Swipe the row right",
            anchor: .agentRow(agent), gesture: .swipeRight,
            phases: [TutorialPhase(action: "Tap Pin", pointer: .swipeButton("pin"), gesture: .tap)],
            done: { $0.terminal(agent)?.pinned == true }, settle: 1.2),
        TutorialStep(
            id: "find", chapter: .tidy, place: .list, title: "Find an agent",
            text: "The ring's panel searches every agent, without reaching for the top of the screen.",
            action: "Tap the ring",
            anchor: .statusRing, gesture: .tap,
            done: { $0.onAgents }, settle: 0.3),
        TutorialStep(
            id: "search", chapter: .tidy, place: .anywhere, title: "Search",
            text: "Tap the field and type a few letters of an agent, try \u{201C}login\u{201D}. A tap on a result opens it.",
            action: "Swipe right to put it away", gesture: .swipeRight,
            free: true, card: .top,
            done: { $0.onList || $0.controller?.compactColumn == .detail }, settle: 0.3),
        TutorialStep(
            id: "result-back", chapter: .tidy, place: .anywhere, title: "Back to the agents",
            text: "It opened right here, over the panel.",
            action: "Tap \u{2039}, or swipe right anywhere",
            anchor: .paneBack, gesture: .tap, also: [.terminal], extra: true,
            done: { $0.onAgents || $0.onList }, settle: 0.3),
        TutorialStep(
            id: "result-spaces", chapter: .tidy, place: .anywhere, title: "Back to your spaces",
            action: "Swipe right anywhere",
            anchor: .agentsPanel, gesture: .swipeRight, extra: true,
            done: { $0.onList }, settle: 0.3),

        // The limits.
        TutorialStep(
            id: "limits", chapter: .limits, place: .list, title: "Your plan limits",
            text: "Your Claude and Codex usage at a glance: a ring for each limit.",
            action: "Tap the rings",
            anchor: .limits, gesture: .tap,
            done: { $0.signals.limits.opens > $0.baseline.limits.opens }, settle: 0.3),
        TutorialStep(
            id: "limits-open", chapter: .limits, place: .anywhere, title: "How to read them",
            bullets: [
                TutorialBullet(mark: .symbol("circle.lefthalf.filled"), text: "The arc: the share used, green on pace, then yellow and red"),
                TutorialBullet(mark: .symbol("line.diagonal"), text: "The tick: how much of the window has gone"),
                TutorialBullet(mark: .text("5 7"), text: "Inside: 5 hours, 7 days, a model's letter"),
                TutorialBullet(mark: .text("\u{203A}\u{203A}"), text: "Used faster than time goes: it may run out before the reset"),
            ],
            action: "Tap outside to close", gesture: .tap, near: .limitsPopover, free: true,
            done: { !$0.signals.limits.open }, settle: 0.3),

        TutorialStep(
            id: "finish", place: .list, title: "You're all set",
            text: "Worth remembering:",
            bullets: [
                TutorialBullet(mark: .symbol("arrow.left"), text: "Swipe left on a terminal: keys"),
                TutorialBullet(mark: .symbol("arrow.right"), text: "Swipe right: back"),
                TutorialBullet(mark: .symbol("circle.dashed"), text: "Tap the ring: every agent, and a search"),
                TutorialBullet(mark: .symbol("hand.point.up.left.fill"), text: "Touch and hold a row: its menu"),
                TutorialBullet(mark: .symbol("plus"), text: "A new space, Settings and this tour"),
            ],
            note: "With your Mac connected, the Lock Screen shows who needs you even with Wierdr closed (Live Activity).",
            card: .center, kind: .finish),
    ]

    /// Every anchor the tours use (other views never look at the tour).
    static let anchors: Set<TutorialAnchor> = Set((phone + pad).flatMap(\.anchorsUsed))
}

// MARK: - The iPad's tour

extension TutorialStep {
    /// The demo's actors are the iPhone's tour's, and herdr-app's agent, whose tab is split
    /// with lazygit (the demo opens on wierdr's agent).
    private static let split = "t6a"

    /// The split view's: the sidebar beside the panes. From the host list into the demo:
    /// the list, someone who needs you found in the agents panel and answered in its window,
    /// a split tab and a message to its agent, the sidebar hidden and slid over the panes,
    /// the limits; at the end what to remember, the keyboard's shortcuts too.
    static let pad: [TutorialStep] = [
        TutorialStep(
            id: "welcome", place: .connect, title: "Welcome to Wierdr",
            text: "Herdr's agents keep working on your Mac. Wierdr brings them to your iPad.",
            bullets: [
                TutorialBullet(mark: .symbol("exclamationmark.bubble.fill"), text: "See who needs you"),
                TutorialBullet(mark: .symbol("hand.tap.fill"), text: "Answer in a tap"),
                TutorialBullet(mark: .symbol("lock.fill"), text: "Straight to your Mac over SSH: no server, no account"),
            ],
            note: "A tour on sample agents, about 2 minutes: you try each thing yourself.",
            card: .center, kind: .welcome),
        TutorialStep(
            id: "try-demo", chapter: .list, place: .connect, title: "Start with sample agents",
            text: "Your Mac comes later: Add Host connects to it over SSH.",
            action: "Tap Try the Demo",
            anchor: .tryDemo, gesture: .tap, spotlight: [.addHost],
            done: { $0.app.mode == .demo }, settle: 0.3),

        // The list.
        TutorialStep(
            id: "fold", chapter: .list, place: .list, title: "One card per space",
            text: "The sidebar runs bottom up: the newest rows and the header stay by your thumb. Folded, a card sums up its agents.",
            action: "Tap the chevron to fold it",
            anchor: .spaceChevron(folded), gesture: .tap, spotlight: [.card(folded)],
            done: { $0.controller?.closedSpaces.contains(folded) == true }, settle: 1.4),
        TutorialStep(
            id: "agent", chapter: .list, place: .list, title: "An agent at a glance",
            text: "Its row is lit while its pane is in front.",
            bullets: [
                TutorialBullet(mark: .symbol("text.alignleft"), text: "What it's working on"),
                TutorialBullet(mark: .symbol("timer"), text: "For how long, in its status's color", legend: true),
                TutorialBullet(mark: .symbol("chart.pie"), text: "Context used, model and effort"),
                TutorialBullet(mark: .icon("bot"), text: "Its sub-agents, in the tree above it"),
            ],
            anchor: .agentRow(agent), spotlight: [.tree(agent)]),

        // Someone needs you.
        TutorialStep(
            id: "ring", chapter: .needsYou, place: .list, title: "The status ring",
            text: "The ring has a dash per agent, the most urgent first. The number counts those who need you.",
            action: "Tap the ring",
            anchor: .statusRing, gesture: .tap,
            done: { $0.onAgents }, settle: 0.3),
        TutorialStep(
            id: "agents", chapter: .needsYou, place: .agents, title: "Every agent",
            text: "By status: whoever needs you is lowest, by your thumb, its sub-agents over it. The field at the bottom searches them, \u{2318}P from a keyboard.",
            action: "Tap the one that needs you",
            anchor: .panelRow(scout), gesture: .tap, spotlight: [.panelRow(agent)],
            done: { $0.peeking(scout) }, settle: 0.4),
        TutorialStep(
            id: "keys", chapter: .needsYou, place: .peek(scout, parent: agent), title: "Answer without the keyboard",
            text: "The scout, one of its sub-agents, asks to read ~/.ssh/config. A sub-agent opens over the panes. The keys stay off-screen, so they never cover a terminal.",
            action: "Swipe left on the terminal",
            anchor: .peekTerminal, gesture: .swipeLeft,
            done: { $0.signals.keys.opens > $0.baseline.keys.opens }, settle: 0.4),
        TutorialStep(
            id: "answer", chapter: .needsYou, place: .peek(scout, parent: agent), title: "Allow it",
            text: "Keys go straight to the program: arrows, y and n, numbers, esc.",
            action: "Tap \u{23CE}",
            anchor: .keyEnter, gesture: .tap, also: [.keys, .peekTerminal],
            phases: [TutorialPhase(action: "Swipe left for the keys again", pointer: .peekTerminal, gesture: .swipeLeft,
                                   when: { !$0.signals.keys.open })],
            done: { $0.terminal(scout)?.status != .blocked }, settle: 1.0),
        TutorialStep(
            id: "close", chapter: .needsYou, place: .peek(scout, parent: agent), title: "Close it, it keeps running",
            text: "Keep would make it a tab next to its parent's. Esc or a tap beside the window closes it too.",
            action: "Tap \u{2715}",
            anchor: .peekClose, gesture: .tap, also: [.keys], card: .below,
            done: { $0.controller?.peek == nil }, settle: 0.3),
        TutorialStep(
            id: "spaces", chapter: .needsYou, place: .agents, title: "Back to your spaces",
            text: "The panel waits where you left it, until you put it away.",
            action: "Swipe right on the panel",
            anchor: .agentsPanel, gesture: .swipeRight,
            done: { $0.onList }, settle: 0.3),

        // Talk to an agent.
        TutorialStep(
            id: "open", chapter: .talk, place: .list, title: "Open an agent",
            text: "Its tab opens beside the list, split as on your Mac. Its terminal takes the pane's size; a click on your Mac sizes it back.",
            action: "Tap the herdr-app agent",
            anchor: .agentRow(split), gesture: .tap,
            done: { $0.showing(split) }, settle: 0.8),
        TutorialStep(
            id: "message", chapter: .talk, place: .pane(split), title: "Message it",
            text: "The field under the panes writes to the focused one, as if typed on your Mac. The paperclip adds photos and files.",
            action: "Tap the field",
            anchor: .composer, gesture: .tap,
            phases: [TutorialPhase(action: "Type anything, then send", symbol: "keyboard",
                                   when: { $0.controller?.composing != nil })],
            done: { $0.signals.messages > $0.baseline.messages }, settle: 0.3),
        TutorialStep(
            id: "reply", chapter: .talk, place: .pane(split), title: "It's on it",
            text: "Its status shows on its row, its tab and the ring. A tap on a pane focuses it; its header splits, zooms and closes it.",
            anchor: .terminal,
            phases: [TutorialPhase(action: "It's answering\u{2026}", symbol: "hourglass",
                                   when: { $0.terminal(split)?.status == .working })]),

        // Make room.
        TutorialStep(
            id: "hide", chapter: .room, place: .list, title: "Make room",
            text: "Hide the sidebar for wider panes: + has Hide Sidebar, and so has \u{2318}B on a keyboard.",
            action: "Tap +, then Hide Sidebar",
            // Free: the menu is the system's, its items in no hole (the ring and the pointer
            // make way while it's over the +, `TutorialAnchors.covered`).
            anchor: .sidebarMenu, gesture: .tap, free: true, card: .center,
            done: { $0.sidebarHidden }, settle: 0.5),
        TutorialStep(
            id: "slide", chapter: .room, place: .bare(split), title: "The sidebar, when you need it",
            text: "A swipe right on a terminal slides it over the panes; a swipe left or a tap beside it puts it away.",
            action: "Swipe right on the terminal",
            anchor: .terminal, gesture: .swipeRight, also: [.sidebarOverlay],
            phases: [TutorialPhase(action: "Swipe left to put it away", pointer: .sidebarOverlay, gesture: .swipeLeft,
                                   when: { $0.signals.overlay.open })],
            done: { $0.signals.overlay.opens > $0.baseline.overlay.opens && !$0.signals.overlay.open }, settle: 0.4),
        TutorialStep(
            id: "show", chapter: .room, place: .bare(split), title: "Dock it again",
            text: "The sidebar button brings it back beside the panes.",
            action: "Tap the sidebar button",
            anchor: .showSidebar, gesture: .tap,
            done: { !$0.sidebarHidden }, settle: 0.4),

        // The limits.
        TutorialStep(
            id: "limits", chapter: .limits, place: .list, title: "Your plan limits",
            text: "Your Claude and Codex usage at a glance: a ring for each limit.",
            action: "Tap the rings",
            anchor: .limits, gesture: .tap,
            done: { $0.signals.limits.opens > $0.baseline.limits.opens }, settle: 0.3),
        TutorialStep(
            id: "limits-open", chapter: .limits, place: .anywhere, title: "How to read them",
            bullets: [
                TutorialBullet(mark: .symbol("circle.lefthalf.filled"), text: "The arc: the share used, green on pace, then yellow and red"),
                TutorialBullet(mark: .symbol("line.diagonal"), text: "The tick: how much of the window has gone"),
                TutorialBullet(mark: .text("5 7"), text: "Inside: 5 hours, 7 days, a model's letter"),
                TutorialBullet(mark: .text("\u{203A}\u{203A}"), text: "Used faster than time goes: it may run out before the reset"),
            ],
            action: "Tap outside to close", gesture: .tap, near: .limitsPopover, free: true,
            done: { !$0.signals.limits.open }, settle: 0.3),

        TutorialStep(
            id: "finish", place: .list, title: "You're all set",
            text: "Worth remembering:",
            bullets: [
                TutorialBullet(mark: .symbol("arrow.left"), text: "Swipe left on a terminal: keys"),
                TutorialBullet(mark: .symbol("arrow.right"), text: "Swipe right on it: the hidden sidebar"),
                TutorialBullet(mark: .symbol("circle.dashed"), text: "Tap the ring: every agent, and a search"),
                TutorialBullet(mark: .symbol("hand.point.up.left.fill"), text: "Touch and hold a row: its menu"),
                TutorialBullet(mark: .symbol("command"), text: "\u{2318}P finds an agent, \u{2318}] goes to the next, \u{2318}B hides the sidebar"),
                TutorialBullet(mark: .symbol("plus"), text: "A new space, Settings and this tour"),
            ],
            note: "On your iPhone, Wierdr shows who needs you on the Lock Screen, even when it's closed (Live Activity).",
            card: .center, kind: .finish),
    ]
}
