import SwiftUI
import WierdrModel

/// A step's hint, in three parts: where it is (its chapter, "2 of 4", a segment per
/// chapter) and Skip; what it shows (title, a sentence or two, a list, small print); and
/// what to do (the action by its gesture's symbol, ✓ once done) or Next. The welcome card
/// starts the tour or not; the last one adds your Mac or keeps you in the demo. Skip asks
/// first, in the card. Its text follows Dynamic Type (up to the first accessibility size).
struct TutorialCard: View {
    var step: TutorialStep
    var progress: (chapter: TutorialChapter, number: Int, count: Int)?
    /// The step's anchor didn't show: Next instead of waiting for the gesture.
    var lost: Bool
    /// The part of the step under way (its action instead of the step's).
    var phase: TutorialPhase?
    /// Done: ✓ in place of the action.
    var succeeded: Bool

    @Environment(\.theme) private var theme
    /// A bullet's mark: as tall as its text's first line.
    @ScaledMetric(relativeTo: .subheadline) private var lineHeight: CGFloat = 20

    var body: some View {
        let tour = Tutorial.shared
        VStack(alignment: .leading, spacing: 0) {
            if tour.confirmingSkip {
                confirm
            } else {
                content
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.popover, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.18), radius: 20, y: 8)
        .animation(.snappy(duration: 0.25), value: tour.confirmingSkip)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var content: some View {
        if step.kind == .normal, let progress { progressView(progress).padding(.bottom, 12) }
        Text(step.title)
            .font(.headline)
            .foregroundStyle(theme.foreground)
            .accessibilityAddTraits(.isHeader)
        if !step.text.isEmpty {
            Text(step.text)
                .font(.subheadline)
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        if !step.bullets.isEmpty {
            bullets.padding(.top, step.text.isEmpty ? 8 : 10)
        }
        if let note = step.note {
            Text(note)
                .font(.footnote)
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        actions.padding(.top, 14)
    }

    // MARK: Where it is

    /// "Someone needs you · 2 of 4" and Skip; under them a segment per chapter, the ones
    /// done full, this one by its steps.
    private func progressView(_ p: (chapter: TutorialChapter, number: Int, count: Int)) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(p.chapter.title) \u{00B7} \(p.number) of \(p.count)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(theme.dim)
                    .lineLimit(1)
                    .accessibilityLabel("\(p.chapter.title), step \(p.number) of \(p.count)")
                Spacer(minLength: 8)
                Button("Skip") { Tutorial.shared.confirmingSkip = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.muted)
                    .buttonStyle(.plain)
                    .accessibilityHint("Ends the tour")
            }
            HStack(spacing: 4) {
                ForEach(TutorialChapter.allCases) { chapter in
                    let fill: CGFloat = chapter.rawValue < p.chapter.rawValue ? 1
                        : chapter == p.chapter ? CGFloat(p.number) / CGFloat(max(1, p.count)) : 0
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.border)
                            Capsule().fill(theme.accent).frame(width: geo.size.width * fill)
                        }
                    }
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
    }

    // MARK: What it shows

    private var bullets: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(step.bullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .top, spacing: 10) {
                    mark(bullet.mark)
                        .frame(width: 24, height: lineHeight)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(bullet.text)
                            .font(.subheadline)
                            .foregroundStyle(theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if bullet.legend { legend }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func mark(_ mark: TutorialBullet.Mark) -> some View {
        switch mark {
        case .symbol(let name):
            Image(systemName: name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.accent)
        case .icon(let name):
            Icon(name, size: 15, color: theme.accent)
        case .text(let text):
            Text(text)
                .font(.footnote.weight(.bold))
                .foregroundStyle(theme.accent)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// The statuses' colors, as the list draws them.
    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([(AgentStatus.blocked, "needs you"), (.done, "done"), (.working, "working")], id: \.1) { status, label in
                HStack(spacing: 5) {
                    Circle().fill(theme.color(for: status)).frame(width: 8, height: 8)
                    Text(label)
                        .font(.footnote)
                        .foregroundStyle(theme.muted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: What to do

    @ViewBuilder
    private var actions: some View {
        let tour = Tutorial.shared
        switch step.kind {
        case .welcome:
            HStack {
                secondary("Not Now") { tour.end() }
                Spacer()
                primary("Start Tour") { tour.next() }
            }
        case .finish:
            HStack {
                secondary("Keep Exploring") { tour.end() }
                Spacer()
                primary(Self.hasHosts ? "Back to Hosts" : "Add My Mac") { tour.finishAddingHost() }
            }
        case .normal:
            HStack(alignment: .center, spacing: 10) {
                if succeeded {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.color(for: .done))
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else if !lost, let action = phase?.action ?? step.action {
                    Label {
                        Text(action).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: symbol)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .transition(.opacity)
                    .id(action)
                }
                Spacer(minLength: 8)
                if !succeeded, step.isExplanation || lost {
                    primary("Next") { tour.next() }
                }
            }
            // As tall as Next where it is.
            .frame(minHeight: !succeeded && (step.isExplanation || lost) ? 38 : nil)
            .animation(.snappy(duration: 0.25), value: succeeded)
            .animation(.easeOut(duration: 0.2), value: phase?.action)
        }
    }

    /// The action's: its phase's own, its gesture's (the pointer resting: an ellipsis).
    private var symbol: String {
        if let phase { return phase.symbol ?? phase.gesture?.symbol ?? "ellipsis" }
        return step.gesture?.symbol ?? "hand.tap.fill"
    }

    /// Asking before the tour ends.
    @ViewBuilder
    private var confirm: some View {
        let tour = Tutorial.shared
        Text("End the tour?")
            .font(.headline)
            .foregroundStyle(theme.foreground)
        Text("You can take it again from the host list or Settings.")
            .font(.subheadline)
            .foregroundStyle(theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        HStack {
            secondary("Continue") { tour.confirmingSkip = false }
            Spacer()
            primary("End Tour") { tour.end() }
        }
        .padding(.top, 14)
    }

    private func primary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.accentForeground)
                .padding(.horizontal, 18)
                .frame(minHeight: 38)
                .background(theme.accent, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func secondary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.muted)
                .frame(minHeight: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @MainActor private static var hasHosts: Bool { !(Tutorial.shared.context?.app.hosts.hosts.isEmpty ?? true) }
}
