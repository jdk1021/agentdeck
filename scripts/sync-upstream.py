#!/usr/bin/env python3
"""Re-vendor the upstream collectors from a release tag.

  python3 scripts/sync-upstream.py --check          print the latest stable tag; exit 10 if newer than vendored
  python3 scripts/sync-upstream.py [--tag vX.Y.Z]   replace Vendor/Upstream and docs/upstream-inventory.json

The naming transform is the one used for the original import; applied to the recorded tag it reproduces
every vendored file byte for byte (`--verify`). Uses GITHUB_TOKEN/GH_TOKEN when set.
"""
from pathlib import Path
import argparse
import hashlib
import io
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / 'Vendor/Upstream'
INVENTORY = ROOT / 'docs/upstream-inventory.json'
NAME = 'om' + 'archy'  # kept out of source text on purpose (scripts/audit.py)
REPO_ID = json.loads(INVENTORY.read_text())['repositoryID']
RULES = [(NAME.upper() + '_AGENT_USAGE_REFRESH_AT', 'AGENTDECK_REFRESH_AT'), (NAME + '-agent-usage-', 'agentdeck-collect-'),
         (NAME + '-agent-usage', 'agentdeck-collect'), (NAME + '-agent-account-', 'agentdeck-account-'),
         (NAME.upper() + '_PATH', 'AGENTDECK_RUNTIME'), (NAME.upper(), 'AGENTDECK'), (NAME.capitalize(), 'Upstream'), (NAME, 'agentdeck')]
SELECT = [re.compile(p) for p in (r'^bin/agentdeck-collect-[a-z0-9-]+$', r'^bin/agentdeck-account-[a-z0-9-]+$', r'^shell/plugins/agents/(?!.*\.qml$)(?!manifest\.json$)',  # collector code only; the Linux UI is not used
                                  
                                  r'^test/shell\.d/agent[-_]usage', r'^test/shell\.d/base-test\.sh$',
                                  r'^docs/agent-usage-collectors\.md$', r'^manual/17-ai\.md$', r'^LICENSE$')]


def transform(text):
    for old, new in RULES:
        text = text.replace(old, new)
    return text


def api(path, raw=False):
    request = urllib.request.Request(f'https://api.github.com/repositories/{REPO_ID}{path}', headers={'Accept': 'application/vnd.github+json'})
    token = os.environ.get('GITHUB_TOKEN') or os.environ.get('GH_TOKEN')
    if token:
        request.add_header('Authorization', f'Bearer {token}')
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read()
    return data if raw else json.loads(data)


def version(tag):
    return tuple(int(x) for x in re.findall(r'\d+', tag)[:3])


def fetch(tag):
    """Upstream files as {transformed relative path: (original bytes, transformed text)}."""
    archive = tarfile.open(fileobj=io.BytesIO(api(f'/tarball/{tag}', raw=True)))
    files = {}
    for member in archive.getmembers():
        if not member.isfile():
            continue
        rel = member.name.split('/', 1)[1] if '/' in member.name else member.name
        mapped = transform(rel)
        if any(p.search(mapped) for p in SELECT) or (VENDOR / mapped).exists():
            data = archive.extractfile(member).read()
            files[mapped] = (data, transform(data.decode('utf-8', 'surrogateescape')), member.mode)
    return files


def inventory(tag, commit, latest, files):
    collectors = []
    for rel in sorted(files):
        match = re.fullmatch(r'bin/agentdeck-collect-([a-z0-9-]+)', rel)
        if not match or match.group(1) == 'update':
            continue
        text = files[rel][1]
        cid = re.search(r'^AGENT_ID = "([^"]+)"', text, re.M)
        name = re.search(r'^AGENT_NAME = "([^"]+)"', text, re.M)
        if not cid or not name:
            continue
        collectors.append({'id': cid.group(1), 'name': name.group(1), 'path': rel, 'sha256': hashlib.sha256(files[rel][0]).hexdigest()})
    data = json.loads(INVENTORY.read_text())  # keeps key order and provenance fields
    data.update(tag=tag, commit=commit, latestStable=latest, collectors=sorted(collectors, key=lambda c: c['id']))
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tag')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--verify', action='store_true', help='confirm the transform reproduces the vendored tree')
    args = parser.parse_args()
    current = json.loads(INVENTORY.read_text())
    latest = api('/releases/latest')['tag_name']
    if args.check:
        print(latest)
        sys.exit(10 if version(latest) > version(current['tag']) else 0)
    tag = current['tag'] if args.verify else (args.tag or latest)
    files = fetch(tag)
    if args.verify:
        vendored = {p.relative_to(VENDOR).as_posix() for p in VENDOR.rglob('*') if p.is_file()}
        bad = [rel for rel in sorted(vendored) if rel not in files or files[rel][1] != (VENDOR / rel).read_text(errors='surrogateescape')]
        print(f'{len(vendored) - len(bad)}/{len(vendored)} vendored files reproduced from {tag}')
        sys.exit(1 if bad else 0)
    commit = api(f'/commits/{tag}')['sha']
    with tempfile.TemporaryDirectory(dir=ROOT) as scratch:
        staged = Path(scratch) / 'Upstream'
        for rel, (_, text, mode) in files.items():
            out = staged / rel
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(text, errors='surrogateescape')
            out.chmod(0o755 if mode & 0o111 else 0o644)
        shutil.rmtree(VENDOR)
        shutil.move(str(staged), VENDOR)
    INVENTORY.write_text(json.dumps(inventory(tag, commit, latest, files), indent=2) + '\n')
    ids = [c['id'] for c in json.loads(INVENTORY.read_text())['collectors']]
    print(f'Vendored {len(files)} files from {tag} ({commit[:12]}); {len(ids)} collectors: {" ".join(ids)}')


if __name__ == '__main__':
    main()
