# codex — Codex CLI for herdr and Wierdr

A [Codex](https://github.com/openai/codex) plugin that tells [herdr](https://herdr.dev) and Wierdr which model, effort and context size each Codex runs with, and how much of your ChatGPT subscription limits is used ([Limits](#limits)). It does for Codex what [`@wierdbytes/pi-wierdr`](https://www.npmjs.com/package/@wierdbytes/pi-wierdr) does for pi and [`cc`](../claude-code/README.md) does for Claude Code. It writes the same labels and the same document, so a herdr agent list shows all three the same way:

```
 D  Fix login redirect loop                    ◌
 O  6.1 Sol @high               ⑂ 1    41k   12m
```

Codex already reports its status (idle, working, done) over OSC 7501, and herdr-core keeps it as the terminal's `status`. That report has no room for the model, so this plugin writes it as `agent.*` labels on the herdr-core terminal Codex runs in. It is made of command hooks (Codex has no in-process extension API) and needs `python3` (standard library only).

Needs Codex 0.167.0 or later. Tested live with 0.170.0 and 0.167.0.

## Install

```
codex plugin marketplace add wierdbytes/wierdr
codex plugin add codex@wierdr
```

or in the TUI, run `/plugins` and pick `codex` from the `wierdr` marketplace. The marketplace is [`.agents/plugins/marketplace.json`](../../.agents/plugins/marketplace.json) at the repository root. Codex reads it before `.claude-plugin/marketplace.json`, which Claude Code uses for the same repository.

**Trust the hooks once.** Codex runs a plugin's hooks only after you trust them. The next Codex you start shows *Hooks need review*: choose *Review hooks* and press `t` on each `codex@wierdr` hook, or choose *Trust all and continue*. Codex pins the plugin's content hash, so **every update of the plugin asks again**. Until you trust them, the hooks don't run and nothing is written.

**Run Codex with `--no-daemon` in herdr terminals.** Plain `codex` (0.167+) starts, or reuses, one shared `codex app-server` daemon per `CODEX_HOME`. That daemon runs the model loop, the tools and the hooks with the environment of the terminal that started it. Its hooks can't tell which terminal they belong to, so the plugin writes no labels for them (the limits still go out). herdr's and Wierdr's launchers already start `codex --no-daemon`. For a Codex you start by hand, put this in your shell rc:

```sh
[ -n "$HC_TERMINAL_ID" ] && alias codex='codex --no-daemon'
```

Any `-c key=value` override (other than a boolean `features.*`) also makes Codex run embedded.

Nothing to configure. Outside a herdr-core terminal (no `HC_TERMINAL_ID` / `HC_TERMINAL_SOCKET`), every hook exits before starting Python.

## Labels

| Label | Example | |
|---|---|---|
| `agent.app` | `codex` | Who wrote the labels |
| `agent.pid` | `99783` | The Codex TUI's pid: the terminal's foreground pid, which is the parent of the hook process. A reader compares it with the terminal's foreground pid and ignores labels left behind by a Codex that crashed. It stays the foreground pid while Codex runs shell commands |
| `agent.model` | `GPT-6.1 Sol` | The model as pi names OpenAI's: Codex's `GPT-6.1-Sol` → `GPT-6.1 Sol`, `gpt-5.3-codex` → `GPT-5.3 Codex`. Herdr and Wierdr show `6.1 Sol` under the openai mark |
| `agent.model_id` | `gpt-6.1-sol` | The slug of the turn's model |
| `agent.provider` | `openai` | The session's `model_provider` |
| `agent.effort` | `high` | The reasoning effort of the latest turn, or of a `/model` change since then. Without one, the model's default level. Absent for `none` |
| `agent.ctx` | `41230` | Tokens in the context now: the last response's `total_tokens`, the number Codex's footer uses. After a compaction, Codex's own estimate. Absent before the first response |
| `agent.ctx_max` | `258400` | The context window Codex works with (`model_context_window`: the model's window times its effective share) |
| `agent.session` | `01a1f03a-3010-7682-91da-ef62917dfb79` | The session (thread) id: `codex resume <id>` opens it again. Follows `/clear`, `/resume` and forks |
| `agent.subagents` | `1` | Sub-agents working now (a turn started and not yet ended, and not closed). Absent when none |
| `agent.subagents_meta` | `{"01a1f07a-232d-75e1-abf3-24c8a50d1710":{"title":"probe","name":"Kepler","status":"running","since":1795035898686,"model":"GPT-6 Luna","model_id":"gpt-6-luna","effort":"low","ctx":16545,"ctx_max":258400,"started":1795035898672}}` | The same sub-agents, one row each, as JSON keyed by the sub-agent's thread id (the hooks' `agent_id`). The keys are the ones the Claude Code plugin [`cc`](../claude-code/README.md#labels) writes. `title` is its task path under the root agent: Codex shows `/root/probe` as "Started `/root/probe`", and the title is `probe` (`probe/check` one level down). `name` is its nickname (`Kepler`, as in Codex's agent picker). Without a task path (the older multi-agent tools), the title is the picker's `Kepler [explorer]`. `status` is always `running`, and `since` is when its current turn started (epoch ms). `model` is named as `agent.model` is, and `model_id` is its slug. `effort` is its latest turn's. `ctx` and `ctx_max` work as `agent.ctx` and `agent.ctx_max` do, but for its own context. `started` is when it was spawned (epoch ms). Ids are sorted and unknown fields are left out. Absent when none |

There are no `agent.cache_until` / `agent.cache_ttl` labels: OpenAI doesn't report a cache lifetime. The first write clears any that an earlier agent left in the terminal.

Read them in a herdr mod from `terminals()`, the same way as pi-wierdr's labels:

```js
const t = terminals().find((t) => t.address === agent.address);
const meta = t?.labels?.["agent.pid"] === String(t?.foreground?.pid) ? t.labels : {};
meta["agent.model"]; // "GPT-6.1 Sol"
```

## Limits

On a ChatGPT plan (Plus, Pro…), every Codex response reports the 5-hour and weekly windows. The plugin folds them into herdr-core's `limits` document on the machine Codex runs on. pi-wierdr writes the same document (schema 1; see [pi-wierdr's README](https://www.npmjs.com/package/@wierdbytes/pi-wierdr#limits)), so herdr, Wierdr and any script show the same numbers:

```json
"codex.d4800446": {
  "provider": "codex", "account": "d4800446", "label": "you@example.com", "plan": "plus",
  "source": "codex", "host": "mentoair", "at": 1795031775,
  "windows": {
    "5h": { "id": "5h", "label": "5 hours", "window_s": 18000, "used": 3, "resets_at": 1795049774, "at": 1795031775 },
    "7d": { "id": "7d", "label": "7 days", "window_s": 604800, "used": 6, "resets_at": 1795159821, "at": 1795031775 }
  }
}
```

- The account key is the first 8 hex digits of sha256 of the ChatGPT account id. The id comes from `tokens.account_id` in `$CODEX_HOME/auth.json`, or from the id token's `chatgpt_account_id`, or (with the credentials in the keyring) from the session's `creator_account_id`. pi-wierdr derives the same key, so Codex's and pi's readings land in one account. `label` is the account's e-mail from the id token. Nothing else is read from `auth.json`, and no token is ever written or logged.
- `plan` is Codex's `plan_type`. The `codex` family's windows are `5h` / `7d` (from `window_minutes`). Other limit families get pi-wierdr's names: `<limit_id>.<window>`, labelled `<limit_name> <window>`. A window at 100 % or more is `exhausted`, and so is the account when Codex reports `rate_limit_reached_type`.
- The readings come from the session's rollout (`token_count` events). Each one is written with the time Codex recorded it, at the end of every turn and at most every 30 s during a turn. Each write reads the document, folds the reading in with pi-wierdr's rules (within one window `used` only grows; a later window replaces it) and writes it back at that version, retrying when another writer got in between. A reading already written isn't written again.
- `codex exec` runs and sub-agents write limits too (they spend the same subscription), but no labels.

## How it works

Each hook runs `python3 hooks/herdr.py <event>` with the hook's JSON on stdin. It prints nothing and always exits 0. It talks to herdr-core over `HC_TERMINAL_SOCKET` directly, using the same JSON-RPC lines `hc connect` sends: `terminal.get`, `terminal.label`, `doc.get`, `doc.set`. No hook carries the effort, the context window or the rate limits, so the plugin reads them from the end of the session's rollout (`transcript_path`), backwards and in chunks.

| Hook | What it writes |
|---|---|
| `SessionStart` | Every label (all keys; empties remove what an earlier agent left). Also on `/clear`, `/resume` and forks, under the new session id |
| `UserPromptSubmit` (async) | Model, effort, window, session (a `/model` between turns shows here), and the sub-agents again |
| `PreModelRequest` (async) | In a sub-agent's turn, it marks the sub-agent as working, so a resumed one shows up when its first request starts. The main agent's requests exit at once |
| `PostModelRequest` (async) | `agent.ctx` from the response's `token_usage`, before the rollout has it; the limits at most every 30 s. In a sub-agent's turn, it marks the sub-agent as working and updates its context |
| `PostCompact` (async) | The context after compaction |
| `SubagentStart` / `SubagentStop` (async) | `agent.subagents`, `agent.subagents_meta` |
| `PostToolUse` of `close_agent` / `resume_agent` (async) | `agent.subagents`, `agent.subagents_meta` |
| `Stop` (async) | Every label again, and the limits |
| `SessionEnd` (3 s) | Removes every label it set |

- **Whose hook is it?** Labels are written only when the terminal's foreground program is one of the hook's nearest ancestors, with no `codex app-server` in between. That is the embedded Codex, whose hooks are its own children. The daemon's hooks fail this check even in the terminal that started the daemon, which is its parent. They also need an interactive session (`session_meta.source` `cli` or `vscode`), so a `codex exec` run inside the terminal never touches its labels.
- Only changed labels are sent: the hook compares with the labels `terminal.get` returned. Small state files in `$PLUGIN_DATA` hold the last context per terminal, the sub-agents' turns per session and which limit readings were written. They are locked against concurrent hooks.
- Sub-agents run inside Codex. `SubagentStart` and a sub-agent's model requests mark one of its turns as working; `SubagentStop` marks that turn done. Turn ids rather than times decide this, because a turn's last model-request hook can start after its `SubagentStop` hook. An agent that Codex's state database lists as closed never counts. Neither does a turn that the sub-agent's own rollout shows as over (`task_complete`, `turn_aborted`, or a later turn already started). An interrupt fires no `SubagentStop`, so this is how an interrupted sub-agent goes away at the next hook.
- **A sub-agent is listed only while one of its turns runs.** When the turn ends it disappears, as a finished Claude subagent does. Codex keeps a sub-agent resumable until `close_agent`, which models rarely call, so an "idle" row could stay forever. If the sub-agent gets more work (`followup_task`, `send_input`), it shows up again from its next request. Its `since` is then that turn's start, and its `started` is still the spawn time.
- A sub-agent's row comes from its own rollout, which `SubagentStart`, its model requests and `SubagentStop`'s `agent_transcript_path` point to. The plugin uses that rollout only if its `session_meta` names the agent. From that rollout it takes the task path, nickname and spawn time (`session_meta`), the model and effort (the latest `turn_context`), the turn's start (`task_started`) and the context and window (`token_count`). The context from its latest `PostModelRequest` wins when it is newer.

## Limits and pitfalls

- **Labels appear only at the first prompt.** Codex fires `SessionStart` lazily, with the first turn, and no hook runs at launch.
- A `/model` or effort change between turns shows at the next prompt.
- `hc send <t> "/exit"` doesn't run a command: hc wraps what it pastes in `<hc from=…>` tags, so Codex gets a message. Type commands as keys: `hc keys <t> / e x i t`, then `hc keys <t> enter`.
- In daemon mode (plain `codex`), there are no labels, and `SessionEnd` only fires when the daemon stops.
- Codex encrypts a sub-agent's task text in the rollout, and the hooks don't carry it either. A row is titled by the task path the model chose (`task_name`), not by the task.
- If `codex plugin add` reinstalls the plugin (with changes) under a running Codex, that Codex runs none of its hooks from then on. There are no new labels, and no `SessionEnd` removes the old ones. Seen on 0.170.0. Restart Codex and trust the hooks again.
- Without `python3` on the login shell's `PATH`, the hooks do nothing.
- The hooks run as `$SHELL -lc '…'`. Anything your login profile prints on stdout would reach `SessionStart` / `UserPromptSubmit` output, which Codex adds to the model's context.

## Development

```bash
python3 -m unittest discover -s Integrations/codex/tests   # pure functions and hooks against a fake herdr-core socket
codex plugin marketplace add "$PWD"                         # the local marketplace
codex plugin add codex@wierdr                               # copies the plugin into ~/.codex/plugins/cache; re-run after edits (and re-trust)
```

`hooks/herdr.py` wires the events. Everything else is plain code, tested directly: `meta.py` (labels, model names), `rollout.py` (reading the rollout's tail), `limits.py` (readings, account, pi-wierdr's fold), `guard.py` (whose hook it is), `subagents.py`, `hc.py`.

To point the limits at a scratch document while testing, start Codex with `WIERDR_CODEX_LIMITS_DOC=<name>`. `WIERDR_CODEX_DEBUG=1` makes every hook append a line (event, decision, labels sent) to `$PLUGIN_DATA/debug.log`.

## License

MIT
