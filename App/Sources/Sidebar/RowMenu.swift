import SwiftUI
import UIKit

/// An item of a row's long-press menu, as data: drawn as UIKit's menu in the sidebar's
/// upside-down list (`SpaceListDragDrop`, with the row drawn afresh as its preview), as
/// SwiftUI's elsewhere (`PhoneMenuButtons`), and as VoiceOver's actions on the row.
struct PhoneMenuItem: Identifiable {
    enum Icon {
        /// An asset (`MenuIcon`).
        case asset(String)
        case system(String)
    }

    var title: String
    var icon: Icon
    var destructive = false
    var run: () -> Void

    var id: String { title }
}

/// A row's menu: sections of items, divided by lines.
typealias PhoneMenu = [[PhoneMenuItem]]

enum PhoneMenuBuilder {
    /// The menu as UIKit's (`UIContextMenuInteraction`).
    @MainActor static func uiMenu(_ menu: PhoneMenu) -> UIMenu {
        UIMenu(children: menu.filter { !$0.isEmpty }.map { section in
            UIMenu(options: .displayInline, children: section.map { item in
                UIAction(title: item.title, image: uiImage(item.icon),
                         attributes: item.destructive ? .destructive : []) { _ in item.run() }
            })
        })
    }

    @MainActor private static func uiImage(_ icon: PhoneMenuItem.Icon) -> UIImage? {
        switch icon {
        case .asset(let name): return MenuIcon.uiImage(name)
        case .system(let name): return UIImage(systemName: name)
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
                Button(role: item.destructive ? .destructive : nil) { item.run() } label: {
                    switch item.icon {
                    case .asset(let name): Label(item.title, image: name)
                    case .system(let name): Label(item.title, systemImage: name)
                    }
                }
            }
        }
    }
}

/// An empty view behind a row of the sidebar's upside-down list, so the list's own menu
/// interaction (`SpaceListDragDrop`) finds the row held, its menu and how to draw it.
/// SwiftUI's `contextMenu` can't be used there: its pictures of a view in the flipped
/// list come out upside down (held, before the menu) and morph through a line.
struct RowMenuMarker<Picture: View>: UIViewRepresentable {
    var id: String
    var markers: NSHashTable<RowMenuMarkerView>
    var menu: () -> PhoneMenu
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
        view.picture = { size in AnyView(picture(size).environment(\.self, environment)) }
        markers.add(view)
    }
}

final class RowMenuMarkerView: UIView {
    var id: String?
    var menu: () -> PhoneMenu = { [] }
    var picture: (CGSize) -> AnyView = { _ in AnyView(EmptyView()) }
}
