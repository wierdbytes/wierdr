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

### `HerdrCore`

**Where:** `Packages/WierdrKit/Sources/HerdrCore`. **Depends on:** Foundation.

herdr-core API client: `CoreTransport` (byte pipe), framing codec, JSON-RPC calls on channel 0,
attach streams (DATA/CREDIT/CLOSE/RESIZE/FOCUS/FACTS), event subscription, typed records,
`JSONValue` for opaque documents. `ProcessTransport` (macOS only) spawns a local `hc connect` for
tests and the CLI.

### `HerdrSSH`

**Where:** `Packages/WierdrKit/Sources/HerdrSSH`. **Depends on:** HerdrCore, SwiftNIO SSH,
swift-crypto.

`SSHTransport`: SSH session + exec of `hc connect` as a `CoreTransport`. Auth: Ed25519 key
(generated on device, kept in Keychain) or password. Host keys: trust on first use.

### `WierdrModel`

**Where:** `Packages/WierdrKit/Sources/WierdrModel`. **Depends on:** HerdrCore.

The Herdr world: machines, spaces, tabs, pane trees, terminals, agents and statuses, built from the
`herdr-app` document(s) + the terminal event stream. Commands that change it (new space/tab, close,
rename) with the same semantics as herdr-app. Also `Daemon`: wierdrd on the connected computer as
the app finds and sets it up (a shell probe and Homebrew actions through `machine.exec`,
`Status.verdict`; [wierdrd.md](../wierdrd.md)); `Integrations`: the agent harnesses there (pi, Claude
Code, Codex, on the login shell's PATH) and Wierdr's integration in each, installed with the
harness's own commands ([host-setup.md](../host-setup.md)).

### App

**Where:** `App/Sources`. **Depends on:** all of the above, SwiftTerm.

SwiftUI UI: connection screen, sidebar, tab bar, pane cards, terminal views (SwiftTerm
`TerminalView` fed by attach streams), theme.

### `WierdrActivity`

**Where:** `Packages/WierdrKit/Sources/WierdrActivity`. **Depends on:** Foundation, CryptoKit.

The agents Live Activity's data, shared by the app, its widget extension and the Mac:
`AgentsActivityAttributes` (+ `ContentState`, `Agent`; `ActivityAttributes` on iOS; they decode
sealed payloads: the agents and the attributes opened with the App Group's key, else
`ContentState.unreadable`), the `wierdr-push` registration document (`PushRegistry`, with each
device's `seal_kid`), the seal (`Sealed.swift`: `ActivitySealKey` — AES-GCM over zlib'd JSON, `kid`;
`SealDocument`, the `wierdr-push-seal` document; `ActivitySeal`, the keys as files in the App Group
`group.pw.xff.wierdr`), `AgentLink` (`wierdr://agent?t=…`).

### `WierdrRelay`

**Where:** `Packages/WierdrKit/Sources/WierdrRelay`. **Depends on:** Foundation, CryptoKit.

The app's registration on the push relay (`RelayRegistration`): App Attest key, attestation,
assertion-signed registration, the grant kept and checked on connecting, bounded retries; behind
`AppAttesting`, `RelayHTTP`, `RegistrationStore` (DeviceCheck, URLSession, UserDefaults in the app).
See [relay.md](../relay.md).

### `WierdrPush`

**Where:** `Packages/WierdrKit/Sources/WierdrPush`. **Depends on:** WierdrModel, WierdrActivity,
swift-crypto.

The Mac side of the Live Activity: `ActivitySummary` (workspace → content state), `Planner` (pure:
when to start/update/end), `ActivityPayload` (`aps` JSON), `APNsSigner`/`APNsClient` (JWT,
push-to-start, broadcasts, channels), `PushTransport` (`APNsClient` or `RelayClient`, the relay's
calls with grants), `Pusher` (the loop: read-only engine + registry + APNs; the seal key in
`~/.config/wierdr/seal-key`, published in `wierdr-push-seal`, every push sealed with it). See
[live-activity.md](../live-activity.md).

### `wierdr-cli`

**Where:** `Packages/WierdrKit/Sources/wierdr-cli`. **Depends on:** all packages.

macOS debugging tool against the local core (`hc connect`) or over SSH.

### `wierdrd`

**Where:** `Packages/WierdrKit/Sources/wierdrd`. **Depends on:** WierdrPush.

Wierdr's macOS daemon (`run`, `status`, `reset`, `--version`; the version in `Version.swift`),
behind the Live Activity. A Homebrew formula in the tap `wierdbytes/apps`
(github.com/wierdbytes/homebrew-apps), the binary in this repository's releases, both by
`.github/workflows/release-wierdrd.yml` (`scripts/wierdrd-release.sh`); `scripts/wierdrd.sh`
installs a build from source in launchd. Without `push.json` it goes through the relay. See
[wierdrd.md](../wierdrd.md).

### `Relay/`

**Where:** `Relay/src`. **Depends on:** Cloudflare Workers (TypeScript, bun).

The push relay ([relay.md](../relay.md)): `index.ts` (routes, D1, rate limits, the hourly sweep, admin
routes), `appattest.ts` (attestation and assertion checks), `der.ts`/`cbor.ts` (the parsing they
need), `grants.ts` (HMAC challenges and owner-named grants, two secrets), `payload.ts` (sealed
Wierdr pushes with Wierdr's alert words only, written again), `apns.ts` (JWT shared per window,
start/broadcast/channels over HTTP/2).

### `Site/`

**Where:** `Site/public`. **Depends on:** Cloudflare Workers static assets.

The landing page at `wierdr.workat.dev` ([site.md](../site.md)): one static page (`index.html`,
`styles.css`, `main.js`), screenshots as WebP from `Site/shots` (`images.sh`), the social card
rendered from `og/og.html`.

### Claude Code plugin

**Where:** `Integrations/claude-code` (plugin `cc@wierdr`, marketplace
`.claude-plugin/marketplace.json`). **Depends on:** Claude Code's mods API, `hc connect`.

Runs inside Claude Code: writes the `agent.*` labels (`agent.app = claude-code`) on its terminal and
the `limits` document, as pi-wierdr does for pi; the app reads them unchanged. Plus
`agent.subagents_meta` (`hooks/subagents.ts`, `SubagentTracker`): each live sub-agent's and
teammate's (an idle one between turns too) title, name, status and since when, model, effort,
context and start, by its `$.agent.list()` id. See [claude-code.md](../claude-code.md).

### pi extension

**Where:** `Integrations/pi` (npm `@wierdbytes/pi-wierdr`, published by
`.github/workflows/publish-pi.yml` through npm's Trusted Publishing). **Depends on:** pi's extension
API, the herdr-core socket.

Runs inside pi. `herdr/`: the `agent.*` labels (`agent.app = pi`) on its terminal, the `limits`
document, pi's bash commands in terminals of their own under pi's. `agents/`: sub-agents, each its
own pi in a child terminal (`Agent` and the other tools, a `pi.events` RPC). Formerly
`@wierdbytes/pi-herdr` and `@wierdbytes/pi-agents` in pi-wierd-stuff. See [pi.md](../pi.md).

### Codex plugin

**Where:** `Integrations/codex` (plugin `codex@wierdr`, marketplace
`.agents/plugins/marketplace.json`). **Depends on:** Codex's hooks, the herdr-core socket.

Codex has no in-process API, so its hooks (session start, prompt, model requests, sub-agents, stop,
end) write the `agent.*` labels (`agent.app = codex`, `agent.pid` = the TUI's pid) on its terminal
(and `agent.subagents_meta`, each sub-agent while one of its turns runs) and its account
(`codex.<slug>`) into the `limits` document, as pi-wierdr does; the app reads them unchanged. Codex
reports its status itself (OSC 7501, no `msg`); herdr and Wierdr start it as `codex --no-daemon`.
See [codex.md](../codex.md).

### Herdr desktop layout

**Where:** `Integrations/herdr-app` (layout `wierdr`, mods `wierdr-sidebar`, `wierdr-tabs`,
`wierdr-pane`; `install.sh` copies them into `~/.config/herdr-app`). **Depends on:** herdr-app's
mods API (`gpui-kit`, `herdr`); the mods `limits`, `wierd-memory` installed from their own
repositories.

Wierdr's sidebar on the Mac's Herdr window: space cards, agent rows, the header with the limits'
rings and the status ring, sized as Wierdr's points × `S` (`look.js`); the tab bar with the side
panel's views and the pane headers, copies of the author's `wierd-tabs` and `wierd-pane`. Formerly
in the author's dotfiles (chezmoi). See its [README](../../Integrations/herdr-app/README.md).

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
