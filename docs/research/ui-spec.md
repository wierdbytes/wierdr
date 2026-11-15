# Wierdr UI spec: sidebar + terminal panel (from the Herdr desktop setup)

Research of `~/.config/herdr-app` (layout `wierd-layout`, mods `wierd-chrome`, `wierd-agents`,
`wierd-tabs`, `wierd-pane`, `agent-counts`, `new-menu`, `menu`), the herdr-app source
(`/tmp/herdr-app-src`), live core data (`hc get`, `hc connect` → `doc.get`, `events.subscribe`)
and screenshots (`/tmp/herdr-shot.png`, `/tmp/wierdr-shot.png`, 2880x1752 = 1440x876 pt @2x).

All sizes are **logical px = SwiftUI points** (desktop zoom is 1.0). Measurements in the
screenshots agree with the code to within 1 pt.

Icons are copied to `docs/research/icons/` (flat, original names; the desktop's own copies of
`search/settings/sidebar` in `wierd-chrome` and `workspace-chrome` are byte-identical, as are
`wierd-pane/*` and `pane/*`, so one copy each). Subfolders:
`icons/providers/` (wierd-agents provider marks, LobeHub license), `icons/programs/` (the whole
program-icon set Herdr ships, Lucide/LobeHub licenses). The program table itself is
`docs/research/programs.json` (copied from `herdr-app-src/defaults/programs.json`).

All SVGs are 24x24 viewBox, `stroke="currentColor"` (Lucide style, stroke 1.5–2) unless noted:
render them as template images tinted with the color given in this spec.
`spinner.svg` has its own stroke 3.2 with a 24%-opacity track circle + a quarter arc.
Program icons with `tint:false` (claude, codex, …) are full-color pictures; `tint:true` ones are
one-color glyphs (pi.svg is `fill="#fff"`: tint it).

---

## 0. Theme, fonts

The layout's theme is `{ light: "paper", dark: "atom-one-dark" }` (from `layouts/.state/wierd-layout.json`).
The screenshot is **atom-one-dark** (sampled pixels match exactly). Resolved `theme()` colors
(dumped with `herdr-app check` on a temp mod):

| name | atom-one-dark (shown) | paper (light) | used for |
|---|---|---|---|
| `canvas` | `#1c1f24` | `#fafaf9` | behind pane cards (work area) |
| `chrome` | `#16191d` | `#f1f1ee` | sidebar, tab bar, status bar bg |
| `background` | `#21252b` | `#ffffff` | terminal + pane header bg |
| `surface` | `#21252b` | `#ffffff` | space card bg |
| `raised` | `#35393e` | `#f6f6f6` | active tab pill bg, ctx bar track, badge hover |
| `popover` | `#2e3238` | `#ffffff` | menus |
| `hover` | `#ffffff0e` | `#0000000c` | hover bg; inactive space header bg |
| `selected` | `#ffffff17` | `#00000012` | selected row bg, open badge |
| `border` | `#ffffff18` | `#00000017` | all 1px borders |
| `input` | `#ffffff24` | `#00000026` | sub-agent tree lines |
| `foreground` | `#eeeeef` | `#1b1b1e` | primary text |
| `muted` | `#9c9ea1` | `#69696b` | secondary text, icons |
| `dim` | `#6f7175` | `#969698` | tertiary text, icons |
| `accent` | `#61afef` | `#1f62d0` | focus rings, focused pane border, active space tint |
| `accent_foreground` | `#21252b` | `#ffffff` | |
| `working` | `#e5c07b` | `#9a6700` | working status |
| `blocked` | `#e06c75` | `#c93c2c` | needs-you status |
| `done` | `#61afef` | `#2f6fe4` | done (unread) status |
| `idle` / `unknown` | `#6f7175` | `#a8a8aa` | idle ring |
| `ansi1..6` | `#e06c75 #98c379 #e5c07b #61afef #c678dd #56b6c2` | see paper | git ahead/behind, connected dot |

Alpha suffixes in the code are hex alpha appended to `#rrggbb`: `26`=15%, `34`=20%, `3d`=24%,
`80`=50%, `99`=60%, `0d`=5%, `59`=35%.

Hex literals used by the mods (theme-independent on dark; on light themes `meta.js` swaps the
statusline hexes for the named ANSI color):

- Space avatar fills (`MARK`): `ansi6 #22a99a`, `ansi3 #e3814f`, `ansi4 #5b8def`, `ansi5 #8b7cf6`,
  `ansi2 #3fae6a`, `ansi1 #d9649a`; letter `#ffffff`.
- Effort ladder (pi-statusline Tokyo Night): `off #565f89`(dim), `minimal #bb9af7`(ansi5),
  `low #7aa2f7`(ansi4), `medium #7dcfff`(ansi6), `high #ff9e64`(ansi3), `xhigh #f7768e`(ansi1),
  `max` = per-letter gradient `#ff9e64 → #f7768e → #d787af → #bb9af7`. Unknown word → `muted`.
- Context bar: `≤60% #9ece6a`(ansi2), `61–80% #e0af68`(ansi3), `>80% #f7768e`(ansi1); fill
  drawn at alpha `99`.
- Context number (prompt cache): warm `#9ece6a`(ansi2), last 30 s `#e0af68`(ansi3), expired/unknown `muted`.

