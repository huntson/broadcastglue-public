# Versioning

Each subproject in this repo carries its own [semver](https://semver.org) version and
its own tag namespace, the same way the main broadcastglue monorepo works.

- Each subproject has a `VERSION` file at its root (e.g. `evs-xfile-xsquare/VERSION`).
- Each subproject has a `CHANGELOG.md` recording what changed per version.
- Tags are namespaced: `<subproject>/vMAJOR.MINOR.PATCH` (e.g. `evs-xfile-xsquare/v0.1.0`).
- Commits follow **Conventional Commits**; the type sets the bump:

| Type | Meaning | Bump |
|---|---|---|
| `feat` | new feature | MINOR |
| `fix` | bug fix | PATCH |
| `perf` | performance | PATCH |
| `refactor` / `docs` / `chore` / `test` | no behavior change | none |
| `feat!` / `BREAKING CHANGE:` | breaking | MAJOR |

Pre-`1.0.0` (`0.x`) means the tool works but hasn't been runtime-proven across every
target; breaking changes may still land in a MINOR.

## Release steps (manual, no CI here)

1. Make commits (prefixed `<subproject>: <type>: …`).
2. Bump the subproject's `VERSION` and add a `CHANGELOG.md` entry.
3. Commit `chore(release): <subproject> vX.Y.Z`, then
   `git tag <subproject>/vX.Y.Z` and push with `--tags`.

## Runtime output is not versioned

The diagnostic bundles the tools produce (`EVS-*-Logs-*.zip`, `-BackupRoot`, `*.log`) are
per-machine state and are `.gitignore`d — only the source and its `VERSION`/`CHANGELOG`
are tracked.
