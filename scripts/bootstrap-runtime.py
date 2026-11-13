#!/usr/bin/env python3
"""Pinned, digest-checked runtime dependencies; never installs an agent CLI."""
from pathlib import Path
import hashlib
import json
import os
import platform
import shutil
import subprocess
import tarfile
import tempfile

root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / 'scripts/dependencies.json').read_text())
arch = 'aarch64' if platform.machine() == 'arm64' else 'x86_64'
runtime = root / 'Runtime'
for component in ['python', 'ripgrep']:
    destination = runtime / ('python' if component == 'python' else 'tools/rg')
    marker = runtime / (component + '.sha256')
    item = manifest[component]['assets'][arch]
    if destination.exists() and marker.exists() and marker.read_text().strip() == item['sha256']:
        continue
    with tempfile.TemporaryDirectory(prefix='agentdeck-runtime-') as scratch:
        folder = Path(scratch)
        archive = folder / 'download.tar.gz'
        subprocess.run(['/usr/bin/curl', '-L', '--fail', '--silent', '--show-error', item['url'], '-o', str(archive)], check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != item['sha256']:
            raise ValueError(f'{component} archive digest mismatch')
        with tarfile.open(archive) as tar:
            tar.extractall(folder / 'extract', filter='data')
        if component == 'python':
            if destination.exists(): shutil.rmtree(destination)
            shutil.move(str(folder / 'extract/python'), destination)
        else:
            binary = next((folder / 'extract').rglob('rg'))
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(binary, destination)
            notices = runtime / 'licenses/ripgrep'; notices.mkdir(parents=True, exist_ok=True)
            for path in binary.parent.glob('*'):
                if path.name.startswith(('COPYING', 'LICENSE', 'UNLICENSE')): shutil.copy2(path, notices / path.name)
        marker.write_text(item['sha256'] + '\n')
    print(f'Prepared {component} for {arch}')
subprocess.run([str(runtime / 'python/bin/python3'), '-c', 'from compression import zstd; import ssl, sqlite3, tomllib; print("Runtime stdlib OK")'], check=True)
