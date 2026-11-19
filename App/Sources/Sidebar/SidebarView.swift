import SwiftUI
import WierdrModel

/// The sidebar, one for the iPhone (the list screen under the pane screen) and the iPad
/// (the split view's column and the overlay over a hidden one), turned for one hand:
/// the space cards drawn bottom up (`SpacesList`: the first space lowest, each card's
/// agents in the iPhone's rows, the newest and pinned lowest), and the header floating
/// over the list's bottom (`SidebarHeader`: the limits, settings, the agents' counts and
/// +). The list runs to the screen's top (its rows scroll under the status bar) and under
/// the header. Go to comes out of the list pulled up past its bottom (`PullToSearch`).
///
/// In the iPhone layout the connection's banner and the toasts show over the header too
/// (the iPad's panel has its own).
struct SidebarView: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @State private var safeTop: CGFloat = 0
    @State private var safeBottom: CGFloat = 0

    var body: some View {
        let bottomGap = SidebarHeader.bottomGap(safeBottom: safeBottom)
        let headerHeight = SidebarHeader.height + bottomGap
        ZStack(alignment: .bottom) {
            SpacesList(topInset: safeTop, bottomInset: headerHeight)
                .overlay {
                    // The tour's pull to Go to: the list between the status bar and the header.
                    Color.clear
                        .padding(.top, safeTop)
                        .padding(.bottom, headerHeight)
                        .tutorialAnchor(.list)
                        .allowsHitTesting(false)
                }
            PhoneEdgeFade(edge: .top, height: PhoneEdgeFade.statusBar(safeTop))
                .frame(maxHeight: .infinity, alignment: .top)
            PhoneEdgeFade(edge: .bottom, height: headerHeight)
            SidebarHeader()
                .padding(.bottom, bottomGap)
            if controller.singlePane, case .failed = controller.workspace.phase {
                // The reason and Retry, over the header (its title says "Not Connected").
                ConnectionBanner(inset: headerHeight + 8, edge: .bottom)
            }
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .overlay(alignment: .bottom) {
            if controller.singlePane {
                // Over the header (this overlay keeps to the safe area).
                ToastStack().padding(.horizontal, 12).padding(.bottom, headerHeight - safeBottom + 10)
            }
        }
        .background(theme.chrome.ignoresSafeArea())
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: {
            safeTop = $0.top
            safeBottom = $0.bottom
        }
    }
}
