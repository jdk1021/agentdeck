# Validation

What was actually run for the first release, on one Apple silicon Mac (macOS 27.2.1, Swift 6.3.3 from the
Command Line Tools). Anything not listed under "Verified" was **not** verified.

## Verified

| Area | Result |
|---|---|
| Swift build | `swift build` (debug) and `package-app.py` (release, arm64) succeed |
| Swift core tests | 17 tests / 49 assertions pass via `scripts/native-tests.py` (switching, stale handling, cooldown, storage atomicity/backup/restore, concurrent writers, zsh merge/uninstall, wrapper recursion, large output, timeout, process-group cleanup, sync privacy, refresh planner) |
| CLI integration | 12 tests pass via `scripts/test-port.py` with a scratch `HOME` and `AGENTDECK_FIXTURE_MODE=1`: inventory, Claude/Codex/Grok settings projection without credentials, settings re-sync, mise resolution and account environment, pending-login and recursion refusal, remove/recover, zsh merge, Keychain naming rules, failure retention |
| Upstream fixtures | 42/42 suites, 1,520 checks pass against the macOS payload (`scripts/test-collectors.py`, Bash 5.3) |
| Live limits (L) | Claude Code (2.1.323) and Codex CLI (0.169.0), primary accounts, read-only: limits, plan and reset times returned, not stale. No Claude file changed. Codex's app-server updated its own `logs_2.sqlite` and `memories_1.sqlite-wal` in `~/.codex`; `auth.json` was unchanged |
| Keychain naming | Claude Code's service naming read from the 2.1.323 binary and mirrored; existing item `Claude Code-credentials` confirmed by attributes only (no secret printed) |
| Package | `.app`, ZIP, DMG, SHA-256 produced; ad-hoc signature verifies (`codesign --verify --deep --strict`); no build-machine paths, credentials or upstream product name inside the bundle (`audit.py --dist`) |
| Relocation | App copied to a path with spaces, CLI invoked through a symlink with an empty `HOME`: runtime found, all 23 collectors ran (1.6 s) |
| App launch (A) | Packaged app in normal mode with a scratch state folder collected all 23 records with no collector failure, including live Claude Code and Codex limits |
| UI rendering | Demo mode rendered and captured: menu bar panel (light/dark), dashboard (light/dark), accounts, balance estimate, settings |
| Gatekeeper | `spctl --assess` rejects the ad-hoc app, as expected for an un-notarized build (documented install path instead) |

## Not verified

- Signing in additional Claude Code / Codex / Grok accounts and switching between them with real
  credentials (needs interactive browser sign-in by the account owner). The isolation logic is covered by
  fixtures and the Keychain naming was derived from the CLI binary, but no secondary item was created.
- Resuming a real conversation from an additional account, concurrent database access, context-mode or
  other MCP servers and hooks running inside an additional account, plugins with absolute paths.
- Live queries for the other 21 providers (not installed or not signed in on the test Mac).
- The Antigravity Keychain adapter against a real `agy` install.
- Clicking through the real menu bar extra, Terminal launches, notifications, Launch at login,
  keyboard-only navigation and VoiceOver in the packaged app (UI was checked through demo windows).
- `x86_64` builds and Intel Macs; `swift test` with XCTest (needs full Xcode — CI runs it).
- Notarization (no Developer ID available).

## How to run

```sh
python3 scripts/prepare-runtime.py
swift build
python3 scripts/native-tests.py      # Swift core tests without XCTest
swift test                           # full Xcode only
python3 scripts/test-port.py         # CLI integration (scratch HOME)
python3 scripts/test-collectors.py --bash "$(command -v bash)"   # Bash 4+ required
python3 scripts/package-app.py && python3 scripts/audit.py --dist
python3 scripts/capture-screenshots.py dist/AgentDeck.app/Contents/MacOS/AgentDeckApp
```

Fixture port notes: Linux `/proc` stdin checks are replaced by `lsof`; one Cursor fixture tolerates the
case-insensitive file system; GNU `date`/`timeout` helpers are provided for tests; `sed -i ''` syntax.
No collector parsing assertion was removed. The x86_64 CPython build lacks `time.tzset`, which only seven fixture harnesses use to simulate
time zones (no collector calls it); on that architecture those harness scripts run under the CI's own Python
while the collector programs still use the bundled interpreter. The upstream update-service and Linux UI watcher suites are
not run because those parts are replaced by the Swift app.
