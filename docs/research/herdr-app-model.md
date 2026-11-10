# Herdr desktop app (herdr-app) data model, for the Wierdr iPad client

Research notes from reading the source. Sources:
- herdr-app source at `/tmp/herdr-app-src` (Cargo version `0.1.15`; minimum core is `distribution/core-version` = `0.1.11`; protocol `GENERATION = 1`, `src/hc.rs:207`).
- herdr-core source at `/tmp/hcore` (`schema/README.md`, `schema/hc.openrpc.json`).
- The live core on this Mac (`hc` 0.1.20, core name `mentoair`, one added machine `lf`).

All `file:line` references are to `/tmp/herdr-app-src` unless they say otherwise.

---

## 0. The short version

- Each machine's core holds one opaque JSON document named `herdr-app`. It contains **only** spaces → tabs → a split tree of panes. It holds no focus, selected tab, zoom, "settled", recent spaces, seen/attention, or colors. Those live per screen in `~/.config/herdr-app/view.json` (and `shared.json`).
- Writes are compare-and-swap: `doc.set {name, value, version, on?}`. A stale version fails with error `data.kind == "conflict"`. Desktop policy: one request in flight per machine, no queue, and the latest state wins. On a conflict it re-reads and **drops its own unsent change** (remote wins, with a "Layout changed elsewhere" toast).
- The desktop **adopts** any live terminal that has a non-empty `herdr.space` label and no pane. It creates the space/tab under the label ids if they are missing. It only does this while it runs, and only for a machine whose document it has read.
- Recommended iPad strategy: do what the desktop does. Start the terminal with labels and `keep:true`, then read-modify-write the document with CAS. Labels make every create self-healing: if your `doc.set` loses a race, the desktop or your own re-read adopts the terminal anyway.

---

## 1. The `herdr-app` document schema

### 1.1 Rust types (exact)

`src/mirror.rs:9-41`:

```rust
pub struct Document {            // top level
    #[serde(default)] pub spaces: Vec<SharedSpace>,
}                                // NOTE: no `rest`, so unknown TOP-LEVEL fields are DROPPED on the desktop's next write

#[serde(default)]                // every field optional; missing => "" / []
pub struct SharedSpace {
    id: String, name: String, folder: String, tabs: Vec<SharedTab>,
    #[serde(flatten)] rest: Map<String, Value>,   // unknown space fields are PRESERVED
}

struct SharedTab {
    #[serde(default)] id: String,
    #[serde(default)] name: String,
    #[serde(default = "empty_root")] root: Node,  // empty_root = {"id":"","type":"row","children":[]}
    #[serde(flatten)] rest: Map<String, Value>,   // unknown tab fields are PRESERVED
}
```

`root` is a `layout::Node` (`src/layout.rs:316-396`). Its `type` is the tag (`#[serde(tag="type", rename_all="lowercase")]` on `Kind`, `src/layout.rs:272-290`):

| `type` | required fields | optional |
|---|---|---|
| `"block"` | `content` | – |
| `"row"` / `"column"` | `children: [Node]` | – |
| `"stack"` | `children` | `active`, `header` (layouts only, never in the doc) |

`content` is untagged (`src/layout.rs:10-30`). Serde tries the variants in this order:

