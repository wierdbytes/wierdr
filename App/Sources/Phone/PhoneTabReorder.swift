import SwiftUI
import UIKit
import WierdrModel

/// Reordering the iPhone's space tabs, as Telegram's folder tabs ("Reorder Tabs" in a
/// tab's menu): the mode, and the order the strip shows meanwhile and after Done,
/// until the workspace has it. A space moves only among its machine's spaces (each
/// machine keeps its own in its document); "All" stays first.
///
/// Done (or a pane pushed over the list) ends the mode and saves: each machine's
/// fewest `space.move`s (`SpaceMove.plan`), one after another
/// (`WorkspaceController.moveSpaces`); a save made while another still runs goes
/// after it. A move that fails: a toast, and the strip shows the workspace's order again.
@MainActor
@Observable
final class PhoneTabReorder {
    /// The mode is on: the tabs jiggle, a held one can be dragged, the list waits (dimmed).
    private(set) var isActive = false
    /// The spaces (ids) in the strip's order: while reordering, and after Done until the
    /// workspace has them (or a move failed, or `settleAfter` passed).
    private(set) var order: [String]?
    /// Each space tab's jiggle phase (0–0.25 s), new each time the mode starts.
    private(set) var phases: [String: Double] = [:]

    @ObservationIgnored weak var controller: WorkspaceController?
    /// The save running (its result: the moves were made), and the order it leads to.
    @ObservationIgnored private var saving: Task<Bool, Never>?
    @ObservationIgnored private var savingTo: [String]?
    @ObservationIgnored private var saveID = 0
    @ObservationIgnored private var settling: Task<Void, Never>?

    /// Tabs moving over (a swap, the drop): Telegram's easeInOut 0.25 s.
    static let motion = Animation.easeInOut(duration: 0.25)
    /// After the last move, how long the strip keeps the new order without the workspace's word.
    static let settleAfter: Duration = .seconds(2)

    /// `spaces` (the workspace's) in the strip's order: each machine's as `order` has
    /// them (ones it doesn't know, new spaces, before the others), the machines as they are.
    func arranged(_ spaces: [Space]) -> [Space] {
        guard let order else { return spaces }
        var rank: [String: Int] = [:]
        for (i, id) in order.enumerated() { rank[id] = i }
        return Self.machines(spaces).flatMap { machine in
            spaces.enumerated()
                .filter { $0.element.machine == machine }
                .sorted { (rank[$0.element.id] ?? -1, $0.offset) < (rank[$1.element.id] ?? -1, $1.offset) }
                .map(\.element)
        }
    }

    /// "Reorder Tabs": the mode starts from the order the strip shows.
    func begin() {
        guard !isActive, let spaces = controller?.workspace.spaces, spaces.count > 1 else { return }
        settling?.cancel()
        let ids = arranged(spaces).map(\.id)
        phases = Dictionary(uniqueKeysWithValues: ids.map { ($0, Double.random(in: 0..<0.25)) })
        withAnimation(PhonePagingMotion.relayout) {
            order = ids
            isActive = true
        }
    }

    /// A tab dragged (or moved by VoiceOver): the spaces' new order.
    func reorder(_ ids: [String]) {
        guard isActive else { return }
        order = ids
    }

    /// Done, or the list left: the mode ends and the new order is saved.
    func done() {
        guard isActive else { return }
        withAnimation(PhonePagingMotion.relayout) { isActive = false }
        guard let controller else { return }
        let spaces = controller.workspace.spaces
        let to = arranged(spaces).map(\.id)
        // From where the save still running leaves them, else as they are.
        let from = savingTo ?? spaces.map(\.id)
        let moves = Self.machines(spaces).flatMap { machine in
            let ids = Set(spaces.filter { $0.machine == machine }.map(\.id))
            return SpaceMove.plan(from: from.filter(ids.contains), to: to.filter(ids.contains))
        }
        guard !moves.isEmpty else {
            if saving == nil { order = nil }
            return
        }
        savingTo = to
        saveID += 1
        let id = saveID
        let previous = saving
        saving = Task { @MainActor [weak self] in
            // After the save before it; that one failed, so this one's start never came.
            if let previous, !(await previous.value) {
                self?.saved(false, id: id)
                return false
            }
            let ok = await controller.moveSpaces(moves)
            self?.saved(ok, id: id)
            return ok
        }
    }

    /// The workspace's spaces changed: once they're in the strip's order, it follows them again.
    func settle() {
        guard !isActive, saving == nil, order != nil, let spaces = controller?.workspace.spaces else { return }
        if arranged(spaces).map(\.id) == spaces.map(\.id) {
            settling?.cancel()
            order = nil
        }
    }

    /// A save ended. Failed: the strip shows the workspace's order again (and the next
    /// Done starts from it). Else, the last one: the strip keeps the new order until the
    /// workspace has it, at most `settleAfter`.
    private func saved(_ ok: Bool, id: Int) {
        guard ok else {
            saving = nil
            savingTo = nil
            settling?.cancel()
            if !isActive { withAnimation(Self.motion) { order = nil } }
            return
        }
        guard id == saveID else { return }
        saving = nil
        savingTo = nil
        settle()
        guard order != nil, !isActive else { return }
        settling?.cancel()
        settling = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settleAfter)
            guard let self, !Task.isCancelled, !self.isActive, self.saving == nil else { return }
            withAnimation(Self.motion) { self.order = nil }
        }
    }

    /// The machines of `spaces`, in their order.
    private static func machines(_ spaces: [Space]) -> [String?] {
        var out: [String?] = []
        for s in spaces where !out.contains(s.machine) { out.append(s.machine) }
        return out
    }
}

