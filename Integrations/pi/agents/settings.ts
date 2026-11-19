/**
 * The `agents` key of `~/.pi/agent/@wierdbytes/pi-wierdr/settings.json`
 * (`../settings.ts`). Every key is optional; a missing or broken file means
 * the defaults.
 */

import { join } from "node:path";
import { legacySettingsPath, packageDir, readJson, settingsPath } from "../settings.ts";

export interface AgentsSettings {
  /** How to start pi in a sub-agent's terminal. */
  command: string[];
  /** Extra pi arguments for every sub-agent, e.g. `["--no-voice", "--no-peon"]`. */
  extraArgs: string[];
  /** How deep sub-agents may nest: 1 = only the top pi starts sub-agents. */
  maxDepth: number;
  /** Give sub-agents this pi's environment (API keys, PATH), minus terminal identity. */
  inheritEnv: boolean;
}

export const DEFAULT_SETTINGS: AgentsSettings = {
  command: ["pi"],
  extraArgs: [],
  maxDepth: 1,
  inheritEnv: true,
};

export const runsDir = (): string => join(packageDir(), "runs");

const strings = (v: unknown): string[] | undefined =>
  Array.isArray(v) && v.every((x) => typeof x === "string") ? (v as string[]) : undefined;

export function parseSettings(raw: unknown): AgentsSettings {
  const o = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  const command = strings(o.command);
  return {
    command: command && command.length > 0 ? command : DEFAULT_SETTINGS.command,
    extraArgs: strings(o.extraArgs) ?? DEFAULT_SETTINGS.extraArgs,
    maxDepth:
      typeof o.maxDepth === "number" && Number.isFinite(o.maxDepth) && o.maxDepth >= 0
        ? Math.floor(o.maxDepth)
        : DEFAULT_SETTINGS.maxDepth,
    inheritEnv: typeof o.inheritEnv === "boolean" ? o.inheritEnv : DEFAULT_SETTINGS.inheritEnv,
  };
}

/** pi-wierdr's file (its `agents` key), or pi-agents' while that one doesn't exist (the same keys at the top). */
export function loadSettings(path = settingsPath(), legacy = legacySettingsPath("pi-agents")): AgentsSettings {
  const raw = readJson(path);
  if (raw === undefined) return parseSettings(readJson(legacy));
  return parseSettings((raw as { agents?: unknown } | null)?.agents);
}
