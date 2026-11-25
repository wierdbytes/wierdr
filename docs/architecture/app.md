# App layer (`App/Sources`)

What each folder of `App/Sources` holds. The sidebar (`Sidebar/`) has a file of its own:
[app-sidebar.md](app-sidebar.md).

## `App/`

`AppModel` (mode none/demo/live, hosts, per-host screen state), `AppServices` (seams the UI calls),
`Host`/`HostStore`.

## `Session/`

`HostSession` (SSH → `CoreConnection` → `WorkspaceEngine` + `TerminalSessionPool`, reconnect loop
with backoff, foreground health check, TOFU host-key question, its `DaemonState` and
`IntegrationsState` probed on each live connection), `LiveConnector` (implements `AppServices`:
connect/disconnect, key, passwords in Keychain, live terminal views, install key), host-key alert.

## `Connect/`

Host list (the password prompt: `AppModel.passwordRequest`, asked for each connection to a password
host, never stored), host editor (address, user, key or password, the public key).

## `Workspace/`

`WorkspaceView` (NavigationSplitView), `WorkspaceController` (commands for buttons/menus/shortcuts,
pending selection, dialogs, toasts), `WorkspaceCommands` (menu bar / ⌘ shortcuts).

## `Sidebar/`

See [app-sidebar.md](app-sidebar.md).

## `Panel/`

