These checks exercise the v0.5.7 control files and installer with isolated files,
fake Docker processes and a stub engine. They never connect to Docker or MariaDB.
They run on a POSIX host with Python 3, PowerShell 7 and `texlua` (TeX Live).

```sh
TIBIASP_TEST_PWSH=/path/to/pwsh python3 tests/save-status/run_checks.py
```

The original full runner targets the v0.5.7 baseline. The Lua, installer and
process integration checks also accept `TIBIASP_TEST_VERSION=0.5.8`; run those
three scripts with that variable to exercise the localized package. The worker
contract check accepts `-ExpectedVersion 0.5.8` for its corresponding release ZIP.

The Lua tests run the actual handler. The PowerShell checks load helper functions
or the launcher's function AST without constructing its WPF window. The installer
checks use synthetic originals with fixture-only old hashes and the actual payload
and new hashes. They verify rejection and rollback as well as success. The final
integration test runs the actual helper and handler across separate processes with
a fake CLI and engine, including an engine error and an explicit restart.

Before release, validate on a **disposable copy** of the target Windows installation:

1. Install through the actual updater using Windows PowerShell 5.1; verify backups,
   expected source hashes, success/failure exit codes and unchanged protected data.
2. Reopen the WPF launcher. Confirm stopped, restarting and unavailable-Docker
   states; a running container alone must not be shown as verified game readiness.
3. Start with the existing database stopped. Confirm database health before game
   startup and verify that `playerbot-setup` is not rerun and the existing database
   container/volume are retained.
4. Change a test character's position/storage, save, stop and explicitly start.
   Verify the change persists and inspect engine/database logs for write failures.
   `SAVE_DONE` acknowledges completion of the Lua save call; the native binding in
   the reference engine does not report every persistence error through its return.
5. Test failed save, late/missing acknowledgement and interrupted shutdown. Failure
   must not be reported as success, force-stop the game, replay a command, or
   blindly restore automatic restart. Preserve outstanding command evidence.
6. Verify successful stop leaves the database running and game restart disabled;
   explicit start restores the previously saved policy only after `PING READY`.

No publication or user-data testing is performed by these checks. The actual
Both supplied updater files have been inspected. Their manifest fields,
`-TargetRoot` invocation, backups, SHA-256 check, success marker and installed
version handling match this package. The worker's native process invocation and
hardcoded Windows path checks still need a real Windows end-to-end run; the
unmodified worker cannot perform a complete installation on a POSIX host.

The optional updater contract checks take the real, separately supplied worker
and a locally built release ZIP with its adjacent `latest.json`:

```sh
pwsh -NoLogo -NoProfile -File tests/save-status/worker-tests.ps1 \
  -WorkerPath /path/to/TibiaSP_UpdateWorker.ps1 \
  -PackageZip /path/to/TibiaSP_v0.5.7_SAVE_STATUS.zip
```

These checks load selected AST functions/statements and mock child launch/Docker;
they never execute the worker's Main body. They report the existing custom-name
guard defect and the POSIX extraction limitation explicitly, not as validated
Windows installation. The v0.5.7 installer separately verifies labels/state.
