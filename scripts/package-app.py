#!/usr/bin/env python3
"""Build dist/AgentDeck.app plus ZIP, DMG and SHA-256 sums for the host architecture.

Steps: pinned runtime bootstrap -> collector payload -> Swift release build -> bundle assembly ->
ad-hoc code signature (inside-out) -> archives. No agent CLI is installed or bundled.
Signing identity: AGENTDECK_SIGN_IDENTITY (default "-" = ad-hoc, not notarized).
"""
from pathlib import Path
import hashlib
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / 'dist'
VERSION = re.search(r'current = "([^"]+)"', (ROOT / 'Sources/AgentDeckCore/Version.swift').read_text()).group(1)
ARCH = 'arm64'
if platform.machine() != 'arm64':
    sys.exit('AgentDeck supports Apple silicon (arm64) Macs only.')
IDENTITY = os.environ.get('AGENTDECK_SIGN_IDENTITY', '-')
BUNDLE_ID = 'org.agentdeck.AgentDeck'


def run(*cmd, **kw):
    print('+', ' '.join(str(c) for c in cmd), flush=True)
    return subprocess.run([str(c) for c in cmd], check=True, **kw)


def macho(path):
    with open(path, 'rb') as f:
        return f.read(4) in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xce\xfa\xed\xfe', b'\xbe\xba\xfe\xca')


