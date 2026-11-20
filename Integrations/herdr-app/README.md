# wierdr — Wierdr's sidebar in the Herdr desktop app

A layout for the [Herdr](https://herdr.dev) desktop app (`herdr-app`) that puts Wierdr's
sidebar on the Mac: space cards drawn bottom up, agent rows, and the header at the bottom
(the limits' rings, the agents' status ring, `+`). Sizes are Wierdr's points scaled by `S`
in [`look.js`](mods/wierdr-sidebar/look.js).

- [`layouts/wierdr.json`](layouts/wierdr.json) (+ its preview `wierdr.svg`): the layout.
- [`mods/wierdr-sidebar`](mods/wierdr-sidebar): one mod, several parts picked by its props
  (the list, the status ring, `+`, the top strip, menus, the peek bar; see the head of
  [`main.js`](mods/wierdr-sidebar/main.js)).
- [`mods/wierdr-tabs`](mods/wierdr-tabs): the tab bar with the side panel's views (Files,
  Changes, Memory), remembered per space. A copy of the author's `wierd-tabs` (itself a clone
  of Herdr's `tabs`).
- [`mods/wierdr-pane`](mods/wierdr-pane): each pane's header (program icon, title, folder;
  split, zoom, close). A copy of `wierd-pane` (a clone of Herdr's `pane`).

## Install

```
sh Integrations/herdr-app/install.sh
```

It copies every mod in `mods/` and the layout into `~/.config/herdr-app` (`HERDR_APP_HOME`
picks another home) and runs `herdr-app check` on each mod. Pick the layout with `layout.switch`
(`cmd-shift-l`). Edit the files here and install again; don't edit the installed copies.

The layout also uses mods that aren't here: `limits` (the rings, from wierd-limits),
`wierd-memory` (the Memory view, `wmem herdr install` from wierd-memory), and Herdr's own
`files` and `changes`.

Keys go in `~/.config/herdr-app/keys.json`, in a section for the layout:

```json
"layout:wierdr": {
  "cmd-]": "wierdr-sidebar.next",
  "cmd-[": "wierdr-sidebar.prev",
  "cmd-shift-m": "wierdr-tabs.memory"
}
```

`wierdr-sidebar.sessions` shows (or hides) the shown space's pi sessions;
`wierdr-tabs.memory` (or `.files`, `.changes`) opens that view of the side panel, or closes it.

Imports must stay inside the mod's folder: `herdr-app check` rejects `../`, absolute paths
and symlinks ("resolves outside the application directory"). Herdr writes
`gpui-kit.d.ts` and `jsconfig.json` into the installed mod; they aren't kept here.
