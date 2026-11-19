import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { DEFAULT_SETTINGS as AGENTS_DEFAULTS, loadSettings as loadAgents, runsDir } from "./agents/settings.ts";
import { loadSettings as loadHerdr } from "./herdr/settings.ts";
import { settingsPath } from "./settings.ts";

describe("one settings file for both halves", () => {
  const saved = process.env.PI_CODING_AGENT_DIR;
  let dir: string;
  const write = (pkg: string, value: unknown) => {
    mkdirSync(join(dir, "@wierdbytes", pkg), { recursive: true });
    writeFileSync(join(dir, "@wierdbytes", pkg, "settings.json"), typeof value === "string" ? value : JSON.stringify(value));
  };

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "pi-wierdr-settings-"));
    process.env.PI_CODING_AGENT_DIR = dir;
  });
  afterEach(() => {
    if (saved === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = saved;
    rmSync(dir, { recursive: true, force: true });
  });

  it("lives under @wierdbytes/pi-wierdr, the runs next to it", () => {
    expect(settingsPath()).toBe(join(dir, "@wierdbytes", "pi-wierdr", "settings.json"));
    expect(runsDir()).toBe(join(dir, "@wierdbytes", "pi-wierdr", "runs"));
  });

  it("defaults without any file", () => {
    expect(loadHerdr()).toEqual({ bash: true });
    expect(loadAgents()).toEqual(AGENTS_DEFAULTS);
  });

  it("reads bash at the top and the sub-agents' keys under agents", () => {
    write("pi-wierdr", { bash: false, agents: { maxDepth: 2, extraArgs: ["--no-voice"] } });
    expect(loadHerdr()).toEqual({ bash: false });
    expect(loadAgents()).toEqual({ ...AGENTS_DEFAULTS, maxDepth: 2, extraArgs: ["--no-voice"] });
  });

  it("reads pi-herdr's and pi-agents' files while its own doesn't exist", () => {
    write("pi-herdr", { bash: false });
    write("pi-agents", { maxDepth: 3 });
    expect(loadHerdr()).toEqual({ bash: false });
    expect(loadAgents()).toEqual({ ...AGENTS_DEFAULTS, maxDepth: 3 });
  });

  it("ignores the old files once its own exists, even a broken one", () => {
    write("pi-herdr", { bash: false });
    write("pi-agents", { maxDepth: 3 });
    write("pi-wierdr", "{ not json");
    expect(loadHerdr()).toEqual({ bash: true });
    expect(loadAgents()).toEqual(AGENTS_DEFAULTS);
  });
});
