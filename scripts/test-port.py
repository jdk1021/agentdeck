#!/usr/bin/env python3
"""Credential-free integration checks for the native CLI and macOS adaptation."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parent.parent
CLI = Path(os.environ.get('AGENTDECK_TEST_CLI', ROOT / '.build/debug/agentdeck')).resolve()
PYTHON = ROOT / 'Runtime/python/bin/python3'


class PortTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='AgentDeck port tests ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'; self.home.mkdir()
        self.bin = self.root / 'tools with spaces'; self.bin.mkdir()
        self.env = {'HOME': str(self.home), 'PATH': f'{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin',
                    'AGENTDECK_HOME': str(self.root / 'app'), 'AGENTDECK_RUNTIME': str(ROOT / 'Runtime'),
                    'AGENTDECK_FIXTURE_MODE': '1', 'LANG': 'en_US.UTF-8'}

    def cli(self, *args, ok=True, env=None):
        result = subprocess.run([str(CLI), *args], env=env or self.env, cwd=ROOT, capture_output=True, text=True, timeout=60)
        if ok: self.assertEqual(result.returncode, 0, result.stderr)
        else: self.assertNotEqual(result.returncode, 0)
        return result

    def fake(self, name, text):
        file = self.bin / name; file.write_text(text); file.chmod(0o755); return file

    def add(self, provider='claude'):
        self.cli('account', 'add', provider, 'Fixture Work')
        registry = json.loads(self.cli('account', 'list', provider).stdout)
        return registry['accounts'][-1]

    def fake_claude(self):
        agent = self.fake('actual claude', f'''#!{PYTHON}
import json,os,sys
if sys.argv[1:] == ['auth','login']: sys.exit(0)
print(json.dumps({{'home':os.environ.get('CLAUDE_CONFIG_DIR'), 'secure':os.environ.get('CLAUDE_SECURESTORAGE_CONFIG_DIR'), 'key':bool(os.environ.get('ANTHROPIC_API_KEY')), 'args':sys.argv[1:]}}))
''')
        self.fake('mise', '#!/bin/sh\nif [ "$1 $2" = "which claude" ]; then\n  printf \'%s\\n\' ' + "'" + str(agent).replace("'", "'\"'\"'") + "'\nelse exit 1; fi\n")

    def test_inventory_has_exactly_all_collectors(self):
        inventory = json.loads((ROOT / 'docs/upstream-inventory.json').read_text())
        expected = {p['id'] for p in inventory['collectors']}
        actual = {f.name.removeprefix('agentdeck-collect-') for f in (ROOT / 'Runtime/bin').iterdir()}
        self.assertEqual(expected, actual); self.assertEqual(len(actual), 23)
        self.assertIn('grok', expected)

    def test_existing_claude_settings_hooks_and_transcripts_preserved(self):
        primary = self.home / '.claude'; primary.mkdir()
        (primary / 'projects').mkdir(); (primary / 'plugins').mkdir(); (primary / 'hooks').mkdir()
        originals = {
            self.home / '.claude.json': {'mcpServers': {'fixture': {'command': '/fixture/mcp'}}, 'oauthAccount': {'accountUuid': 'fixture-primary'}, 'apiKey': 'fixture-primary-secret'},
            primary / 'settings.json': {'hooks': {'PreToolUse': []}, 'enabledPlugins': {'fixture@market': True}, 'env': {'ANTHROPIC_AUTH_TOKEN': 'fixture-routing-secret'}},
            primary / '.credentials.json': {'claudeAiOauth': {'accessToken': 'fixture-primary-secret'}}
        }
        for path, data in originals.items(): path.write_text(json.dumps(data))
        transcript = primary / 'projects/fixture.jsonl'; transcript.write_text('{"type":"fixture-no-conversation"}\n')
        before = {p: p.read_bytes() for p in [*originals, transcript]}
        account = self.add(); target = Path(account['home'])
        copied = json.loads((target / '.claude.json').read_text())
        self.assertIn('mcpServers', copied); self.assertNotIn('oauthAccount', copied); self.assertNotIn('apiKey', copied)
        self.assertNotIn('env', json.loads((target / 'settings.json').read_text()))
        self.assertFalse((target / '.credentials.json').exists())
        self.assertTrue((target / 'projects').is_symlink()); self.assertTrue((target / 'plugins').is_symlink())
        self.assertTrue((target / 'hooks').is_symlink())
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_codex_projection_keeps_mcp_and_hooks_isolates_auth_and_database(self):
        primary = self.home / '.codex'; primary.mkdir()
        (primary / 'sessions').mkdir(); (primary / 'plugins').mkdir()
        (primary / 'config.toml').write_text('model = "fixture-model"\ncli_auth_credentials_store = "keyring"\nmodel_provider = "fixture"\n[mcp_servers.fixture]\ncommand = "/fixture/mcp"\n[model_providers.fixture]\nbase_url = "https://example.invalid"\nexperimental_bearer_token = "fixture-secret"\n')
        (primary / 'auth.json').write_text('{"access_token":"fixture-primary-secret"}')
        (primary / 'state_5.sqlite').write_bytes(b'fixture-database')
        (primary / 'hooks.json').write_text('{"hooks":{}}')
        before = {p: p.read_bytes() for p in primary.iterdir() if p.is_file()}
        target = Path(self.add('codex')['home']); config = tomllib.loads((target / 'config.toml').read_text())
        self.assertEqual(config['cli_auth_credentials_store'], 'keyring')
        self.assertEqual(config['mcp_servers']['fixture']['command'], '/fixture/mcp')
        self.assertNotIn('model_providers', config); self.assertNotIn('model_provider', config)
        self.assertFalse((target / 'auth.json').exists()); self.assertFalse((target / 'state_5.sqlite').exists())
        self.assertTrue((target / 'sessions').is_symlink()); self.assertTrue((target / 'hooks.json').is_symlink())
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_mise_resolution_account_isolation_explicit_environment_and_arguments(self):
        self.fake_claude(); account = self.add()
        self.cli('account', 'login', 'claude', account['id'])
        self.cli('account', 'use', 'claude', account['id'])
        env = dict(self.env, ANTHROPIC_API_KEY='fixture-primary-key')
        result = json.loads(self.cli('run', 'claude', '--', '--continue', 'path with spaces', env=env).stdout)
        self.assertEqual(result['home'], account['home']); self.assertEqual(result['secure'], account['home'])
        self.assertFalse(result['key']); self.assertEqual(result['args'], ['--continue', 'path with spaces'])
        explicit = dict(env, CLAUDE_CONFIG_DIR=str(self.root / 'explicit user home'))
        result = json.loads(self.cli('run', 'claude', '--', env=explicit).stdout)
        self.assertEqual(result['home'], explicit['CLAUDE_CONFIG_DIR']); self.assertTrue(result['key'])

    def test_pending_login_and_wrapper_recursion_are_refused(self):
        self.fake_claude(); account = self.add()
        self.cli('account', 'use', 'claude', account['id'], ok=False)
        env = dict(self.env, AGENTDECK_LAUNCH_DEPTH='2')
        self.cli('run', 'claude', '--', ok=False, env=env)

    def test_remove_preserves_home_and_recovers_registry(self):
        account = self.add(); home = Path(account['home']); (home / 'fixture.txt').write_text('keep')
        self.cli('account', 'remove', 'claude', account['id'])
        self.assertEqual((home / 'fixture.txt').read_text(), 'keep')
        self.cli('account', 'recover', 'claude', account['id'])
        ids = [a['id'] for a in json.loads(self.cli('account', 'list', 'claude').stdout)['accounts']]
        self.assertIn(account['id'], ids)

    def test_zsh_merge_backup_uninstall_preserves_existing_file(self):
        rc = self.home / '.zshrc'; original = '# fixture mise and hooks\nexport FIXTURE_SETTING=1\n'; rc.write_text(original)
        self.cli('shell', 'install'); self.cli('shell', 'install')
        self.assertEqual(rc.read_text().count('# >>> AgentDeck'), 1)
        self.cli('shell', 'uninstall'); self.assertEqual(rc.read_text(), original)

    def test_keychain_namespace_is_directory_scoped(self):
        spec = importlib.util.spec_from_file_location('mac_adapter', ROOT / 'scripts/agentdeck_macos.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        self.assertEqual(module.service_name(), 'Claude Code-credentials')
        self.assertNotEqual(module.service_name('/fixture/a'), module.service_name('/fixture/b'))
        self.assertEqual(module.service_name('/fixture/a').split('-')[-1], hashlib.sha256(b'/fixture/a').hexdigest()[:8])

    def test_keychain_selection_mirrors_claude_cli_rules(self):
        spec = importlib.util.spec_from_file_location('mac_adapter', ROOT / 'scripts/agentdeck_macos.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        default = Path.home() / '.claude'
        pick = module.storage_directory
        # Primary home: the same variables a plain `claude` would see decide the item.
        self.assertIsNone(pick(default, environ={}))
        self.assertEqual(pick(default, environ={'CLAUDE_CONFIG_DIR': '/fixture/cfg'}), '/fixture/cfg')
        self.assertEqual(pick(default, environ={'CLAUDE_CONFIG_DIR': '/fixture/cfg', 'CLAUDE_SECURESTORAGE_CONFIG_DIR': '/fixture/sec'}), '/fixture/sec')
        self.assertIsNone(pick(default, environ={'CLAUDE_CONFIG_DIR': '/fixture/cfg', 'CLAUDE_SECURESTORAGE_CONFIG_DIR': ''}))
        # A secondary home hashes the exact launched string, never falls back to the primary item.
        self.assertEqual(pick('/fixture/account', '/fixture/account', environ={}), '/fixture/account')
        self.assertEqual(module.service_name('/fixture/café'), module.service_name('/fixture/café'))
        # agy's Secret Service pair maps to a generic password; go-keyring payload prefixes are decoded.
        import base64, types
        calls = []
        def fake_run(cmd, **kwargs):
            calls.append(cmd); return types.SimpleNamespace(returncode=0, stdout=fake_run.payload)
        original_run, original_env = module.subprocess.run, os.environ.get('AGENTDECK_MACOS')
        module.subprocess.run = fake_run; os.environ['AGENTDECK_MACOS'] = '1'
        try:
            fake_run.payload = b'go-keyring-base64:' + base64.b64encode(b'{"token":{}}') + b'\n'
            self.assertEqual(module.keyring_lookup('gemini', 'antigravity'), '{"token":{}}')
            fake_run.payload = b'go-keyring-encoded:' + b'{}'.hex().encode()
            self.assertEqual(module.keyring_lookup('gemini', 'antigravity'), '{}')
            self.assertEqual(calls[0][1:6], ['find-generic-password', '-s', 'gemini', '-a', 'antigravity'])
        finally:
            module.subprocess.run = original_run
            if original_env is None: os.environ.pop('AGENTDECK_MACOS', None)
            else: os.environ['AGENTDECK_MACOS'] = original_env

    def test_grok_projection_keeps_general_settings_without_credentials(self):
        primary = self.home / '.grok'; (primary / 'sessions').mkdir(parents=True)
        (primary / 'config.toml').write_text('model = "fixture-model"\napi_key = "fixture-secret"\n[ui]\ntheme = "dark"\nauth_token = "fixture-secret"\n')
        (primary / 'settings.json').write_text(json.dumps({'editor': 'fixture', 'accessToken': 'fixture-secret'}))
        (primary / 'lsp.json').write_text('{}'); (primary / 'auth.json').write_text('{"token":"fixture-secret"}')
        before = {p: p.read_bytes() for p in primary.iterdir() if p.is_file()}
        target = Path(self.add('grok')['home'])
        config = tomllib.loads((target / 'config.toml').read_text())
        self.assertEqual(config, {'model': 'fixture-model', 'ui': {'theme': 'dark'}})
        self.assertEqual(json.loads((target / 'settings.json').read_text()), {'editor': 'fixture'})
        self.assertTrue((target / 'lsp.json').is_symlink()); self.assertFalse((target / 'auth.json').exists())
        self.assertTrue((target / 'sessions').is_symlink())
        self.assertNotIn('fixture-secret', ''.join(p.read_text() for p in target.iterdir() if p.is_file() and not p.is_symlink()))
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_settings_resync_updates_shared_keys_and_keeps_account_state(self):
        primary = self.home / '.claude'; primary.mkdir()
        (self.home / '.claude.json').write_text(json.dumps({'mcpServers': {'a': {'command': '/fixture/a'}}, 'oauthAccount': {'accountUuid': 'fixture-primary'}}))
        (primary / 'settings.json').write_text(json.dumps({'model': 'one'}))
        account = self.add(); target = Path(account['home'])
        own = json.loads((target / '.claude.json').read_text()); own['oauthAccount'] = {'accountUuid': 'fixture-secondary'}
        (target / '.claude.json').write_text(json.dumps(own))
        (self.home / '.claude.json').write_text(json.dumps({'mcpServers': {'b': {'command': '/fixture/b'}}, 'oauthAccount': {'accountUuid': 'fixture-primary'}}))
        (primary / 'settings.json').write_text(json.dumps({'model': 'two', 'hooks': {}}))
        self.cli('account', 'sync-settings', 'claude', account['id'])
        synced = json.loads((target / '.claude.json').read_text())
        self.assertEqual(synced['mcpServers'], {'b': {'command': '/fixture/b'}})
        self.assertEqual(synced['oauthAccount'], {'accountUuid': 'fixture-secondary'})
        self.assertEqual(json.loads((target / 'settings.json').read_text()), {'model': 'two', 'hooks': {}})
        self.assertTrue((target / '.claude.json.previous').exists())
        self.cli('account', 'sync-settings', 'claude', 'primary', ok=False)

    def test_plain_collector_failure_retains_last_measurements(self):
        payload = self.root / 'runtime'; (payload / 'bin').mkdir(parents=True); (payload / 'python/bin').mkdir(parents=True)
        (payload / 'inventory.json').write_text(json.dumps({'collectors':[{'id':'fixture', 'name':'Fixture'}]}))
        (payload / 'python/bin/python3').symlink_to(PYTHON)
        collector = payload / 'bin/agentdeck-collect-fixture'; collector.write_text('raise RuntimeError("fixture failure")\n')
        usage = self.root / 'app/usage'; usage.mkdir(parents=True)
        old = {'schemaVersion':1,'id':'fixture','name':'Fixture','limits':[{'label':'Weekly','percent':0.99,'resetsAt':''}],'limitsFetchedAt':1234}
        (usage / 'fixture.json').write_text(json.dumps(old))
        env = dict(self.env, AGENTDECK_RUNTIME=str(payload))
        self.cli('refresh', ok=False, env=env)
        record = json.loads((usage / 'fixture.json').read_text())
        self.assertEqual(record['limits'], old['limits']); self.assertEqual(record['limitsFetchedAt'],1234)
        self.assertTrue(record['limitsStale']); self.assertTrue(record['collectorFailed'])


if __name__ == '__main__': unittest.main(verbosity=2)