Fonts: UI font **Geist** (`ui_font_family`, base 13), mono **JetBrains Mono**
(`settings().font_family`, terminal 14). Both ship with Herdr and are OFL – bundle them.
Each mod sets its own text sizes (listed below). "medium" = 500, "semibold" = 600, "bold" = 700.
Mono text in the sidebar: model, effort, context number, age, folder paths.

---

## 1. Window wireframe

Layout file values (sidebar 268). **Note:** the user's current window has the sidebar dragged
to **370** (`layouts/.state` + screenshot); everything inside is width-flexible.

```
┌──────────── sidebar 268 (bg chrome) ───────────┬1┬──────────────── work (bg canvas) ─────────────────────────┐
│ brand bar                                 46   │ │ tab bar 42  [⧉ 1 ◔ ×] [⧉ 2]  ...flex...  + │Files│Changes│Memory│
│  [logo] Wierdr                    (⌕) (▯)      │ │──────────────────────────── border_b 1 ────────────────────│
├────────────────────────────────────────────────┤ │ work-body: padding 8, gap 8 between panes                  │
│ spaces list (flex, min 90)  pt 4, px 8         │ │ ┌ pane card (radius 10, 1px border / accent if focused) ┐ │
│  ▭ This computer             + ● ˅      26     │ │ │ header 30: [icon] Pi  ~/me/dev/wierdr     ⇥ ⤓ ⤢ ×   │ │
│ ╭ [W] wierdr                     ⟲ ˅    34 ╮   │ │ │────────────────────────────────────────────────────│ │
│ │ ╭ ◔ Wierdr iPad-приложение…          ╮  │    │ │ │ terminal (padding 14 x, 12 y)                      │ │
│ │ │ A\ Opus 5.5 @xhigh  ⑂2 105k  5m   │52│    │ │ │                                                    │ │
│ │ ╰ ▬▬▬▬───────────────ı──────────────╯  │    │ │ │                                                    │ │
│ ╰─────────────────────────────────────────╯ 6 │ │ └────────────────────────────────────────────────────┘ │
│ ╭ [H] herdr-app                  ⟲ ˅       ╮   │ │                                                            │
│ │  ○ Исходники мобильного…              52 │   │ │                                                            │
│ │  ⑂ lazygit        ~/.local/share/chezmoi 28│   │ │                                                            │
│ ╰──────────────────────────────────────────╯   │ │                                                            │
│  …                                             │ │                                                            │
│  ⊟ lf (folded)                     ● ›    26   │ │                                                            │
│  + Add machine                            26   │ │                                                            │
├─ (limits/usage panel 93 — NOT in scope) ───────┤ ├────────────────────────────────────────────────────────────┤
│ footer 41: ⚙ Settings                          │ │ status bar 28:  ◔ 1   ○ 12      (limits strip: out of scope)│
└────────────────────────────────────────────────┴─┴────────────────────────────────────────────────────────────┘
```

- Root: row, bg `canvas`, 1px vertical divider (`border`) between sidebar and work.
- Sidebar column (bg `chrome`): brand 46 / spaces flex / usage 93 (drop) / footer 41.
- Work column: tabs 42 / work-body (padding 8, gap 8) / status row 28.
- Right side panel (Files/Changes/Memory, 368 wide, hidden by default) is outside this spec;
  only its toggle buttons in the tab bar are described.

---

## 2. Brand bar (`wierd-chrome`, no props) — height 46

- Row, bg `chrome`, `padding-left 14` (desktop uses 76 on macOS windowed to clear the traffic
  lights – drop on iPad), `padding-right 10`, gap 4, vertically centered, text 13.5.
- Left (flex 1, gap 8): logo `icons/herdr.png` 20×20 corner radius 5; then **"Wierdr"**
  semibold, `foreground`.
- Right: two icon buttons, each 26×26, radius 6, icon 15×15, color `muted`;
  hover: bg `hover`, icon `foreground`.
  1. `search.svg` → opens the **picker** (Herdr's ⌘P quick switcher: type to filter
     spaces/tabs, Enter goes, spaces needing you first). Wierdr's is "Go to"
     (`QuickSwitcher`): spaces and agents in the iPhone list's look, fuzzy filtered, the
     field at the bottom (docs/FEATURES.md §2). **Wierdr has no button for it**: the spaces
     list pulled down past its top opens it (`PullToSearch`), and ⌘P; the bar keeps only
     the toggle.
  2. `sidebar.svg` → collapses the sidebar to a 44/76 px "rail" (or back to its width).
- The whole block is a window-drag area on desktop (drop).

Collapsed rail (optional on iPad): width < 160 → brand bar shows only the toggle; spaces become
26-pt rows with the space number (+ most urgent compact mark), active row bg `raised`; a `»`
at the bottom (13, dim) expands.

## 3. Footer (`wierd-chrome` `{footer:true}`) — height 41

- Column, bg `chrome`, `border-top 1 border`, padding: h 8, top 4, bottom 8, text 13.
- One row: h 28, padding-x 8, gap 9, radius 8, color `muted`, hover bg `hover` + text
  `foreground`; icon `settings.svg` 14; label **"Settings"**. Tap → `app.settings`.
- When an app update is ready, a 6×6 `accent` dot follows the label (iPad: use for an
  app/core-update badge or drop).

---

## 4. Spaces list (`wierd-agents` → `spaces.js` + `agents.js` + `scroll.js`)

### 4.1 List container
- bg `chrome`, `padding-top 4`, rows placed in a custom scroll view with `padding-x 8`, rows
  **gap 0** (a card is drawn as pieces that meet edge to edge), 8 pt end spacer.
