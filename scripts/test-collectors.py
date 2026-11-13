#!/usr/bin/env python3
"""Run upstream fixtures against the macOS payload, not unused copied source."""
from pathlib import Path
import argparse
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--bash', default=shutil.which('bash'))
parser.add_argument('--jobs', type=int, default=4)
parser.add_argument('--only')
args = parser.parse_args()
stage = root / 'artifacts/collector-tests'
stage.mkdir(parents=True, exist_ok=True)
shutil.copytree(root / 'Runtime/bin', stage / 'bin', dirs_exist_ok=True)
for file in (stage / 'bin').glob('agentdeck-collect-*'):
    # Fixture loaders use the upstream source layout; only the generated stage uses this path.
    file.write_text(file.read_text().replace('"lib"', '"shell", "plugins", "agents"')
                    .replace('Path(os.environ.get("AGENTDECK_PROVIDER_CONFIG_DIR") or (config_home() / "agentdeck" / "providers"))', 'config_home() / "agentdeck" / "agents"'))
shutil.copytree(root / 'Runtime/lib', stage / 'shell/plugins/agents', dirs_exist_ok=True)
module = stage / 'shell/plugins/agents/collectors.py'
module.write_text(module.read_text().replace('AGENTDECK_REFRESH_AT', 'AGENTDECK_REFRESH_AT'))
shutil.copytree(root / 'Vendor/Upstream/test', stage / 'test', dirs_exist_ok=True)
for file in (root / 'Vendor/Upstream/bin').glob('agentdeck-account-*'):
    shutil.copy2(file, stage / 'bin' / file.name)
helpers = stage / 'test/shell.d/agent-usage-helpers.sh'
helpers.write_text(helpers.read_text().replace('"${agent_sandbox_pids[@]}"', '"${agent_sandbox_pids[@]:-}"') + '\n')
# A test-only Bash 5.3 built without readline has no compgen builtin.
base = stage / 'test/shell.d/base-test.sh'
base.write_text(base.read_text() + '\nif ! type compgen >/dev/null 2>&1; then\n  compgen() { python3 -c "import os; print(chr(10).join(os.environ))"; }\nfi\n')
fixture = stage / 'test/shell.d/agent-usage-shared-test.sh'
fixture.write_text(fixture.read_text().replace('cli.parent.mkdir(parents=True)', 'cli.parent.mkdir(parents=True, exist_ok=True)'))
partition = stage / 'test/shell.d/agent-usage-partition-test.sh'
partition.write_text(partition.read_text().replace("sed -i 's#", "sed -i '' 's#"))
# Only this fixture's Linux descriptor assertion changes. The collector still receives /dev/null.
fixture = stage / 'test/shell.d/agent-usage-agy-harness-test.sh'
fixture.write_text(fixture.read_text().replace('$(readlink /proc/$$/fd/0) == /dev/null',
    '$(/usr/sbin/lsof -a -p $$ -d 0 -Fn | /usr/bin/tail -1) == n/dev/null'))
# No production payload has Linux shebang assumptions. Tests launch collector files directly.
python = (root / 'Runtime/python/bin/python3').resolve() if (root / 'Runtime/python/bin/python3').exists() else Path(sys.executable)
for file in (stage / 'bin').iterdir():
    file.write_text(file.read_text().replace('#!/usr/bin/python3', '#!' + str(python)))
tools = root / 'artifacts/test-tools'; tools.mkdir(parents=True, exist_ok=True)
for name in ['date', 'timeout']:
    source = root / 'scripts/test-tools' / name
    shutil.copy2(source, tools / name); (tools / name).chmod(0o755)
env = dict(os.environ, PATH=os.pathsep.join([str(python.parent), str(root / 'Runtime/tools'), str(tools), '/usr/bin', '/bin', '/usr/sbin', '/sbin']))
env['AGENTDECK_TEST_PYTHON'] = str(python)
logs = root / 'artifacts/collector-logs'; logs.mkdir(exist_ok=True)
tests = sorted((stage / 'test/shell.d').glob('agent-usage*-test.sh'))
# update is a Linux service command replaced by CollectorService, not shipped in our runtime.
tests = [f for f in tests if f.name not in ['agent-usage-update-test.sh', 'agent-usage-fallback-test.sh'] and (args.only is None or args.only in f.name)]
def run(file):
    log = logs / (file.stem + '.log')
    with log.open('w') as out:
        try:
            result = subprocess.run([args.bash, str(file)], cwd=root, env=env, stdout=out, stderr=subprocess.STDOUT, timeout=600)
            status = result.returncode
        except subprocess.TimeoutExpired:
            status = 124
    text = log.read_text(errors='replace')
    count = sum(line.startswith('ok -') for line in text.splitlines())
    print(f'{"PASS" if status == 0 else "FAIL"} {file.name}: {count} checks', flush=True)
    return {'test': file.name, 'status': status, 'checks': count, 'log': str(log.relative_to(root))}
with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
    results = list(pool.map(run, tests))
(root / 'artifacts/collector-results.json').write_text(json.dumps(results, indent=2) + '\n')
print(f'{sum(r["status"] == 0 for r in results)}/{len(results)} suites; {sum(r["checks"] for r in results)} checks')
sys.exit(any(r['status'] != 0 for r in results))
