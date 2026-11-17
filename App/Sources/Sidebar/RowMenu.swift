import SwiftUI
import UIKit

/// An item of a long-press menu, as data: drawn as the list's own menu in the sidebar
/// (`ListMenuOverlay`, Telegram's), as SwiftUI's elsewhere (`PhoneMenuButtons`), and as
/// VoiceOver's actions on the row.
struct PhoneMenuItem: Identifiable {
    enum Icon {
        /// An asset (`MenuIcon`).
        case asset(String)
        case system(String)
    }

    var title: String
    var icon: Icon
    var destructive = false
    var disabled = false
    /// A submenu: chosen, it takes the menu's place (with a Back item on top).
    var children: PhoneMenu? = nil
    var run: () -> Void = {}

    var id: String { title }
}

/// A menu: sections of items, divided by lines.
typealias PhoneMenu = [[PhoneMenuItem]]

extension PhoneMenuItem.Icon {
    @MainActor var uiImage: UIImage? {
        switch self {
        case .asset(let name): return MenuIcon.uiImage(name)
        case .system(let name):
            return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        }
    }
}

/// The menu as SwiftUI's (a `contextMenu`'s content).
struct PhoneMenuButtons: View {
    var menu: PhoneMenu

    var body: some View {
        let sections = menu.filter { !$0.isEmpty }
        ForEach(sections.indices, id: \.self) { i in
            if i > 0 { Divider() }
            ForEach(sections[i]) { item in
                if let children = item.children {
                    Menu {
                        PhoneMenuButtons(menu: children)
                    } label: {
                        label(item)
                    }
                } else {
                    Button(role: item.destructive ? .destructive : nil) { item.run() } label: { label(item) }
                        .disabled(item.disabled)
                }
            }
        }
    }

    @ViewBuilder
    private func label(_ item: PhoneMenuItem) -> some View {
        switch item.icon {
        case .asset(let name): Label(item.title, image: name)
        case .system(let name): Label(item.title, systemImage: name)
        }
    }
}

/// An empty view behind a row of the sidebar's list (each block upside down in its host,
/// flipped back), so the list's own press (`SpaceListDragDrop`) finds the row held, its
/// menu, how to draw it and how to open it. SwiftUI's `contextMenu` can't be used there:
/// its pictures of a view in a flipped list came out upside down (held, before the menu)
/// and morphed through a line.
struct RowMenuMarker<Picture: View>: UIViewRepresentable {
    var id: String
    var markers: NSHashTable<RowMenuMarkerView>
    var menu: () -> PhoneMenu
    /// The row's tap (a tap on it lifted opens it, as Telegram's chat preview).
    var open: () -> Void
    /// The row drawn afresh at its size (given the row's environment here).
    var picture: (CGSize) -> Picture

    func makeUIView(context: Context) -> RowMenuMarkerView {
        let view = RowMenuMarkerView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: RowMenuMarkerView, context: Context) {
        let environment = context.environment
        let picture = picture
        view.id = id
        view.menu = menu
        view.open = open
        view.picture = { size in AnyView(picture(size).environment(\.self, environment)) }
        markers.add(view)
    }
}

final class RowMenuMarkerView: UIView {
    var id: String?
    var menu: () -> PhoneMenu = { [] }
    var open: () -> Void = {}
    var picture: (CGSize) -> AnyView = { _ in AnyView(EmptyView()) }
}
