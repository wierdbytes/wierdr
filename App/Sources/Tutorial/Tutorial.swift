import SwiftUI
import WierdrModel

/// The tour: the app's features shown on the demo, step by step, with a hint card and a
/// pointer on the screen (`TutorialPresenter`'s overlay window). It starts on the host
/// list (first launch with no hosts, "Take the Tour" there or in Settings), goes into the
/// demo by its Try the Demo, and there has the person do each thing: the screen is dimmed
/// but for what a step points at, which alone takes a finger, until the step's condition
/// holds (`TutorialStep.done`); explanations go on with Next. Skip ends it at any step;
/// it's marked seen once ended, and auto-starts no more.
///
/// The iPhone's layout only, for now (`isAvailable`).
@MainActor
@Observable
final class Tutorial {
    static let shared = Tutorial()

    private(set) var isActive = false
    private(set) var index = 0
    /// The step's card and pointer are up (not while the app moves between steps).
    private(set) var shown = false
    /// The app left the step's place (a finger opened something else): the hint waits,
    /// the screen dimmed, until the tour takes it back (`takeBack`).
    private(set) var away = false
    /// The card asks whether to end the tour.
    var confirmingSkip = false
    private(set) var signals = TutorialSignals()
    /// The signals as the step came (its done condition compares with them).
    @ObservationIgnored private(set) var baseline = TutorialSignals()
    /// When the step's card came up (the overlay gives up on a missing anchor after a while).
    @ObservationIgnored private(set) var shownAt = Date.distantPast

    let steps = TutorialStep.phone
    @ObservationIgnored private weak var app: AppModel?
    /// Changes with each step (and its end): late work of an earlier one stops.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watchID = 0
    @ObservationIgnored private var returning = false
    @ObservationIgnored private var presenter: TutorialPresenter?

    /// UserDefaults: the tour was taken or skipped (no auto-start any more).
    static let seenKey = "tour.seen"

    /// The iPhone's layout only, for now.
    static var isAvailable: Bool { Device.isPhone }

    var step: TutorialStep? { isActive ? steps[index] : nil }
    var count: Int { steps.count }

    var context: TutorialContext? { app.map { TutorialContext(app: $0, tour: self) } }

    func attach(_ app: AppModel) { self.app = app }

    // MARK: Starting and ending

    /// At launch: the first one (no hosts, nothing open, never toured).
    func startIfFirstLaunch() {
        guard Self.isAvailable, !isActive, let app, app.mode == .none, app.hosts.hosts.isEmpty,
              !UserDefaults.standard.bool(forKey: Self.seenKey) else { return }
        start()
    }

    /// From the start, on the host list (an open session is left first), or at step `id`
    /// (DEBUG: `-tour <id>`; a demo step opens the demo).
    func start(at id: String? = nil) {
        guard let app else { return }
        let i = id.flatMap { id in steps.firstIndex { $0.id == id } } ?? 0
        if steps[i].needsDemo, app.mode != .demo { app.startDemo() }
        signals = TutorialSignals()
        confirmingSkip = false
        isActive = true
        if presenter == nil { presenter = TutorialPresenter(tour: self) }
        presenter?.show()
        go(to: i)
    }

