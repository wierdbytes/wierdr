# WierdrModel internals

Public surface: `Workspace` (observable state + commands), `ScreenState`
(per-screen selection), the value types in `Types.swift`, and the live driver
`WorkspaceEngine` (+ `EngineOptions`, `ProgramTable`). Everything else is
internal to `Sources/WierdrModel/Engine`:

## `WorkspaceEngine.swift`

`@MainActor` driver. `run(on:)`: `events.subscribe` first, `machine.list`, `doc.get` per machine
slot (`""` = connected computer, else machine name), then the event loop. Re-reads a slot on its
`doc` event (skipped when the version is already known) and on `missed`; polls `machine.list` every
5 s (and soon after remote `created` events). Rebuilds the published state at most 10×/s and assigns
only what changed. Implements `WorkspaceBackend`.

## `LayoutDoc.swift`

Ids (`qualify`/`local`/`fresh`), raw-JSON lookups, the strict validator (`LayoutValidator.decode`
mirrors herdr-app's serde types; `checkWrite` refuses null, >1 MiB, and any invariant violation the
base document did not already have).

## `LayoutEdits.swift`

Pure intents `(JSONValue) -> JSONValue?` mirroring herdr-app's model: new space/tab, `Node::split`
(same axis halves the share in f32; cross axis wraps in an `s…` container taking the slot's size),
`Node::remove` (share to the previous sibling, else the next; collapse single-child rows/columns;
the root never collapses), last pane → tab close → space close, rename, move. Nil = the intent no
longer applies. Unknown fields, key order, number kinds and mod panes are preserved.

## `LayoutParser.swift`

Raw doc → `Space`/`Tab`/`PaneNode` with machine-qualified ids.

## `TerminalFacts.swift`

Record → `TerminalInfo` (`shown_title`, process name, program, status per §6.2 with shared
`<prefix>.seen` (`StatusRule`; for 7501 app `codex` its `idle` is idle whatever the turn counter
says and only its `done` is done while unseen, as herdr-core counts its launch, `/new` and approvals
as turns), `agent.*` meta with the pid trust rule (pi's, Claude Code's `cc@wierdr`, Codex's
`codex@wierdr`), provider marks, model shortening, the 7501 `records` → `TaskRecord`s by id
(`StatusRecords.parse`; Claude Code's background sub-agents and shells, none once the terminal
ended), merged with the sub-agents and teammates of `agent.subagents_meta` (`AgentLabels.subagents`:
title, name, status, since, model under the terminal's provider, effort, ctx, ctx_max, started; only
with trusted `agent.*`) by `StatusRecords.merge`: one row each, under the `$.agent.list()` id, its
record found by id (a sub-agent's) or by title (a teammate's, keyed by its task), and one without a
record (a teammate between turns: idle) a row of the label alone), space naming (`folder_name`),
avatar colors, agent launch argv (`remote_shell::launch`) and the installed-agents check
(`remote_shell::check`).

## `Programs.swift`

`programs.json` (package resource) + `programs::resolve`.

## `SubAgents.swift` (in `WierdrModel/`)

`SubAgentIndex`: who started whom (`parent`), from one snapshot of spaces and terminals (cached by
`Workspace`, rebuilt when either changes; reading it still registers both for observation). An agent
with a pane shows its live descendants depth first (`SidebarRow.subtree`, kept ones too, which then
are no rows of their own tab: `isNested`), and with them the records each terminal of the tree
reports, after that terminal's own children, by id (`tree(of:)` → `SidebarRow.tree`, `TreeNode`:
`.kid(SubAgent)` / `.record(RecordKid)`; the lines are drawn for both; records count in no status,
urgency or count of agents); `SidebarRow.urgency` is the most urgent of it and its sub-agents
(`kidStatus`: never done); `countsBySpace` counts a sub-agent in its topmost listed ancestor's
space; `home` is where Keep puts it (nearest ancestor with a pane; `Workspace.keepTarget` goes past
that ancestor's kin tabs). `Workspace.keepAsTab` → engine: `terminal.label`
(`herdr.space`/`herdr.tab`), `terminal.keep`, then `LayoutEdits.newTab` with its address.
`TreeFolds`: how a tree folds in the list: `chipOwners` (each terminal row's agent: the one that
started it, through plain terminals; a shell's, the terminal reporting it), `terminals(of:in:)` (an
agent's or sub-agent's `>_` count), `shown` (sub-agents while the bot chip is open, an agent's
terminals while its `>_` is, nothing under a hidden row, the agents panel's matches forced) and
`relined` (the lines drawn afresh for what shows), `owners` (terminals with terminals: an open `>_`
without them folds again, `WorkspaceController.openTerminals`).

## `Fuzzy.swift` (in `WierdrModel/`)

fzf-style fuzzy matching for the agents panel's search (`AgentsPanel`): the query's letters in
order, the best fit by DP (word starts, camelCase humps and runs score more, gaps cost), case and
diacritics ignored, query words matched in any order; the matched offsets for lighting them.
`SidebarRow` sequences' `tally` (agents, sub-agents with the in-process ones, terminals with
background shells): what a space holds.

## `Types.swift` (in `WierdrModel/`)

The value types. Besides spaces, tabs, panes and `TerminalInfo`: `TaskRecord` (a 7501 record: id,
title, state → `status`, `kind` agent/shell from Claude's id shape; a sub-agent's `meta`,
`startedAt`, `statusSince` (its age, `ageSince`) and `name`), `RecordKid` / `TreeNode` (a row of an
agent's tree; a record's `program`, its terminal's, fills the model slot without meta), `KidCounts`
(the row's badges: sub-agents with a terminal + per terminal of the block `inProcessAgents` =
max(`agent.subagents`, its sub-agent records); the agent's own terminals + background shells,
`TerminalTally`; `alert`), `SpaceTally` (the same rule per space), `countedAgents` (terminals only),
`TerminalInfo.canMarkUnread` (idle, but not a Codex saying idle: Mark Unread couldn't make it done).

## `Inbox.swift` (in `WierdrModel/`)

`AgentText`: the agent title rule every place uses (row, pane screen's capsule, agents panel,
banner, Live Activity): `msg` first, but for 7501 app `claude-code` a telling terminal title first
(its session's title) unless it's blocked/error with a message; `tellingTitle` (the title when it
tells something), for 7501 app `codex` what `codexTitle` leaves of Codex's window title (its
thread's name: no spinner, no `[ ! ] Action Required | ` / `[ . ] Action Required | `, no last
` | <project>` when that's the name of the cwd or a folder it's in, as Codex names its project, cut
at 24); `kidTitle`, a sub-agent's row (msg, telling title, `--name`, …). `Workspace.inbox` (the
agents by status, the Live Activity's) and `agentsByStatus` (the same order as one list, the agents
panel's), both by `InboxOrder`.

## `Limits.swift` (in `WierdrModel/`)

pi-wierdr's `limits` document (schema 1) → `LimitAccount`/`LimitWindow`, merging the same account
read on several machines (pi-wierdr's fold), pace/tone/headline, plan names, a window's mark in its
ring (`symbol`). The engine reads `limits` on every connected slot at start, on its `doc` events
(skipped when the version is known), on `missed` and when a machine (re)connects; failed reads keep
what was shown. Published as `Workspace.limits`; `EngineOptions.limitsDocument = nil` turns it off.

## Writes

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

## Demo

The demo (`Workspace.preview()`, `isLocal`, no backend) changes itself: pin, unread,
idle, `space.move`, ending a sub-agent, `markSeen` (done turns idle at once on screen; each turn once while it stays there, as the engine's `looked`, so Mark Unread on the agent in front sticks),
and `changeLocally(_:_:)`, which the app's `DemoAgents` uses to make its agents work and
answer; live, it does nothing (`DemoTests`).

## Facts

Facts fetched with `machine.exec`/`file.read`: home per machine
(`printf %s "$HOME"`), git per (machine, first-terminal folder) every 60 s
(`rev-parse --show-toplevel --abbrev-ref HEAD`, `--git-common-dir`,
`rev-list --left-right --count HEAD...@{upstream}`), `space.colors` from
`~/.config/herdr-app/shared.json` on the connected computer every 60 s, and
installed agents (login-shell check, cached 60 s, on connect and on
`refreshLaunchers`). Space names use the connected computer's home for `~`,
exactly like herdr-app (so a remote space in its home shows its folder name).

## Tests

Tests: `swift test --filter WierdrModelTests` (pure layers + the engine
against an in-memory `FakeCore`); `WIERDR_LIVE=1` adds a read-only run
against the real `herdr-app` document and a full write path on the scratch
document `wierdr-test-layout` with label prefix `wierdrtest`.
`wierdr-cli ws [--watch]` prints what the engine builds from the local core.
