/**
 * @wierdbytes/pi-wierdr — pi for herdr and Wierdr, two halves in one extension:
 *
 * - `herdr/`  — model, effort, context, session and cache as `agent.*` labels
 *               on pi's herdr-core terminal; Claude / Codex subscription limits
 *               as herdr-core's `limits` document; pi's bash commands in
 *               herdr-core terminals under pi's (formerly @wierdbytes/pi-herdr)
 * - `agents/` — sub-agents as their own pi in herdr-core terminals nested
 *               under this one: Agent / get_subagent_result / steer_subagent /
 *               stop_subagent and a pi.events RPC (formerly @wierdbytes/pi-agents)
 *
 * Settings for both: `~/.pi/agent/@wierdbytes/pi-wierdr/settings.json`
 * (`settings.ts`). Outside a herdr-core terminal neither does anything.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import setupAgents from "./agents/index.ts";
import setupHerdr from "./herdr/index.ts";

export default function piWierdr(pi: ExtensionAPI) {
  setupHerdr(pi);
  setupAgents(pi);
}
