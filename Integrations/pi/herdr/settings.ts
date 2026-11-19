/**
 * The herdr side's key in `~/.pi/agent/@wierdbytes/pi-wierdr/settings.json`
 * (`../settings.ts`). Every key is optional; a missing or broken file means
 * the defaults.
 */

import { legacySettingsPath, readJson, settingsPath } from "../settings.ts";

export interface HerdrSettings {
  /** Run bash commands (the model's and `!`) in herdr-core terminals under pi's. */
  bash: boolean;
}

export const DEFAULT_SETTINGS: HerdrSettings = { bash: true };

export function parseSettings(raw: unknown): HerdrSettings {
  const o = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  return { bash: typeof o.bash === "boolean" ? o.bash : DEFAULT_SETTINGS.bash };
}

/** pi-wierdr's file, or pi-herdr's while that one doesn't exist (the same keys at the top). */
export function loadSettings(path = settingsPath(), legacy = legacySettingsPath("pi-herdr")): HerdrSettings {
  const raw = readJson(path);
  return parseSettings(raw === undefined ? readJson(legacy) : raw);
}
