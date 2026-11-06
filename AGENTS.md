# TibiaSP development and releases

- The user has authorized publishing completed fixes and update packages to this
  repository through its existing GitHub Actions workflow without asking for a
  separate publication confirmation. Later explicit user instructions take
  precedence. Validate the concrete update before pushing, monitor the workflow,
  and verify the released ZIP and `latest.json` before announcing availability.
- Preserve the workflow: the assistant prepares/publishes; the user checks,
  downloads and installs only through the existing launcher. Do not require
  manual source-file replacement as the normal installation method.
- Releases are immutable. Add a new `packages/vX.Y.Z` version; do not overwrite
  published release assets. A push changing `packages/**` on `main` triggers
  `.github/workflows/publish-tibiasp.yml` and publishes the newest complete package.
- This checkout contains update sources, not the user's running Windows server.
  Never reset databases, characters or the world; remove volumes; or run schema
  provisioning against the user's data. Keep bot AI, stamina and equipment outside
  the save/status fix unless separately requested.
- Keep secrets, database dumps, private configuration and world files out of
  commits and packages. Use platform-provided Git authentication; do not print
  credentials or request a token solely because the GitHub CLI is not logged in.
- Preserve installer checksums, backups, rollback and noninteractive execution.
  Windows PowerShell payloads need a single UTF-8 BOM and PS5.1-compatible syntax.
- Run `tests/save-status/run_checks.py` on a POSIX host with PowerShell 7 and
  `texlua` (set `TIBIASP_TEST_PWSH` if needed). These are isolated checks with fake
  services, not proof of Windows/WPF behavior or real game/database persistence.
- Communicate in Polish and report release success only when GitHub Actions and
  the launcher-facing release assets have been checked.
- Keep every user-facing TibiaSP UI/log/status/error message in Polish, matching
  the existing launcher. Machine protocol tokens such as PING, READY, SAVE_DONE
  and JSON keys remain unchanged. Do not ship new English diagnostic prose.
