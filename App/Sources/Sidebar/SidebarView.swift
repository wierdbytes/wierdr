import SwiftUI
import WierdrModel

/// The sidebar (ui-spec §1–4): brand bar, spaces list, subscription limits, footer.
struct SidebarView: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            BrandBar()
            SpacesList()
            LimitsPanel()
            SidebarFooter()
        }
        .background(theme.chrome.ignoresSafeArea())
    }
}

/// Brand bar (§2): logo, "Wierdr", sidebar toggle. 46 pt. Go to (Herdr's search
/// button here) comes out of the spaces list pulled down past its top (`SpacesList`).
struct BrandBar: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @Environment(\.isCompactLayout) private var isCompact

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 8) {
                Image("BrandMark")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text("Wierdr")
                    .font(.ui(13.5, .semibold))
                    .foregroundStyle(theme.foreground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            // Go to is a pull of the list; VoiceOver's is here.
            GoToAccessibilityButton()
            if !isCompact {
                // On iPhone the panel is pushed over the sidebar instead.
                ChromeIconButton(icon: "sidebar", label: "Hide Sidebar") { controller.toggleSidebar() }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 46)
        .clearsWindowControls()
    }
}

/// Footer (§3): Settings. 41 pt.
struct SidebarFooter: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button { controller.showSettings = true } label: {
            HStack(spacing: 9) {
                Icon("settings", size: 14, color: hovering ? theme.foreground : theme.muted)
                Text("Settings")
                    .font(.ui(13))
                    .foregroundStyle(hovering ? theme.foreground : theme.muted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovering ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .hoverEffect(.highlight)
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Hairline() }
    }
}
