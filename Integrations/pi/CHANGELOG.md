# Changelog

## 0.1.1

- **Fix:** bash frame shows `⚡ timed out` when background processes kept writing until the timeout, instead of leaving pi's status line in the output.

## 0.1.0

- **New:** `@wierdbytes/pi-herdr` (0.6.1) and `@wierdbytes/pi-agents` (0.1.3) in one package, nothing else changed: `agent.*` labels, the `limits` document, bash in herdr-core terminals and sub-agents.
- **Change:** settings in one file, `~/.pi/agent/@wierdbytes/pi-wierdr/settings.json` (`bash`, and the sub-agents' keys under `agents`); the old packages' files are read until it exists.
- **Change:** sub-agents' run files in `~/.pi/agent/@wierdbytes/pi-wierdr/runs`.
- **Change:** the RPC client for other extensions is `@wierdbytes/pi-wierdr/client`.
