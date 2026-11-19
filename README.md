# Wierdr

**Answer your coding agents from your iPhone or iPad.** Wierdr is a native app for
[Herdr](https://herdr.dev). It shows every agent running on your computer and which ones
need you, and it opens their live terminals so you can reply. It connects straight to your
computer over SSH: no account, no cloud service in between.

<img src="docs/screenshots/iphone-agents-dark.png" width="260" alt="Agents list on iPhone"> <img src="docs/screenshots/iphone-pane-dark.png" width="260" alt="An agent's terminal with the key panel"> <img src="docs/screenshots/iphone-live-activity.jpg" width="260" alt="Live Activity on the Lock Screen">

![Wierdr on iPad](docs/screenshots/ipad-landscape-dark.png)

## Why

Coding agents like Claude Code, Codex and pi work on their own for minutes or hours, then
stop: to ask for a permission, to wait for a decision, or because they are done. Away from
your desk you don't see it, and they sit idle until you are back.

Wierdr puts them on your phone and tablet. A glance at the list, or at the Lock Screen,
tells you who needs you. Tap the agent and reply in its real terminal: approve a command,
answer a question, send the next prompt.

## Features

- **Every agent in one list.** The spaces, tabs and agents of herdr-core, on your computer
  and on the machines it is connected to. Each agent shows its status (needs you, done,
  working, idle), its title, model, reasoning effort and context, with its sub-agents under it.
- **Real terminals.** A full terminal emulator: Claude Code, Codex, pi, vim or btop work as
  on the desktop. A key panel for Esc, arrows, Tab and Return, and a message field for
  typing, dictating, pasting and sending screenshots and photos.
- **In sync with the desktop.** Start agents, create, rename and close spaces, tabs and
  splits; the Herdr desktop app sees the changes at once. What you have read on one is read
  on the other.
- **Lock Screen and Dynamic Island.** A Live Activity counts the agents by status and lists
  the most urgent ones, even with Wierdr closed. The screen lights up when an agent needs you.
- **Subscription limits.** How much of your Claude and Codex limits (5 hours, 7 days) is used.
- **Made for each device.** iPhone: a list for one hand with the controls at the bottom, one
  terminal per screen, swipe back. iPad: the sidebar next to split panes, and keyboard
  shortcuts with a hardware keyboard (⌘T, ⌘N, ⌘P, ⌘]…).
- **Try it without a computer.** A demo with sample agents that answer, and a guided tour on
  iPhone.
- **Private.** No account, no tracking, no analytics. Terminals go only between your device
  and your computer, over SSH. The SSH key is made on the device and stays in its Keychain.

Requires iOS or iPadOS 18 or later.

## Getting started

### 1. Prepare your computer

- Install [Herdr](https://herdr.dev). Wierdr talks to herdr-core (`hc`), which comes with it.
- Turn on **System Settings › General › Sharing › Remote Login** (SSH).
- To reach the computer away from home, put it and your iPhone or iPad on the same
  [Tailscale](https://tailscale.com) network (or another VPN).

### 2. Install Wierdr

Wierdr is not on the App Store yet; a release is being prepared. Until then,
[build it from source](#building-from-source).

### 3. Connect

1. In Wierdr, tap **Add Host**. Address: `your-mac.local` on the same Wi‑Fi, or the
   computer's Tailscale name. User: your user name on the computer (`whoami`). Sign in with:
   **Password**. Then **Connect**.
2. Confirm the host key. Its fingerprint should match the one this prints on the computer:
   `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.
3. In **Settings**, tap **Install This iPhone's Key on …** (iPad's on an iPad). Wierdr adds
   its key to `~/.ssh/authorized_keys` and signs in with it from then on, without the password.

### 4. Optional: more about each agent

Herdr already knows each agent's status. To also see the model, reasoning effort, context,
sub-agents and subscription limits, install the integration for your agent on the computer:

| Agent | Install | Details |
|---|---|---|
| [pi](https://github.com/earendil-works/pi) | `pi install npm:@wierdbytes/pi-wierdr` | [README](Integrations/pi/README.md) |
| Claude Code | `/plugin marketplace add wierdbytes/wierdr`, then `/plugin install cc@wierdr` | [README](Integrations/claude-code/README.md) |
| Codex CLI | `codex plugin marketplace add wierdbytes/wierdr`, then `codex plugin add codex@wierdr`; trust its hooks when Codex asks | [README](Integrations/codex/README.md) |

### 5. Optional: Lock Screen and Dynamic Island

The Live Activity comes from `wierdrd`, Wierdr's small daemon on your Mac: it watches
herdr-core and sends pushes through Apple's push service. After Wierdr first connects to your
computer, it offers to install and start wierdrd with [Homebrew](https://brew.sh) (later:
**Settings › Daemon**). By hand:

```sh
brew install wierdbytes/apps/wierdrd
brew services start wierdrd
```

Agent titles, spaces and machine names are encrypted with a key that only your Mac and your
iPhone have: Apple and the push relay see only the counts. More:
[docs/wierdrd.md](docs/wierdrd.md), [docs/live-activity.md](docs/live-activity.md). A
self-built app needs its own APNs key, since the hosted push relay serves only official
Wierdr builds.

## Building from source

You need a Mac with Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

**Try the demo in the Simulator:**

```sh
make sim-iphone     # builds Wierdr, creates an iPhone simulator, opens the demo
```

**Install on your iPhone or iPad.** This needs a paid Apple Developer account (Wierdr uses
push notifications, App Attest and an App Group), signed in to Xcode (Settings › Accounts).
Bundle identifiers belong to one team, so put in your own Team ID and your own
reverse-domain prefix, then regenerate the project:

```sh
sed -i '' -e 's/AUL4CCB2XY/YOUR_TEAM_ID/' -e 's/pw\.xff/com.yourname/g' project.yml
make project
```

Turn on Developer Mode on the device (Settings › Privacy & Security), connect it by cable
and run `make install-iphone`, or `make install` for an iPad: a Release build, signed with
your team and installed with `devicectl`. You can also open `Wierdr.xcodeproj` in Xcode and
Run, but choose the Release configuration: a Debug build parses terminal output about 7×
slower.

More in [docs/BUILD.md](docs/BUILD.md).

## Documentation

Most of the detailed docs are in Russian for now (RU); the rest are in English (EN).

- [Features](docs/FEATURES.md): everything Wierdr does, screen by screen (RU).
- [Building and installing](docs/BUILD.md): devices, install over the air, preparing the Mac (RU).
- [SSH](docs/ssh.md): sign-in, keys, host keys, setting up the Mac (EN).
- [Live Activity](docs/live-activity.md): how it works and how to set it up (RU);
  the [push relay](docs/relay.md) (RU); [wierdrd](docs/wierdrd.md), the daemon behind it:
  installing, how the app sets it up, releases (RU).
- Agent integrations: [pi](Integrations/pi/README.md), [Claude Code](Integrations/claude-code/README.md),
  [Codex](Integrations/codex/README.md) (EN); how they work inside: [pi](docs/pi.md),
  [Claude Code](docs/claude-code.md), [Codex](docs/codex.md) (RU).
- For developers: [architecture](docs/architecture.md) (EN),
  [the herdr-core client](docs/hc-protocol-client.md) (EN),
  [assumptions and trade-offs](docs/TRADEOFFS.md) (RU), [App Store plan](docs/app-store.md) (RU).
