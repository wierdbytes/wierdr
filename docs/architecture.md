# Wierdr architecture

Wierdr is a native iPadOS/iOS client of **herdr-core** (`hc`). It shows the same
spaces, tabs, panes and agents as the Herdr desktop app (`herdr-app`) and lets
you work in their live terminals.

```
iPad (Wierdr)                                   Mac (or any machine with hc)
┌──────────────────────────────┐   SSH (port 22) ┌──────────────────────────┐
│ SwiftUI  (App/Sources)       │ ──────────────▶ │ sshd → `hc connect`      │
│   Sidebar · TabBar · Panes   │   exec channel  │   JSON-RPC + frames      │
│   SwiftTerm terminal views   │                 │ herdr-core (terminals,   │
│ WierdrModel (store)          │                 │   agents, docs, machines)│
│ HerdrCore (protocol client)  │                 │ herdr-app (desktop) uses │
│ HerdrSSH  (SwiftNIO SSH)     │                 │   the same core + doc    │
└──────────────────────────────┘                 └──────────────────────────┘
```

## Layers

| Layer | Where | Depends on | Responsibility |
|---|---|---|---|
| `HerdrCore` | `Packages/WierdrKit/Sources/HerdrCore` | Foundation | herdr-core API client: `CoreTransport` (byte pipe), framing codec, JSON-RPC calls on channel 0, attach streams (DATA/CREDIT/CLOSE/RESIZE/FOCUS/FACTS), event subscription, typed records, `JSONValue` for opaque documents. `ProcessTransport` (macOS only) spawns a local `hc connect` for tests and the CLI. |
| `HerdrSSH` | `Packages/WierdrKit/Sources/HerdrSSH` | HerdrCore, SwiftNIO SSH, swift-crypto | `SSHTransport`: SSH session + exec of `hc connect` as a `CoreTransport`. Auth: Ed25519 key (generated on device, kept in Keychain) or password. Host keys: trust on first use. |
| `WierdrModel` | `Packages/WierdrKit/Sources/WierdrModel` | HerdrCore | The Herdr world: machines, spaces, tabs, pane trees, terminals, agents and statuses, built from the `herdr-app` document(s) + the terminal event stream. Commands that change it (new space/tab, close, rename) with the same semantics as herdr-app. |
| App | `App/Sources` | all of the above, SwiftTerm | SwiftUI UI: connection screen, sidebar, tab bar, pane cards, terminal views (SwiftTerm `TerminalView` fed by attach streams), theme. |
| `WierdrActivity` | `Packages/WierdrKit/Sources/WierdrActivity` | Foundation | The agents Live Activity's data, shared by the app, its widget extension and the Mac: `AgentsActivityAttributes` (+ `ContentState`, `Agent`; `ActivityAttributes` on iOS), the `wierdr-push` registration document (`PushRegistry`), `AgentLink` (`wierdr://agent?t=…`). |
| `WierdrPush` | `Packages/WierdrKit/Sources/WierdrPush` | WierdrModel, WierdrActivity, swift-crypto | The Mac side of the Live Activity: `ActivitySummary` (workspace → content state), `Planner` (pure: when to start/update/end), `ActivityPayload` (`aps` JSON), `APNsSigner`/`APNsClient` (JWT, push-to-start, broadcasts, channels), `Pusher` (the loop: read-only engine + registry + APNs). See [live-activity.md](live-activity.md). |
| `wierdr-cli` | `Packages/WierdrKit/Sources/wierdr-cli` | all packages | macOS debugging tool against the local core (`hc connect`) or over SSH. |
| `wierdr-push` | `Packages/WierdrKit/Sources/wierdr-push` | WierdrPush | macOS daemon (`run`, `status`, `reset`) behind the Live Activity; `scripts/push-agent.sh` installs it in launchd. |

Rules:
- `HerdrCore` and `WierdrModel` are platform-neutral and unit-testable on
  macOS (`swift test`). Nothing UIKit there.
- The app target holds only UI and UI glue. Everything the iPhone version
  will reuse lives in the package.