def main():
    if '--skip-runtime' not in sys.argv:
        run(sys.executable, ROOT / 'scripts/bootstrap-runtime.py')
    run(sys.executable, ROOT / 'scripts/prepare-runtime.py')
    # Keep the build machine's paths out of the release: remap source paths and strip debug maps below.
    build = ['swift', 'build', '-c', 'release', '--arch', ARCH, '-Xswiftc', '-file-prefix-map', '-Xswiftc', f'{ROOT}=AgentDeck']
    run(*build, cwd=ROOT)
    bin_dir = Path(subprocess.run([*build, '--show-bin-path'], cwd=ROOT,
                                  check=True, capture_output=True, text=True).stdout.strip())

    app = DIST / 'AgentDeck.app'
    if app.exists(): shutil.rmtree(app)
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    resources = contents / 'Resources'; resources.mkdir()
    shutil.copy2(bin_dir / 'AgentDeckApp', contents / 'MacOS/AgentDeckApp')
    shutil.copy2(bin_dir / 'agentdeck', contents / 'MacOS/agentdeck')
    for exe in ('AgentDeckApp', 'agentdeck'):
        run('strip', '-S', '-x', contents / 'MacOS' / exe)

    runtime = resources / 'Runtime'
    shutil.copytree(ROOT / 'Runtime', runtime, symlinks=True,
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '*.sha256', 'idlelib', 'tkinter', 'turtledemo',
                                                  'ensurepip', '_tkinter*', 'include', 'pkgconfig', 'itcl*', 'libtcl*',
                                                  'tcl9*', 'thread3*', 'tk9*'))
    shutil.copytree(ROOT / 'Resources/ProviderIcons', resources / 'ProviderIcons')
    licenses = resources / 'Licenses'; licenses.mkdir()
    shutil.copy2(ROOT / 'LICENSE', licenses / 'LICENSE.txt')
    shutil.copy2(ROOT / 'THIRD_PARTY_NOTICES.md', licenses / 'THIRD_PARTY_NOTICES.md')
    shutil.copy2(ROOT / 'Vendor/Upstream/LICENSE', licenses / 'UPSTREAM-MIT-LICENSE.txt')
    shutil.copy2(ROOT / 'Runtime/python/lib/python3.14/LICENSE.txt', licenses / 'PYTHON-LICENSE.txt')
    shutil.copy2(ROOT / 'Resources/ProviderIcons/LICENSE-lobe-icons.txt', licenses / 'LOBE-ICONS-LICENSE.txt')
    for file in (ROOT / 'Runtime/licenses/ripgrep').iterdir():
        shutil.copy2(file, licenses / f'RIPGREP-{file.name}')

    iconset = DIST / 'AppIcon.iconset'
    run('swift', ROOT / 'scripts/make-icon.swift', iconset)
    run('iconutil', '-c', 'icns', iconset, '-o', resources / 'AppIcon.icns')
    shutil.rmtree(iconset)

    with open(contents / 'Info.plist', 'wb') as f:
        plistlib.dump({
            'CFBundleName': 'AgentDeck', 'CFBundleDisplayName': 'AgentDeck', 'CFBundleIdentifier': BUNDLE_ID,
            'CFBundleExecutable': 'AgentDeckApp', 'CFBundlePackageType': 'APPL', 'CFBundleIconFile': 'AppIcon',
            'CFBundleShortVersionString': VERSION, 'CFBundleVersion': VERSION, 'CFBundleInfoDictionaryVersion': '6.0',
            'LSMinimumSystemVersion': '14.0', 'LSUIElement': True, 'LSApplicationCategoryType': 'public.app-category.developer-tools',
            'NSHumanReadableCopyright': 'MIT License. Includes MIT-licensed collectors; see Resources/Licenses.',
            'NSHighResolutionCapable': True,
        }, f)

    # Inside-out signing: every nested Mach-O first, then the helper CLI, then the bundle.
    nested = [p for p in runtime.rglob('*') if p.is_file() and not p.is_symlink() and macho(p)]
    for path in nested:
        run('codesign', '--force', '--sign', IDENTITY, '--timestamp=none', path, stdout=subprocess.DEVNULL)
    run('codesign', '--force', '--sign', IDENTITY, '--timestamp=none', '--identifier', BUNDLE_ID + '.cli', contents / 'MacOS/agentdeck')
    run('codesign', '--force', '--sign', IDENTITY, '--timestamp=none', app)
    run('codesign', '--verify', '--deep', '--strict', app)
    names = [p.name.lower() for p in (contents / 'MacOS').iterdir()]
    assert len(names) == len(set(names)) == 2, 'executables must differ case-insensitively'
    probe = subprocess.run([contents / 'MacOS/agentdeck', '--help'], capture_output=True, text=True, timeout=20)
    # Running the bundled CLI and a collector must leave the sealed bundle unchanged.
    smoke = DIST / 'smoke-state'; shutil.rmtree(smoke, ignore_errors=True)
    subprocess.run([contents / 'MacOS/agentdeck', 'refresh', 'hermes'], capture_output=True, timeout=120,
                   env={'HOME': str(smoke), 'PATH': '/usr/bin:/bin', 'AGENTDECK_HOME': str(smoke / 'state'), 'AGENTDECK_FIXTURE_MODE': '1'})
    shutil.rmtree(smoke, ignore_errors=True)
    run('codesign', '--verify', '--deep', '--strict', app)
    assert probe.returncode == 0 and 'agentdeck providers' in probe.stdout, 'bundled CLI is not the CLI'

    stem = f'AgentDeck-{VERSION}-macos-{ARCH}'
    zip_path, dmg_path = DIST / f'{stem}.zip', DIST / f'{stem}.dmg'
    for path in (zip_path, dmg_path):
        path.unlink(missing_ok=True)
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, zip_path)
    staging = DIST / 'dmg'
    if staging.exists(): shutil.rmtree(staging)
    staging.mkdir(); run('ditto', app, staging / 'AgentDeck.app'); (staging / 'Applications').symlink_to('/Applications')
    run('hdiutil', 'create', '-volname', 'AgentDeck', '-srcfolder', staging, '-ov', '-format', 'UDZO', dmg_path, stdout=subprocess.DEVNULL)
    shutil.rmtree(staging)
    sums = ''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in (zip_path, dmg_path))
    (DIST / f'{stem}.sha256').write_text(sums)
    print(sums, end='')
    print(f'Packaged {app} ({ARCH}, signature: {"ad-hoc" if IDENTITY == "-" else IDENTITY}, not notarized)')


if __name__ == '__main__':
    main()
