#!/usr/bin/env python3
"""Release audit. Exit status 1 on any finding.

  python3 scripts/audit.py            source tree checks
  python3 scripts/audit.py --dist     also checks dist/AgentDeck.app and the release archives

Checks: upstream inventory vs. vendored collectors, generated payload, support matrix and fixtures;
the upstream product name outside the README credit; credentials and personal data in tracked files;
bundle composition and licenses.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parent.parent
findings = []


def finding(message):
    findings.append(message)
    print('FAIL', message)


def tracked_files():
    try:
        out = subprocess.run(['git', 'ls-files', '-co', '--exclude-standard'], cwd=ROOT, capture_output=True, text=True, check=True).stdout
        return [ROOT / line for line in out.splitlines() if (ROOT / line).is_file()]
    except (OSError, subprocess.CalledProcessError):
        skip = {'.build', 'artifacts', 'dist', 'Runtime', '.git', '.swiftpm', '__pycache__'}
        return [p for p in ROOT.rglob('*') if p.is_file() and not (set(p.relative_to(ROOT).parts) & skip)]


# 1. Collector inventory and coverage.
inventory = json.loads((ROOT / 'docs/upstream-inventory.json').read_text())
ids = [c['id'] for c in inventory['collectors']]
if len(ids) != 23 or len(set(ids)) != 23:
    finding(f'inventory lists {len(ids)} collectors; expected 23 unique')
matrix = (ROOT / 'docs/support-matrix.md').read_text()
fixtures = '\n'.join(p.read_text(errors='replace') for p in (ROOT / 'Vendor/Upstream/test').rglob('*') if p.is_file())
for cid in ids:
    if not (ROOT / f'Vendor/Upstream/bin/agentdeck-collect-{cid}').is_file():
        finding(f'{cid}: vendored collector missing')
    if (ROOT / 'Runtime/bin').exists() and not (ROOT / f'Runtime/bin/agentdeck-collect-{cid}').is_file():
        finding(f'{cid}: generated payload missing (run scripts/prepare-runtime.py)')
    if f'`{cid}`' not in matrix:
        finding(f'{cid}: no row in docs/support-matrix.md')
    if f'agentdeck-collect-{cid}' not in fixtures and cid not in fixtures:
        finding(f'{cid}: no upstream fixture references it')
    if cid != 'local' and not (ROOT / f'Resources/ProviderIcons/{cid}.png').is_file():
        finding(f'{cid}: provider icon missing')
print(f'inventory: {len(ids)} collectors checked')

# 2. Upstream product name: only the README credit may carry it.
NAME = re.compile('om' + 'archy', re.I)
CREDIT_FILES = {'README.md', 'README.ko.md'}
files = tracked_files()
for path in files:
    rel = path.relative_to(ROOT).as_posix()
    if rel in CREDIT_FILES or rel == 'CLAUDE_HANDOFF.md':
        continue
    data = path.read_bytes()
    if NAME.search(data.decode('utf-8', 'replace')) or NAME.search(rel):
        finding(f'upstream product name in {rel}')

# 3. Credentials and personal data.
SECRET = re.compile(r'(sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|xai-[A-Za-z0-9]{40,}'
                    r'|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{20,}\.eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,})')
HOME = re.compile(r'/(?:Users|home)/(?!Shared/|runner/|<|\$|USER|you|me/|example|fixture|alice|bob|test|user)[A-Za-z0-9_-][A-Za-z0-9._-]+/')
EMAIL = re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
ALLOWED_EMAIL = re.compile(r'@(example\.(com|org|net|invalid)|[a-z0-9.-]*\.(invalid|test|example)|anthropic\.com|lobehub\.com)$|^git@github\.com$|^noreply@', re.I)
for path in files:
    rel = path.relative_to(ROOT).as_posix()
    if path.suffix.lower() in {'.png', '.icns', '.jpg', '.tgz', '.zip', '.dmg'} or rel == 'CLAUDE_HANDOFF.md':
        continue
    text = path.read_text(errors='replace')
    for match in SECRET.finditer(text):
        if 'fixture' in text[max(0, match.start() - 80):match.end() + 80].lower() and rel.startswith('Vendor/Upstream/test'):
            continue
        finding(f'possible credential in {rel}: {match.group(0)[:12]}…')
    for match in HOME.finditer(text):
        finding(f'personal home path in {rel}: {match.group(0)}')
    for match in EMAIL.finditer(text):
        if not ALLOWED_EMAIL.search(match.group(0)) and not rel.startswith('Vendor/Upstream/'):
            finding(f'e-mail address in {rel}: {match.group(0)}')
print(f'scanned {len(files)} files for names, credentials and personal data')

# 4. Release bundle.
if '--dist' in sys.argv:
    app = ROOT / 'dist/AgentDeck.app/Contents'
    required = ['MacOS/AgentDeckApp', 'MacOS/agentdeck', 'Info.plist', 'Resources/AppIcon.icns', 'Resources/Runtime/inventory.json',
                'Resources/Runtime/python/bin/python3', 'Resources/Runtime/tools/rg', 'Resources/Runtime/project-settings.py',
                'Resources/Runtime/lib/collectors.py', 'Resources/Runtime/lib/agentdeck_macos.py', 'Resources/Licenses/LICENSE.txt',
                'Resources/Licenses/THIRD_PARTY_NOTICES.md', 'Resources/Licenses/UPSTREAM-MIT-LICENSE.txt',
                'Resources/Licenses/PYTHON-LICENSE.txt', 'Resources/Licenses/RIPGREP-LICENSE-MIT', 'Resources/Licenses/RIPGREP-UNLICENSE',
                'Resources/Licenses/LOBE-ICONS-LICENSE.txt']
    required += [f'Resources/Runtime/bin/agentdeck-collect-{cid}' for cid in ids]
    for item in required:
        if not (app / item).exists():
            finding(f'bundle missing {item}')
    for path in app.rglob('*'):
        rel = path.relative_to(app).as_posix()
        if path.name in {'bash', 'CLAUDE_HANDOFF.md'} or path.suffix in {'.pyc'} or 'collector-tests' in rel:
            finding(f'bundle must not contain {rel}')
        if path.is_file() and not path.is_symlink() and path.stat().st_size < 50_000_000:
            data = path.read_bytes()
            if NAME.search(data.decode('latin-1')):
                finding(f'upstream product name inside bundle file {rel}')
            if HOME.search(data.decode('latin-1')):
                finding(f'personal home path inside bundle file {rel}: {HOME.search(data.decode("latin-1")).group(0)}')
    lister = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app.parent)], capture_output=True, text=True)
    if lister.returncode != 0:
        finding('code signature does not verify: ' + lister.stderr.strip()[:200])
    for archive in (ROOT / 'dist').glob('AgentDeck-*.zip'):
        with zipfile.ZipFile(archive) as z:
            names = z.namelist()
            if not any(n.endswith('Contents/MacOS/agentdeck') for n in names):
                finding(f'{archive.name}: CLI missing')
    print('bundle checked')

if findings:
    print(f'{len(findings)} finding(s)')
    sys.exit(1)
print('audit: OK')