- Swift 6 toolchain, Swift 5 language mode.

## Build

```
make project        # xcodegen → Wierdr.xcodeproj
make test           # swift test in Packages/WierdrKit
make sim            # build + run in the iPad Pro 13" simulator
make device         # signed Release build for a real device (CONFIG=Debug for debug)
make install        # build + install on the connected iPad (devicectl)
make ipa            # dist/Wierdr.ipa (development signing)
```

## App layer (App/Sources)

| Folder | What |
|---|---|
| `App/` | `AppModel` (mode none/demo/live, hosts, per-host screen state), `AppServices` (seams the UI calls), `Host`/`HostStore`. |
| `Session/` | `HostSession` (SSH → `CoreConnection` → `WorkspaceEngine` + `TerminalSessionPool`, reconnect loop with backoff, foreground health check, TOFU host-key question), `LiveConnector` (implements `AppServices`: connect/disconnect, key, passwords in Keychain, live terminal views, install key), host-key alert. |
| `Connect/` | Host list, host editor (public key, password). |
| `Workspace/` | `WorkspaceView` (NavigationSplitView), `WorkspaceController` (commands for buttons/menus/shortcuts, pending selection, dialogs, toasts), `WorkspaceCommands` (menu bar / ⌘ shortcuts). |
| `Sidebar/` | Brand bar, machine headers, space cards, agent/terminal rows and the sub-agent tree under an agent's row (each sub-agent a `List` row of its own, `CardItem.kid`, so folding is a native row insert/remove; `TreeLines` draws `├ └ │`), quick switcher, `LimitsPanel` (subscription limits above the footer; also on the iPhone's home, `large`). `SpaceDrag`: reordering space cards. The `List`'s collection view drags and drops through `SpaceListDragDrop`, standing in for SwiftUI's delegates (which get everything else; SwiftUI sets them again as it updates the list, so ours return on every touch): a header starts a drag of its space; the system's preview is invisible and the lifted card is drawn in the window (`LiftedCard`: the card rendered afresh by `SpaceDragPreview`, lifted and resting; a display link holds it where the finger took it, on the list or off it; it lands in its slot with a crossfade, or flies back there when let go off the list, which `SpaceOffListDrop`, a see-through drop target over the window during the drag, hears at once); row markers (UIKit views behind the card rows) say where the cards are; the list shows the machine's spaces in the drag's lane order, the dragged card's rows staying as its dashed slot; the drop is `Workspace.moveSpace` (`space.move`). |
| `Panel/` | Tab bar + new menu, pane tree with weights, pane cards/headers, the message field under the panes (`ComposerBar`), terminal view seam (`TerminalViewProvider`), demo terminal. `SubAgentPeek`: a sub-agent without a pane over the window (iPad; `WorkspaceController.peek`), with Keep/Close; the iPhone shows `peek` on `PhonePaneScreen` in its parent's place. `KeyLayerHost`: the iPad's one key panel (`KeyPanelLayer` on a clear rect laid over the panes' frame, `controller.keyArea`, reported by `TerminalPanel`), drawn over the whole window, so over the sub-agent's window too, for the focused pane's terminal or the sub-agent looked at (`controller.keys`). |
| `Phone/` | The iPhone (and narrow iPad window) layout: `PhoneWorkspaceView` (one pane with the list slid over it, the screen's width, by a swipe right on the terminal or from the left edge, attention banner), `PhoneHome` (Agents inbox by status / Spaces list, footer counts, new-space menu), `PhonePaneScreen` (top bar, attention pill, panes strip, pane menu, the terminal and under it the message field, `Input/ComposerBar`, the key panel over the terminal), `PhoneKeyPanel` (key column pulled out over the terminal, see `Input/`: keys → `TerminalSession.send(key:)`, clipboard text → `send(text:submit: false)` or into the message). `WorkspaceView` picks it when `Device.isPhone` or the width is compact; `WorkspaceController.singlePane` makes "seen" follow the one pane on screen. |
| `Input/` | `ComposerBar`: the message field, always under the terminal (iPhone), under all the panes (iPad, for the focused one) and at the bottom of a sub-agent's window, hidden while the terminal has the keyboard itself; Telegram's composer (geometry, glass, motion: `ComposerMotion`) in the theme's colors: the attach menu (photo, file, clipboard image → `TerminalSession.put`, `Support/ImageForAgent`, the path into the draft), the field (`ComposerTextView`, a `UITextView`: one truncated line without the keyboard, grows to Telegram's cap with it; on the iPad a 1-pt input accessory for `KeyboardCover`), the send button inside it (one paste + Return via `TerminalSession.send(text:submit:)`); drafts in `WorkspaceController.drafts`, the field with the keyboard is `WorkspaceController.composing`. `KeyPanelLayer`: the key panel (`PhoneKeyPanel`) over a terminal area and how it and the keyboards come, shared by the iPhone screen and the iPad panel: a swipe to the left anywhere on a terminal (`PhoneKeyPanelGestures`, on the window's root view: the terminal's pans wait for it; ⏎ comes to rest where the swipe began); VoiceOver: the terminal's action Keys (`WierdrTerminalView.appActions`). The terminal's own keyboard comes with a finger's double tap on it (`WierdrTerminalView`); while a keyboard is up, a double tap hides it (the field down to one line). |
| `Terminal/` | SwiftTerm integration: `TerminalSession` (one attach stream ↔ one emulator, grid/FACTS/RESIZE/FOCUS/credit, reattach), `TerminalSessionPool` (per-address sessions, detach when hidden), `TerminalSurface` (SwiftUI), key bar, theme, keymap, `KeyboardCover` (the iPad sidebar's and panel's bottom inset, measured from the key bar, or the message field's empty accessory (`ComposeAccessory`), instead of SwiftUI's keyboard safe area, which iPadOS gets wrong with the floating keyboard). |
| `Theme/` | Atom One Dark / Paper colors, Geist + JetBrains Mono, icon assets. |
| `Activity/` | `LiveActivities`: this iPhone's push-to-start token (ActivityKit) written to the connected computer's `wierdr-push` document whenever a session goes live (`HostSession.onLive`) or the token / Live Activities setting changes; ends a second activity. `AppModel.openAgent`: a tap on an agent in the activity (`onOpenURL`). The widget extension `App/Widgets` (target `WierdrWidgets`, `pw.xff.wierdr.widgets`) draws the activity: Lock Screen and Dynamic Island. |
| `Debug/` | DEBUG-only: `LiveActivityDemo` (`-live-activity-demo YES`: a local activity with sample agents), terminal lab (`-terminal-lab YES`), simulator auto-connect hooks (`WIERDR_AUTOCONNECT`, `WIERDR_IMPORT_KEY`, `WIERDR_TRUST_HOSTKEY`, `WIERDR_DEBUG_STEPS`). |

### End-to-end test in the simulator

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

## WierdrModel internals

Public surface: `Workspace` (observable state + commands), `ScreenState`
(per-screen selection), the value types in `Types.swift`, and the live driver
`WorkspaceEngine` (+ `EngineOptions`, `ProgramTable`). Everything else is
internal to `Sources/WierdrModel/Engine`:

| File | What |
|---|---|
| `WorkspaceEngine.swift` | `@MainActor` driver. `run(on:)`: `events.subscribe` first, `machine.list`, `doc.get` per machine slot (`""` = connected computer, else machine name), then the event loop. Re-reads a slot on its `doc` event (skipped when the version is already known) and on `missed`; polls `machine.list` every 5 s (and soon after remote `created` events). Rebuilds the published state at most 10×/s and assigns only what changed. Implements `WorkspaceBackend`. |
| `LayoutDoc.swift` | Ids (`qualify`/`local`/`fresh`), raw-JSON lookups, the strict validator (`LayoutValidator.decode` mirrors herdr-app's serde types; `checkWrite` refuses null, >1 MiB, and any invariant violation the base document did not already have). |
| `LayoutEdits.swift` | Pure intents `(JSONValue) -> JSONValue?` mirroring herdr-app's model: new space/tab, `Node::split` (same axis halves the share in f32; cross axis wraps in an `s…` container taking the slot's size), `Node::remove` (share to the previous sibling, else the next; collapse single-child rows/columns; the root never collapses), last pane → tab close → space close, rename, move. Nil = the intent no longer applies. Unknown fields, key order, number kinds and mod panes are preserved. |
| `LayoutParser.swift` | Raw doc → `Space`/`Tab`/`PaneNode` with machine-qualified ids. |
| `TerminalFacts.swift` | Record → `TerminalInfo` (`shown_title`, process name, program, status per §6.2 with shared `<prefix>.seen`, `agent.*` meta with the pid trust rule, provider marks, model shortening), space naming (`folder_name`), avatar colors, agent launch argv (`remote_shell::launch`) and the installed-agents check (`remote_shell::check`). |
| `Programs.swift` | `programs.json` (package resource) + `programs::resolve`. |
| `SubAgents.swift` (in `WierdrModel/`) | `SubAgentIndex`: who started whom (`parent`), from one snapshot of spaces and terminals (cached by `Workspace`, rebuilt when either changes; reading it still registers both for observation). An agent with a pane shows its live descendants depth first (`SidebarRow.subtree`, kept ones too, which then are no rows of their own tab: `isNested`); `SidebarRow.urgency` is the most urgent of it and its sub-agents (`kidStatus`: never done); `countsBySpace` counts a sub-agent in its topmost listed ancestor's space; `home` is where Keep puts it (nearest ancestor with a pane; `Workspace.keepTarget` goes past that ancestor's kin tabs). `Workspace.keepAsTab` → engine: `terminal.label` (`herdr.space`/`herdr.tab`), `terminal.keep`, then `LayoutEdits.newTab` with its address. |
| `Limits.swift` (in `WierdrModel/`) | pi-herdr's `limits` document (schema 1) → `LimitAccount`/`LimitWindow`, merging the same account read on several machines (pi-herdr's fold), pace/tone/headline, plan names. The engine reads `limits` on every connected slot at start, on its `doc` events (skipped when the version is known), on `missed` and when a machine (re)connects; failed reads keep what was shown. Published as `Workspace.limits`; `EngineOptions.limitsDocument = nil` turns it off. |

