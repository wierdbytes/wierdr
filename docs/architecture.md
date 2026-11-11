# Wierdr architecture

Wierdr is a native iPadOS client of **herdr-core** (`hc`). It shows the same
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
| `wierdr-cli` | `Packages/WierdrKit/Sources/wierdr-cli` | all packages | macOS debugging tool against the local core (`hc connect`) or over SSH. |

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
| `Sidebar/` | Brand bar, machine headers, space cards, agent/terminal/sub-agent rows, quick switcher. |
| `Panel/` | Tab bar + new menu, pane tree with weights, pane cards/headers, status bar, terminal view seam (`TerminalViewProvider`), demo terminal. |
| `Terminal/` | SwiftTerm integration: `TerminalSession` (one attach stream ↔ one emulator, grid/FACTS/RESIZE/FOCUS/credit, reattach), `TerminalSessionPool` (per-address sessions, detach when hidden), `TerminalSurface` (SwiftUI), key bar, theme, keymap. |
| `Theme/` | Atom One Dark / Paper colors, Geist + JetBrains Mono, icon assets. |
| `Debug/` | DEBUG-only: terminal lab (`-terminal-lab YES`), simulator auto-connect hooks (`WIERDR_AUTOCONNECT`, `WIERDR_IMPORT_KEY`, `WIERDR_TRUST_HOSTKEY`, `WIERDR_DEBUG_STEPS`). |

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