`TabBar` (the iPad's, in the app's glass, `composerGlass`: the sidebar button, which hides the
docked sidebar and docks the hidden one; the active space's tabs as glass capsules, `TabPill`, named
as their sidebar rows, `subject`: the focused pane if it runs an agent, else the first agent, else
the focused one; the status as a keyline; laid out by `TabStripLayout`, whole while they fit, else
the widest cut to a common width, not under 84 pt, then scrolled; held, the sidebar's own menu and
drag (`TabDrag.swift`: `TabDrag`, the state, as `SpaceDrag`: pressing, the tab whose menu is out,
the dragged one shown as a dashed slot, the bar's order meanwhile, `Lane`, until the workspace has
it; `TabDragDrop` puts `ListPressRecognizer` on the window's root view, taking only touches on a
tab, `TabMarker`, and shows `ListMenuOverlay` with no picture (the tab stays, seen through a hole
in the dim: its glass can't be drawn afresh) with `TabMenu`: Mark Idle or Mark Unread as the
sidebar rows', rename, the focused pane's split, zoom and close under its name, close tab; moved
along the bar, the tab follows the finger as a `LiftedCard`, `TabPicture`, and lands with `tab.move`;
`TabDragHost` behind the strip attaches it); the tabs' glass not in a container, not interactive;
the + new menu, `NewMenu`), pane tree with weights (the pane header without buttons: its commands
are in the tab's menu and its own), pane cards/headers, the message field under the panes
(`ComposerBar`), terminal view seam (`TerminalViewProvider`), demo terminal (`DemoTerminalView`,
drawn; with what was sent to it) and the demo's agents answering (`DemoAgents`,
`WorkspaceController.demo`: a message from the field is the prompt, ~3 s working, then a canned
reply and done; ⏎/y/1/2 or esc/n/3 from the key panel answer one that's blocked; through
`Workspace.changeLocally`). `SubAgentPeek`: a sub-agent without a pane over the window (iPad;
`WorkspaceController.peek`), with Keep/Close; the iPhone shows `peek` on `PhonePaneScreen` in its
parent's place. `KeyLayerHost`: the iPad's one key panel (`KeyPanelLayer` on a clear rect laid over
the panes' frame, `controller.keyArea`, reported by `TerminalPanel`), drawn over the whole window,
so over the sub-agent's window too, for the focused pane's terminal or the sub-agent looked at
(`controller.keys`).

## `Phone/`

The iPhone (and narrow iPad window) layout, after Telegram's chat list and chat:
`PhoneWorkspaceView` (Telegram's navigation: the list is the root screen and the pane screen is
pushed over it while `compactColumn == .detail`; `PhoneNavController`, a UIKit container, moves both
screens by Core Animation at a progress (the pane's at (1 − p)·W, its card `PhoneCardView` with the
display's corners and a faint shadow while it moves; the list at −0.3·W·p under a black dim): a
finger sets the layers, pushes and pops are SwiftUI's springs played as keyframes by the render
server (`PhoneSpring`: critically damped 0.3 s, or damping 0.85 from the finger's speed, stopping at
its end); each screen is a hosting controller filling the window (`PhoneHosting.swift`:
`PhoneHosted` carries the app's environment over, `PhoneHostContext`, and the container's safe area,
UIKit's being ignored as it changes while a view moves); while a finger moves the pane screen or the
agents panel, `PhoneFrameRateBoost` asks the display for 120 Hz
(`CADisableMinimumFrameDurationOnPhone` in Info.plist); `PhoneBackSwipe` (a pan on the window's root
view, `PhoneBackSwipeRecognizer`: Telegram's 2-pt start rule, every other pan waits for it, the key
panel's first while it's out) and `PhonePopTracker` (UIKit's release rule) for the swipe back;
popped, the pane screen leaves the hierarchy; attention banner), the list screen is the sidebar
(`Sidebar/SidebarView`, the space cards, as on the iPad; nothing selected on it), the rows' pieces
it draws are here: `PhoneListRow` (Telegram's chat-row frame: the pinned background, the press
highlight, the iPad's selection, separators, its ground `rowGround`, Telegram's swipe actions,
`PhoneRowSwipe`: `PhoneRowPan`, round buttons, full swipe), `PhoneAgentRow` (the rows' contents: an
agent's two lines (its bot and `>_` chips apart), a sub-agent's two (its dot in the marks' column;
under the title, as an agent's, its context ring, model and its `>_` chip), a terminal's, a 7501
record's: a sub-agent's or teammate's two as a pi sub-agent's, from `TaskRecord.meta`, a shell's
one; `PhoneModelLine` takes a terminal's `agent.*` or a record's meta; the tree's lines and axes are
`Sidebar/SidebarRows`' `TreeLines` and `Tree`), `PhoneLimits` (per account its icon and a
`LimitRing` per limit, the old sidebar's bar bent round, its mark inside, `Limits.symbol`; a tap
shows the account's limits in a popover over it); the order is `Workspace.phoneList(space:)`,
Telegram's, pinned by pin time (`herdr.pinned` holds it, `TerminalInfo.pinnedAt`); `PhonePaneScreen`
(top bar, Telegram's chat header in the message field's glass (`ComposerGlassGroup` /
`composerGlass` from `Input/ComposerBar`): 44-pt pills, Telegram's back button "‹", or "‹ (N)" while
other agents aren't idle (`WorkspaceController.attention(excluding:)`), the title capsule ringed
with the agent's status (a 1.5-pt keyline on the glass, as the Dynamic Island's: glass of another
tint doesn't merge with the list button's as it goes into the capsule and comes back out of it),
title over space; the bar floats over the terminal (the screen keeps its collapsed 56 pt), so a tap
on the capsule can grow it (left over the list button, always; down over the terminal, which keeps
its size, for a title cut on one line) and slide the pane menu down (`PhonePaneMenu`, its own glass
panel rather than a system `Menu`, which on iOS 26+ morphs out of its label and hides it) under the
capsules' row (not in the capsule's column, which moves left as it grows), over a layer that takes
the tap that closes it; the terminal and under it the message field, `Input/ComposerBar`, the key
panel over the terminal), `PhoneKeyPanel` (key column pulled out over the terminal, its keys pills
in the same glass, one `ComposerGlassGroup`, ⏎ with the send button's accent pill; scrolls rest
where the end key shows whole and the next one half (`restRange`); less room moves the keys only to
keep that, animated, more room leaves them; a constant empty room above and below the keys and
Hide's place kept, the limits only where a finger's scroll ends (`KeyColumnStops`), the app's own
scrolls to an offset (`ScrollPosition`); see `Input/`: keys → `TerminalSession.send(key:)`,
clipboard text → `send(text:submit: false)` or into the message). `WorkspaceView` picks it when
`Device.isPhone` or the width is compact; `WorkspaceController.singlePane` makes "seen" follow the
one pane on screen.

## `Input/`

`ComposerBar`: the message field, always under the terminal (iPhone), under all the panes (iPad, for
the focused one) and at the bottom of a sub-agent's window, hidden while the terminal has the
keyboard itself; Telegram's composer (geometry, glass, motion: `ComposerMotion`) in the theme's
colors: the attach menu (photo, file, clipboard image → `TerminalSession.put`,
`Support/ImageForAgent`, the path into the draft), the field (`ComposerTextView`, a `UITextView`:
one truncated line without the keyboard, grows to Telegram's cap with it; on the iPad a 1-pt input
accessory for `KeyboardCover`), the send button inside it (one paste + Return via
`TerminalSession.send(text:submit:)`); drafts in `WorkspaceController.drafts`, the field with the
keyboard is `WorkspaceController.composing`. `KeyPanelLayer`: the key panel (`PhoneKeyPanel`) over a
terminal area and how it and the keyboards come, shared by the iPhone screen and the iPad panel: a
swipe to the left anywhere on a terminal (`PhoneKeyPanelGestures`, on the window's root view: the
terminal's pans wait for it; ⏎ comes out where the swipe began); VoiceOver: the terminal's action
Keys (`WierdrTerminalView.appActions`). The terminal's own keyboard comes with a finger's double tap
on it (`WierdrTerminalView`); while a keyboard is up, a double tap hides it (the field down to one
line).

## `Terminal/`

SwiftTerm integration: `TerminalSession` (one attach stream ↔ one emulator,
grid/FACTS/RESIZE/FOCUS/credit, reattach), `TerminalSessionPool` (per-address sessions, detach when
hidden), `TerminalSurface` (SwiftUI), key bar, theme, keymap, `ScrollCoast` (inertia for the
scrolls a program takes, fed to SwiftTerm's own handlers), `KeyboardCover` (the iPad sidebar's
and panel's bottom inset, measured from the key bar, or the message field's empty accessory
(`ComposeAccessory`), instead of SwiftUI's keyboard safe area, which iPadOS gets wrong with the
floating keyboard).

## `Theme/`

Atom One Dark / Paper colors, Geist + JetBrains Mono (the sidebar's and the panel's text; mono for
models, effort, ages, folders), icon assets.

## `Activity/`

`LiveActivities`: this iPhone's push-to-start token (ActivityKit) written to the connected
computer's `wierdr-push` document whenever a session goes live (`HostSession.onLive`) or the token /
Live Activities setting changes, after it took the computer's seal key from `wierdr-push-seal` into
the App Group (`ActivitySeal.store`; the entry's `seal_kid`) and its push relay grant
(`RelayRegistration.swift`: the WierdrRelay registration on DeviceCheck; checked with the relay on
each connection; the entry's `relay_grant`); ends a second activity. `apnsEnvironment`: the
profile's `aps-environment`, `production` without a profile (TestFlight, App Store).
`AppModel.openAgent`: a tap on an agent in the activity (`onOpenURL`). The widget extension
`App/Widgets` (target `WierdrWidgets`, `pw.xff.wierdr.widgets`) draws the activity: Lock Screen and
Dynamic Island.

## `Setup/`

What the connected computer has for Wierdr, and setting it up ([host-setup.md](../host-setup.md)):
`DaemonState` (wierdrd, [wierdrd.md](../wierdrd.md): the last probe, an action running, its error;
`perform` runs Install / Start / Update with Homebrew and probes until it runs) and
`IntegrationsState` (the harnesses found and Wierdr's integration in each; `install` one at a time,
then probe), both per `HostSession` and probed on each live connection; `DaemonRows`,
`IntegrationRows` (state, why, the button, the commands behind it: rows shared by the sheet and
Settings), `HostSetupSheet` (Daemon, Agent Integrations), `SetupOffer` (`.setupOffer()` on
`WorkspaceView`: the sheet once per host, after its first connection's two probes, when something
wants the person; `setup.checked.<host id>`). Settings → Daemon (`DaemonSection`: the rows and, on
the iPhone, the Live Activity's registration) and Agent Integrations (`IntegrationsSection`), in
`Settings/SettingsView.swift`.

## `Tutorial/`

The tour, a scenario per layout, picked as it starts by the window's (`Tutorial.phone`,
`phoneLayout`): the iPhone layout's (`TutorialStep.phone`, an iPad's narrow window too) and the
iPad's split view (`TutorialStep.pad`); a window changing layout under it ends it. `Tutorial` (the
engine, a singleton: steps, `chapters`, `start`/`restart`/`end`, `progress(of:)` by chapter, the
signals the app reports, `report(_:open:)` and `reportMessage`, for what isn't observable state: the
list's menu (`SpaceDrag.menuLifted`), the pane menu and the key panel (`PhonePaneScreen`; the iPad's
key panel, `KeyLayerHost`), the iPad's sidebar overlay (`SidebarOverlay`), the limits' popover
(`PhoneLimits`), demo messages (`DemoAgents`); a menu out that the step didn't ask for is a `detour`
(nothing dimmed, blocked or hinted); `watch` follows a step's `done` with `withObservationTracking`,
then `succeed` holds the result for the step's `settle` (the card's ✓); a step away from its place
(`TutorialPlace`: host list, list, an agent's pane, a sub-agent's peek, the iPad's pane with the
sidebar hidden, `bare`; `TutorialContext.isIn` reads them for the layout: on the iPad the list is
the sidebar shown, a pane the focused one, a peek its window) is taken back (`prepare`, the iPad's
`preparePad`); an `extra` step already done is skipped; `tour.seen` in UserDefaults),
`TutorialSteps` (`TutorialStep`: title, `text`, `bullets` (`TutorialBullet`, the statuses'
`legend`), `note`, `action`, `anchor`/`gesture`, `also`, `spotlight`, `near`, `phases`
(`TutorialPhase`: another action and pointer while a condition holds or an anchor shows), `chapter`
(`TutorialChapter`); `TutorialContext`, `TutorialSignals`, the scenarios `TutorialStep.phone` and
`TutorialStep.pad`), `TutorialAnchor` (`tutorialAnchor(_:)`: an empty UIKit marker behind a view
while a step points at it, `TutorialAnchors` finds its frame on screen through the presentation
layers, `union` for the many rows of an agent's `tree`, `covered` when something else is on top at
its middle (a free step's system menu: no ring or pointer then); `tutorialAnchorsOff` in
`ImageRenderer` pictures), `TutorialOverlay` (`TutorialPresenter`: its own window over the app's,
`TutorialWindow`, whose `hitTest` lets a finger through to the app only at the step's anchors and
its phase's pointer (everywhere in a free step or a detour; on an explanation's hole it's Next); a
display link following the anchors and the phase into `TutorialOverlayModel`; the SwiftUI overlay:
the dim (`TutorialDim`: one layer, the hole and the spotlight cut out, `also` lightly dimmed), the
ring (breathing for a gesture, still for an explanation, none round what fills the screen), the
pointer (`PointerPath`: waits 0.7 s, small targets briefly; Reduce Motion: still), the card placed
by what the step shows, beside a key column, clear of the keyboard; in the iPad's tour beside what
it shows, at its height, where there's room, `cardCenter`), `TutorialCard` (chapter progress, text,
bullets, action or Next, ✓ Done; Dynamic Type). Started by `WierdrApp` (`startIfFirstLaunch`; DEBUG
`-tour YES` or `-tour <step id>`), the host list's and Settings' Take the Tour.

## `Debug/`

DEBUG-only: `LiveActivityDemo` (`-live-activity-demo YES`: a local activity with sample agents),
terminal lab (`-terminal-lab YES`), simulator auto-connect hooks (`WIERDR_AUTOCONNECT`,
`WIERDR_IMPORT_KEY`, `WIERDR_TRUST_HOSTKEY`, `WIERDR_DEBUG_STEPS`).

## End-to-end test in the simulator

```sh
scripts/test-sshd.sh start            # throwaway sshd on 127.0.0.1:2222 (test key only)
make sim-build
SIM="Wierdr iPad Pro 13 (M4)"
xcrun simctl install "$SIM" build/DerivedData/Build/Products/Debug-iphonesimulator/Wierdr.app
SIMCTL_CHILD_WIERDR_IMPORT_KEY=/tmp/wierdr-sshd/client_ed25519 \
SIMCTL_CHILD_WIERDR_AUTOCONNECT="$(id -un)@127.0.0.1:2222" \
SIMCTL_CHILD_WIERDR_TRUST_HOSTKEY=1 \
SIMCTL_CHILD_WIERDR_DEBUG_STEPS='sleep 3;newSpace;sleep 4;renameSpace e2e;newTab;sleep 3;split right;sleep 20;closeSpace' \
  xcrun simctl launch "$SIM" pw.xff.wierdr
```
