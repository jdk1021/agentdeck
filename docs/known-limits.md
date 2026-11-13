# Known limits

- **Not notarized.** Releases are ad-hoc signed. First launch needs *Open Anyway* (see installation).
- **Private and undocumented endpoints.** Several collectors (Claude, Cursor, Grok Bot, Google
  Antigravity, some billing APIs) read endpoints the vendors can change without notice. When that happens
  the provider shows its last measurement as stale; it never drops to zero.
- **Rate limits.** Anthropic's usage endpoint rate-limits readily; results are reused for a short window
  and a 429 keeps recent numbers current. Manual refresh bypasses the reuse window.
- **Sign-in lifetimes.** Claude Code's access token lasts hours; only the CLI refreshes it. If nothing
  runs Claude Code for a while, limits pause ("Limits paused") until it runs again. AgentDeck never refreshes
  or rewrites tokens.
- **Switching affects new sessions only.** A running agent keeps its account until it exits. Install
  integration for each shell you use (`agentdeck shell install --shell zsh|bash|fish`) so `claude`,
  `codex` and `grok` use the selected account. Other shells and IDE extensions use whatever environment
  they are launched with. An explicit provider home environment variable overrides the selection.
- **Settings of additional accounts are snapshots.** Use *Copy settings from primary again*
  (`agentdeck account sync-settings`) after changing MCP servers, hooks or plugins on the primary.
- **Estimates.** Copilot's local allowance, Fireworks' configured funding and DeepSeek's funded amount are
  estimates and are labelled so. They are not provider-reported balances.
- **Antigravity on macOS.** The Keychain lookup (service `gemini`, account `antigravity`) follows how
  common keyring libraries map the Linux Secret Service entry, but it has not been confirmed against a
  real `agy` install. The token file and harness stores work as upstream.
- **Codex app-server side effects.** Querying Codex limits starts `codex app-server` in the account's
  `CODEX_HOME`, which writes its own log database there, as any Codex run does.
- **Cross-device aggregation** relies on a folder you sync yourself (iCloud Drive, Dropbox, …).
  Lifetime totals take the largest value across devices, because histories can be shared; daily values
  are summed.
- **Apple silicon only.** Intel Macs are not supported; release archives are `arm64` only.
