# Upstream analysis

## Source

- GitHub repository ID `994093166` (<https://api.github.com/repositories/994093166>), MIT License.
- Tag `v4.5.0`, commit `ac2690cd7be4f47e4a255f5e2e78d904d436b068`. On 2026-11-13 `v4.5.0` was also the
  latest stable release; no later fixes were cherry-picked.
- Account-management reference: pull request 13770 of the same repository.
- `docs/upstream-inventory.json` lists the 23 collectors enumerated from the executable sources and the
  SHA-256 of each original file *before* renaming, so every vendored file can be traced to the original bytes.

## What was taken

| Upstream part | Use in AgentDeck |
|---|---|
| 23 `…-collect-<id>` programs and the shared collector module | Shipped in `Runtime/` and run by the Swift core |
| Fixture suites under `test/` | Run on macOS by `scripts/test-collectors.py` (42 suites) |
| Account scripts (`…-account-*`) | Reference only: sharing lists, reserved IDs and switching rules were re-implemented in Swift |
| Shell UI, update service, Linux desktop integration | Not used; replaced by the native app |

## Mechanical changes

Product, command, environment-variable and path names were renamed to AgentDeck naming throughout the
vendored files (`agentdeck-collect-<id>`, `AGENTDECK_*`). No logic changed in that step.

## macOS patches (applied by `scripts/prepare-runtime.py`; a missing anchor fails the build)

| Patch | File | Why |
|---|---|---|
| Payload layout `shell/plugins/agents` → `lib` | collectors | Flat bundle layout |
| App-private provider configuration directory | collectors | `AGENTDECK_PROVIDER_CONFIG_DIR` instead of `~/.config/…` |
| App-private cache directory | shared module | `AGENTDECK_CACHE_DIR` |
| App-owned account registry | shared module | `AGENTDECK_ACCOUNTS_DIR` |
| Cursor editor database path | shared module | `~/Library/Application Support/Cursor` on macOS |
| Keychain credential reader | Claude | macOS stores the sign-in in the Keychain, not only `.credentials.json` |
| Exact launched home string for the Keychain namespace | Claude | Matches the CLI's hash input |
| Canonical home comparison (`resolve()`) | Claude | `/var` vs `/private/var` and symlinked homes |
| Explicit Codex binary | Codex | Uses the resolved mise installation instead of a fresh lookup |
| Keychain equivalent of `secret-tool lookup` | Antigravity | No Secret Service on macOS |

## Behaviour that is intentionally different

- Settings of additional accounts are projected (filtered copies) instead of symlinking whole mixed files
  such as `settings.json` or `config.toml`, so credentials and custom providers cannot leak between
  accounts. Grok's `worktrees.db` is per account, like other SQLite state.
- The refresh loop is native: bounded concurrency, timeouts with process-group cleanup, last good record
  kept on failure, one refresh per wake-up.
- The switching policy adds conservative guards: stale or failed measurements are excluded, a 180 s
  cooldown applies, and alerts are de-duplicated.
