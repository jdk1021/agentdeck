#!/usr/bin/env python3
"""Check the pinned runtime dependencies (CPython, ripgrep) for newer Apple silicon releases.

  python3 scripts/check-dependencies.py            report; exit 10 when an update exists
  python3 scripts/check-dependencies.py --update   download, verify SHA-256 against GitHub's asset digest,
                                                   and rewrite scripts/dependencies.json and the notices
CPython stays on the bundled minor version (3.14); a new minor needs a deliberate change.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import sys
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / 'scripts/dependencies.json'
NOTICES = ROOT / 'THIRD_PARTY_NOTICES.md'
PYTHON_MINOR = '3.14'


def get(url, raw=False):
    request = urllib.request.Request(url, headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'agentdeck-dependency-check'})
    token = os.environ.get('GITHUB_TOKEN') or os.environ.get('GH_TOKEN')
    if token and url.startswith('https://api.github.com/'):
        request.add_header('Authorization', f'Bearer {token}')
    with urllib.request.urlopen(request, timeout=300) as response:
        data = response.read()
    return data if raw else json.loads(data)


def latest(repo, pattern):
    release = get(f'https://api.github.com/repos/{repo}/releases/latest')
    matches = [a for a in release['assets'] if re.fullmatch(pattern, a['name'])]
    if not matches:
        sys.exit(f'{repo} {release["tag_name"]}: no asset matches {pattern}')
    asset = max(matches, key=lambda a: [int(x) for x in re.findall(r'\d+', a['name'])[:4]])
    return release['tag_name'], asset


def verified_digest(asset):
    data = get(asset['browser_download_url'], raw=True)
    digest = hashlib.sha256(data).hexdigest()
    published = (asset.get('digest') or '').removeprefix('sha256:')
    if published and published != digest:
        sys.exit(f'{asset["name"]}: downloaded SHA-256 {digest} does not match the published digest {published}')
    return digest


def main():
    manifest = json.loads(MANIFEST.read_text())
    py_tag, py_asset = latest('astral-sh/python-build-standalone',
                              rf'cpython-{re.escape(PYTHON_MINOR)}\.\d+\+\d+-aarch64-apple-darwin-install_only_stripped\.tar\.gz')
    rg_tag, rg_asset = latest('BurntSushi/ripgrep', r'ripgrep-[\d.]+-aarch64-apple-darwin\.tar\.gz')
    current_py = manifest['python']['assets']['aarch64']['url']
    current_rg = manifest['ripgrep']['assets']['aarch64']['url']
    changes = []
    if py_asset['browser_download_url'] != current_py:
        changes.append(('python', py_tag, py_asset))
    if rg_asset['browser_download_url'] != current_rg:
        changes.append(('ripgrep', rg_tag, rg_asset))
    for name, tag, asset in changes:
        print(f'update available: {name} -> {asset["name"]}')
    if not changes:
        cpython = urllib.parse.unquote(Path(current_py).name).split('-aarch64')[0]
        print(f'up to date: {cpython}, ripgrep {manifest["ripgrep"]["version"]}')
        return 0
    if '--update' not in sys.argv:
        return 10
    notices = NOTICES.read_text()
    for name, tag, asset in changes:
        manifest[name]['version'] = tag
        manifest[name]['assets'] = {'aarch64': {'url': asset['browser_download_url'], 'sha256': verified_digest(asset)}}
        if name == 'python':
            cpython = re.search(r'cpython-(\d+\.\d+\.\d+)', asset['name']).group(1)
            notices = re.sub(r'## CPython [\d.]+', f'## CPython {cpython}', notices)
            notices = re.sub(r'python-build-standalone release `\d+`', f'python-build-standalone release `{tag}`', notices)
        else:
            notices = re.sub(r'## ripgrep [\d.]+', f'## ripgrep {tag}', notices)
    MANIFEST.write_text(json.dumps(manifest, indent=2) + '\n')
    NOTICES.write_text(notices)
    print('updated', MANIFEST.relative_to(ROOT), 'and', NOTICES.relative_to(ROOT))
    return 0


if __name__ == '__main__':
    sys.exit(main())