- Scrollbar: 3-pt thumb, 2 pt from the right edge (inside the 8-pt padding), min 24 tall,
  color `dim`@40% (`66`), hovered/dragged `muted`@60%. iPad: native indicator is fine.
- Auto-scroll: when the shown space or the focused pane changes, the row is scrolled into view
  (centered if it fits, 8-pt margin), animated 280 ms ease-out.
- Row reorder animation: when rows change places inside a card (an agent overtakes another) each
  moved row slides from its old y to the new one, 240 ms ease-in-out. Nothing else animates;
  **nothing spins** (deliberate: GPU cost on desktop).

### 4.2 Machine header ("This computer") — height 26
Shown only when at least one remote machine exists (`hc machine ls` / `machine.list`
non-temporary, here `lf`); then rows are grouped: this computer first, then machines by name.
- Row h 26, padding-x 8, gap 7, text 11, color `dim`, hover bg `hover` (no radius).
- `monitor.svg` 13 (local) / `server.svg` 13 (remote) · label "This computer" / machine name
  (flex, truncate) · [folded only: status summary marks, §4.6] · [not connected: state word e.g.
  "unreachable", "asleep" (underscores→spaces)] · `+` text glyph (padding-x 4, radius 4, hover bg
  `hover` + `foreground`; tap → new space on that machine) · 6×6 dot: `ansi2` (#98c379) when
  connected, else `dim` · chevron 11 (`chevron-down.svg` open / `chevron-right.svg` folded).
- Tap row → fold/unfold that machine (persisted; `wierd.spaces.folded`, currently `["lf"]`).
- Folded machine: no spaces under it. Remote machine with no spaces: a 28-pt "New space there"
  row (`plus.svg` 12, text 12 dim, radius 7, hover). "Loading…" row (28, 12 dim) while its
  layout loads. Rebuilt machine: "rebuilt · Connect" (Connect `muted`, error in `blocked`).
- After the last machine: **"Add machine"** row, same style as a machine header with `plus.svg` 13.

### 4.3 Space card
Each space is a card: bg `surface`, 1px `border`, corner radius **10**, 6 pt gap after each card.
Inside: header (34), then 4 pt, then the rows with 4 pt between them, 4 pt under the last row.
Rows inside the card are inset 4 pt from the card's border (card padding 4).

**Space header** (h 34; a worktree space nested under its repo: h 32):
- `padding-left 12` (4 card pad + 8 row pad so avatar aligns with row icons), `padding-right 10`,
  top corners radius 9 (all 4 when the card has no body), `border-bottom 1 border` when the body
  shows.
- Background: active (shown) space `accent`@15% (= `#2b3a48` on atom-one-dark); others `hover`
  (`#2d3137` composited). Hover: active `accent`@20%, others `selected`.
- Content row, gap 9, vertically centered:
  1. **Avatar** 18×18, radius 5, fill = space color (§4.7), centered first letter of the name,
     uppercased, 10.5 bold `#ffffff`. (Worktree: instead 22-pt indent + `branch.svg` 13 `dim`.)
  2. **Name** semibold 13 `foreground`, max width 150, truncate tail.
  3. **Git tail** (flex, right-aligned, gives way first), text 11.5 `dim`, gap 5:
     `"<repo> · <branch>"` only where unusual — repo omitted when equal to the space name (or
     for a worktree row), branch omitted when equal to the name or `master`/`main`; then
     `↑N` in `ansi2`, `↓N` in `ansi1` (ahead/behind upstream). Detached → "detached".
  4. **Status marks** only while the card body is hidden (§4.6).
  5. Two 20×20 button slots (radius 5, gap 1, trailing −4 margin), icon `dim`, hover bg `raised`
     + `foreground`; an unavailable button leaves an empty slot so columns line up:
     - `history.svg` 13: "pi sessions" (§4.10). Only for local spaces.
     - `chevron-down.svg` 12 (shown) / `chevron-right.svg` 12 (hidden): "Hide tabs"/"Show tabs";
       only when the space has tabs. Persisted per space (`wierd.spaces.closed`).
- Tap header → select space (`space.select`). Right-click → space menu (§4.9). Press-and-hold
  220 ms or move 4 pt → drag to reorder within its machine (card lifts, bg `raised`, border
  `accent`@60%, big shadow; landing slot = dashed `accent`@35% outline on `accent`@5%).

### 4.4 Agent row (h 52)
Container: padding h 8 / v 6, gap 2, radius 8, two lines + context bar overlay.

- **Background by status** (`statusTint`): working → `working`@15%, done → `done`@15%,
  blocked → `blocked`@15%; hover → same @24%. Idle: none; idle+focused → `selected`; idle hover
  → `hover`.
- **Focus ring**: the agent whose pane is focused gets a 1-pt `accent` border overlay, radius 8
  (drawn on top; nothing moves).
- **Line 1** (h 20, gap 9): status column 18 wide (centered status mark, §4.5) · **title** flex,
  truncate tail, 13 medium `foreground`.
- **Line 2** (h 18, gap 9, base 12):
  - provider column 18 wide: provider mark (`icons/providers/<mark>.svg`) 13 `muted`, else
    the program icon 14 `muted` (§4.8). Tooltip: raw provider id.
  - flex (gap 4, mono 10.5): **model** (truncate; `muted`, or `dim` when idle and not focused)
    then **@effort** colored per level (§0).
  - right group (gap 7, no shrink):
    - remote agents: machine name (10, `dim`), e.g. `lf`.
    - sub-agents badge: h 18, padding-x 5, gap 4, radius 5, bg `hover` (open: `selected`),
      text 11 `muted` (open: `foreground`), `git-branch.svg` 11 + count in a 14-wide centered slot.
      Count = live hc child agents + `agent.subagents` label. Tappable only when hc child
      agents exist (expands the tree, §4.4.1).
    - terminals badge: same with `terminal.svg`, count of live child terminals that don't report.
    - **context number** in a fixed 34-wide right-aligned slot, mono 10.5, colored by prompt
      cache (§0). Empty slot kept for a pi with no context yet.
    - **age** in a fixed 26-wide right-aligned slot, mono 10.5 `dim`. On hover the slot shows
      the pin button instead (`pin.svg` / `pin-off.svg` 13, padding 2, radius 4, `dim`, hover
      bg `hover`).
- **Context bar** (only when the agent has `agent.*` labels): absolute, left 8 / right 8 /
  bottom 3, height 2, radius 1, track `raised`; fill width = ctx/ctx_max (min 2 pt), color by
  threshold (§0) at 60% alpha. **Cache tick**: 2×6 pt (bar 2 + 4 up), `foreground` @50%,
  bottom-aligned with the bar, x = round(fraction_left × (bar_width − 2)) where fraction_left =
  (cache_until − now)/cache_ttl; moves right→left as the prompt cache expires, disappears at expiry.
- Tap → focus that pane (`pane.focus`, i.e. select its space+tab and focus the pane).
- Tooltip on the number: `"105k of 1M context · 10% · cache till 00:16:44"` or `· cache expired`.

#### 4.4.1 Sub-agent rows (expanded, h 26)
padding-left 17 / right 8, radius 8, text 12.5; tree connectors (9 wide, 17 tall, 1.5-pt
`input` lines, `└`/`├` get a bottom stroke with radius 6) per depth; program icon 14
`foreground` + 8 gap; name (`name` || `template` || program name || address) `muted`
(`foreground` when shown); trailing status mark (non-compact). Tap → peek that terminal.
Child status: core word, `error`→blocked, `done`→idle.

### 4.5 Status marks (`kit.js statusMark`, compact form used in rows)
| status | mark |
|---|---|
| working | `spinner.svg` 12×12 (+1 h margin), `working` color. **Static** (ring + 90° arc). |
| blocked (compact) | 14×14 radius 4, bg `blocked`@15%, "!" 10.5 bold `blocked` |
| blocked (full) | pill h 18, padding-x 6, radius 5, bg `blocked`@15%, "Needs you" 10.5 semibold `blocked` |
| done (unread) | 7×7 filled circle `done` (+3 h margin) |
| idle | 7×7 ring, 1.5-pt stroke `idle` (+3 h margin) |
| other/unknown | 7×7 empty |

The **unread/"done" marker** is the blue filled dot + blue row tint. A done agent you look at
becomes idle but keeps its "done" place in the sort until you leave it.

### 4.6 Status summary marks (hidden card body / folded machine)
Row gap 8, text 11; per status with count>0 in order blocked, done, working: compact mark + count
(gap 4), count `blocked` for blocked else `muted`. Tooltip "1 needs you · 2 done". Counts include
pane-less sub-agents (attributed to their nearest ancestor's space); idle not counted.

### 4.7 Space color / name
- Color: shared `space.colors` map spaceId → `ansi1..6` or `#rrggbb`; a new space gets the
  palette entry used least (palette order `ansi6, ansi3, ansi4, ansi5, ansi2, ansi1`), `~`
  spaces get none (default `ansi6`). Map to `MARK` hexes.
- Name: the doc's `name` when set; else the **repo top-level folder name** of the space's first
  terminal's live folder (foreground cwd → `git rev-parse --show-toplevel`), else that folder's
  basename, `~` at home, else the space's `folder`.

### 4.8 Program (icon/name/tile) resolution
From `programs.json` (`programs.rs::resolve`): (1) if the terminal's 7501 report has `app`
→ entry whose key or `match` equals it (case-insensitive), else the generic `agent` entry named
after the app; (2) else `foreground.argv` (fallback `argv`): unwrap `zsh -ic '"$@"…' zsh <cmd>`;
interpreters (`node`, `npx`, `uv`, …) → first known script name; then the table by
`basename(argv0)`; shells → `shell` entry named after the shell (`zsh`); else `program` entry with
a hashed tile color (`#6d5bd0 #2f80ed #0f9d8a #d9822b #c2417d #3a7d44 #8a5a44 #4e5d94`, FNV-1a
of the name). Object: `{key, name, icon, tint, tile, color, shell, agent}`. These layouts draw
icons only (tinted when `tint`); `tile`/`color` (colored rounded tile + glyph) are unused here.

### 4.9 Plain terminal row (non-agent pane, h 28)
e.g. `lazygit                ~/.local/share/chezmoi`
- padding-x 8, gap 9, radius 8; focused: bg `selected` + accent focus ring; hover bg `hover`.
- 18-wide icon column: program icon 14 `muted` (lazygit → `programs/lazygit.svg`); no icon in
  the table → `terminal.svg`; mod pane → `file-text.svg`.
- Name 13 `foreground`, max width 150, truncate: **the foreground process's own name** =
  basename of `foreground.argv[0]` (leading `-` dropped) || `foreground.name` || basename(`argv[0]`).
  (Not the program table's name: shows `lazygit`, `zsh`, `ping`.)
- Folder: flex, right-aligned, mono 10.5 `dim`, **middle-truncated** to fit (`~/…/slides/deck`;
  ≈6.4 pt/char budget): for a shell, the path in its title `user@host:PATH`; else
  `foreground.cwd`, else pane cwd; `$HOME` → `~`. Tooltip: full path.
- Tap → focus the pane.

### 4.10 Sessions ("history") view
History button replaces the whole list with that space's pi sessions:
- Header h 31, padding l 10 / r 16, gap 8, text 11.5 `dim`: "Back" button (h 24, pl 4 pr 8,
  radius 6, `chevron-left.svg` 13 + "Back", hover bg `hover`) · spacer · avatar 16 · space name
  `muted` truncate · total count `dim`.
- Rows exactly like agent rows (h 52) but: title = session name || first user line || "Untitled
  session"; status column = status of the pi that has it open (else empty; a spinner `dim`
  while launching); model `muted` if open else `dim`; context/effort from the open pi's labels,
  else from the file; age = file mtime; bar always shown. Rows separated by 1 pt.
- Paging: 10 at first, +10 at the end of the list; a 26-pt "N more · M left" row
  (`chevron-down.svg` 11) or "Loading… · M more" with spinner.
- Notes (26 pt, 11.5 `dim`): "Reading sessions…", "No pi sessions in this folder.",
  "This space has no folder on this computer.", "Can't read sessions: …".
- Tap: open pi → focus its pane; else starts `pi --session <id>` (hc run --bg --rm --no-parent
  in the session's cwd through a login shell) and shows it in a peek overlay (82%×82% dialog with
  a 38-pt bar: status, provider icon, title semibold 12.5, **Keep ↵** (accent button) makes it a
  tab, **✕ esc** closes and kills that pi).

### 4.11 Ordering
- **Spaces**: doc order (per machine: local first, then machines by name), except each git
  worktree space is moved directly under its repo's main checkout space (`├─`/`└─`, branch icon).
  The mod also writes that order back with `space.move`.
- **Inside a space**: groups = tabs. Tabs that contain agents first, sorted by their first
  agent; then tabs without agents in tab order. Empty tabs skipped.
- **Inside a tab**: agents sorted by `pinned` desc → urgency desc (blocked 4 > done 3 > working 2
  > idle 1; an agent takes the max of its own and its sub-agents' ranks; a viewed done agent keeps
  rank 3 until left) → time of last status change desc (newest first) → `seq` desc. Then the
  tab's non-agent panes in pane order.
- A tab with ≥2 panes: its rows are joined by a 2-pt `accent`@50% bracket on the left
  (`[` shape, 10 pt wide, corners radius 8, at x = card pad 4).
- `⌘]`/`⌘[` step through all visible rows (agents and terminals) in this order, wrapping.

---

## 5. Tab bar (`wierd-tabs`) — height 42
- Row, bg `chrome`, `border-bottom 1 border`, padding-x 10 (desktop: left pad grows to clear
  traffic lights when the sidebar is hidden – use 10), gap 3, centered.
- Tabs strip: flex, horizontal scroll, gap 3. Then `+`, then the panel buttons.
- Scroll wheel over the bar → previous/next tab.

### Tab pill
- h 29, padding-x 10, gap 7, radius 7, text 12.8, 1-pt border.
- **Active**: bg `raised`, border `border`, text `foreground`, plus close button.
  **Inactive**: bg `chrome`, border `chrome` (invisible), text `muted`. Hover: bg `hover`.
- Content: program icon 14 (`muted` when tinted) of the tab's first agent pane, else its first
  pane · label (max width 170, truncate): tab `name` (unnamed tabs are "1", "2", … = position),
  `+ " Z"` when zoomed · status: working → `spinner.svg` 12 `working` (static); blocked or done →
  6×6 dot in `blocked`/`done`; idle → nothing · active only: `close.svg` 12 `dim` → `tab.close`.
- Interactions: tap → `tab.select`; double-click → rename; drag onto another pill → `tab.move`;
  right-click → tab menu (§7).

### `+` button
26×26 radius 6, text glyph "+" `dim`, hover bg `hover` + `foreground`. Opens **new-menu**
(§6) as a 250-wide popup.

### Right-side panel buttons (Files / Changes / Memory)
h 26, padding-x 8, gap 5, radius 6, text 12, icon 14 (`file.svg`, `changes.svg`,
`memory.svg`); on: bg `selected` + `foreground`; off: bg `chrome` + `muted`; hover `hover`.
Toggle the right side panel (remembered per space). Out of scope for v1 – drop or keep as stubs.
Windows-only min/max/close buttons – drop.

## 6. New menu (`new-menu`) — popup 250 wide, bg `popover`, padding 5, text 12.8
- Row style: h 31, padding-x 9, gap 10, radius 7, hover bg `selected`; icon 14; label flex;
  hint 11 `dim` right.
1. **Terminal** (`programs/shell.svg`, hint `⌘T`) → `tab.new` (a shell tab in the active space).
2. Section label "Start an agent" (11 `dim`, padding 9/8/4).
3. Installed agents from `knownAgents()` (most-picked first), icon per program (tinted
   `foreground` when `tint`), hint = `1`…`9` (number keys start them); then up to 2 not-installed
   ones disabled (`dim`, hint "not installed"). Each → `tab.new {name, argv: run}`.
   Currently: Claude Code, Codex, Pi, Cursor installed; OpenCode, Copilot shown as not installed.
   "Checking installed agents…" / "Could not check installed agents" placeholder rows.
4. 1-pt `border` separator (mx 4, my 5).
5. **New space** ("+" glyph, `⌘N`) → `space.new`; **New worktree…**, **Open worktree…**
   (`branch.svg`) → worktree dialogs.

## 7. Context menus (`menu`) — popup 200 wide, bg `popover`, padding 5, text 12.8
Row h 31, padding-x 8, gap 9, radius 7, icon 14 `muted`, label `foreground`, shortcut 11 `dim`;
keyboard-selected row bg `selected`; 1-pt separator (mx 7, my 4) before Close items.
- **Space**: Rename (`square-pen`) · New worktree / Open worktree (`git-branch`, if a git repo) ·
  Remove worktree (if a linked worktree) · Close (`x`).
- **Tab**: Rename (`square-pen`, F2) · New tab (`plus`, ⌘T) · Close (`x`, ⌘W).
- **Pane** (terminal right-click): Split right (`panel-right`, ⌘D) · Split down (⌘⇧D) · Zoom
  (`square`, ⌘⇧↩) · Send right-clicks to pane / Use Herdr right-click menu · Send back to
  `<parent>` (kept sub-agents) · Close pane (`x`, ⌘⇧W).

## 8. Pane card + pane header (`wierd-pane`)
**Card** (layout `pane` frame, `lone: true` = even a single pane is a card): bg `background`,
1-pt `border`, **focused pane: 1-pt `accent`** (replaces the border), radius 10, gap 8 between
panes; work-body padding 8 on `canvas`. Terminal content padding 14 (x) × 12 (y).
Splits follow the doc's row/column tree with `size.weight`s.

**Header** (h 30, top, always visible):
- Row, padding-x 10, gap 8, bg `background`, `border-bottom 1 border`, text 12.
- Program icon 14 `dim` · **name** medium `foreground`, max width 260, truncate:
  agent or shell → program name ("Pi", "zsh"); else the terminal title; else program name; else
  "shell" · **cwd** flex, truncate, `dim`, `$HOME`→`~` (pane cwd = foreground cwd).
- Buttons only while hovered: padding 3, radius 4, icon 14 `dim`, hover bg `hover` +
  `foreground`: `split-right.svg` → `pane.split right`, `split-down.svg` → `pane.split down`,
  `zoom.svg`/`unzoom.svg` → `pane.zoom` (toggle), `close.svg` → `pane.close`.
- No agent status in the header (the sidebar and tab show it). Tap header → focus pane.

## 9. Status bar (`agent-counts`) — height 28 (left third of the status row)
- Row, bg `chrome`, `border-top 1 border`, padding-x 14, gap 14, text 11.5 `muted`.
- Items in order blocked, done, working, idle; **working and idle always**, blocked/done only
  when > 0. Each: compact mark (§4.5) + count, gap 6. Count color `dim` when 0, `blocked` for
  blocked, else `muted`; working spinner `dim` when 0.
- Counts are over `agents()` (pane agents only).
- Tap an item with count > 0 → focus the next agent with that status after the focused one in
  sidebar order (wrapping). Tooltip "12 idle".
- The right two thirds is the `limits` strip – out of scope.

---

## 10. Data: where every piece of text comes from

### 10.1 Core API is enough for nearly everything
herdr-core already exposes what the desktop mods read. The app's `agents()`/`terminals()`/
`panes()`/`spaces()` are derived from:

| desktop API | core source (iPad) |
|---|---|
| spaces/tabs/panes tree, names, folders | `doc.get {name:"herdr-app"}` (and `{…, on:"lf"}` per machine); live via `events.subscribe` `doc` events. Shape: `{spaces:[{id, name, folder, tabs:[{id, name, root:{type:"row"/"column"/"block", id, children, size:{weight}, content:{terminal:"t5w"}}}]}]}` (~6 KB). Active space/tab/focus are **per screen**, not in the doc – keep your own. |
| terminal records | `events.subscribe {}` → snapshot of all terminals + events `created, restarted, removed, finished, lost, status, turn, title, labels (whole map), keep, size, foreground, doc`; heartbeat 15 s. One subscription, push-only, ~1–2 KB per terminal in the snapshot. |
| `terminals()[i].report` | the record's `status` object (OSC 7501 root record) |
| `terminals()[i].status` word | `status.state` |
| pane cwd | `foreground.cwd` (fallback record `cwd`) |
| program | resolved from `status.app` / `foreground.argv` / `argv` (§4.8) |
| machines | `machine.list` |

Agent status as shown (docs/labels.md, `model.rs::status`): `status.state` `working` → working;
`blocked`/`error` → blocked; otherwise **done if `turn > labels["herdr.seen"]`** (no label →
client's own rule), else idle. The iPad should also **write** `herdr.seen=<turn>` via
`terminal.label` once per turn while an agent is really on screen (only raising it), so "done"
clears on every client; "mark unread" = `turn-1`. Pinned = `labels["herdr.pinned"]` non-empty;
pin/unpin = `terminal.label {herdr.pinned:"1"|""}` (Wierdr writes the pin's Unix time in seconds
instead of "1", still non-empty, for the iPhone list's pin order). A terminal belongs to a space/tab via labels
`herdr.space`/`herdr.tab` (ids local to its machine).

### 10.2 OSC 7501 status record (live, `hc get t5w --json`)
```json
"status": {"app":"pi","msg":"Wierdr iPad-приложение для herdr-core","state":"working"},
"status_ms": 1794351820588, "turn": 0, "reported": true
```
Record fields (schema `Status`): `state` (idle|working|done|blocked|error, required), `app`,
`msg`, `title`, `kind` (permission|question|auth, blocked only), `progress` (0–100).
`records` (other 7501 records by id) is **empty/absent on every live terminal** today – nothing
in these mods reads it. The rich agent data comes from **labels** (below), not records.

### 10.3 `agent.*` labels written by pi (`@wierdbytes/pi-herdr`), live values
```
agent.app=pi                 agent.model=Claude Opus 5.5    agent.model_id=claude-opus-5-5
agent.provider=anthropic     agent.effort=xhigh             agent.ctx=102488
agent.ctx_max=1000000        agent.cache_until=1794352397764 (epoch ms)
agent.cache_ttl=300000 (ms)  agent.session=01a1c7a8-55bf-77ad-b9e3-d3c9830b09a8
agent.pid=55908              agent.subagents=2 (only when >0)
herdr.seen=0  herdr.space=sp…  herdr.tab=tb…  [herdr.pinned=1]
```
All strings. Trust them only if `agent.app` is set **and** `agent.pid == foreground.pid` (stale
labels from a crashed pi are ignored). Claude Code/Codex/etc. have no `agent.*` labels → their
rows show the program name in the model slot and no bar/number.

### 10.4 Agent row, field by field
| UI | source | transform |
|---|---|---|
| status mark + row tint | `status.state`, `turn`, `herdr.seen` | §10.1 |
| title "Wierdr iPad-приложение для herdr-core" | `status.msg` (pi's session name; a question while blocked) | strip leading non-letter/digit chars, trim. Fallbacks: tab name if the tab was named and ≠ program name; terminal `title` if "telling" (not program name/key, not starting with `~` or `/`, no `@`); program name; tab name; address |
| provider mark (Anthropic "A\\") | `agent.provider` | regex map → `providers/<mark>.svg` (anthropic, openai\|chatgpt→openai, google\|gemini\|vertex→google, opencode, openrouter, *copilot*→github-copilot, …, see `meta.js PROVIDERS`); none → program icon |
| model "Opus 5.5" | `agent.model` | drop `"Vendor: "` prefix and `vendor/` id prefix; drop leading `Claude ` under anthropic, `GPT ` under openai, `Kimi ` under kimi/moonshot. No label → program name ("Claude Code") |
| "@xhigh" | `agent.effort` | `"@"+word`, color per level (§0) |
| sub-agent badge "⑂ 2" | `agent.subagents` + count of live terminals whose `parent` == this address and that report a status | |
| context "59.4k" / "105k" | `agent.ctx` | `<1000`: integer; `<100k`: one decimal + `k` (`.0` dropped); `<1M`: integer `k`; else `x.yM`. Hidden when 0/absent |
| its color | `agent.cache_until` vs now | warm green; ≤30 s left yellow; expired `muted` |
| bar fill | `agent.ctx / agent.ctx_max` | clamp 0–1; color ≤60 green / ≤80 yellow / >80 red (by floor %) |
| bar tick | `cache_until`, `cache_ttl` | §4.4 |
| age "56s" | time since the agent's state last changed | use `status_ms` from the record (the desktop uses the earlier of its own observed change time and the tab's `working_since`/`changed_at`; done→idle is not a change). Format: largest unit that fits: `Ns` (<60), `Nm` (<60), `Nh` (<24), `Nd`. Re-render when the string would change |
| machine "lf" | address prefix `lf/t1` | |
| plain row name/folder | `foreground.argv`/`name`, title, `foreground.cwd` | §4.9 |
| pane header name/cwd | program, `title`, `foreground.cwd` | §8 |

Cost: all of the above come from the single `events.subscribe` stream + `doc.get` → **zero
extra calls**; the age needs only a local timer.

### 10.5 Things that need `machine.exec` / `file.read` (and estimated cost)
1. **Space name** (unnamed spaces) and **git tail** (repo/branch/ahead/behind):
   `machine.exec {argv:["git","--no-optional-locks","-c","core.fsmonitor=false","status","--porcelain=v2","--branch"], cwd}`
   (`# branch.head X`, `# branch.ab +A -B`) + `git rev-parse --show-toplevel` +
   `git rev-parse --path-format=absolute --git-common-dir` (repo name = folder of `<common>/..`;
   linked worktree when common ≠ `<top>/.git`). ~10–50 ms each on the Mac, one per distinct
   (machine, folder); re-run when a cwd changes, when an agent's turn ends / a program exits,
   and at most every 60 s while visible. Cheap approximation: basename of `foreground.cwd`.
2. **Space colors**: `file.read {path:"~/.config/herdr-app/shared.json"}` → key `space.colors`
   (~6 KB, desktop-local file; read once + on refresh). Fallback: assign with the same palette rule
   and store on the iPad.
3. **Sessions/history view**: the desktop runs
   `node ~/.config/herdr-app/mods/wierd-agents/sessions.mjs '<json>'` with
   `{root:"~/.pi/agent/sessions", dirs:[{cwd, limit:10}], known:{file: byteOffset}}` and gets
   `{dirs:{cwd:{total, files:[{file, mtime}]}}, read:{file:{end, id, cwd, name, provider, model, effort, ctx, first}}}`.
   Session folder = `root/--<cwd without leading "/", "/" "\\" ":" → "-">--/`, files
   `<ISO time>_<session id>.jsonl`, newest by mtime. JSONL lines used: `{"type":"session", id, cwd}`
   (line 1), `{"type":"session_info", name}`, `{"type":"model_change", provider, modelId}`,
   `{"type":"thinking_level_change", thinkingLevel}`, assistant `message` lines (tail after the last
   `"api":"` → `provider`, `model`, `thinkingLevel`/`providerThinkingLevel`, `usage.totalTokens` =
   ctx; skip `stopReason` aborted/error), first user message text = fallback title.
   Live pi ↔ session: label `agent.session` = session id (= file name suffix).
   Remotely: `machine.exec {line:"node ~/.config/herdr-app/mods/wierd-agents/sessions.mjs '<json>'"}`
   (`line` runs in the machine's shell; node must be on that PATH – else use
   `argv:["/bin/zsh","-lc", …]`). First page reads whole files (1–2.5 MB each here → ~100–400 ms);
   later polls pass `known` offsets and cost ~ms; output a few KB. Polled every 10 s while shown.
   `file.read` alone can't list a directory and is line-based, so it isn't a good fit.
   Model windows for closed sessions: `pi --list-models` via login shell (~1 s, cache forever).
4. **Installed agents** for the + menu: `machine.exec` the login shell with
   `command -v claude codex pi …` (the app's check, cached 1 min/machine) — or read the desktop's
   cache `shared.json` → `new-menu.agents[""]` (already has key/name/icon/run/installed).
5. **Program icons**: bundle `icons/programs/*.svg` + `programs.json` in the app; no fetch.

---

## 11. Behavior summary
| element | tap | secondary (desktop right-click / hover) |
|---|---|---|
| search button | quick switcher (picker); Wierdr: a pull of the spaces list instead | |
| sidebar toggle | collapse to rail / restore | |
| machine header | fold/unfold machine | `+` new space on that machine |
| space header | select space | menu: Rename, worktrees, Close; drag to reorder |
| history button | sessions view | |
| chevron | hide/show the space's rows | |
| agent row | focus its pane (select space+tab) | hover: pin/unpin; badge: expand sub-agents |
| sub-agent row | peek the terminal | |
| terminal row | focus pane | |
| Settings | settings | |
| tab pill | select tab | ×: close; double-click rename; drag reorder; menu |
| + | new menu | |
| pane header | focus pane | hover: split right/down, zoom, close |
| status count | focus next agent with that status | |

Keyboard (keys.json, worth mapping to iPad hardware keyboards): `⌘]`/`⌘[` next/prev sidebar row
(this layout), `⌘⌥]`/`⌘⌥[` next/prev space, `⌘⇧]`/`⌘⇧[` and `⌃Tab`/`⌃⇧Tab` next/prev tab,
`⌘1–9` tab N, `⌃1–9` space N, `⌘T` new tab (terminal), `⌘W` close tab, `⌘N` new space, `⌘P`
picker, `⌘B` toggle sidebar, `⌘D` / `⌘⇧D` split right/down, `⌘⇧W` close pane, `⌘⇧↩` zoom,
`⌘⌥←↑→↓` move focus between panes, `⌘⌥⇧arrows` swap panes, `F2` rename tab, `⇧F2` rename space,
`⌘⇧M` Memory panel, `⌘,` settings. Menus: ↑/↓, Enter, Esc; new menu: `1–9` start the Nth agent.

Desktop commands vs core: `space.*`, `tab.*`, `pane.split/close/zoom` are desktop-app commands
that edit the `herdr-app` doc (`doc.set` with `version`) and start/kill terminals
(`terminal.run` with labels `herdr.space`/`herdr.tab`/`herdr.seen=0`, `terminal.kill`). The iPad must
implement them the same way.

## 12. Desktop-only → drop or adapt on iPad
- Traffic lights / `pl(76)` brand padding / tab-bar traffic-light padding, `window_drag`,
  double-click-to-maximize, Windows min/max/close buttons → drop.
- Collapsible rail (44/76 px) → use `NavigationSplitView` sidebar show/hide (⌘B, toggle button).
- Hover-only affordances:
  - pane header buttons → always show compact buttons in the focused pane's header, or a `⋯`
    menu / context menu (long-press) with Split right/down, Zoom, Close.
  - pin button in the age slot → swipe action (leading "Pin") + context menu.
  - hover tints → pressed/selected states only.
  - tooltips (ctx details, provider, full path) → context-menu preview or a popover on long-press.
- Right-click menus (space, tab, pane) → `.contextMenu` (long-press).
- Drag-to-reorder spaces (hold 220 ms) / tabs → long-press drag (`onMove` / `draggable`).
- Double-click tab to rename → context menu "Rename".
- Scroll-wheel tab switching → swipe on the tab bar / keyboard shortcuts.
- Custom scroll list + scrollbar → native `ScrollView`/`List` with `ScrollViewReader`
  (keep the "scroll focused row into view" behavior).
- Swipe actions on agent rows: Pin, Mark unread (`herdr.seen=turn-1`), Close tab.
- Sessions peek overlay → sheet / full-screen cover with Keep / Close.
- Files/Changes/Memory side panel and the limits/usage panels → out of scope.
- Sounds, toasts, `app.settings` → iPad settings screen.
- 2x desktop sizes are already in points; on iPad consider +1 pt on 10.5/11 pt mono text and
  44-pt hit targets (keep visuals, enlarge tappable frames).
