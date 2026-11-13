#!/usr/bin/env python3
"""Produce the standalone collector payload in Runtime/.

Every source change is a small, named patch. A patch whose anchor is missing fails the build, so an
upstream refresh can never silently drop a macOS adaptation. `scripts/audit.py` lists them.
"""
from pathlib import Path
import json
import shutil
import sys

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / 'Vendor/Upstream'
RUNTIME = ROOT / 'Runtime'


def patch(path, old, new, label):
    text = path.read_text()
    if text.count(old) < 1:
        sys.exit(f'prepare-runtime: patch "{label}" anchor missing in {path.name}')
    path.write_text(text.replace(old, new))


# Collector payload: shared module into lib/, collector entry points into bin/. Update/service helpers
# are Linux shell plumbing replaced by the native CollectorService and are not shipped.
PATCHES_COMMON = [
    ('"shell", "plugins", "agents"', '"lib"', 'payload layout'),
]
RUNTIME.mkdir(exist_ok=True)
(RUNTIME / 'bin').mkdir(exist_ok=True)
(RUNTIME / 'lib').mkdir(exist_ok=True)
for file in (VENDOR / 'shell/plugins/agents').iterdir():
    if file.name == 'collectors.py':
        shutil.copy2(file, RUNTIME / 'lib' / file.name)
for file in (VENDOR / 'bin').iterdir():
    if file.is_file() and file.name.startswith('agentdeck-collect-') and not file.name.endswith('-update'):
        out = RUNTIME / 'bin' / file.name
        shutil.copy2(file, out)
        for old, new, label in PATCHES_COMMON:
            if old in out.read_text():
                patch(out, old, new, label)
        if 'config_home() / "agentdeck" / "agents"' in out.read_text():
            patch(out, 'config_home() / "agentdeck" / "agents"',
                  'Path(os.environ.get("AGENTDECK_PROVIDER_CONFIG_DIR") or (config_home() / "agentdeck" / "providers"))',
                  'app-private provider configuration')
        text = out.read_text()
        if '~/.config/agentdeck/agents' in text:
            out.write_text(text.replace('~/.config/agentdeck/agents', '~/.config/agentdeck/providers'))

shutil.copy2(ROOT / 'docs/upstream-inventory.json', RUNTIME / 'inventory.json')
shutil.copy2(ROOT / 'scripts/agentdeck_macos.py', RUNTIME / 'lib/agentdeck_macos.py')
shutil.copy2(ROOT / 'scripts/project-settings.py', RUNTIME / 'project-settings.py')

module = RUNTIME / 'lib/collectors.py'
patch(module, 'root = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "agentdeck" / "agent-usage"',
      'root = Path(os.environ["AGENTDECK_CACHE_DIR"]) if os.environ.get("AGENTDECK_CACHE_DIR") else Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "agentdeck" / "agent-usage"',
      'app-private cache directory')
patch(module, 'registry = read_json(state / "agentdeck" / "agents" / "accounts" / f"{agent_id}.json")',
      'registry = read_json(Path(os.environ["AGENTDECK_ACCOUNTS_DIR"]) / f"{agent_id}.json") if os.environ.get("AGENTDECK_ACCOUNTS_DIR") else read_json(state / "agentdeck" / "agents" / "accounts" / f"{agent_id}.json")',
      'app-owned account registry')
patch(module, 'return config_home() / "Cursor" / "User" / "globalStorage" / "state.vscdb"',
      'return (Path.home() / "Library/Application Support/Cursor" if sys.platform == "darwin" and not os.environ.get("XDG_CONFIG_HOME") else config_home() / "Cursor") / "User" / "globalStorage" / "state.vscdb"',
      'macOS Cursor editor database')

claude = RUNTIME / 'bin/agentdeck-collect-claude'
patch(claude, 'def oauth_login(claude_dir: Path) -> tuple[str, int, int, str]:\n  login = read_json(claude_dir / ".credentials.json").get("claudeAiOauth")',
      'def oauth_login(claude_dir: Path, storage_dir: str | None = None) -> tuple[str, int, int, str]:\n'
      '  from agentdeck_macos import claude_credentials\n'
      '  login = claude_credentials(claude_dir, storage_dir).get("claudeAiOauth")',
      'macOS Keychain credential reader')
patch(claude, 'access_token, expires_at_ms, refresh_expires_at_ms, plan = oauth_login(home)',
      'access_token, expires_at_ms, refresh_expires_at_ms, plan = oauth_login(home, os.path.expanduser(account["home"]) if account.get("home") else None)',
      'Keychain namespace uses the exact launched home string')
patch(claude, 'if home == expand_path("~/.claude") and not', 'if home.resolve() == expand_path("~/.claude") and not',
      'canonical default-home comparison')
patch(claude, 'expand_path(configured) == home)', 'expand_path(configured) == home.resolve())',
      'canonical configured-home comparison')

agy = RUNTIME / 'bin/agentdeck-collect-agy'
patch(agy, '    raw = subprocess.check_output(\n      ["secret-tool", "lookup", "service", "gemini", "username", "antigravity"],\n'
           '      text=True, stderr=subprocess.DEVNULL, timeout=3,\n    )',
      '    from agentdeck_macos import keyring_lookup\n    raw = keyring_lookup("gemini", "antigravity", timeout=3)',
      'macOS Keychain equivalent of the Secret Service lookup')

codex = RUNTIME / 'bin/agentdeck-collect-codex'
patch(codex, 'def find_codex_binary():',
      'def find_codex_binary():\n  explicit = os.environ.get("AGENTDECK_CODEX_BINARY", "")\n'
      '  if explicit and os.path.isfile(explicit) and os.access(explicit, os.X_OK):\n    return explicit',
      'resolved mise Codex binary')

for file in (RUNTIME / 'bin').glob('agentdeck-agent-*'):
    file.unlink()  # Generated payload only; source provenance remains in Vendor.
if (RUNTIME / 'shell').exists():
    shutil.rmtree(RUNTIME / 'shell')  # Remove obsolete generated layout.
count = len(json.loads((RUNTIME / 'inventory.json').read_text())['collectors'])
print(f'Prepared {count} collectors at {RUNTIME}')
