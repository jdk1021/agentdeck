#!/usr/bin/env python3
"""Project general configuration from a primary home into a secondary account home.

Never edits a primary file. Credentials are never copied: Claude and Codex use explicit allowlists,
Grok (whose upstream policy shares its whole config files) uses a recursive credential-key denylist.

  project-settings.py <provider> <primary> <target>            first projection; existing files kept
  project-settings.py --refresh <provider> <primary> <target>  re-sync projected keys; keys the
      account wrote itself (sign-in state, trust prompts) are preserved; previous file -> .previous
"""
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import tomllib

CLAUDE_KEYS = {'mcpServers', 'projects', 'theme', 'hasCompletedOnboarding', 'lastOnboardingVersion', 'editorMode'}
SETTINGS_KEYS = {'permissions', 'hooks', 'enabledPlugins', 'extraKnownMarketplaces', 'statusLine', 'language',
                 'model', 'outputStyle', 'includeCoAuthoredBy', 'alwaysThinkingEnabled', 'spinnerTipsEnabled'}
CODEX_KEYS = {'model', 'model_reasoning_effort', 'model_verbosity', 'approval_policy', 'sandbox_mode', 'sandbox_workspace_write',
              'mcp_servers', 'features', 'projects', 'plugins', 'hooks', 'tui', 'notice', 'history', 'shell_environment_policy',
              'agents', 'personality', 'web_search', 'file_opener', 'analytics', 'feedback',
              # Credential-storage preference only (file/keyring/auto); Codex namespaces the keyring by CODEX_HOME.
              'cli_auth_credentials_store'}
SECRET_KEY = re.compile(r'(api[_-]?key|token|secret|password|passwd|credential|auth|cookie|session[_-]?key|bearer)', re.I)


def without_secrets(value):
    if isinstance(value, dict):
        return {k: without_secrets(v) for k, v in value.items() if not SECRET_KEY.search(str(k))}
    if isinstance(value, list):
        return [without_secrets(v) for v in value]
    return value


def toml_key(key):
    return key if re.fullmatch(r'[A-Za-z0-9_-]+', key) else json.dumps(key, ensure_ascii=False)


def toml_value(value):
    if isinstance(value, bool): return str(value).lower()
    if isinstance(value, (int, float)): return str(value)
    if isinstance(value, str): return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list): return '[' + ', '.join(toml_value(v) for v in value) + ']'
    if isinstance(value, dict): return '{ ' + ', '.join(toml_key(k) + ' = ' + toml_value(v) for k, v in value.items()) + ' }'
    raise ValueError('Unsupported configuration value')


def dump_toml(obj):
    return ''.join(toml_key(k) + ' = ' + toml_value(v) + '\n' for k, v in obj.items())


def atomic_write(path, text, refresh):
    if refresh and path.exists():
        shutil.copy2(path, path.with_name(path.name + '.previous'))
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix='.' + path.name)
    with os.fdopen(fd, 'w') as handle:
        handle.write(text)
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def project(source, dest, load, dump, select, refresh):
    """select(primary_obj) -> projected keys. With refresh, those keys replace the account's copies."""
    if not source.is_file() or (dest.exists() and not refresh):
        return
    if dest.is_symlink():
        return  # The person's own link; never write through it.
    projected = select(load(source.read_text()))
    if refresh and dest.exists():
        current = load(dest.read_text())
        keys = projected.keys() | {k for k in current if k in select(current)}
        merged = {k: v for k, v in current.items() if k not in keys}
        merged.update(projected)
        projected = merged
    atomic_write(dest, dump(projected), refresh)


def main():
    args = sys.argv[1:]
    refresh = bool(args) and args[0] == '--refresh'
    if refresh: args = args[1:]
    provider, primary_arg, target_arg = args
    primary, target = Path(primary_arg), Path(target_arg)
    if primary.resolve() == target.resolve(): raise ValueError('Refusing to change the primary home')
    target.mkdir(parents=True, exist_ok=True, mode=0o700)
    load_json = json.loads
    dump_json = lambda obj: json.dumps(obj, indent=2) + '\n'
    if provider == 'claude':
        source = primary / '.claude.json'
        if primary.resolve() == (Path.home() / '.claude').resolve(): source = Path.home() / '.claude.json'
        project(source, target / '.claude.json', load_json, dump_json, lambda o: {k: v for k, v in o.items() if k in CLAUDE_KEYS}, refresh)
        project(primary / 'settings.json', target / 'settings.json', load_json, dump_json, lambda o: {k: v for k, v in o.items() if k in SETTINGS_KEYS}, refresh)
    elif provider == 'codex':
        project(primary / 'config.toml', target / 'config.toml', tomllib.loads, dump_toml, lambda o: {k: v for k, v in o.items() if k in CODEX_KEYS}, refresh)
    elif provider == 'grok':
        project(primary / 'config.toml', target / 'config.toml', tomllib.loads, dump_toml, without_secrets, refresh)
        project(primary / 'settings.json', target / 'settings.json', load_json, dump_json, without_secrets, refresh)
    else:
        raise ValueError('Unsupported provider')


if __name__ == '__main__':
    main()
