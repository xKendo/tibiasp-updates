#!/usr/bin/env python3
"""Run the real installer against synthetic originals and a fail-closed fake Docker.

No game services, Docker daemon, real LOCALAPPDATA or checkout files are modified.
PowerShell is Linux 7.4.6; Windows 5.1/CIM and the absent updater remain unverified.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE_CANDIDATES = (Path(__file__).resolve().parents[2] / 'packages/v0.5.7/source',
                     Path.cwd() / 'packages/v0.5.7/source')
REPO_SOURCE = Path(os.environ['TIBIASP_INSTALLER_SOURCE']) if 'TIBIASP_INSTALLER_SOURCE' in os.environ else next(p for p in SOURCE_CANDIDATES if p.is_dir())
PWSH_NAME = os.environ.get('TIBIASP_TEST_PWSH') or shutil.which('pwsh')
assert PWSH_NAME, 'Set TIBIASP_TEST_PWSH or put pwsh on PATH'
PWSH = Path(PWSH_NAME)
CONTROL = (
    'TibiaSP_Launcher.ps1',
    'TIBIA_REAL860.ps1',
    'silnik-8.60/server/data/globalevents/scripts/tibiasp_launcher_commands.lua',
)
CHANNEL_BASE = 'silnik-8.60/server/data/'
CHANNEL = {
    CHANNEL_BASE + 'tibiasp_launcher.request': b'SAVE\n',
    CHANNEL_BASE + 'tibiasp_launcher.processing': b'SHUTDOWN\n',
    CHANNEL_BASE + 'tibiasp_launcher.response': b'SAVE_DONE\n',
}
PROTECTED = {
    'silnik-8.60/server/protected-world.otbm': b'fixture world: must not change',
    'silnik-8.60/server/protected-characters.sql': b'fixture characters: must not change',
    'silnik-8.60/server/config.lua': b'fixture stamina config: must not change',
    'silnik-8.60/server/data/bots/protected-bot.lua': b'fixture bot AI: must not change',
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()



FAKE_DOCKER = '''#!{python}
import json, os, pathlib, sys
root = pathlib.Path(os.environ['TIBIASP_INSTALL_FIXTURE']).resolve()
if not (root / 'ONLY_TEST_FIXTURE').is_file():
    raise SystemExit('refusing non-fixture operation')
args = sys.argv[1:]
with (root / 'docker-calls.jsonl').open('a') as out:
    out.write(json.dumps(args) + '\\n')
config_path = root / 'docker-state.json'
config = json.loads(config_path.read_text())
if args == ['info', '--format', '{{{{.ServerVersion}}}}']:
    if config.get('info_failure'):
        raise SystemExit(17)
    print('fixture-only-27.0')
elif args == ['ps', '-aq', '--filter', 'label=com.docker.compose.project=tibiasp-real860', '--filter', 'label=com.docker.compose.service=server']:
    config['ps_calls'] = config.get('ps_calls', 0) + 1
    config_path.write_text(json.dumps(config))
    for identity in config.get('ids', ['fixture-game']):
        print(identity)
elif len(args) == 4 and args[:2] == ['inspect', '--format'] and args[3] in config.get('ids', ['fixture-game']):
    if args[2] == '{{{{json .Config.Labels}}}}':
        print(json.dumps({{'com.docker.compose.project':'tibiasp-real860','com.docker.compose.service':'server','com.docker.compose.oneoff': config.get('oneoff', 'False')}}))
    elif args[2] == '{{{{json .State}}}}':
        state = config.get('state', {{'Running':False, 'Restarting':False, 'Status':'exited'}})
        if config.get('running_on_second_check') and config.get('ps_calls', 0) >= 2:
            state = {{'Running':True, 'Restarting':False, 'Status':'running'}}
        print(json.dumps(state))
    else:
        raise SystemExit('unexpected inspect template')
else:
    raise SystemExit('forbidden Docker command in fixture')
'''

# Fault injection invokes the unmodified installer and fails a real command after
# backup or after partial write/removal, so rollback is exercised, not simulated.
COPY_FAULT = r'''
$script:Injected = $false
function Copy-Item {
    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
    if (-not $script:Injected -and $LiteralPath.EndsWith('/payload/TIBIA_REAL860.ps1')) {
        $script:Injected = $true
        [IO.File]::WriteAllText($Destination, 'fixture partial write')
        throw 'fixture injected partial payload copy failure'
    }
    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
}
'''
REMOVE_FAULT = r'''
$script:Injected = $false
function Remove-Item {
    param([string]$LiteralPath, [switch]$Force)
    if (-not $script:Injected -and $LiteralPath.EndsWith('/tibiasp_launcher.processing')) {
        $script:Injected = $true
        Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
        throw 'fixture injected removal failure after deleting channel file'
    }
    Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
}
'''

SOURCE_RACE = r'''
$script:Injected = $false
function Copy-Item {
    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
    if (-not $script:Injected -and $LiteralPath.EndsWith('/TibiaSP_Launcher.ps1') -and $Destination.Contains('/Backups/')) {
        $script:Injected = $true
        [IO.File]::WriteAllText($LiteralPath, 'fixture externally changed during backup')
    }
    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
}
'''


class InstallerFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='tibiasp-installer-fixture-', dir='/tmp')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        (self.base / 'ONLY_TEST_FIXTURE').write_text('no user data')
        self.target = self.base / 'TibiaSP'
        self.package = self.base / 'package'
        self.local = self.base / 'local-app-data'
        self.bin = self.base / 'bin'
        self.target.mkdir(); self.local.mkdir(); self.bin.mkdir()
        shutil.copytree(REPO_SOURCE, self.package)
        for relative in CONTROL:
            path = self.target / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('# synthetic pre-update control fixture: ' + relative + '\n')
        fixture_support = {
            'silnik-8.60/server/data/globalevents/globalevents.xml': '<globalevents><globalevent name="TibiaSP launcher" interval="1000" script="tibiasp_launcher_commands.lua"/></globalevents>',
            'silnik-8.60/server/compose.yaml': '# synthetic protected compose fixture\n',
            'URUCHOM_TIBIASP.vbs': "' synthetic launcher marker; never executed\n",
        }
        for relative, content in fixture_support.items():
            path = self.target / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        for relative, content in {**CHANNEL, **PROTECTED}.items():
            path = self.target / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        # Override OLD hashes only in this temporary package to support synthetic
        # originals. Keep the saved package NEW hashes, and validate those against
        # the actual copied payload so packaging mistakes still fail the tests.
        manifest_path = self.package / 'file-hashes.json'
        if manifest_path.is_file():
            manifest = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
        else:
            manifest = {'version':'0.5.7', 'files':[
                {'path':relative, 'new':digest(self.package / 'payload' / relative)}
                for relative in CONTROL
            ]}
        self.assertEqual({entry['path'] for entry in manifest['files']}, set(CONTROL))
        for entry in manifest['files']:
            self.assertEqual(entry['new'], digest(self.package / 'payload' / entry['path']))
            entry['old'] = [digest(self.target / entry['path'])]
        manifest_path.write_text(json.dumps(manifest))
        fake = self.bin / 'docker.exe'
        fake.write_text(FAKE_DOCKER.format(python=sys.executable))
        fake.chmod(0o700)
        self.state({})
        self.original = self.snapshot()

    def state(self, config):
        (self.base / 'docker-state.json').write_text(json.dumps(config))

    def snapshot(self):
        return {str(path.relative_to(self.target)):path.read_bytes()
                for path in self.target.rglob('*') if path.is_file()}

    def run_installer(self, injection=''):
        wrapper = self.base / 'invoke-installer.ps1'
        wrapper.write_text(injection + '\n& $env:TIBIASP_INSTALLER -TargetRoot $env:TIBIASP_TARGET\nexit $LASTEXITCODE\n')
        env = os.environ.copy()
        env.update({
            'PATH':str(self.bin) + os.pathsep + env['PATH'],
            'LOCALAPPDATA':str(self.local),
            'TIBIASP_INSTALL_FIXTURE':str(self.base),
            'TIBIASP_INSTALLER':str(self.package / 'install.ps1'),
            'TIBIASP_TARGET':str(self.target),
        })
        result = subprocess.run([str(PWSH), '-NoLogo', '-NoProfile', '-NonInteractive', '-File', str(wrapper)],
                                env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        self.last_output = result.stdout
        return result

    def assert_protected_unchanged(self):
        current = self.snapshot()
        for relative, original in self.original.items():
            if relative not in CONTROL and relative not in CHANNEL:
                self.assertEqual(original, current.get(relative), relative)

    def assert_failure_unchanged(self, result, expected):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('TIBIASP_UPDATE_OK', result.stdout)
        self.assertIn(expected, result.stdout)
        self.assertEqual(self.snapshot(), self.original)

    def assert_success_archives_and_preserves_data(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('TIBIASP_UPDATE_OK', result.stdout)
        for relative in CONTROL:
            self.assertEqual((self.target / relative).read_bytes(), (self.package / 'payload' / relative).read_bytes())
        for relative in CHANNEL:
            self.assertFalse((self.target / relative).exists())
        backups = list((self.local / 'TibiaSP/Backups').glob('SaveStatus_*'))
        self.assertEqual(len(backups), 1)
        for relative in (*CONTROL, *CHANNEL):
            self.assertEqual((backups[0] / relative).read_bytes(), self.original[relative])
        backup_hashes = json.loads((backups[0] / 'backup-hashes.json').read_text(encoding='utf-8-sig'))
        self.assertEqual(set(backup_hashes), set(CONTROL) | set(CHANNEL))
        for relative, expected_hash in backup_hashes.items():
            self.assertEqual(digest(backups[0] / relative), expected_hash)
        self.assert_protected_unchanged()
        calls = [json.loads(line) for line in (self.base / 'docker-calls.jsonl').read_text().splitlines()]
        self.assertEqual(sum(call[0] == 'ps' for call in calls), 2)
        self.assertTrue(all(call[0] in ('info', 'ps', 'inspect') for call in calls))

    def test_success_archives_legacy_channels_and_preserves_data(self):
        self.assert_success_archives_and_preserves_data()

    def test_empty_legacy_response_is_archived(self):
        (self.target / CHANNEL_BASE / 'tibiasp_launcher.response').write_bytes(b'')
        self.original = self.snapshot()
        self.assert_success_archives_and_preserves_data()

    def test_reinstallation_accepts_new_hashes(self):
        first = self.run_installer(); self.assertEqual(first.returncode, 0, first.stdout)
        installed = self.snapshot()
        second = self.run_installer()
        self.assertEqual(second.returncode, 0, second.stdout)
        self.assertIn('TIBIASP_UPDATE_OK', second.stdout)
        self.assertEqual(self.snapshot(), installed)

    def test_running_game_is_refused(self):
        self.state({'state':{'Running':True, 'Restarting':False, 'Status':'running'}})
        self.assert_failure_unchanged(self.run_installer(), 'Zatrzymaj gre')

    def test_restarting_game_is_refused(self):
        self.state({'state':{'Running':True, 'Restarting':True, 'Status':'restarting'}})
        self.assert_failure_unchanged(self.run_installer(), 'Zatrzymaj gre')

    def test_paused_game_is_refused(self):
        self.state({'state':{'Running':True, 'Restarting':False, 'Status':'paused'}})
        self.assert_failure_unchanged(self.run_installer(), 'Zatrzymaj gre')

    def test_no_existing_game_is_refused(self):
        self.state({'ids':[]})
        self.assert_failure_unchanged(self.run_installer(), 'Wymagany jest jeden istniejacy')

    def test_ambiguous_game_is_refused(self):
        self.state({'ids':['fixture-game', 'fixture-game-2']})
        self.assert_failure_unchanged(self.run_installer(), 'Wymagany jest jeden istniejacy')

    def test_oneoff_container_does_not_count_as_game(self):
        self.state({'oneoff':'True'})
        self.assert_failure_unchanged(self.run_installer(), 'Wymagany jest jeden istniejacy')

    def test_running_oneoff_game_is_refused(self):
        self.state({'oneoff':'True', 'state':{'Running':True, 'Restarting':False, 'Status':'running'}})
        self.assert_failure_unchanged(self.run_installer(), 'Zatrzymaj gre')

    def test_unknown_target_hash_is_refused(self):
        (self.target / CONTROL[0]).write_bytes(b'unknown customized launcher')
        self.original = self.snapshot()
        self.assert_failure_unchanged(self.run_installer(), 'Nieznana wersja pliku')

    def test_tampered_payload_is_refused(self):
        (self.package / 'payload' / CONTROL[1]).write_bytes(b'broken package')
        self.assert_failure_unchanged(self.run_installer(), 'Niezgodny SHA-256 pakietu')

    def test_unknown_channel_is_not_deleted(self):
        (self.target / CHANNEL_BASE / 'tibiasp_launcher.request').write_bytes(b'DO_SOMETHING_UNKNOWN')
        self.original = self.snapshot()
        self.assert_failure_unchanged(self.run_installer(), 'Nieznane oczekujace polecenie')

    def test_second_stopped_check_prevents_write_after_start(self):
        self.state({'running_on_second_check':True})
        self.assert_failure_unchanged(self.run_installer(), 'Zatrzymaj gre')

    def test_source_change_during_backup_is_not_overwritten(self):
        result = self.run_installer(SOURCE_RACE)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('TIBIASP_UPDATE_OK', result.stdout)
        self.assertIn('Plik zmienil sie podczas wykonywania kopii.', result.stdout)
        expected = dict(self.original)
        expected[CONTROL[0]] = b'fixture externally changed during backup'
        self.assertEqual(self.snapshot(), expected)

    def test_partial_payload_failure_rolls_back_all_files(self):
        result = self.run_installer(COPY_FAULT)
        self.assert_failure_unchanged(result, 'fixture injected partial payload copy failure')
        self.assertIn('Przywrocono poprzednie pliki i kanal polecen.', result.stdout)

    def test_partial_channel_cleanup_rolls_back_code_and_channels(self):
        result = self.run_installer(REMOVE_FAULT)
        self.assert_failure_unchanged(result, 'fixture injected removal failure')
        self.assertIn('Przywrocono poprzednie pliki i kanal polecen.', result.stdout)

    def test_update_manifest_keeps_supported_shape_and_only_allowed_files(self):
        current = json.loads((self.package / 'update-package.json').read_text())
        old = json.loads((REPO_SOURCE.parent.parent / 'v0.5.6/source/update-package.json').read_text())
        self.assertEqual(set(current), set(old))
        self.assertEqual(current['entrypoint'], 'install.ps1')
        self.assertEqual(current['version'], '0.5.7')
        self.assertEqual(current['backupFiles'], list(CONTROL))


if __name__ == '__main__':
    print('Manifest:', 'saved package manifest' if (REPO_SOURCE / 'file-hashes.json').is_file() else 'PROVISIONAL fixture-only generated manifest', flush=True)
    unittest.main(verbosity=2)
