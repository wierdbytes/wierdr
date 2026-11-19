# @wierdbytes/pi-wierdr

[pi](https://github.com/earendil-works/pi) for [herdr](https://herdr.dev) and Wierdr. One extension, two halves:

- **[herdr](#labels)** — tells herdr which model, reasoning effort and context size each pi runs with ([Labels](#labels)), how much of your Claude and Codex subscription limits is used ([Limits](#limits)), and runs pi's bash commands in herdr-core terminals under pi's, so you can watch each one live in herdr ([Bash](#bash)). Formerly `@wierdbytes/pi-herdr`.
- **[sub-agents](#sub-agents)** — each sub-agent is its own interactive pi in a herdr-core terminal nested under the agent that started it ([Sub-agents](#sub-agents)). Formerly `@wierdbytes/pi-agents`.

```
 ◌ Fix login redirect loop                       Opus 5.5 @high   228k
   ├ ◌ find-auth-code          Explore           Sonnet 5.5 @low
   └ ✓ review-session-store    general-purpose   Opus 5.5 @medium
```

The source lives in the [Wierdr](https://github.com/wierdbytes/wierdr) repository next to its Claude Code and Codex plugins, which write the same labels and the same document.

## Install

```bash
pi install npm:@wierdbytes/pi-wierdr
pi remove npm:@wierdbytes/pi-herdr      # replaced by this one
pi remove npm:@wierdbytes/pi-agents     # replaced by this one
pi remove npm:@tintinweb/pi-subagents   # same tool names: keep only one
```

pi must run inside a herdr-core terminal (`HC_TERMINAL_ID` / `HC_TERMINAL_SOCKET` set, as in every herdr pane). Elsewhere it does nothing: no labels, bash stays in pi, the sub-agent tools aren't registered and the RPC's `ping` answers `available: false`.

## Settings

Optional, in `~/.pi/agent/@wierdbytes/pi-wierdr/settings.json`, every key optional:

```json
{
  "bash": true,
  "agents": {
    "command": ["pi"],
    "extraArgs": ["--no-voice", "--no-peon"],
    "maxDepth": 1,
    "inheritEnv": true
  }
}
```

| Key | Default | |
|---|---|---|
| `bash` | `true` | Run bash commands in herdr-core terminals ([Bash](#bash)). `false` keeps them in pi's own process |
| `agents.command` | `["pi"]` | How to start pi in a sub-agent's terminal |
| `agents.extraArgs` | `[]` | Extra pi arguments for every sub-agent — e.g. silence pi-voice and pi-peon in sub-agents. Only list flags of extensions you have installed |
| `agents.maxDepth` | `1` | `2` lets sub-agents start their own sub-agents |
| `agents.inheritEnv` | `true` | Sub-agents get the parent's environment (PATH, API keys) minus terminal identity (`HC_*`, `TERM*`, the parent's `PI_SESSION_*`) |

Until this file exists, `~/.pi/agent/@wierdbytes/pi-herdr/settings.json` (`bash`) and `~/.pi/agent/@wierdbytes/pi-agents/settings.json` (the `agents` keys, at the top) are read instead.

## Labels

Pi already reports its status (working, blocked, done) over OSC 7501, but that report has no room for the model. This extension writes it as `agent.*` labels on the herdr-core terminal pi runs in, so a herdr agent list can show a second line under each pi:

```
 D  Fix login redirect loop                    ◌
 A\ Opus 5.5 @high              ⑂ 2   228k   4m
```

| Label | Example | |
|---|---|---|
| `agent.app` | `pi` | Who wrote the labels |
| `agent.pid` | `88638` | pi's process id: a reader compares it with the terminal's foreground pid and ignores labels left behind by a pi that crashed |
| `agent.model` | `Claude Opus 5.5` | Model display name (`ctx.model.name`, else its id) |
| `agent.model_id` | `claude-opus-5-5` | Model id |
| `agent.provider` | `anthropic` | Provider id |
| `agent.effort` | `high` | Thinking level, or the model's own word for it (`max`, a token budget). Absent when off or the model doesn't reason |
| `agent.ctx` | `228432` | Tokens in the context now. Absent while unknown (right after compaction) |
| `agent.ctx_max` | `1000000` | Context window |
| `agent.session` | `019f8940-4b3b-7d72-8112-3a9ebd007d5c` | The open session's id (`pi --session <id>` opens it again). Follows `/new`, `/resume` and forks; absent for `--no-session` |
| `agent.cache_until` | `1793534700000` | When the prompt cache of the current branch expires (epoch ms), as pi-statusline's countdown reads it: the last request or cache warming that touched the cache, plus the model's cache lifetime. Stays after expiry (compare with now); absent when the cache was never touched or the model's cache lifetime is unknown |
| `agent.cache_ttl` | `300000` | How long that cache entry lives from its last refresh (ms): the model's short or long tier. Set with `agent.cache_until`; together they give the share of the lifetime left |
| `agent.subagents` | `2` | [`@tintinweb/pi-subagents`](https://github.com/tintinweb/pi-subagents) agents queued or running (in-process, so herdr can't see them). Absent when none. This package's own sub-agents are terminals of their own and aren't counted |

Read them in a herdr mod from `terminals()`:

```js
const t = terminals().find((t) => t.address === agent.address);
const meta = t?.labels?.["agent.pid"] === String(t?.foreground?.pid) ? t.labels : {};
meta["agent.model"]; // "Claude Opus 5.5"
```

- Updates on session start, `/model` and model cycling, effort changes, every assistant request and reply, turn end, compaction, tree navigation and cache warming.
- Changes within 150 ms collapse into one `terminal.label` request over herdr-core's JSON-RPC socket; unchanged values are never sent. No `hc` process is spawned.
- Only the interactive pi owns the terminal: `pi -p`, RPC hosts and in-process sub-agents never write labels.
- Quitting pi removes every label it set (the `limits` document stays: it belongs to the subscription, not to this pi). Switching sessions and `/reload` keep them and the next session republishes.

## Limits

Every Claude and Codex response carries the subscription's usage windows (Anthropic's `anthropic-ratelimit-unified-*` headers, Codex's `x-codex-*` headers or `codex.rate_limits` stream event). pi-wierdr folds them into one herdr-core document, `limits`, on the machine pi runs on. Any herdr-core client reads it with `doc.get {name: "limits"}` and hears about changes as `doc` events (`events.subscribe`), so the herdr app, Wierdr or a script all show the same numbers, also from other machines (`on`).

```json
{
  "schema": 1,
  "updated_at": 1794310000,
  "accounts": {
    "claude.1a2b3c4d": {
      "provider": "claude", "account": "1a2b3c4d", "plan": "max",
      "status": "ok", "binding": "5h", "source": "header", "host": "mentoair", "at": 1794310000,
      "windows": {
        "5h": { "id": "5h", "label": "5 hours", "window_s": 18000, "used": 67, "resets_at": 1794321600, "status": "ok", "at": 1794310000 },
        "7d": { "id": "7d", "label": "7 days", "window_s": 604800, "used": 36, "resets_at": 1794571200, "status": "ok", "at": 1794310000 }
      }
    }
  }
}
```

- Accounts are keyed `<provider>.<account>`; `account` is the first 8 hex digits of sha256 of the provider's account id (`main` without one), the same as pi-langfuse's `rl.<provider>.<account>.<window>` scores. Codex accounts carry the e-mail pi signs in with as `label`.
- Window ids: `5h`, `7d`, `7d_oi` (weekly with extra usage), `7d_opus`, `7d_sonnet` for Claude; `5h`, `7d` and `<family>.<window>` for extra Codex limit families. `used` is in percent and can pass 100. Times are unix seconds; `at` is when a window was last read, so readers can tell live from stale.
- Several pi processes write it: each reads the document, folds its reading in and writes it back at that version, retrying when another pi wrote in between. Within one window (same reset, give or take two minutes) `used` only grows; a later window replaces it.
- Every reading is written, even with the same numbers: `at` is when a provider last reported the window. Nothing is written between responses. Readings within 500 ms go out as one write.
- Every pi writes, not only the interactive one: `pi -p` runs and sub-agents spend the same subscription. Windows a provider stops reporting stay until a later reading replaces them.

## Bash

Every command pi runs, the model's `bash` tool calls and your `!` / `!!` commands, gets a herdr-core terminal of its own (`terminal.run`, what `hc run` does), a child of pi's. Herdr shows it under pi while it runs:

- the screen starts with `$ <command>`, then the output as it comes;
- the title is the command's first line, and the program in front is the command itself (`bash -c '<command>'`, or the program when it is a single one);
- the label `pi-herdr.bash` (named before the move, kept) is `tool` or `user`, for mods that want to tell these terminals apart;
- ctrl+c typed into it stops the command, and pi reports the exit code.

In pi, the model's commands are drawn in pi-facelift's frame (the shared renderer from `@wierdbytes/pi-common/tool-frame/bash`), with or without pi-facelift installed: the command in the top border, the output on the rail, duration and `✓ exit 0` / `✗ exit N` in the bottom border. `!` commands keep pi's own look.

```
╭── bash npm test ──────────────────────────────── t14s ─
│ 12 passed
╰── 3.2s ──────────────────────────────────────────────────
```

The terminal is removed as soon as the command ends; when pi quits, running ones are ended and removed.

Commands run as with pi's own bash: stdin is `/dev/null`, stdout and stderr are one pipe (no colors, no pagers, no prompts). `tee` copies it to the terminal and to a file pi reads, so pi gets the exact output however long it is, and the command's exit code. What it starts in the background (`server &`) outlives the terminal, as before. Inside, `HC_TERMINAL_ID` is pi's: `hc run` starts terminals under pi, `hc send $HC_TERMINAL_ID` reaches pi.

Commands that call `hc wait` run in pi's own process: in a terminal under pi they would wait for themselves (`hc wait --children all`). So does a command herdr-core can't start a terminal for (the core is down or refuses), and everything when pi's shell isn't bash (`shellPath`) or on Windows.

Only one extension can own `bash`, and pi won't start when two register it, so pi-wierdr registers its tool at session start, and only over pi's built-in one. With another extension that replaces `bash`, the model's commands stay in pi's process and pi-wierdr says so once at start; `!` commands still run in herdr terminals. pi-facelift (0.8.0+) can leave `bash` to pi: switch it off in `/facelift` → Tools, then `/reload`.

## Sub-agents

Each sub-agent is its own interactive `pi`, started in a herdr-core terminal as a **child of the terminal the parent pi runs in**. Herdr already understands that relation: its agent list nests sub-agents under the agent that started them, shows their status (working / blocked / done) and, through the labels above, their model and context. You can peek at any of them, type into it, or take it over.

Replaces [`@tintinweb/pi-subagents`](https://github.com/tintinweb/pi-subagents) — same tool names, so models keep using them the way they know.

### Tools

| Tool | What it does |
|---|---|
| `Agent` | Start a sub-agent: `description` (its title in herdr, like a session name), `prompt`, optional `subagent_type`, `model` (`provider/id` or fuzzy: `"sonnet"`), `thinking` (`off` … `max`), `cwd`, `run_in_background`. Foreground (default) waits and returns its report, with live progress; background returns at once. |
| `get_subagent_result` | State now, or `wait: true` until it finishes (optional `timeout` seconds). |
| `steer_subagent` | Type a message into it: a steer while it works, a follow-up turn once it has finished (context intact). |
| `stop_subagent` | End it and close its terminal. |

- **Defaults:** the agent type's model / effort, else the parent session's.
- **Background results** arrive as one message per batch when the parent is idle (or right after its current run), and start a turn. Results already collected with `get_subagent_result` are not repeated.
- **Blocked:** a sub-agent waiting on a dialog shows as blocked in herdr; the parent gets a note (no turn) and `wait` returns, so nothing hangs on it.
- **Lifecycle:** a finished sub-agent stays open and idle — inspect it in herdr or send a follow-up. `stop_subagent`, `/agents → Stop`, or quitting the parent pi ends it. After `/reload` the parent picks its sub-agents up again.
- **Depth:** sub-agents don't get these tools (`agents.maxDepth: 1`).
- `/agents` lists the sub-agents; pick one to peek at it in herdr (`herdr-app do terminal.peek`) or stop it.

### Agent types

Built in: `general-purpose` (all tools), `Explore` and `Plan` (read-only: `read, bash, grep, find, ls`). Add your own as Markdown in `~/.pi/agent/agents/*.md` or, in trusted projects, `.pi/agents/*.md` — the same files pi-subagents reads:

```md
---
name: reviewer
description: Reviews a diff for bugs and risky changes
model: anthropic/claude-sonnet-5-5   # optional; "inherit" = the parent's
thinking: medium                     # optional
tools: read, grep, find, ls, bash    # optional allowlist → pi --tools
disallowed_tools: write, edit        # optional denylist → pi --exclude-tools
---
Review only what you were pointed at. Report each finding with file:line and severity.
```

The body is added to the sub-agent's system prompt (pi-subagents' `prompt_mode: replace` is treated as append). A file named like a built-in replaces it.

### For other extensions: `pi.events` RPC

```ts
import { agentsClient } from "@wierdbytes/pi-wierdr/client";

const agents = agentsClient(pi.events);
if ((await agents.ping()).available) {
  const a = await agents.spawn({ description: "Review diff", prompt: "…", model: "sonnet", thinking: "low" });
  const done = await agents.wait(a.id);          // until it finishes or needs a person
  console.log(done.status, done.result);
}
agents.on("completed", (a) => { /* … */ });
```

Without the client: emit `agents:rpc:<method>` with a `requestId`, listen on `agents:rpc:<method>:reply:<requestId>` for `{ success: true, data } | { success: false, error }`.

| Method | Params | Data |
|---|---|---|
| `ping` | — | `{ version, available }` |
| `spawn` | `{ prompt, description, subagent_type?, model?, thinking?, cwd?, notify? }` | snapshot. Always background; the parent model hears about it only with `notify: true` |
| `get` / `stop` | `{ id }` | snapshot |
| `wait` | `{ id, timeoutMs? }` | snapshot once it isn't working |
| `steer` | `{ id, message }` | snapshot + `mode: "steer" \| "follow-up"` |
| `list` | — | snapshots |

Broadcasts: `agents:spawned`, `agents:running`, `agents:blocked`, `agents:completed`, `agents:failed`, `agents:stopped`, each with the snapshot (`id`, `address`, `status`, `description`, `type`, `model`, `thinking`, `result`, `error`, `activity`, …). `id` is the herdr terminal name (`find-auth-code`); `address` its hc address (`t8c`) — both work wherever an id is asked for.

### How it works

- **Start:** herdr-core `terminal.run` over `HC_TERMINAL_SOCKET` with `parent` = this pi's terminal, `no_notify` (pi-wierdr reports to the model itself instead of hc typing notes into pi), labels `pi-agents.run` / `pi-agents.pid` (named before the move, kept), and `pi --model … --thinking … --name <description> [--tools …] -- <prompt>`. The terminal is named after the description (Cyrillic transliterated, `-2` on collisions).
- **Child side:** the same extension, loaded in the sub-agent, sees `PI_AGENTS_RUN`: it adds a `<subagent>` system-prompt section (role, report format, the type's instructions), inherits the parent's project trust, and writes `~/.pi/agent/@wierdbytes/pi-wierdr/runs/<run>.json` — settled-run count, last assistant message, tool activity. It takes `PI_AGENTS_*` out of its environment, so a pi that a tool of the sub-agent starts doesn't take itself for the sub-agent.
- **Parent side:** one `events.subscribe {children_of}` stream (status, exit), `fs.watch` on the run files and a 2 s safety poll. A record finishes when the child's settled-run count moves past where it was when the work was handed over, so a fresh pi's startup idle never counts as done. A pi that exits without a result fails with its last screen.
- Run files older than 7 days are pruned.

## Development

```bash
cd Integrations/pi
bun install
bun run test
pi -ne -e ./index.ts      # try it without the installed copy
```

Published to npm by [`.github/workflows/publish-pi.yml`](../../.github/workflows/publish-pi.yml) on push to `master`, when `version` in `package.json` isn't on npm yet: bump it, add a matching `## <version>` entry at the top of `CHANGELOG.md`, push.
