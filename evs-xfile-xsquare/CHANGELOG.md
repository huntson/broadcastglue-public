# Changelog — evs-xfile-xsquare

All notable changes to the EVS XFile3 / XSquare install + cleaner tooling.
Versions follow [semver](https://semver.org); see `../VERSIONING.md`.

## 0.1.0 — 2026-09-17

Initial tracked release.

### Added
- `Install-EVS-Xsquare-Unit.ps1` — drives the XFile3 setup and repairs the broken SQL
  ARP `UninstallString` gate automatically; SQL-version-agnostic (2016/2017/2019/2022,
  detected live from the registry).
- `Clean-EVS-Xsquare-Unit.ps1` — dry-run-by-default teardown of the suite (and optionally
  its SQL instance), dynamic discovery, DB backup, reboot-resume.
- Live WinForms progress window on both (status line + progress bar + live log), on by
  default; `-NoGui` for console/headless.
- Diagnostic `.zip` on the Desktop: auto-saved on failure, offered by dialog on success,
  forced with `-CollectLogs`; verbose end-of-run summary telling the operator what happened
  and exactly where the file is.
- Both scripts pass PSScriptAnalyzer (cosmetic style rules intentionally not applied).

### Known limitations
- Static-verified only (parser + PSScriptAnalyzer). The WinForms UI, registry writes, and
  install/teardown flow are not yet runtime-tested on Windows.
- The SQL-ARP repair write path is proven on SQL 2016; 2017/2019/2022 values are
  doc-verified but not runtime-tested (no such unit available).
