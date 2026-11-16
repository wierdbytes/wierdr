import SwiftUI

/// Go to in the iPhone layout: a screen pushed over the list and the pane screen as a
/// pane screen is, from the right, and popped the same way, a swipe right anywhere on it
/// (`PhoneNavController.setGoTo`, its `swipe`); as Telegram's archive comes out of its
/// pulled chat list. This is its content: `QuickSwitcher` in its panel form, its list
/// fading under the status bar as the iPhone list's does.
///
/// The safe area's bottom (the home indicator's) goes to the field's bar
/// (`QuickSwitcher.barBottom`), not to the list as its safe area, which its scroll view
/// wouldn't count as its inset (its last rows would rest under the field): the field
/// 28 pt over the card's bottom (as the list's header row and the message field), 8 pt
/// without a home indicator. The card keeps over the keyboard, its bottom 20 pt behind it,
/// so the field is 8 pt over the keyboard (`PhoneNavController.layoutGoCard`).
struct PhoneGoToRoot: View {
    let context: PhoneHostContext

    var body: some View {
        QuickSwitcher(inPanel: true, barBottom: context.insets.bottom > 0 ? 28 : 8)
            .overlay(alignment: .top) {
                PhoneEdgeFade(edge: .top, height: PhoneEdgeFade.statusBar(context.insets.top))
                    .ignoresSafeArea(.container, edges: .top)
            }
    }
}
