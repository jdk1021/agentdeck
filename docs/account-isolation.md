# Account isolation

Multiple accounts are supported for Claude Code, Codex and Grok — the providers whose upstream collectors
support them. Switching selects the account for **new** processes. It never stops running sessions and
never rewrites the global sign-in.

## Homes

| | Primary | Additional account |
|---|---|---|
| Home | the provider's own (`~/.claude`, `~/.codex`, `~/.grok`) | `~/Library/Application Support/AgentDeck/accounts/<provider>/<uuid>` |
| Selected by | leaving `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `GROK_HOME` unset | those variables set to the account home |
| Credentials | untouched | created by the provider CLI's own login inside that home |

An explicitly exported home variable always wins over the registry unless an account is chosen with
`--account` or in the app. When another account is selected, exported API keys/tokens for that provider
(`ANTHROPIC_API_KEY`, `CODEX_API_KEY`, `XAI_API_KEY`, …) are removed from the launched environment so they
cannot silently authenticate the wrong account.

## Claude Code Keychain items

Verified against the Claude Code 2.1.323 binary: the generic-password service is `Claude Code-credentials`
for the default home. `CLAUDE_SECURESTORAGE_CONFIG_DIR` decides alone when set (empty = default item);
otherwise a set `CLAUDE_CONFIG_DIR` selects `Claude Code-credentials-<first 8 hex of SHA-256(NFC path)>`.
AgentDeck launches additional accounts with both variables set to the same exact path, and the collector
hashes that same string, so each account reads only its own item. A secondary account never falls back to
the primary item. The collector reads the item in memory with `/usr/bin/security` and never writes,
refreshes or exports it; `.credentials.json` in the home is the fallback.

## Codex

The Codex collector asks the official app-server (`account/rateLimits/read`) with `CODEX_HOME` set to the
account home, so Codex itself reads its credentials from file, keyring or auto storage as configured. The
keyring is namespaced by the canonical `CODEX_HOME`, which is why `cli_auth_credentials_store` is the only
storage-related key copied. `auth.json` and SQLite state (`state_*.sqlite`, `logs_*.sqlite`) are never
shared; each account keeps its own databases.

## What is shared

Shared by **symlink** to the primary (only if it exists there; existing files and links are never replaced):

| Provider | Directories | Files |
|---|---|---|
| Claude Code | projects, skills, agents, commands, plugins, hooks, themes, output-styles, file-history, todos, plans | CLAUDE.md, history.jsonl, keybindings.json |
| Codex | sessions, archived_sessions, prompts, skills, rules, plugins | AGENTS.md, history.jsonl, hooks.json |
| Grok | sessions, skills, agents, plugins, installed-plugins, marketplace-cache, hooks, memory, memory-v2, rules, commands, workflows, personas, worktrees | lsp.json, pager.toml, sandbox.toml, trusted_folders.toml, statusline.sh |

**Projected** (copied, filtered) — mixed files are never linked whole:

| Provider | File | Kept |
|---|---|---|
| Claude Code | `.claude.json` | `mcpServers`, `projects`, `theme`, `hasCompletedOnboarding`, `lastOnboardingVersion`, `editorMode` |
| Claude Code | `settings.json` | `permissions`, `hooks`, `enabledPlugins`, `extraKnownMarketplaces`, `statusLine`, `language`, `model`, `outputStyle`, `includeCoAuthoredBy`, `alwaysThinkingEnabled`, `spinnerTipsEnabled` (no `env`) |
| Codex | `config.toml` | `model*`, `approval_policy`, `sandbox_*`, `mcp_servers`, `features`, `projects`, `plugins`, `hooks`, `tui`, `notice`, `history`, `shell_environment_policy`, `agents`, `personality`, `web_search`, `file_opener`, `analytics`, `feedback`, `cli_auth_credentials_store` (no custom providers or bearer tokens) |
| Grok | `config.toml`, `settings.json` | everything except keys that look like credentials (`*key*`, `*token*`, `*secret*`, `*auth*`, `*password*`, `*credential*`, `*cookie*`), recursively |

## Keeping settings in step

Projection happens when the account is created. Later changes to the primary are **not** merged
automatically, because an automatic merge could overwrite something the account changed on purpose. Re-apply
them when you want:

- App: account menu → **Copy settings from primary again**
- CLI: `agentdeck account sync-settings <provider> <id>`

Projected keys are replaced with the primary's current values; keys the account wrote itself (for example
its own `oauthAccount`) are kept. The previous file is saved next to it as `.previous`.

## Removing and recovering

`agentdeck account remove` only takes the account out of the registry. Its home and Keychain item stay,
so running sessions are unaffected and `agentdeck account recover` brings it back. The primary account
cannot be removed.
