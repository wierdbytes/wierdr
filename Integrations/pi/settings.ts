/**
 * `~/.pi/agent/@wierdbytes/pi-wierdr/settings.json`, one file for both
 * halves: `bash` for the herdr side, `agents` for sub-agents. Every key is
 * optional; a missing or broken file means the defaults.
 *
 * Until that file exists, the files of the two packages this one replaced
 * (`@wierdbytes/pi-herdr/settings.json`, `@wierdbytes/pi-agents/settings.json`)
 * are read instead, each for its own half.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";

export const packageDir = (): string => join(getAgentDir(), "@wierdbytes", "pi-wierdr");
export const settingsPath = (): string => join(packageDir(), "settings.json");

/** The settings file of the package a half came from, read while pi-wierdr's own doesn't exist. */
export const legacySettingsPath = (pkg: "pi-herdr" | "pi-agents"): string =>
  join(getAgentDir(), "@wierdbytes", pkg, "settings.json");

/** The file's JSON; `undefined` when there is no file, `null` when it can't be read. */
export function readJson(path: string): unknown {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return undefined;
  }
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
