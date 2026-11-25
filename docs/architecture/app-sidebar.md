# App layer: `App/Sources/Sidebar/`

The sidebar, one for both layouts (the iPhone's list screen, the iPad's split-view column and its
overlay), turned for one hand: `SidebarView` (two screens in its own UIKit container,
`SidebarNavController`, moved as the iPhone's pane screen over its list: `SpacesSidebar`, the list
under the status bar and the header, Telegram's edge fades over both; over it the agents panel,
`AgentsPanel` in `AgentsPanelRoot`, pushed from the right by the ring's tap or ⌘P
(`WorkspaceController.openAgents`: `showAgents`, `agentsAtOnce` when the sidebar was covered,
`agentsSearchPending` for ⌘P's focus) and popped by a swipe right anywhere on it (`PhoneBackSwipe`
on the container's view, which doesn't move, enabled while the panel is up, waiting for a row's own
swipe where one takes the touch, `yieldsToRows`; its card a `PhoneCardView`, the spaces at −0.3·W·p
under a dim of 0.1·p, `PhoneNavController.push`/`.release` springs, `PhonePopTracker`); the
container clips, so on the iPad the panel comes from the sidebar's right edge, not over the panes;
each screen a `UIHostingController.moving` with its own `PhoneHostContext`, the sidebar's safe area
handed down; the panel leaves the hierarchy once popped; in the iPhone layout the connection banner
and the toasts over both), `SidebarHeader` at the bottom (one 44-pt row, its bottom 28 pt over the
screen's: at its left the subscription limits as rings, `SidebarLimits` over `PhoneLimits` in the
widest of its styles that fits, every ring, the headline ring by the icon, the headline ring alone,
then scrolled; in the middle the agents' statuses as one ring, `SidebarStatusRing` over `StatusRing`
(a dash per agent from the top, clockwise, the most urgent first in their colors, idle ones faint;
past 24 an arc per status, each at least a tenth; inside, the most urgent status's count; a tap
opens the agents panel; the dashes' trims animate), or the connection's state, `SidebarTitle`; at
its right + in a glass circle, `SidebarMenu`: Settings and a new space (the iPad hides its sidebar
with the tab bar's sidebar button); `SidebarHeaderRow` gives the ring its room first and the limits
what's left, and centers the ring when it fits), `SpacesList` (the list's SwiftUI side: its blocks,
`SpacesListBlock.blocks`, an item per card, drawn bottom up, headers too: this computer's spaces
lowest, the first space at the bottom, each added machine's group over them, a group's
`MachineHeader` under it; the empty note over it; on the iPad the focused pane's card comes into
view, through `SpacesListHandle`) over `SpacesListContent` (`Sidebar/SpacesListView.swift`, a
`UIViewControllerRepresentable`: `SpacesListController`, Telegram's `ListView`: a plain
`UIScrollView`, `SpacesListScroller`, hidden, only the physics, its pan moved onto the list's view,
`SpacesListView`, Telegram's `ListViewBackingView`, so UIKit's deceleration, rubber band, bounce and
catch are used unchanged; each block in its own `UIHostingController` (`PhoneHosted` with the list's
`PhoneHostContext`, plus its `SpaceDrag`, `PhoneRowSwipes`, `listMenus`), upside down with its
content flipped back (`SpacesListBlockRoot`, `flippedUp`), so a block grows and shrinks from its
bottom; built (realized) on screen and half a screen round it as it moves, and at rest two screens
ahead, one a run-loop turn (`schedulePrefetch`), measured before it shows (`sizeThatFits`), let go
past three screens; the built run is stacked up from its lowest block's bottom (`anchor`), which a
finger moves by the scroller's offset's step; the hosts sit in one view (`SpacesListBlocksView`,
`content`) that a step moves by its layer alone, so neither UIKit nor SwiftUI in each host hears of
it (they'd update every block every frame: two thirds of the main thread in a fling), and UIKit
hears where it is once the list is at rest (`announceContentOrigin`); while a finger scrolls it and
as it decelerates a display link asks for 120 Hz (`boostFrameRate`, Telegram's auxiliary display
link: else UIKit decelerates the hidden scroller at 80 Hz, then 60 and 48); the scroller's size and
offset are Telegram's `updateScroller` rule: both ends built, the exact sum of the heights; one end,
2 × 10000 with the offset kept from that end; neither, 2 × 10000 recentred; set with its scroll
events ignored. It rests at its start, the screen's bottom, short content there too, and anything
that grows, comes or goes keeps the bottom of the built run in place and moves only what's over it
in the same animation (but a block wholly under the screen, scrolled away from, changes downward, so
the screen stays): a block's own change animates in SwiftUI in its host (a card's fold,
`SpaceCard.fold`, a critically damped 0.35-s spring, the header a `geometryGroup` so its summary
comes in its place), an empty view behind it, `DrawnHeight`, reporting its height as drawn, frame by
frame, so the blocks over it move in the same frame; blocks that come, go or move among the others
(a machine's fold, a dragged card's lane) are the list's own animation on its display link, on the
transaction's curve known by name (`ListCurve`: `SpaceDrag.part`, else the fold's spring); its own
scroll to a block or to the start (`reveal`, the status bar's tap through
`SpacesListStatusBarTarget`, an empty scroll view behind the blocks) eases out toward a target taken
each frame, a far one laid out afresh a screen short of it (`jump`); its own scroll indicator;
VoiceOver reads the blocks on screen top to bottom, three fingers scroll a page; a tap off the rows
closes an open row, scrolling too; SwiftUI's context menu drew a view in the old flipped
`ScrollView` upside down, so the rows' menus and the headers' are the list's own, Telegram's
(`ListMenuOverlay`, below; a row's is `PhoneMenuItem`s, found by its `RowMenuMarker` under
`listMenus`)), `SpaceCard` (one view: at its bottom `SpaceHeader`, 44 pt, avatar, name, git tail,
the agents' `StatusBadges` while folded, the chevron pointing up while open; a tap selects the space
on the iPad and folds it in the iPhone layout; held, its menu, `SpaceHeaderMenu`, the list's own
(`ListMenuOverlay`, the header drawn afresh, `SpaceHeaderBar`); over it its rows in the iPhone's
chat-row style, `PhoneListRow` on the card's surface (`rowGround`) with `PhoneAgentRowContent` /
`PhoneKidRowContent` / `PhoneRecordRowContent` / `PhonePaneRowContent`, in `PhoneListLine.lines` of
`Workspace.phoneList(space:)`: the terminals on top, the agents bottom up, pinned lowest, an agent's
tree (`SidebarRow.tree`: sub-agents, terminals, records) over it with `TreeLines.upward`; a record's
row has no swipes or menu, its tap is `WorkspaceController.open(_:in:)` (the terminal reporting it);
on the iPad the focused pane's row (or the sub-agent shown) is `selected`; folding is
`closedSpaces`), the agents panel (`AgentsPanel`: every agent in the list's rows by status,
`Workspace.agentsByStatus` (`InboxOrder`: needs you, done, working, idle, none; pinned, then the
newest), drawn bottom up as the list (`AgentsResults.lines`), each block upside down with its shown
tree (`shownTree`, a search's matches forced), the space's name as a chip on the row, no spaces and
no group headers; fuzzy filtered by agents', sub-agents' and records' titles, the best lowest,
Return the lowest; the list rests at its bottom (`defaultScrollAnchor(.bottom)`); a tap opens the
row's agent and the panel stays (on the iPad the focused pane's row `selected`); the rows have the
list's swipes and menus (`RowActions`, shared with `SpaceCardLine`), the swipes from the rows' edge
zones only, away from their edge (`edgeSwipesOnly`, `PhoneRowPan`'s `edgeOnly`,
`PhoneRowPanRecognizer.allowedDirection`: not the leftmost 16 pt, the panel's; the iPad overlay's
closing waits for them there (`PhoneRowPanRecognizer.goesFirst`; a spaces list row goes first at its
trailing edge or open, else waits for it)), the menus by the list's own press on the panel's view
(`SpaceListDragDrop` with the container's `SpaceDrag`, `listMenus` in the environment); the search
field at the bottom, `AgentsSearchField` over `AgentsSearchUITextField` (a `UITextField`: on the
iPad the composer's empty 1-pt accessory, which `KeyboardCover` measures, Esc closes the panel), not
focused as the panel comes, focused by ⌘P (`agentsSearchPending`, taken by the field that becomes
first responder: a hidden column's can't); a glass circle at its right puts the keyboard away while
it's up, and so does scrolling), `LimitsPanel` (the old sidebar panel's parts: bars, percent,
resets, which the rings' popover draws, `PhoneLimits`). `ListPressRecognizer` / `SpaceListDragDrop`
(attached by `SpacesListController` to the list's view, where its scroller's pan is; by
`SidebarNavController` to the agents panel's, rows only): the list's long press, Telegram's
`ContextGesture` (0.12 s, then the held item shrinks 15 pt narrower linearly for 0.2 s,
`SpaceDrag.pressing`; at 0.32 s, within 10 pt of where it came down, the menu; along with every
recognizer but a pan, so scrolling or a swipe lets it go, a chip doesn't; begun, it cancels the
others on its touch), on a header or a row with a menu (the markers say which; the item's identifier
is `space:` or `row:` and its id). `ListMenuOverlay` (Sidebar/ListMenu.swift): over the list's
screen in the iPhone layout (in `PhoneNavController`'s view right over the list, so the pane screen
pushed by a row opened from it or by Split Right slides over the menu as it goes), else over the
window; the item drawn afresh (`ImageRenderer`) and lifted over a blur dimmed 60 % (the iPad: a 40 %
dim, no blur), the item itself hidden in the list meanwhile (`SpaceDrag.menuLifted`), the menu
`ListMenuView` under it, 7 pt, at the item's left edge in the screen's left half, else at its right,
both moved up together when they don't fit; a medium haptic, one spring (ζ 0.775, 0.42 s), the menu
growing out of the item's bottom edge; the holding finger lights the item under it past 4 pt (a
selection haptic on each change) and runs it let go; a new touch on the menu too; a tap elsewhere
puts it away (on a lifted row, opens it, the picture fading where it is); a submenu
(`PhoneMenuItem.children`) takes the page's place with Back on top; away in 0.2 s, the item back
where the list has it once an item's work is laid out. `ListMenuView`: the glass panel
(`UIGlassEffect` on iOS 26+, a material on 18), 220–260 pt, 43-pt items, 20-pt dividers between
sections, the lit item's pill. `SpaceDrag`: reordering cards by their header, the same press: a
header's menu, the finger gone off it and off the lifted header (12 pt; 24 pt round the menu), puts
it away at once and lifts the card, which follows the finger (`LiftedCard` in the window, rendered
by `SpaceDragPreview`; a display link holds it where the finger took it, on the list or off it, and
scrolls the list near its top or bottom, `SpacesListView.scroll(by:)`); a pointer's press on a
header moved on drags at once; the drag works in the window's coordinates, the list's own being
upside down (`SpaceMarker` views behind each card and header say where they are); let go over the
list it lands in its slot with a crossfade, off it it flies back; the list shows the machine's
spaces in the drag's lane order (bottom up), the dragged card as its dashed slot; the drop is
`Workspace.moveSpace` (`space.move`).
