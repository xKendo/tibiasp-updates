from pathlib import Path
import subprocess
import os
import shutil
import tempfile

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parents[1] / 'packages/v0.5.7/source/payload/silnik-8.60/server/data/globalevents/scripts/tibiasp_launcher_commands.lua'
TEXLUA = os.environ.get('TIBIASP_TEST_TEXLUA') or shutil.which('texlua')
assert TEXLUA, 'texlua is required'
CASES = [
    'no_request', 'ping', 'save', 'void_save', 'save_false', 'save_exception',
    'shutdown', 'shutdown_false', 'shutdown_exception', 'shutdown_unavailable',
    'legacy_request', 'empty_request', 'malformed_correlated', 'unknown_command',
    'oversized_request', 'crlf_request', 'stale_processing', 'stale_response',
    'atomic_response', 'request_claim_failure', 'processing_state_unknown', 'request_state_unknown',
    'request_read_failure', 'request_close_failure', 'processing_remove_failure',
    'shutdown_remove_failure', 'shutdown_response_failure', 'response_open_failure', 'response_write_failure',
    'response_flush_failure', 'response_close_failure', 'response_rename_failure',
    'new_request_during_save',
]

for case in CASES:
    with tempfile.TemporaryDirectory(prefix='lua_case_') as directory:
        cwd = Path(directory)
        (cwd / 'data').mkdir()
        result = subprocess.run(
            [TEXLUA, str(ROOT / 'lua_harness.lua'), str(SOURCE), case],
            cwd=cwd, text=True, capture_output=True,
        )
        if result.returncode:
            raise SystemExit(f'FAIL {case}\n{result.stdout}\n{result.stderr}')
        assert result.stdout.strip() == f'PASS {case}', result.stdout
        print(result.stdout.strip())
print(f'{len(CASES)} Lua protocol tests passed using actual texlua in isolated temporary directories.')
