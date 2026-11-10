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
make device         # signed Debug build for a real device
make install        # build + install on the connected iPad (devicectl)
```
