import SwiftUI

/// A step's hint: where it is in the tour and Skip, its title and text, and what to do:
/// the gesture to make (the pointer shows it on the anchor) or Next. The welcome card
/// starts the tour or not; the last one adds your Mac or keeps you in the demo. Skip asks
/// first, in the card.
struct TutorialCard: View {
    var step: TutorialStep
    /// 1-based.
    var number: Int
    var count: Int
    /// The step's anchor didn't show: Next instead of waiting for the gesture.
    var lost: Bool

    @Environment(\.theme) private var theme

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
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var content: some View {
        if step.kind == .normal { progress.padding(.bottom, 10) }
        Text(step.title)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(theme.foreground)
            .accessibilityAddTraits(.isHeader)
        Text(step.text)
            .font(.system(size: 15))
            .foregroundStyle(theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        actions.padding(.top, 14)
    }

    /// "4 of 25", a bar, and Skip.
    private var progress: some View {
        HStack(spacing: 10) {
            Text("\(number) of \(count)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.dim)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.border)
                    Capsule().fill(theme.accent)
                        .frame(width: geo.size.width * CGFloat(number) / CGFloat(max(1, count)))
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
            Button("Skip") { Tutorial.shared.confirmingSkip = true }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.muted)
                .buttonStyle(.plain)
                .accessibilityHint("Ends the tour")
        }
    }

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
            HStack {
                if let gesture = step.gesture, !lost {
                    Label(gesture.label, systemImage: gesture.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .labelStyle(.titleAndIcon)
                } else if step.free {
                    Text("Waiting for you")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.dim)
                }
                Spacer()
                if step.gesture == nil && !step.free || lost {
                    primary(number == count ? "Done" : "Next") { tour.next() }
                }
            }
        }
    }

    /// Asking before the tour ends.
    @ViewBuilder
    private var confirm: some View {
        let tour = Tutorial.shared
        Text("End the tour?")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(theme.foreground)
        Text("You can take it again from Settings.")
            .font(.system(size: 15))
            .foregroundStyle(theme.muted)
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accentForeground)
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(theme.accent, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func secondary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.muted)
                .frame(height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @MainActor private static var hasHosts: Bool { !(Tutorial.shared.context?.app.hosts.hosts.isEmpty ?? true) }
}