/// Telegram's jiggle for tabs in reorder mode: moved by the keyframes (−1, −1) →
/// (0, 0) → (−1, 0) → (0, −1) → (−1, −1) every 0.4 s and turned −2° → 2° → −2°
/// every 0.3 s, both linear, `phase` seconds in.
struct PhoneJiggle: ViewModifier {
    var isOn: Bool
    var phase: Double

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !isOn)) { context in
            let (offset, angle) = isOn ? Self.at(context.date.timeIntervalSinceReferenceDate + phase) : (.zero, 0)
            content
                .rotationEffect(.degrees(angle))
                .offset(offset)
        }
    }

    private static let points: [CGSize] = [
        CGSize(width: -1, height: -1), .zero, CGSize(width: -1, height: 0), CGSize(width: 0, height: -1),
        CGSize(width: -1, height: -1),
    ]

    /// The offset and the angle (degrees) at time `t` (seconds).
    static func at(_ t: Double) -> (CGSize, Double) {
        let p = t.truncatingRemainder(dividingBy: 0.4) / 0.1
        let k = min(max(Int(p), 0), 3)
        let f = CGFloat(p - Double(k))
        let a = points[k], b = points[k + 1]
        let offset = CGSize(width: a.width + (b.width - a.width) * f, height: a.height + (b.height - a.height) * f)
        let r = t.truncatingRemainder(dividingBy: 0.3) / 0.15
        let angle = r < 1 ? -2 + 4 * r : 2 - 4 * (r - 1)
        return (offset, angle)
    }
}

// MARK: - The hold

/// Telegram's hold to drag a tab in reorder mode: a finger held still for 0.2 s on a
/// space tab (`canBegin`) begins the drag, with the finger's x; moved more than 4 pt
/// before that, it fails and the strip scrolls instead (its pan waits for this).
/// Then it follows the finger, and `tick` runs every frame (the strip's auto-scroll).
/// x in the view's own coordinates.
struct PhoneTabHold: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var canBegin: (CGFloat) -> Bool
    var began: (CGFloat) -> Void
    var moved: (CGFloat) -> Void
    var ended: () -> Void
    var tick: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter, parent: self)
    }

    func makeUIGestureRecognizer(context: Context) -> PhoneTabHoldRecognizer {
        let hold = PhoneTabHoldRecognizer()
        hold.delegate = context.coordinator
        hold.isEnabled = isEnabled
        context.coordinator.hold = hold
        return hold
    }

    func updateUIGestureRecognizer(_ hold: PhoneTabHoldRecognizer, context: Context) {
        context.coordinator.parent = self
        if hold.isEnabled != isEnabled { hold.isEnabled = isEnabled }
    }

    func handleUIGestureRecognizerAction(_ hold: PhoneTabHoldRecognizer, context: Context) {
        let x = context.converter.localLocation.x
        switch hold.state {
        case .began:
            began(x)
            context.coordinator.startTicking()
        case .changed:
            moved(x)
        case .ended, .cancelled:
            context.coordinator.stopTicking()
            ended()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let converter: CoordinateSpaceConverter
        var parent: PhoneTabHold
        weak var hold: PhoneTabHoldRecognizer?
        private var link: CADisplayLink?

        init(converter: CoordinateSpaceConverter, parent: PhoneTabHold) {
            self.converter = converter
            self.parent = parent
        }

        /// Only touches that come down on a space tab.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            parent.canBegin(converter.convert(globalPoint: touch.location(in: nil), to: .local).x)
        }

        /// The strip's scrolling waits for it to fail (a finger that moves at once scrolls).
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer
        }

        func startTicking() {
            stopTicking()
            let link = CADisplayLink(target: self, selector: #selector(frame))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stopTicking() {
            link?.invalidate()
            link = nil
        }

        @objc private func frame() {
            guard let hold, hold.state == .began || hold.state == .changed else { return stopTicking() }
            parent.tick()
        }
    }
}

/// The hold's recognizer: one finger, begins 0.2 s after it came down unless it
/// moved more than 4 pt meanwhile; changes as it moves; ends as it lifts.
final class PhoneTabHoldRecognizer: UIGestureRecognizer {
    private var start: CGPoint?
    private var timer: Timer?

    static let delay: TimeInterval = 0.2
    static let slop: CGFloat = 4

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // A second finger: before the hold, it fails; during the drag, it's ignored.
        guard start == nil, touches.count == 1, let touch = touches.first else {
            if state == .possible { state = .failed }
            return
        }
        start = touch.location(in: view)
        let timer = Timer(timeInterval: Self.delay, target: self, selector: #selector(held), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func held() {
        timer = nil
        if state == .possible { state = .began }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let start, let touch = touches.first else { return }
        switch state {
        case .possible:
            let p = touch.location(in: view)
            if hypot(p.x - start.x, p.y - start.y) > Self.slop { state = .failed }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        state = state == .began || state == .changed ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = state == .began || state == .changed ? .cancelled : .failed
    }

    override func reset() {
        super.reset()
        timer?.invalidate()
        timer = nil
        start = nil
    }
}