    /// Again, from Settings: once its sheet is down.
    func restart() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            self.start()
        }
    }

    /// An explanation's Next (the welcome's Start Tour).
    func next() {
        guard isActive, shown else { return }
        complete(pause: 0.15)
    }

    /// Ends it where it is (Skip, Not Now, Keep Exploring).
    func end() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        generation += 1
        watchID += 1
        confirmingSkip = false
        withAnimation(.easeOut(duration: 0.2)) {
            shown = false
            isActive = false
        }
        presenter?.hide()
    }

    /// The last card's Add My Mac: out of the demo, and the host editor opens.
    func finishAddingHost() {
        end()
        guard let app else { return }
        Task { @MainActor in
            await app.disconnect()
            if app.hosts.hosts.isEmpty { app.addHostRequested = true }
        }
    }

    // MARK: Signals

    /// Whether a view marked `anchor` should carry its marker now.
    func marks(_ anchor: TutorialAnchor) -> Bool {
        // Not observed by views the tour never points at.
        guard TutorialStep.anchors.contains(anchor), isActive, let step else { return false }
        return step.anchor == anchor || step.also.contains(anchor)
    }

    /// A menu or panel the tour waits for opened or closed.
    func report(_ toggle: WritableKeyPath<TutorialSignals, TutorialSignals.Toggle>, open: Bool) {
        guard isActive, signals[keyPath: toggle].open != open else { return }
        signals[keyPath: toggle].open = open
        if open { signals[keyPath: toggle].opens += 1 }
    }

    /// A message sent in the demo.
    func reportMessage() {
        guard isActive else { return }
        signals.messages += 1
    }

    // MARK: Steps

    private func go(to i: Int) {
        guard i < steps.count else { return end() }
        generation += 1
        let gen = generation
        index = i
        shown = false
        away = false
        confirmingSkip = false
        baseline = signals
        guard let ctx = context else { return end() }
        let step = steps[i]
        if step.needsDemo, ctx.app.mode != .demo { return end() }
        // Already done (the person got ahead): on.
        if step.done?(ctx) == true { return complete(pause: 0) }
        var wait = 0.05
        if !ctx.isIn(step.place) {
            prepare(step.place, ctx)
            wait = 0.5
        } else if !step.free, let c = ctx.controller {
            Self.dismissDialogs(c)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            guard self.generation == gen, self.isActive else { return }
            self.shownAt = Date()
            withAnimation(.easeOut(duration: 0.25)) { self.shown = true }
            self.watch()
        }
    }

    /// The step is done (or Next): its card goes, and after `pause` (the app's own move
    /// settling) the next one comes.
    private func complete(pause: Double) {
        generation += 1
        watchID += 1
        let gen = generation
        withAnimation(.easeOut(duration: 0.2)) { shown = false }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(pause))
            guard self.generation == gen, self.isActive else { return }
            self.go(to: self.index + 1)
        }
    }

    /// Follows what the step's condition reads: done, it goes on; the demo left, the tour
    /// ends; the app away from the step's place, it's taken back after a moment.
    private func watch() {
        watchID += 1
        let id = watchID
        guard isActive, shown, let step, let ctx = context else { return }
        let (done, here, left) = withObservationTracking {
            (step.done?(ctx) ?? false, ctx.isIn(step.place), step.needsDemo && ctx.app.mode != .demo)
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.watchID == id else { return }
                self.watch()
            }
        }
        if left { return end() }
        if done { return complete(pause: 0.5) }
        let off = !here && !step.free
        if away != off { withAnimation(.easeOut(duration: 0.2)) { away = off } }
        if off { takeBack() }
    }

    /// Back to the step's place, if the app is still away from it in a moment.
    private func takeBack() {
        guard !returning else { return }
        returning = true
        let gen = generation
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            self.returning = false
            guard self.generation == gen, self.isActive, let step = self.step, let ctx = self.context,
                  step.done?(ctx) != true, !ctx.isIn(step.place) else { return }
            self.prepare(step.place, ctx)
        }
    }

    /// Takes the app to `place`: the host list (the session left), the list, an agent's
    /// pane screen, a sub-agent shown in its parent's place. Dialogs and sheets go.
    private func prepare(_ place: TutorialPlace, _ ctx: TutorialContext) {
        if place == .connect {
            if ctx.app.session != nil { Task { await ctx.app.disconnect() } }
            return
        }
        guard let c = ctx.controller else { return }
        Self.dismissDialogs(c)
        let ws = c.workspace
        switch place {
        case .list:
            c.showSwitcher = false
            c.closePeek()
            if c.compactColumn != .sidebar { c.showSidebar() }
        case .pane(let address):
            c.showSwitcher = false
            if let at = ws.pane(showing: address) { c.focus(pane: at.pane.id) }
        case .peek(let address, let parent):
            c.showSwitcher = false
            if let at = ws.pane(showing: parent),
               let kid = ws.subtree(of: parent).first(where: { $0.terminal.address == address }) {
                c.open(kid, from: at.pane.id)
            }
        case .connect, .anywhere:
            break
        }
    }

    /// What a finger could have left open in a free step, which a dimmed one would block.
    private static func dismissDialogs(_ c: WorkspaceController) {
        if c.rename != nil { c.rename = nil }
        if c.confirmClose != nil { c.confirmClose = nil }
        if c.showSettings { c.showSettings = false }
    }
}
