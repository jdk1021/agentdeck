# Installation, uninstall and restore

## Requirements

- A Mac with Apple silicon (M1 or later) and macOS 14 or later. Intel Macs are not supported.
- The agent CLIs you want to use, installed your usual way (mise, Homebrew, npm, vendor installer).
  AgentDeck never installs them.

## Install with Homebrew

```sh
brew install --cask jdk1021/tap/agentdeck   # also links the agentdeck CLI
brew upgrade --cask agentdeck
```

The first launch still needs *Open Anyway* (see step 3 below).

## Install a release

1. Download the `.dmg` or `.zip` and verify it: `shasum -a 256 -c AgentDeck-<version>-macos-<arch>.sha256`
2. Move `AgentDeck.app` to `/Applications`.
3. The app is ad-hoc signed and **not notarized**. macOS blocks the first launch. Open
   **System Settings → Privacy & Security** and choose **Open Anyway** for AgentDeck, or Control-click the
   app → **Open**. If you prefer the terminal, clearing the quarantine flag on this one app is enough:
   `xattr -d com.apple.quarantine /Applications/AgentDeck.app`. Do not disable Gatekeeper globally.
4. Optional CLI on your `PATH`:
   `ln -s /Applications/AgentDeck.app/Contents/MacOS/agentdeck ~/.local/bin/agentdeck`
   The CLI follows the link back to the app and uses its bundled runtime.
5. Optional: *Launch at login* in Settings, then select your *Terminal shell* and *Install shell integration*
   so `claude`, `codex` and `grok` start with the selected account. From the CLI, use
   `agentdeck shell install --shell bash` (also supports `zsh`, the default, and `fish`). Open a new terminal
   after installing. Install separately for each shell you use.

   zsh updates `~/.zshrc`. bash updates `~/.bashrc` and the first existing login profile
   (`~/.bash_profile`, `~/.bash_login`, then `~/.profile`), creating `~/.bash_profile` only if none exist.
   fish updates `$XDG_CONFIG_HOME/fish/config.fish`, or `~/.config/fish/config.fish` by default.
   Each file gets a marked block and a backup; other settings and mise installs are preserved.

## Build from source

Requires Xcode or the Command Line Tools (Swift 6), Python 3.11+ and network access for the pinned runtime.

```sh
python3 scripts/bootstrap-runtime.py   # pinned CPython + ripgrep, SHA-256 verified
python3 scripts/prepare-runtime.py     # collector payload into Runtime/
swift build                            # .build/debug/AgentDeckApp and .build/debug/agentdeck
python3 scripts/package-app.py         # dist/AgentDeck.app, .zip, .dmg, .sha256
```

Set `AGENTDECK_SIGN_IDENTITY` to a Developer ID to sign with it instead of ad-hoc (notarization is a
separate step that this project does not perform).

Tests: see [validation.md](validation.md#how-to-run).

## Where things live

| Path | Contents |
|---|---|
| `~/Library/Application Support/AgentDeck/settings.json` | refresh interval, notifications, sync folder, disabled collectors |
| `…/AgentDeck/accounts/<provider>.json` | account registry; `retired-*.json` for removed accounts |
| `…/AgentDeck/accounts/<provider>/<uuid>/` | homes of additional accounts (contain their sign-ins) |
| `…/AgentDeck/usage/`, `…/cache/` | last collector records and collector caches |
| `…/AgentDeck/providers/` | optional provider configuration (for example Copilot `monthlyCredits`) |
| `…/AgentDeck/backups/` | shell startup file copies made before every change |
| Keychain `org.agentdeck.provider-credentials` | API keys saved in AgentDeck's Settings |

## Uninstall

1. `agentdeck uninstall` removes managed blocks for zsh, bash and fish; backups are saved first.
   To remove one shell, use `agentdeck shell uninstall --shell bash` (or `zsh` / `fish`), or select the
   shell in Settings and click *Remove*.
2. Turn off *Launch at login*, quit AgentDeck, delete `AgentDeck.app` and any `agentdeck` symlink.

Nothing else is removed: provider sign-ins, settings, histories, MCP configuration and databases stay
untouched, and so does AgentDeck's own state, so reinstalling restores everything.

### Optional cleanup

Only if you are sure you no longer need additional accounts:

- Delete `~/Library/Application Support/AgentDeck`. This removes the homes (and sign-ins) of
  **additional** accounts; the primary homes `~/.claude`, `~/.codex`, `~/.grok` are not inside it.
- In Keychain Access, delete items named `org.agentdeck.provider-credentials`, and Claude Code items
  `Claude Code-credentials-<8 hex>` that belonged to removed additional accounts. Never delete the plain
  `Claude Code-credentials` item — that is your primary sign-in.

## Restore

- `agentdeck restore settings` or `agentdeck restore <claude|codex|grok>` puts back the previous complete
  version of the settings file or an account registry (every write keeps one `.previous`).
- `agentdeck account recover <provider> <id>` re-adds a removed account.
- Earlier shell startup file versions are in `…/AgentDeck/backups/`.
- After `account sync-settings`, the account's previous `.claude.json`, `settings.json` or `config.toml`
  is next to it as `<name>.previous`.