Writes: every command is an intent applied to the freshest raw document of
its machine and written with `doc.set` CAS, one writer per machine. On a
conflict the slot is re-read, the intent re-applied (≤ 5 tries, jittered
100–400 ms); nothing is written when the intent no longer applies, when the
result equals the document, when the slot is not `ready`, or when validation
fails. Creating commands start the terminal first (labels `<prefix>.space`,
`.tab`, `.seen=0`, `keep`, `no_parent`), then insert it; if the desktop
adopted it meanwhile only the leftover (a name) is written. Closing commands
remove first, then kill the removed terminals and their non-kept
descendants. Panes whose terminal ended (`exited`/`killed`, or `not_found`)
are removed like the desktop does (3 s after the event, or after two machine
polls for panes whose terminal is missing). `allowWrites: false` makes the
engine a pure mirror (the CLI's `ws` uses that).

Facts fetched with `machine.exec`/`file.read`: home per machine
(`printf %s "$HOME"`), git per (machine, first-terminal folder) every 60 s
(`rev-parse --show-toplevel --abbrev-ref HEAD`, `--git-common-dir`,
`rev-list --left-right --count HEAD...@{upstream}`), `space.colors` from
`~/.config/herdr-app/shared.json` on the connected computer every 60 s, and
installed agents (login-shell check, cached 60 s, on connect and on
`refreshLaunchers`). Space names use the connected computer's home for `~`,
exactly like herdr-app (so a remote space in its home shows its folder name).

Tests: `swift test --filter WierdrModelTests` (pure layers + the engine
against an in-memory `FakeCore`); `WIERDR_LIVE=1` adds a read-only run
against the real `herdr-app` document and a full write path on the scratch
document `wierdr-test-layout` with label prefix `wierdrtest`.
`wierdr-cli ws [--watch]` prints what the engine builds from the local core.
