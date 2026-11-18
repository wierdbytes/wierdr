# cc — Claude Code for herdr and Wierdr

A Claude Code [mod](https://code.claude.com/docs/en/plugins/mods/overview) that tells [herdr](https://herdr.dev) and Wierdr which model, effort and context size each Claude Code runs with, and how much of your Claude subscription limits is used ([Limits](#limits)). It is what [`@wierdbytes/pi-herdr`](https://www.npmjs.com/package/@wierdbytes/pi-herdr) does for pi, with the same labels and the same document, so a herdr agent list shows both alike:

```
 D  Fix login redirect loop                    ◌
 A\ Opus 5.5 @high              ⑂ 1   228k   52m
```

Claude Code already reports its status (idle, working, blocked, done) and its background agents over OSC 7501; herdr-core keeps them as the terminal's `status` and `records`. That report has no room for the model, so this mod writes it as `agent.*` labels on the herdr-core terminal Claude Code runs in.

Needs Claude Code 2.1.304 or later (`$.settings.read` by key). Tested live with 2.1.327, and with 2.1.319 at start and quit; `claude plugin test` passes on both.

## Install

```
/plugin marketplace add wierdbytes/wierdr
/plugin install cc@wierdr
```

or from the shell: `claude plugin marketplace add wierdbytes/wierdr && claude plugin install cc@wierdr`. Run `/reload-plugins` in an open session, or start a new one.

Nothing to configure: it has no options, and the labels and the limits are always written. Outside a herdr-core terminal (no `HC_TERMINAL_ID` / `HC_TERMINAL_SOCKET`) it does nothing. It needs `hc` (herdr-core's CLI) on `PATH` or at `~/.local/bin/hc`, which herdr-core terminals have.

## Labels

| Label | Example | |
|---|---|---|
| `agent.app` | `claude-code` | Who wrote the labels |
| `agent.pid` | `53188` | Claude Code's pid (the parent of a `/bin/sh -c 'echo $PPID'` the mod runs; `CLAUDE_PID` in settings hooks). A reader compares it with the terminal's foreground pid and ignores labels left behind by a Claude that crashed. It stays the foreground pid while Claude runs Bash commands |
| `agent.model` | `Claude Opus 5.5` | The model as pi names Anthropic's: `claude-opus-5-5` → `Claude Opus 5.5`, `claude-haiku-4-5-20251001` → `Claude Haiku 4.5`; Bedrock's and Vertex's ids and a `[1m]` suffix name the same model; anything else is its id. Herdr and Wierdr show `Opus 5.5` under the anthropic mark |
| `agent.model_id` | `claude-opus-5-5` | The model id the last main-loop request named, or the session's after `/model` |
| `agent.provider` | `anthropic` | `amazon-bedrock`, `google-vertex` or `azure-foundry` with `CLAUDE_CODE_USE_BEDROCK` / `_VERTEX` / `_FOUNDRY` |
| `agent.effort` | `high` | The effort the last main-loop request was sent with (a level or a number); before the first request, `CLAUDE_CODE_EFFORT_LEVEL` or the `effortLevel` setting. Absent when the request carried none |
| `agent.ctx` | `228432` | Tokens in the context now (Claude Code's `context.tokens`). Absent while unknown: before the first reply, after `/clear` |
| `agent.ctx_max` | `1000000` | Context window |
| `agent.session` | `3c14007c-8945-4642-9b80-bccea03804b5` | The session id (`claude --resume <id>` opens it again). Follows `/clear` and `/resume` |
| `agent.cache_until` | `1795028589487` | When the main conversation's prompt cache expires (epoch ms): when the last request that read or wrote it was sent, plus its lifetime. Stays after expiry (compare with now); absent until a request touched the cache, and after `/clear` |
| `agent.cache_ttl` | `3600000` | That lifetime (ms): one hour when the request wrote one-hour entries (`ephemeral_1h_input_tokens`, Claude Code's default on a subscription), five minutes for five-minute ones; a request that only read the cache keeps the last one seen |
| `agent.subagents` | `1` | Subagents and teammates queued or running (`$.agent.list()`: `pending`, `running`, `waiting`). Absent when none |

Read them in a herdr mod from `terminals()`, as pi-herdr's:

```js
const t = terminals().find((t) => t.address === agent.address);
const meta = t?.labels?.["agent.pid"] === String(t?.foreground?.pid) ? t.labels : {};
meta["agent.model"]; // "Claude Opus 5.5"
```

## Limits

On a claude.ai subscription (Pro, Max) Claude Code knows the 5-hour and 7-day windows from every response. The mod folds them into herdr-core's `limits` document on the machine Claude runs on, the one pi-herdr writes (schema 1; see [pi-herdr's README](https://www.npmjs.com/package/@wierdbytes/pi-herdr#limits)), so herdr, Wierdr and any script show the same numbers:

```json
"claude.849d2d8c": {
  "provider": "claude", "account": "849d2d8c", "plan": "max_5x",
  "source": "claude-code", "host": "mentoair", "at": 1795024992,
  "windows": {
    "5h": { "id": "5h", "label": "5 hours", "window_s": 18000, "used": 14, "resets_at": 1795031400, "at": 1795024992 },
    "7d": { "id": "7d", "label": "7 days", "window_s": 604800, "used": 53, "resets_at": 1795176000, "at": 1795024992 }
  }
}
```

- The account is the first 8 hex digits of sha256 of the organization id (`oauthAccount.organizationUuid` in `~/.claude.json`, or `$CLAUDE_CONFIG_DIR/.claude.json`): the same key pi-herdr derives from the `anthropic-organization-id` header, so Claude Code's and pi's readings land in one account. `main` when no account is signed in.
- `plan` is `organizationType` without `claude_`, with Max's tier from `organizationRateLimitTier` (`max_5x`, `max_20x`), which readers show as Max and Ultra.
- `five_hour` → `5h`, `seven_day` → `7d`; a gateway's `spend_limit` is not a subscription window and is left out. A window at 100 % or more is `exhausted`; Claude Code reports no other status, nor which window binds.
- Written on Claude Code's first measurement, whenever a window moves a whole point (`session.measure`), and at the end of every turn, so `at` stays fresh. Each write reads the document, folds the reading in with pi-herdr's rules (within one window `used` only grows; a later window replaces it) and writes it back at that version, retrying when someone wrote in between. Readings within 500 ms go out as one write.
- `claude -p` runs write limits too (they spend the same subscription), but no labels.

## How it works

- `session.start` reads the session's id, model and usage, Claude's pid and the configured effort, and writes every label before the first prompt. Each `turn.step` of the main loop (no `agentId`) updates the model, the effort and the cache window when the request is sent, then the context and the cache lifetime from its usage. `turn.complete`, `session.measure` and every command (`/model`, `/effort`, `/clear`…) re-read the session.
- Labels go out as `terminal.label` requests through `hc connect` (herdr-core's JSON-RPC over stdin, one process a request, `HC_SOCKET` set to the terminal's `HC_TERMINAL_SOCKET`). Changes within 150 ms collapse into one request, unchanged values are never sent, one request is in flight at a time, and the first write after a load sends every key, removing what an earlier Claude left.
- `agent.subagents` is re-read on `agent.spawn`, on every request, and every 5 s while any runs.
- Only the interactive session owns the terminal: `claude -p` runs inside it never write labels.
- Quitting (`/exit`, ctrl+c, logout) removes every label it set within the 1.5 s that `session.end` hooks share; the `limits` document stays. `/clear` and `/resume` keep the labels and republish them a moment later under the new session id.

## Limits and pitfalls

- `hc send <t> "/clear"` doesn't run a command: hc wraps what it pastes in `<hc from=…>` tags, so Claude gets a message. Type commands with `hc keys <t> / c l e a r` then `hc keys <t> enter`.
- Before the first request `agent.effort` is the configured level, which can differ from what the model runs at (a model with a lower default, such as Haiku, shows the setting's `high` until its first request says `medium`). Claude Code's mods API has no read of the effective level outside a request.
- Not tested: an interactive Claude that inherits another one's `HC_TERMINAL_ID` (an agent-team teammate in a tmux pane, say) would write its labels on that terminal over the first one's.
- Background agents and shells also show up in the terminal's `records` (Claude Code's own OSC 7501 report); `agent.subagents` counts only `$.agent.list()`'s agents and teammates, not background shells.
- A hot reload of the mod (`--plugin-dir` watches its folder) starts it afresh: its first write resends every label.

## Development

```bash
claude --plugin-dir ./Integrations/claude-code     # one session, reloads on save
CLAUDE_CODE_PLUGIN_DIRS=$PWD/Integrations/claude-code claude   # for apps that take no flag
claude plugin validate ./Integrations/claude-code  # what Claude Code reads from the mod
claude plugin validate .                           # the marketplace at the repo root
claude plugin test ./Integrations/claude-code      # unit tests and hook tests, no session
tsc -p ./Integrations/claude-code                  # type-check, once a --plugin-dir session wrote .claude-plugin/types/
```

The hooks are wired in `hooks/register.ts`; everything else (`meta.ts`, `cache.ts`, `limits.ts`, the two publishers, `hc.ts`) is plain code without `$`, tested directly. `tests/register.test.ts` drives the hooks through `claude-code/testing` with stubbed `hc connect` runs.

To point the limits at a scratch document while testing, start Claude with `WIERDR_CC_LIMITS_DOC=<name>`.

## License

MIT
