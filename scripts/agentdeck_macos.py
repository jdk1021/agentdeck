"""Read Claude Code's macOS credential item in memory; never export, refresh, or overwrite it.

Naming mirrors the Claude Code CLI (observed in 2.1.x): the generic-password service is
``Claude Code-credentials`` for the default home. When CLAUDE_SECURESTORAGE_CONFIG_DIR is set it
decides alone (an empty value means the default item); otherwise a set CLAUDE_CONFIG_DIR selects a
per-directory item. The suffix is ``-`` plus the first 8 hex digits of SHA-256 over the NFC
normalized directory string exactly as the CLI received it (not a resolved path).
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import unicodedata

BASE_SERVICE = 'Claude Code-credentials'


def service_name(directory=None):
    if not directory:
        return BASE_SERVICE
    digest = hashlib.sha256(unicodedata.normalize('NFC', str(directory)).encode()).hexdigest()[:8]
    return f'{BASE_SERVICE}-{digest}'


def storage_directory(home, raw_home=None, environ=None):
    """The directory string Claude Code hashes for the home being read, or None for the default item."""
    environ = os.environ if environ is None else environ
    if Path(home).resolve() != (Path.home() / '.claude').resolve():
        # AgentDeck launches a secondary home with both variables set to this exact string.
        # A secondary home always uses its own item and never falls back to the primary one.
        return raw_home or str(home)
    if 'CLAUDE_SECURESTORAGE_CONFIG_DIR' in environ:
        return environ['CLAUDE_SECURESTORAGE_CONFIG_DIR'] or None
    return environ.get('CLAUDE_CONFIG_DIR') or None


def claude_credentials(home, raw_home=None):
    home = Path(home)
    if sys.platform == 'darwin' and os.environ.get('AGENTDECK_MACOS') == '1':
        try:
            result = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s',
                                     service_name(storage_directory(home, raw_home)), '-w'],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    timeout=12, check=False)
            if result.returncode == 0:
                value = json.loads(result.stdout)
                if isinstance(value, dict):
                    return value
        except (OSError, ValueError, subprocess.TimeoutExpired):
            pass
    try:
        value = json.loads((home / '.credentials.json').read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def keyring_lookup(service, account, timeout=3):
    """Linux `secret-tool lookup service <s> username <a>` equivalent.

    On macOS, the common keyring libraries (go-keyring, keyring-rs) store the same pair as a
    generic password with that service and account. go-keyring may prefix the payload with
    ``go-keyring-base64:`` or ``go-keyring-encoded:`` (hex). Read-only; returns '' when absent.
    """
    if sys.platform == 'darwin' and os.environ.get('AGENTDECK_MACOS') == '1':
        try:
            result = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', service, '-a', account, '-w'],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    timeout=timeout, check=False)
        except (OSError, subprocess.TimeoutExpired):
            return ''
        if result.returncode != 0:
            return ''
        raw = result.stdout.decode('utf-8', 'replace').rstrip('\n')
        try:
            if raw.startswith('go-keyring-base64:'):
                import base64
                return base64.b64decode(raw.split(':', 1)[1]).decode()
            if raw.startswith('go-keyring-encoded:'):
                return bytes.fromhex(raw.split(':', 1)[1]).decode()
        except ValueError:
            return ''
        return raw
    return subprocess.check_output(['secret-tool', 'lookup', 'service', service, 'username', account],
                                   text=True, stderr=subprocess.DEVNULL, timeout=timeout)