| shape | meaning |
|---|---|
| `{"terminal": "<address>"}` | **terminal pane** (address local to that machine's core, e.g. `"t5w"`) |
| `{"mod": "<mod name>", "props": <any, omitted when null>}` | **mod pane** (markdown viewer, board…); no terminal |
| `{"tab": "active", "pane": {...}}` (alias `context`) | only in window layouts, never in the doc |
| `{"agent": "focused"}` | only in window layouts, never in the doc |

Common `Node` fields that can appear in the doc: `id` (String, default `""`), `size` (untagged: `{"px": f32}` or `{"weight": f32}`), `min`, `max`, `hidden` (omitted when false), `title`. The desktop never puts the look fields in tab trees (`background`, `border`, `radius`, `padding`, `theme`, `font`, `font_size`, `terminal_padding`, `floating`, …), but they would parse. **`Node` has no `rest` map: unknown node fields are DROPPED** the next time the desktop writes the document.

Decoding is strict on types. If a document doesn't decode, the desktop marks that machine's layout "unavailable" (`Outcome::Undecodable`, `src/mirror_sync.rs:76-79`). It shows a "Layout unavailable" toast, refuses structural commands for that machine, and does not retry until the next `doc` event or a reconnect (`src/mirror_sync.rs:32-34`, `src/window.rs:1945-1960`). Things that break decoding:
- `null` where a String is expected (`"name": null` fails: `serde(default)` covers a missing field, not `null`).
- A node without `type`, or a `type` outside block/row/column/stack.
- A block whose `content` matches none of the variants.
- `size` that is neither `{px:n}` nor `{weight:n}`.
- Non-numeric sizes.
- A missing `version` in the `doc.get` reply ("Layout document has no version").

### 1.2 Real example (live document on this Mac, trimmed; `version: 263`)

```json
{"value":{"spaces":[
  {"folder":"/Users/mentor/me/dev/wierd-memory","id":"spe3e2159554ee24c732bb21789555be18","name":"",
   "tabs":[{"id":"tb1b681725cad16be9d0dc040037f2b29a","name":"",
            "root":{"id":"tb1b681725cad16be9d0dc040037f2b29a","type":"row",
                    "children":[{"id":"p04d43dc41b24f4d49b3d7258483c1f77","type":"block","content":{"terminal":"t5w"}}]}}]},
  {"folder":"/Users/mentor","id":"sp4efbad83f656de99e594082ebf2455de","name":"",
   "tabs":[{"id":"tbf10bf70073a2821aaec1c28eafa96dd2","name":"",
            "root":{"id":"tbf10bf70073a2821aaec1c28eafa96dd2","type":"row",
                    "children":[{"id":"p4f77cdf632005f8b05cd79c635a7e819","type":"block","size":{"weight":0.9999997615814208},"content":{"terminal":"t1w"}}]}},
           {"id":"tbdf9f95ad68e33b9e6322bcbab56856ec","name":"",
            "root":{"id":"tbdf9f95ad68e33b9e6322bcbab56856ec","type":"row",
                    "children":[{"id":"p8f00aa9f7531dd27e8244961456069c2","size":{"weight":4.0},"type":"block","content":{"terminal":"t41"}}]}}]}
]},"version":263}
```

The core returns object keys sorted alphabetically. Order doesn't matter. Weights are f32 values widened to f64 (`0.9999997615814208`), and a lone pane can keep a leftover `size`.

Remote machine `lf` (`doc.get {"name":"herdr-app","on":"lf"}` → `version: 3`): same shape, **ids and addresses unqualified**, `folder: ""` (that machine's home):

```json
{"spaces":[{"folder":"","id":"sp6bc8f7a059117d7f59c9102b833bdb0d","name":"",
  "tabs":[{"id":"tb655f6f387d7c23704d8fb56a6de5168e","name":"",
    "root":{"id":"tb655f6f387d7c23704d8fb56a6de5168e","type":"row",
      "children":[{"id":"pb85dd291deefc9c91d2e09e614ac4af4","type":"block","content":{"terminal":"t1"}}]}}]}]}
```

A split tab, as the desktop writes it (from `Node::split`, `src/layout.rs:583-610`):

```json
{"id":"tbA","name":"","root":{"id":"tbA","type":"row","children":[
  {"id":"pX","type":"block","size":{"weight":0.5},"content":{"terminal":"t1"}},
  {"id":"s<32hex>","type":"column","children":[
      {"id":"pY","type":"block","content":{"terminal":"t2"}},
      {"id":"pZ","type":"block","content":{"mod":"markdown","props":{"file":"README.md"}}}]}]}}
```

### 1.3 Field semantics

- `space.id`: `sp…`. Stable. It also appears on terminals as label `herdr.space`.
- `space.name`: the name a person gave. `""` means unnamed (automatic name, §5). The UI's `named` flag = `!name.is_empty()`. It is computed, not stored (`src/model.rs:633-650`).
- `space.folder`: the folder its first terminal was started in. It is the fallback for new terminals and for the automatic name. Empty on remote spaces started in the remote home.
- `tab.id`: `tb…`. **`tab.root.id == tab.id` always** (`Tab::with_pane` builds `Node::container(id, Row, [pane])`, `src/model.rs:113-125`). Label `herdr.tab` holds it.
- `tab.name`: `""` means it is called by its 1-based index.
- `tab.root`: always a `row` container at the root. The root never collapses, even with one child (`src/layout.rs:691-713`, test at `:850-866`).
- Pane = a `block` whose content is `terminal` or `mod` (`Node::is_pane`, `src/layout.rs:439-441`). Split containers have id `s…`.
- Sizes: `{"weight": w}`. A missing size is weight 1.0. `{"px": n}` is fixed and has weight 0 in the flex math (`src/window/pane_size.rs:31-37`). Flex share = weight / sum of sibling weights.
- No version, generation, focus, zoom, settled, or active fields are in the doc. The `version` comes from the core, outside `value`.

### 1.4 Per-machine vs per-screen (verified)

Per machine, shared through the doc: `spaces[].{id,name,folder,tabs}`, `tabs[].{id,name,root}`, and unknown space/tab fields.

Per screen (`mirror::View`, `src/mirror.rs:44-64`, saved to `~/.config/herdr-app/view.json` by `save_view`, `src/window.rs:1096-1104`):

```rust
pub struct View {
    active: Option<String>,                          // selected space id
    spaces: BTreeMap<String, Option<String>>,        // space id -> selected tab id
    tabs: BTreeMap<String, TabView>,                 // tab id -> {focused, before[], zoomed, settled}
    recent: Vec<Recent>,                             // closed spaces {name, folder}
    attention: BTreeMap<String, Seen>,               // address -> {word, seen}
}
```

The test `focus_zoom_and_settle_are_private` (`src/mirror.rs:261-275`) asserts that zoom and settle don't change the document. In `view.json`, ids are machine-qualified (`"lf/sp6bc8…": "lf/tb655…"`). Space avatar colors are per screen too (`shared.json` key `space.colors`).

---

## 2. ID formats and generation

`src/model.rs:173-181`:

```rust
pub fn fresh_id(&mut self, prefix: &str) -> String {
    let random = || RandomState::new().build_hasher().finish();     // random u64
    format!("{prefix}{:016x}{:016x}", random(), random())           // 32 lowercase hex chars
}
pub fn fresh_id_on(&mut self, prefix, machine) -> String { qualify(&self.fresh_id(prefix), machine) }
```

| kind | prefix | example | where |
|---|---|---|---|
| space | `sp` | `spe3e2159554ee24c732bb21789555be18` | `new_space` `src/window.rs:2446` |
| tab | `tb` | `tb1b681725cad16be9d0dc040037f2b29a` | `new_tab`, `adopt`, `keep_terminal` |
| pane | `p` | `p04d43dc41b24f4d49b3d7258483c1f77` | `new_space`, `new_tab`, `split`, `adopt` |
| split container | `s` | `s0123…` | `Model::split_with`, `move_pane` (`src/model.rs:294,322`) |

(`n`, `b`, `r` prefixes are used only in window layouts, never in the doc.)

Swift: `prefix + String(format: "%016llx%016llx", UInt64.random(in: .min ... .max), UInt64.random(in: .min ... .max))`.

**Machine qualification** (`src/mirror.rs:67-73`): inside the app, ids and terminal addresses of a remote machine `lf` are `lf/<id>`. The doc and the labels store them unqualified:

```rust
pub fn qualify(id, machine) -> String { machine.map_or(id, |m| format!("{m}/{id}")) }
pub fn local(id, machine) -> &str      { id.strip_prefix("{m}/") or id }
```

`map_node` (`src/mirror.rs:75-93`) maps each node `id`, `content.terminal`, stack `active`, and float `id`/`terminal`. **Mod `props` are never mapped.**

---

## 3. How the desktop writes the document

### 3.1 Read

`mirror_sync::read` (`src/mirror_sync.rs:72-81`): `doc.get {"name":"herdr-app","on": <machine or null>}`. `value: null` gives `Document::default()` (no spaces). The `version` must be a u64.

### 3.2 Write: one CAS round (`src/mirror_sync.rs:87-110`)

```text
doc.set {"name":"herdr-app","on":on,"version":slot.version,"value":Document}
  ok       -> Written(doc, result.version)
  conflict -> doc.get again -> Conflict(remoteDoc, remoteVersion)
  needs_update | needs_login -> Blocked   (no retry until reconnect or doc event)
  other    -> Unavailable
```

Timeout 10 s (2 s for remote machines while quitting).

### 3.3 When it writes (`flush_documents`, `src/window.rs:1847-1876`)

Per machine slot (key `""` = local, else the machine name):
- Called after **every command** (`run_as` → `flush_documents(false)`, `src/window.rs:2856`). Also on **every 500 ms tick** of the event loop (`src/window.rs:701`, with `refresh = true` when a `doc` or `missed` event arrived), after adoption, and after keep/park.
- `slot.ready()` = connected && no request in flight && (not blocked || dirty).
- `doc = Document::capture(model, machine)`. It writes only if `slot.available && doc != slot.document && no pane drag in progress`. Otherwise, if dirty, it does a plain read.
- There is no debounce and no queue: "Latest-state CAS flushing, with one request per machine and no operation queue" (`src/mirror_sync.rs:1`). Edits made while a request is in flight are carried by the next round, because the projection is recomputed.

### 3.4 When another client writes (`documents_updated`, `src/window.rs:1924-2000`)

- The core sends `{"method":"event","params":{"seq":N,"type":"doc","data":{"name":"herdr-app","version":V},"machine":"lf"?}}` to unfiltered subscribers (`/tmp/hcore/schema/README.md:179-212`). The desktop treats any `doc` or `missed` event as "re-read all slots" (`src/hc.rs:120-140`).
- `Read(d, v)`: when the version changed, or the slot was not available, it **replaces** that machine's spaces in its model with `d` (`Document::replace`, `src/mirror.rs:122-148`), then re-applies its own per-screen view. If it also had an unsent local change that differs from `d`, it shows the toast "Layout changed elsewhere / The other screen's layout is shown." **Remote wins; there is no merge.**
- `Conflict(d, v)`: same, always replace + toast.
- `Written(d, v)`: just records the version.

So the desktop re-reads within about 0.5 s of your `doc.set` and shows your change. The AGENTS.md wording: "On simultaneous edits the newest accepted document wins (no merging); structural commands fail while that machine's layout is unavailable."

### 3.5 Is it safe for a second writer? Yes, with these rules

1. **Always CAS** with the version from your last `doc.get` or `doc.set`. Never write version 0 unless `doc.get` returned `version: 0`.
2. On `conflict`: re-read, re-apply **your intent** (not your stale document), and retry. Use bounded retries with a small jittered backoff. The desktop does not retry the same way: it gives up its edit.
3. **Edit the raw JSON** (`[String: Any]`/`JSONValue`), touching only what you change. Keep:
   - unknown top-level keys (the desktop drops them, but you shouldn't),
   - unknown space/tab keys (the desktop keeps them: `rest`, test `unknown_space_and_tab_fields_survive_a_read_and_write`, `src/mirror.rs:308-330`),
   - unknown node keys,
   - `mod` panes and their `props` exactly as they are,
   - existing `size` numbers (don't reformat them).
4. Invariants the desktop keeps (and assumes):
   - every space has ≥ 1 tab; every tab has ≥ 1 pane (`remove_pane` closes the tab, `remove_tab` closes the space, `src/model.rs:358-411`);
   - `tab.root.id == tab.id` and `tab.root.type == "row"`;
   - every row/column has ≥ 2 children, except the root (`collapse`, `src/layout.rs:691-713`);
   - every id is unique in the document; each terminal address appears in **at most one** pane across the whole doc (`pane_of` takes the first match);
   - a terminal pane's address is local to that machine's core (`t5w`, never `lf/t5w` in the `lf` doc);
   - strings are never `null`.
5. Don't write documents that only differ in formatting: a no-op write still bumps the version and makes the desktop re-read.
6. Values are limited to 1 MiB. `doc.set` with `value: null` **deletes** the document. Never do that.
7. A malformed write "bricks" the desktop's layout for that machine until a valid write happens: it shows "Layout unavailable" and refuses `space.new`/`tab.new`/etc. Validate before writing: encode, decode with your own strict model, and check the invariants above.

---

## 4. Terminals: labels, adoption, and the commands

### 4.1 How the desktop starts a terminal (`AppWindow::spawn`, `src/window.rs:2390-2413`; `Core::run`, `src/hc.rs:466-479`)

```json
{"jsonrpc":"2.0","id":7,"method":"terminal.run","params":{
  "argv": [],                                  // [] => that machine's own shell; agents see below
  "cwd": "/Users/mentor/me/dev/x",             // null/omitted when empty
  "env": {"TERM":"xterm-256color","COLORTERM":"truecolor","TERM_PROGRAM":"herdr"},
  "labels": {"herdr.space":"sp<32hex>","herdr.tab":"tb<32hex>","herdr.seen":"0"},  // LOCAL (unqualified) ids
  "on": null,                                  // or "lf"
  "keep": true,
  "display": {"fg":"#d2d4d9","bg":"#17191d","cursor":"#d2d4d9","cell":[18,36]},     // device px
  "size": {"cols": 120, "rows": 40}            // only when it can compute the pane's grid
}}
→ {"result":{"address":"t5x", ...}}            // remote: "lf/t7"
```

- No `name`, `parent`, `rm`, `wait`, or `line`.
- Folder fallback (`run_following_folder`, `src/window.rs:4686-4698`): if the folder was inherited (not given explicitly) and the run fails with `kind == "spawn_failed"` (and the message does not contain "the holder did not answer"), it retries once in home. For local, home is the absolute home path. For remote it is `""` (cwd omitted), and with `on` that means the remote home.
- Agent argv (`agent_argv` + `unix_agent_argv`, `src/window.rs:111-122, 2419-2434`):
  - local macOS: `[$SHELL, "-lic", "\"$@\"; exec \"$0\" -li", $SHELL, <cmd...>, <task?>]` (fish: `"command $argv[2..]; exec $argv[1] -li"`);
  - remote: `remote_shell::launch(cmd)` = `["sh","-c",<script choosing ${SHELL}>,"sh",<cmd...>]` (`src/remote_shell.rs:8-33`). This form is the right one for the iPad on any machine, because it doesn't need to know `$SHELL`.
  - The task (first message) is appended as the last argv word.
  - Agent commands come from `programs.json` `run`, e.g. `["claude"]`, `["codex","--no-daemon"]`, `["pi"]`.
- After `run`, the desktop adds the pane to its model at once, and the next flush writes the doc.

### 4.2 Adoption (desktop only: `reconcile` / `start_adoption` / `adopt`, `src/window.rs:2144-2243`)

The desktop runs this on every tick, via `tend_terminals` (`src/window.rs:2057`), unless it is quitting:

1. **Orphans** = live terminals where:
   - no pane in the model has this address;
   - the terminal isn't mid-change (keep/park) or being closed;
   - the machine's doc slot is `available` (doc read OK);
   - label `herdr.space` is non-empty.
   They are sorted by address.
2. For each orphan: `terminal.get`. Then `adoptable` (`src/window.rs:4821-4827`): `state == "live"` && `labels.herdr.space == local(space)` && `labels.herdr.tab (non-empty) == local(tab)`. If `keep != true`, it calls `terminal.keep {terminal, keep:true}`.
3. `adopt(addr, space, tab)` (`src/window.rs:2204-2243`):
   - new pane id `p…`; tab id = the label's `herdr.tab`, else a fresh `tb…`;
   - **space unknown** → `add_space(space_label_id, name:"", folder, Tab{id:tab, name:"", pane})`. The folder is the live cwd, else `foreground.cwd`, else `cwd`, else home. The space goes at the end of its machine's block. The selected space is unchanged unless none was selected;
   - **tab exists** → split its *last* pane to the right (`Axis::Row`). Focus and zoom stay as they were;
   - **space exists, tab doesn't** → `add_tab` (inserted after that space's selected tab on that screen). The selected tab is unchanged;
   - then `sync` + `flush_documents` → `doc.set`.

Consequences for the iPad:
- **Labels-only creation works while the desktop is running.** `terminal.run` with fresh `herdr.space`/`herdr.tab` and `keep:true` → the desktop adopts it within about 0.5–1 s and writes the doc. Limitations: the space and tab come out **unnamed**; the tab position depends on that screen's selected tab; a new pane in an existing tab is always split right of the last pane.
- **The desktop isn't running** → nothing happens in the doc. On its next start, once it has read the doc, it adopts any labeled terminal that is still live. Because of `keep:true`, it survives program loss, but not an explicit kill or `exit`.
- **Two adopters are safe thanks to CAS**: the loser of the `doc.set` race re-reads and sees the pane already placed (`pane_of(addr).is_some()`). The desktop as loser shows its "Layout changed elsewhere" toast, nothing worse.
- Labels outlive placement. To "park" a terminal (running, no pane), the desktop writes `herdr.space=""`, `herdr.tab=""` and `keep:false` (`start_terminal_change`, `src/window.rs:2612-2643`). Otherwise it would be re-adopted.

### 4.3 Pane removal when terminals end

- A shown terminal whose attach stream closes with `reason ∈ {exited, killed, finished}` → `remove_pane`. That cascades to the tab and then the space (`terminal_ended`, `src/window.rs:2308-2341`).
- Every tick, panes whose address isn't live (and not just started: 5 s grace, `just_born`) are checked with `terminal.get`. They are removed if `reason ∈ {exited, killed}` or the lookup fails with `kind == "not_found"`. A failed lookup for any other reason is not evidence of exit (`check_closed`/`checked_closed`, `src/window.rs:2527-2566`). Kept terminals in `lost` state stay (`state: "live"`, waiting for `restarted`).

### 4.4 Exactly what each command does (desktop `dispatch`, `src/window.rs:2890-3040`)

The desktop first requires the target machine's doc slot to be `available` (`require_document`, `src/window.rs:2372-2383`; checked in `run_as`, `src/window.rs:2838-2847`).

| command | model change (→ doc) | core calls |
|---|---|---|
| `space.new {name?, folder?, tab?, argv?, task?, machine?}` | ids `sp`,`tb`,`p` on that machine; folder = explicit, else focused pane's cwd **if on the same machine**, else home (`""` remote); `add_space(id, name.trim(), folderActuallyUsed, Tab(tb, tabName.trim(), p, addr))` → **appended at the end of that machine's block** | `terminal.run` as in 4.1 (with `size` from the would-be pane grid) |
| `tab.new {space?, name?, folder?, argv?, task?}` | `add_tab`: inserted **right after the space's selected tab** (end if none); selects it | `terminal.run`, folder = explicit, else the live cwd of the space's selected tab's focused pane, else `space.folder`, else home |
| `tab.new {mod, props}` | tab whose only pane is `{"mod":…,"props":…}` | none |
| `pane.split {direction:"right"\|"down", pane?, argv?}` | `Model::split(target, Row\|Column, p, addr)`; new pane focused; zoom cleared | `terminal.run`, cwd = target pane's live cwd, else `space.folder`; machine = the target pane's address machine |
| `pane.close {pane?}` | if the tab has 1 pane → `tab.close`; else `remove_pane` (share goes back to the previous sibling) | `terminal.kill` on its address + non-kept descendants |
| `tab.close {id?, confirmed?}` | if it's the space's only tab → `space.close`; else `remove_tab` (selection moves to the tab that slides into the slot, else the last) | `kill` of all its addresses (+ descendants) |
| `space.close {id?, confirmed:true}` | `remove_space`; remembered in per-screen `recent` | `kill` of all addresses (+ descendants) |
| `space.rename {id?, name}` | `space.name = name.trim()` (`""` = automatic) | none (the desktop later rewrites the `where` label) |
| `tab.rename {id?, name}` | `tab.name = name.trim()` | none |
| `space.move {id, index}` | reorder inside its machine block only (`move_space`, `src/model.rs:188-199`) | none |
| `tab.move {id, index}` | reorder within its space | none |

`kill` (`src/window.rs:2685-2719`) runs **after** the model change. It walks descendants: any live terminal whose `parent` is a doomed address, **unless it has a non-empty `herdr.space` label** (a kept sub-agent). Each one gets `terminal.kill {terminal}`. Kills are final even for `keep:true` terminals.

`Model::split` details (`src/layout.rs:583-610`):
- If the target's parent has the same axis: insert the new pane right after the target. The target gets `weight = share/2` (unless it is px-sized), and the new pane gets `weight = share/2`, where `share` = the target's weight (missing = 1.0, px = 1.0).
- Otherwise: replace the target with a container `{id: "s<32hex>", type: row|column, children: [target, new]}`. The container takes the target's old `size`; both children have no size.

`remove_pane` → `Node::remove` (`src/layout.rs:570-581, 660-713`):
- The removed share goes to the previous sibling, or to the next one if the removed node was first. This only happens when both sizes are weights or missing.
- Containers left empty are dropped. A row/column left with one child is replaced by that child, and the child takes the container's size. The tab root is never replaced.

---

## 5. Naming and ordering

- **Space name** (`Model::space_name`, `src/model.rs:250-260`): `name` if non-empty. Otherwise take the first terminal pane of the space (tabs in order, panes in tree order). Use `folder_info[address].top` (git toplevel), else `pane_folders[pane]`, else `space.folder`. Then apply `folder_name`.
  - `folder_info` (`src/window.rs:4607-4628`): runs `git -C <cwd> rev-parse --show-toplevel --abbrev-ref HEAD`. Remote machines run it there via `machine.exec` (`mods::run_remote`). It is skipped for local home. Output is two lines, `top` and branch (`HEAD` means detached, so no branch). On failure, `top = cwd`.
  - The cwd comes from the record's `foreground.cwd`, else (local) the shell pid's cwd, else the record's `cwd` (`track_folders`, `src/window.rs:2247-2275`).
  - `folder_name` (`src/model.rs:573-588`): trim trailing `/` and `\`; empty or equal to home → `~`; `/` → `/`; else the last path component.
- **Tab name** (`Model::tab_name`, `src/model.rs:262-267`): `name` if non-empty, else its 1-based index in the space.
- The `where` label (`src/window.rs:1798-1845`): the desktop writes `where = "<space name> / <tab name>"` on each terminal (sub-agents inherit their parent's). `hc ls` shows it. Optional for the iPad.
- **Space order** (`Model::order_spaces`, `src/model.rs:184-186`): a stable sort by `machine: Option<String>`. `None` (this machine) comes first, then machines by byte-wise name. Inside a machine block, the doc order. Tabs: doc order. Panes: tree order (depth first).
- **Pane title**:
  1. the OSC 0/2 title from the stream (`vt.take_title`); empty → the address;
  2. before the stream: the record's `title`;
  3. always passed through `shown_title` (`src/terminal.rs:1131-1155`), which strips leading spinner glyphs (U+2800–28FF braille, `·`, `✢`, `✳`, `✶`, `✻`, `✽`, `◐`–`◓`) and the `"π ⠹ task"`-style braille frame after a ≤ 3-char prefix.
- **Agents' list row text** (`defaults/mods/agents/main.js:41-48, 270-290`): "space · detail". The detail is the tab name if named. Otherwise it is the agent's live title, unless that title equals the program name/key, looks like a path, or contains `@`.

---

## 6. Agent status

### 6.1 Inputs (core)

- Record `status`: the root OSC 7501 record `{state, app, msg, title?, kind?, progress?}` or `null`. `records`: other records by id. `reported`: whether it ever reported. `turn`: counter, +1 each time it stops working.
- Events: `status {status, records, reported}`, `turn {turn, state}`, `labels {labels, record?}`, `title {title}`, `foreground {pid,name,argv,cwd}`.
- Example (`t5w`): `"status":{"app":"pi","msg":"…","state":"working"}`, `"turn":0`, `"labels":{"herdr.seen":"0","herdr.space":"sp…","herdr.tab":"tb…","where":"wierdr / 1","agent.app":"pi",…}`.

### 6.2 Mapping (`terminals_listed` `src/window.rs:2025-2055`, `Model::set_word`/`status`/`rollup` `src/model.rs:468-565`)

```
word = record.status.state   (or record.status itself if it's a string; null if none)
app  = record.status.app     (non-empty)

status(addr):
  no agent entry or word == nil  -> nil (not an agent)
  "working"                      -> "working"
  "blocked" | "error"            -> "blocked"
  otherwise (idle, done, ...)    -> seen_turn != nil ? (turn > seen_turn ? "done" : "idle")
                                                   : (!seen ? "done" : "idle")
seen_turn = max(labels["herdr.seen"] as u64, our own pending write)
local `seen` flag (only when no herdr.seen label):
  word -> working|blocked : seen = true
  any other word after working|blocked : seen = looking (on screen && window active)
  mark_seen(visible addresses) sets seen = true
priority: blocked 4 > done 3 > working 2 > idle 1 > nil 0
tab/space status = max-priority status over the addresses in its tree (rollup)
```

Shared "seen" (`docs/labels.md`, `share_seen` `src/window.rs:1538-1575`):
- While an agent is on screen and the app is in front, write `terminal.label {terminal, labels:{"herdr.seen":"<turn>"}}`.
- Do it once per turn, only to raise the value, and also when the label is missing.
- "Mark unread" writes `turn-1`.
- Terminals a client starts get `herdr.seen=0`.
- Decide on the `turn` event (it follows `status`).

Alerts (`Model::alert`, `src/model.rs:490-503`): a change into blocked/error → "needs you" (sound + toast). A change from busy (working/blocked/error) to a non-busy word while not looking → "finished". There are no alerts for sub-agents (`parent` set) or for terminals that have no pane.

### 6.3 Names and sub-agents

- Display name of an agent: record `name`, else `programs::name(app)` (`programs.json` entry name, e.g. "Claude Code"), else "An agent" (`alert`, `src/window.rs:2103-2140`).
- Sub-agents: a record with non-empty `parent` (normalized to the viewer's address space by `EventLines::live_for`, `src/hc.rs:72-104`).
  - `root_agent` walks `parent` up to 32 levels.
  - In the agents mod, sub-agents without a pane appear as tree rows under their parent. Their status is the raw word, with `error` shown as `blocked` and `done` as `idle` (`kidStatus`).
  - A parent's rank is the max over its subtree.
  - Kept sub-agents (with a pane and `herdr.space`) are also full agents.

---

## 7. Attach details used by the desktop

- One framed connection (`hc connect`, then `{"jsonrpc":"2.0","id":0,"method":"hello","params":{"framed":true}}`). Frames are `[u32 LE channel][u8 kind][u32 LE len][payload]`. Kinds: DATA 0, CREDIT 1, CLOSE 2, RESIZE 3, FOCUS 4, FACTS 5, AUTOMATIC_INPUT 6 (`src/hc.rs:14-21`).
- `events.subscribe {}` (unfiltered, needed for `doc` events). Then `CREDIT 1 MiB` on that channel, and credit for each chunk consumed (`src/hc.rs:482-492`). The event loop drains every 500 ms (`src/window.rs:615-705`).
- **Attach** (`Core::attach`, `src/hc.rs:494-511`):
  ```json
  {"method":"terminal.attach","params":{"terminal":"t5w","cols":C,"rows":R,"history":2000,
    "display":{"fg":"#rrggbb","bg":"#rrggbb","cursor":"#rrggbb","cell":[w_px,h_px]}}}
  ```
  - It doesn't use `observe`, `resize_notifications`, or `resumed`.
  - `automatic_input` is used only if `hello.features` contains `"automatic_input"` **and** the attach reply has `automatic_input: true`. Then VT-generated replies (DA, size reports, kitty graphics replies, mode 2048) go as kind 6; otherwise as DATA.
  - Remote terminals are attached by their qualified address `lf/t7` on the same connection. The core relays.
- **When it attaches**: after the pane's first layout fit, or a 100 ms deadline (`TerminalView::attach/connect`, `src/terminal.rs:259-404`).
  - On each (re)connect it creates a **fresh VT** of the current size: the core repaints screen + history + status + title + `CSI ?9001h/l`.
  - If the pane size changed while the attach was in flight, it detaches and attaches again (replay must match the attach size, `src/terminal.rs:406-420`).
  - The first paint is ingested with a 250 ms batch budget; after that, 6 ms per turn.
- **Every tab's terminals stay attached**, visible or not (instant tab switches; kitty images survive). Hidden tabs are re-fitted once the window geometry is stable for two ticks (`fit_hidden_tabs`, `src/window/pane_size.rs:169-192`).
- **Credits**: after writing each DATA chunk into the VT, `CREDIT len`. The stream starts with 256 KiB; a viewer more than 4 MiB behind gets a repaint.
- **Resize**: `RESIZE cols,rows` (u16 LE each) on every grid change. FACTS (display) is sent *before* the resize (`Grid::fit`, `src/terminal.rs:214-233`). It also re-sends RESIZE on mouse-down in the pane, to reclaim size from another device (CHANGELOG 0.1.15). The last *active* viewer (attached, typed, resized, or focused) owns the size. **The iPad will fight the desktop for size**: whoever was active last wins.
- **Grid size** = `floor((w - 2*padX)/cellW)` (min 2) × `floor((h - 2*padY)/cellH)` (min 1) (`grid_size`, `src/terminal.rs:51-56`).
- **Focus**: `FOCUS [1]` when the terminal view gains keyboard focus, `[0]` when it loses it or its pane is hidden (`blur`).
- **FACTS** (JSON `Display`) on theme or cell-size change, only when changed (`display_update`, `src/terminal.rs:182-196`).
- **Stream end**: `CLOSE` with `{"reason":"exited","exit_code":0,"signal":null}`. `exited`/`killed`/`finished` remove the pane. `Stream::Lost` (connection drop) → `lost = true`, reattach on reconnect. After a `restarted` event (kept terminal got a new shell, record `pid` set again), `reattach_if_needed` reattaches (`src/window.rs:2093-2097`).
  - Attach errors: `unavailable` / "lost the core" / "no reply" mean lost (retry later); `finished` means the pane goes; anything else is shown but not treated as an exit.
- **Keys** (`key_bytes`, `src/terminal.rs:1404-1480`): every key goes through **libghostty-vt's key encoder**, configured from the VT's current modes (`ghostty_key_encoder_setopt_from_terminal`, `src/vt.rs:1694-1730`). The core never encodes keys. Modes that matter, all tracked by the client VT:
  - kitty keyboard protocol flags (`CSI > u` push/pop);
  - modifyOtherKeys (CSI 27 sequences);
  - DECCKM application cursor keys and keypad mode;
  - win32-input-mode `?9001` (ConPTY; special Enter/Escape encodings, `src/win32_keys.rs`);
  - bracketed paste `?2004` (`vt.paste_bytes`);
  - mouse tracking/SGR modes (`vt` mouse encoder);
  - macOS Option-as-Alt.
  Legacy-mode extras: Ctrl+[ → ESC, Ctrl+I → TAB, Ctrl+M → CR, Ctrl+-/_ → 0x1f (unless modifyOtherKeys asks for CSI 27). An iPad client without a full VT must at least track DECCKM, bracketed paste, and kitty flags; using libghostty-vt on iOS is the faithful route.
- **Env for spawned terminals**: `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=herdr`.

---

## 8. Remote machines

- `machine.list {}` → `{"machines":[{"name":"lf","host":"de-1","id":"…","target":"agent@lf.example.com","session":null,"state":"connected","temporary":false,"version":"0.1.14","via":false,"since_ms"?,"why"?}]}`.
  - The desktop asks every 5th tick (~2.5 s) or whenever the terminal list changed (`src/window.rs:676-679`).
  - It **ignores `temporary: true`** machines entirely.
  - States: `connected` (doc slot usable); `needs_update` / `needs_login` (blocked, hint `hc machine update|login <name>`); anything else = unavailable with `why`.
  - On a reconnect (`since_ms` changes) the slot becomes dirty and is re-read (`Slot::connection`, `src/mirror_sync.rs:35-50`).
  - Spaces of machines no longer listed are dropped from the model (not from their doc) (`src/window.rs:1990-2005`).
- Each machine's doc: `doc.get {"name":"herdr-app","on":"lf"}` and `doc.set {..., "on":"lf"}`. Its `doc` events arrive on the local subscription with `"machine":"lf"`. After any `missed` event (which the core also sends when a remote stream (re)subscribes), re-read all machines' docs.
- In-app qualification: `Document::replace(model, Some("lf"))` maps every id/address to `lf/<x>` and sets `space.machine = "lf"`. `capture` strips the prefix on write. Terminal records for remote machines already come qualified (`lf/t1`). New ids for a remote space are generated with `fresh_id_on(prefix, "lf")` → `lf/sp…` in the app, written as `sp…` in lf's doc.
- New space on a remote machine: `on: "lf"`; folder `""`, so cwd is omitted and the core uses the remote home. Agents use the `remote_shell::launch` argv. A split stays on the target pane's machine.
- Labels written on remote terminals use the unqualified ids (`herdr.space: "sp…"`). Adoption qualifies them using the address prefix.

---

## 9. Theme

Presets live in `src/settings.rs:17-79`. Defaults: dark = `graphite`, light = `paper` (`DEFAULT_DARK/LIGHT`, `:83-84`).

Panel colors are derived in `resolve` (`src/settings.rs:306-367`). `mix(a,b,t)` mixes each 8-bit channel: `round(a*(1-t)+b*t)`. `is_light` = `0.2126R+0.7152G+0.0722B > 0.5`.

- dark: `fg = #eeeeef`; popover = mix(bg,white,.06); raised = mix(bg,white,.09); hover `#ffffff0e`; selected `#ffffff17`; border `#ffffff18`; input `#ffffff24`; canvas = mix(bg,black,.16); chrome = mix(bg,black,.32); muted = mix(bg,fg,.6); dim = mix(bg,fg,.38); solid_foreground = mix(bg,black,.28).
- light: `fg = #1b1b1e`; popover = bg; raised = mix(bg,black,.035); hover `#0000000c`; selected `#00000012`; border `#00000017`; input `#00000026`; canvas = mix(bg,#e8e8e2,.2); chrome = mix(bg,#e8e8e2,.6); muted = mix(bg,fg,.66); dim = mix(bg,fg,.46); solid_foreground = `#ffffff`.
- both: accent = ansi4; accent_foreground = bg; solid = fg; ring = mix(bg,fg,.7); idle = unknown = mix(bg,fg,.38); working/blocked/done = the preset's `status` triple (theme files: ansi3/ansi1/ansi4); cursor = palette cursor or terminal foreground.

Computed values (Python replica of `resolve`; f32 vs f64 could change a single channel by 1 in rare .5 cases):

| key | graphite (dark) | paper (light) |
|---|---|---|
| `background` (terminal bg, `surface`) | `#17191d` | `#ffffff` |
| `terminal_foreground` | `#d2d4d9` | `#25272c` |
| `foreground` (UI text) | `#eeeeef` | `#1b1b1e` |
| `surface` | `#17191d` | `#ffffff` |
| `canvas` | `#131518` | `#fafaf9` |
| `chrome` | `#101114` | `#f1f1ee` |
| `popover` | `#25272b` | `#ffffff` |
| `raised` | `#2c2e31` | `#f6f6f6` |
| `hover` | `#ffffff0e` | `#0000000c` |
| `selected` | `#ffffff17` | `#00000012` |
| `border` | `#ffffff18` | `#00000017` |
| `input` | `#ffffff24` | `#00000026` |
| `muted` | `#98999b` | `#69696a` |
| `dim` | `#696a6d` | `#969698` |
| `accent` | `#96b2d7` | `#1f62d0` |
| `accent_foreground` | `#17191d` | `#ffffff` |
| `solid` | `#eeeeef` | `#1b1b1e` |
| `solid_foreground` | `#111215` | `#ffffff` |
| `ring` | `#aeaeb0` | `#5f5f62` |
| `selection` | `#394454` | `#cfdcf5` |
| `cursor` | `#d2d4d9` | `#25272c` |
| `working` | `#e5c07b` | `#9a6700` |
| `blocked` | `#f0705f` | `#c93c2c` |
| `done` | `#76a8ff` | `#2f6fe4` |
| `idle` | `#696a6d` | `#a8a8aa` |
| `unknown` | `#696a6d` | `#a8a8aa` |
| `ansi0` | `#45484f` | `#25272c` |
| `ansi1` | `#dc8c95` | `#c62a2a` |
| `ansi2` | `#a6bd91` | `#1a7f37` |
| `ansi3` | `#d8be87` | `#8f5d00` |
| `ansi4` | `#96b2d7` | `#1f62d0` |
| `ansi5` | `#b5a2ce` | `#7a45c8` |
| `ansi6` | `#8cbdc3` | `#0f6f74` |
| `ansi7` | `#d2d4d9` | `#5f6068` |
| `ansi8` | `#818793` | `#7b7e87` |
| `ansi9` | `#f0a5ad` | `#d1242f` |
| `ansi10` | `#bad5a2` | `#1f883d` |
| `ansi11` | `#ead2a1` | `#9a6700` |
| `ansi12` | `#b0cbef` | `#0969da` |
| `ansi13` | `#cbb7e6` | `#8250df` |
| `ansi14` | `#a4d5db` | `#1b7c83` |
| `ansi15` | `#f0f0f2` | `#111214` |

The terminal VT theme is `fg = terminal_foreground`, `bg = background`, `cursor`, `selection_bg = selection`, `palette16 = ansi0…15`, plus `minimum_contrast` (default 1.0 = off) (`vt::theme`, `src/vt.rs:64-73`). Status icons in the agents mod: working = spinner in `working`; blocked = "Needs you" pill with `blocked` text on `blocked + "26"` (15% alpha); done = filled 7 px dot in `done`; idle = 7 px ring (1.5 px) in `idle`.

**Fonts and sizes** (`Settings::default`, `src/settings.rs:518-540`):
- Terminal: `"JetBrains Mono"` (`DEFAULT_FONT`, `:841`), 14 px, ligatures off.
- UI: `"Geist"`, 13 px.
- `terminal_padding` default `[10, 6]` (x, y px). **The shipped `main` layout overrides it to `[14, 12]`** (`defaults/layouts/main.json:10-13`); the `terminals` layout uses font size 15.
- Zoom 1.0 (0.5–3.0).

Bundled fonts (`assets/fonts/`, embedded via `include_bytes!` at `src/settings.rs:826-835`):

| file | license |
|---|---|
| `Geist.ttf` (variable, UI) | SIL OFL 1.1, `OFL.txt` ("Copyright 2024 The Geist Project Authors") |
| `GeistMono-Variable.ttf`, `GeistMono-Italic-Variable.ttf` | SIL OFL 1.1, `OFL.txt` |
| `JetBrainsMono-Variable.ttf`, `JetBrainsMono-Italic-Variable.ttf` (terminal) | SIL OFL 1.1, `OFL-JetBrainsMono.txt` ("Copyright 2020 The JetBrains Mono Project Authors") |
| `SymbolsNerdFont-Regular.ttf` (icon fallback for terminals) | MIT, `LICENSE-SymbolsNerdFont.txt` ("Copyright (c) 2014 Ryan L McIntyre") |

Full notices are in `THIRD-PARTY-NOTICES`.

---

## 10. Program table and icons

- Built-in table: `defaults/programs.json` (122 programs), compiled in (`src/programs.rs:13`). A person's `~/.config/herdr-app/programs.json` overrides it entry by entry. Icons: `defaults/icons/*.svg` (24×24 viewBox SVGs), installed to `~/.config/herdr-app/icons/`. The `icon` path is relative to that home (`"icons/claude.svg"`). Licenses: `defaults/icons/LICENSES.md` (Simple Icons CC0, Lucide ISC/MIT, LobeHub MIT).
- Entry fields: `name`, `icon`, `tint` (true = one-color glyph drawn in `color`/currentColor; false = full-color picture), `tile` (square background), `color` (glyph color on the tile), `match` (aliases: process names or 7501 app names), `run` (argv to start it as an agent).
- **Resolution** (`programs::of` → `resolve`, `src/programs.rs:291-353`), with inputs `app` = `record.status.app` and `argv` = `record.foreground.argv` if non-empty, else `record.argv` (`running_argv`, `src/window.rs:4814-4817`):
  1. `app` non-empty → find by key or `match` (case-insensitive) → that entry with `agent:true`. Unknown → the `agent` entry, with the name set to `app`.
  2. Shell wrapper `argv = [shell, "-…c", script containing "$@" (or the fish form), x, cmd…]` → resolve `argv[4..]`. Windows `pwsh -NoExit -Command "& 'x' …"` → the parsed words.
  3. No argv → `shell` entry (`shell:true`).
  4. `first = basename(argv[0])` with leading `-` and trailing `.exe` stripped. If `first` is an interpreter (`node, bun, bunx, deno, python, python3, npx, pnpm, yarn, uv, uvx, ruby, bundle, env, sudo, nice, time, watch, nodemon`), take the first non-`-` argument whose basename (minus `.js/.mjs/.cjs/.ts/.py/.rb`) is a known non-interpreter entry.
  5. Find `first` by key or `match`.
  6. `first` is a shell (`zsh, bash, fish, sh, dash, nu, pwsh, powershell, cmd, elvish, xonsh, tcsh, csh, ksh, ion`) → `shell` entry, named after the shell, `shell:true`.
  7. Otherwise → `program` entry named `first`, with `tile = hash_color(first)` (FNV-1a 32-bit over the bytes, mod 8, into `["#6d5bd0","#2f80ed","#0f9d8a","#d9822b","#c2417d","#3a7d44","#8a5a44","#4e5d94"]`) and `color = "#ffffff"`.
  - Output: `{key, name, icon, tint (default true), tile, color, shell, agent}`.

| key | name | icon | tint | tile | color | match | run |
|---|---|---|---|---|---|---|---|
| `claude` | Claude Code | `icons/claude.svg` | false | `#1c1d21` | `#ffffff` | `claude-code` | `["claude"]` |
| `codex` | Codex | `icons/codex.svg` | false | `#1c1d21` | `#ffffff` | – | `["codex","--no-daemon"]` |
| `pi` | Pi | `icons/pi.svg` | true | `#1c1d21` | `#ffffff` | – | `["pi"]` |
| `gemini` | Gemini | `icons/gemini.svg` | true | `#8e75b2` | `#ffffff` | – | `["gemini"]` |
| `opencode` | OpenCode | `icons/opencode.svg` | true | `#1c1d21` | `#ffffff` | – | `["opencode"]` |
| `cursor` | Cursor | `icons/cursor.svg` | true | `#1c1d21` | `#ffffff` | `cursor-agent` | `["cursor-agent"]` |
| `copilot` | Copilot | `icons/copilot.svg` | true | `#1c1d21` | `#ffffff` | `github-copilot` | `["copilot"]` |
| `amp` | Amp | `icons/amp.svg` | false | `#1c1d21` | `#ffffff` | – | `["amp"]` |
| `grok` | Grok | `icons/grok.svg` | true | `#1c1d21` | `#ffffff` | `grok-build` | `["grok"]` |
| `shell` | Shell | `icons/shell.svg` (Lucide terminal) | true | `#16241a` | `#4ec95f` | – | – |
| `lazygit` | Git Changes | `icons/lazygit.svg` | true | `#3f8f4f` | `#ffffff` | `gitui`, `tig` | – |
| `nvim` | Neovim | `icons/nvim.svg` | true | `#57a143` | `#ffffff` | – | – |
| `vim` | Vim | `icons/vim.svg` | true | `#019733` | `#ffffff` | `vi`, `view` | – |
| `git` | Git | `icons/git.svg` | true | `#f03c2e` | `#ffffff` | – | – |
| `ssh` | SSH | `icons/ssh.svg` | true | `#5b4bd6` | `#ffffff` | `mosh`, `et` | – |
| `node` | Node | `icons/node.svg` | true | `#5fa04e` | `#ffffff` | – | – |
| `python` | Python | `icons/python.svg` | true | `#3776ab` | `#ffffff` | `python3`, `ipython`, `pip`, `pip3` | – |
| `agent` (unknown agent) | Agent | `icons/agent.svg` | true | `#1c1d21` | `#d6d8db` | – | – |
| `program` (unknown program) | Program | `icons/program.svg` | true | hash color | `#ffffff` (base `#d6d8db`) | – | – |

Menu order for startable agents: `claude, codex, pi, opencode, cursor, copilot, amp, gemini, grok`, then the rest by key (`AGENTS_FIRST`, `src/programs.rs:65`). Note that `claude.svg` and `codex.svg` are full-color (`tint:false`): render them as images, not template glyphs.

---

## 11. Recommendations for the iPad client

1. **Data layer = one `MachineDocStore` per machine** (`""` local + each non-temporary `machine.list` entry). Each holds `{rawJSON, version, state: loading|ready|unavailable|blocked, error}`.
   - Subscribe first (`events.subscribe {}` unfiltered).
   - Then `doc.get` each machine. Re-read on a `doc` event (use `params.machine` and `data.name == "herdr-app"`), on `missed`, on reconnect, and when a machine's `since_ms` changes.
2. **Model** in app space with qualified ids (`lf/sp…`, `lf/t7`), exactly like `Document::replace`. Keep the raw JSON per machine and apply edits as JSON patches on the raw tree, so unknown fields survive. Strip qualification only when writing.
3. **Writes**: a single serialized writer per machine.
   - `doc.set` with the last version. On `conflict`, `doc.get` → re-apply the *intent* (a pure function `(doc) -> doc?`) → retry (≤ 5, jittered 100–400 ms). If the intent no longer applies (tab gone, terminal already placed), stop.
   - Never write while `unavailable`/`blocked` (mirror `require_document`).
   - Validate invariants before every write (§3.5). Skip writes that change nothing semantically.
4. **Creating** (mirror §4.4 exactly):
   - `space.new`: generate `sp`/`tb`/`p` ids. Then `terminal.run` with `labels {herdr.space, herdr.tab, herdr.seen:"0"}`, `keep:true`, the env triple, `display`, `size`, `on`, and cwd (with the home-fallback retry). Then CAS-insert `{id, name: trimmed or "", folder: cwdUsed, tabs:[{id, name:"", root:{id: tbId, type:"row", children:[{id: pId, type:"block", content:{terminal: localAddr}}]}}]}` at the end of `spaces`.
   - `tab.new`: same, inserting after the iPad's selected tab, or appending.
   - `pane.split`: same, with the `Node::split` weight rules.
   - Order matters: run the terminal **first**, then write the doc, as the desktop does. If the doc write ultimately fails, the labels let the desktop adopt the terminal. Before each retry, re-check `pane_of(address)`: if the desktop adopted it meanwhile, apply only the leftover intent (e.g. set the name) instead of adding a second pane.
5. **Closing**: CAS-remove first (`tab.close` on the last tab = `space.close`; `pane.close` on the last pane = `tab.close`). Apply `Node::remove` share/collapse rules. Then `terminal.kill` every address plus non-kept descendants (`parent` chain, skip those with a non-empty `herdr.space`). Ask for confirmation, as the desktop does (`confirmed`).
6. **Renames**: CAS-set `name` (trimmed; `""` = automatic). Nothing else is needed. The desktop refreshes the `where` label itself; the iPad may also write `where` when the desktop is off.
7. **Optional orphan adoption on the iPad** (when the desktop is off), following `reconcile`/`adoptable`/`adopt` exactly: CAS makes concurrent adopters safe. Optionally also remove dead panes per §4.3. Both are safe and keep the iPad's view truthful when the Mac app is closed. If you skip them, show labeled-but-unplaced terminals as "pending" in the UI.
8. **Alternative for structure edits while the desktop runs**: `ssh mac herdr-app do tab.new '{"space":"sp…"}'` drives the running window over `~/.config/herdr-app/herdr-app.sock` (`src/control.rs`). It has exact desktop semantics, but only works when the app runs, needs the `herdr-app` CLI on PATH, and isn't usable for remote-machine-only setups. Use it as a fallback at most.
9. **Per-screen state stays on the iPad**: selected space/tab, focused pane, zoom, settled, recent, colors. Store it in app storage keyed by qualified ids, and fall back to the first tab/pane when an id disappears (`View::apply`).
10. **Attach**: `history: 2000`, `display` facts, and real `cols/rows` (send `RESIZE` when the grid changes, FACTS before RESIZE). Send `FOCUS` 1/0. Credit after consuming. Negotiate `automatic_input`. Consider `observe: true` for thumbnails/peeks so the iPad doesn't steal the Mac's size. Reattach on `restarted` and on connection loss. Drop the pane on CLOSE with `exited|killed|finished`.
11. **Status**: implement `status()`/`rollup()` from §6.2, and write `herdr.seen` per `docs/labels.md`, only while the iPad app is in the foreground and the agent is on screen.
12. **Theme and fonts**: hard-code the graphite/paper tables above. Bundle JetBrains Mono (terminal, 14 pt) and Geist (UI, 13 pt), both OFL. Use terminal padding `[14, 12]` to match the default layout.
