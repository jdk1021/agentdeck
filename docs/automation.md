# Automation

All automation runs on GitHub Actions. Source changes land on `main` through pull requests.

| Workflow | When | What it does |
|---|---|---|
| `ci.yml` | pushes to `main`, pull requests, `v*` tags | Runtime bootstrap, build, `swift test`, core and CLI tests, 42 upstream fixture suites, packaging, release audit on Apple silicon. On a tag it publishes the release archives; assets that are already published are never replaced. |
| `upstream-sync.yml` | daily, or manually with a tag | When the upstream collectors publish a newer stable release, re-vendors it with `scripts/sync-upstream.py`, applies the macOS patches, runs the fixtures and the audit, and opens a pull request with the results (as a draft if anything failed). |
| `dependencies.yml` | weekly, or manually | Looks for newer CPython 3.14 / ripgrep builds for Apple silicon (`scripts/check-dependencies.py`), verifies each download against GitHub's published SHA-256, rebuilds and tests the app, and opens a pull request with the results. |
| `pr-screenshots.yml` | pull requests touching the app UI | Captures the synthetic demo screens on an Apple silicon runner, stores them on the `pr-screenshots` branch and keeps one comment on the pull request up to date with the images. |
| `pages.yml` | changes to `site/`, screenshots or icons | Publishes the website at <https://jdk1021.github.io/agentdeck/>. |
| [`jdk1021/homebrew-tap`](https://github.com/jdk1021/homebrew-tap) `update.yml` | every 6 hours, or manually | Follows the latest AgentDeck release, renders `Casks/agentdeck.rb` from the published ZIP (its SHA-256 must match the release's `.sha256` file), commits it, then installs the cask on a clean Apple silicon runner and runs the CLI. It uses only the tap's own workflow token. |

Pull requests opened by these workflows do not start other workflows (a GitHub rule for the built-in
token), which is why the sync and dependency workflows run the full test set themselves and report the
results in the pull request.

## Manual runs

```sh
gh workflow run upstream-sync.yml -R jdk1021/agentdeck -f tag=v4.6.0
gh workflow run dependencies.yml -R jdk1021/agentdeck
gh workflow run update.yml -R jdk1021/homebrew-tap
```

Locally: `python3 scripts/sync-upstream.py --check` (exit 10 = newer release), `--verify` (the naming
transform reproduces the vendored tree byte for byte); `python3 scripts/check-dependencies.py`.
