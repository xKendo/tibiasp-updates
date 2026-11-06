"""Isolated Linux/CI checks. Requires Python 3, PowerShell 7 and texlua; no Docker daemon."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
PWSH = os.environ.get('TIBIASP_TEST_PWSH') or shutil.which('pwsh')
if not PWSH:
    raise SystemExit('Set TIBIASP_TEST_PWSH to an installed pwsh, or add pwsh to PATH.')
if not (os.environ.get('TIBIASP_TEST_TEXLUA') or shutil.which('texlua')):
    raise SystemExit('texlua is required for Lua protocol tests.')
if os.name != 'posix':
    raise SystemExit('The fake docker.exe fixtures currently require a POSIX execution host.')

checks = [
    ('Lua protocol', [sys.executable, str(ROOT / 'lua_protocol_tests.py')]),
    ('Launcher state/results', [PWSH, '-NoLogo', '-NoProfile', '-File', str(ROOT / 'launcher-tests.ps1')]),
    ('Control helper', [PWSH, '-NoLogo', '-NoProfile', '-File', str(ROOT / 'helper-tests.ps1')]),
    ('Installer/rollback', [sys.executable, str(ROOT / 'installer-tests.py')]),
    ('Helper/Lua integration with fake services', [sys.executable, str(ROOT / 'integration-tests.py')]),
]
environment = dict(os.environ, TIBIASP_TEST_PWSH=PWSH)
for name, command in checks:
    result = subprocess.run(command, cwd=ROOT.parents[1], env=environment, text=True, capture_output=True, timeout=180)
    if result.returncode:
        print(f'FAIL: {name}\n{result.stdout}\n{result.stderr}')
        raise SystemExit(result.returncode)
    tail = '\n'.join((result.stdout.strip() or result.stderr.strip()).splitlines()[-2:])
    print(f'PASS: {name}\n{tail}', flush=True)
print('All isolated checks passed. Windows/WPF, real persistence and updater integration remain unverified.')
