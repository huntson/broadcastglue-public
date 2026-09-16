# EVS XFile3 / XSquare — Install & Teardown Tooling

Two PowerShell tools for rebuilding EVS Broadcast units that run the **XFile3 / XSquare**
suite on top of a bundled **SQL Server** instance:

| Script | Purpose |
|---|---|
| `Install-EVS-Xsquare-Unit.ps1` | Drives the XFile3 setup and works around the installer's broken SQL-detection gate — so the suite actually installs instead of aborting. |
| `Clean-EVS-Xsquare-Unit.ps1` | "Cleaner app" that fully removes the suite (and optionally its SQL instance) so a unit can be reinstalled clean. Safe by default. |

Both are self-contained, self-elevating, and hold no IPs, hostnames, or credentials.

---

## Background — the failure

On rebuilt units the XSquare suite kept aborting with:

> **The XSquare Suite installation failed** — *"SQL Server 2016 is required but has not been installed"*

…even though SQL Server was fully installed and running. The install log
(`C:\EVSLogs\Xsquare\Install\XSquareInstall.log`) showed the suite deciding SQL wasn't
present and calling `Abort`.

## Root cause

The XFile3 installer is Inno Setup with a compiled Pascal `[Code]` section. Disassembling
that code revealed the suite's SQL check is, in effect:

```pascal
IsSqlServer2016Installed :=
    RemoveQuotes(GetStringValue('Microsoft SQL Server SQLServer2016', 'UninstallString')) <> '';
```

It does **not** look at the SQL service, the instance registry, or the engine version. It
reads exactly one Add/Remove-Programs value — the SQL uninstall key's `UninstallString` —
strips quotes, and tests that the result is non-empty.

On a unit that has had SQL removed and reinstalled, that value is sometimes left as a pair
of **empty quotes** (`""`). `RemoveQuotes("")` → `""` → the gate reads *false* → the suite
aborts, regardless of SQL actually being there.

**Fix:** put a real, non-empty path back into that `UninstallString` (both the 64-bit and
`WOW6432Node` views, since the 32-bit installer reads the 32-bit view first) the moment SQL
is detected as present. The value only needs to be non-empty — the gate never executes it.

This is baked into `Install-EVS-Xsquare-Unit.ps1` as an internal step of the install flow,
not a manual repair.

## Two earlier SQL issues (handled by the cleaner)

Before the gate was understood, two leftover-state problems were blocking a clean SQL
reinstall:

1. **Stale database files** — old `*.mdf` / `*.ldf` left in the SQL `DATA` folder caused
   SQL Server **error 5170** ("file already exists"), so setup couldn't recreate its
   databases.
2. **Orphaned ARP keys** — leftover SQL uninstall registry keys made `msiexec /x` return
   **1605** ("not installed") and blocked reinstall; they must be deleted directly from the
   registry.

---

## `Install-EVS-Xsquare-Unit.ps1`

Auto-detects the XFile3 setup exe, self-elevates, and loops install passes. On each pass it
repairs the SQL-detection ARP value (if needed), runs the setup, and checks whether the
XSquare service appeared. Pass 1 installs SQL and aborts at the gate; the wrapper fixes the
value; pass 2 completes.

```powershell
# auto-detect the setup exe on the Desktop / R:\XF3_Restore\Software Versions
.\Install-EVS-Xsquare-Unit.ps1

# or point it at a specific build
.\Install-EVS-Xsquare-Unit.ps1 -Setup "R:\XF3_Restore\Software Versions\XFile3_v5.4.0.7664_Win10_setup.exe"
```

| Parameter | Default | Meaning |
|---|---|---|
| `-Setup <path>` | auto-detect | Path to the XFile3 setup exe. |
| `-Silent` | off | Run the setup `/VERYSILENT`. The suite is most reliable run interactively. |
| `-MaxPasses <n>` | 3 | Max setup passes (pass 1 installs SQL, pass 2 completes). |

### SQL-version-agnostic

The gate detection is **not** hard-coded to 2016. `Get-InstalledSqlInfo` reads the live
instance (`MSSQL13/14/15/16.*`) and derives the release year, folder number
(`130/140/150/160`), version, and a real `SetupARP.exe` path. The repair then:

- **(a)** sweeps every existing SQL-Server / SMO uninstall key and fixes any whose
  `UninstallString` is empty — catching whatever leaf name the installed version uses
  (2016 = `...SQLServer2016`; 2019/2022 = `...SQL2019` / `...SQL2022`), and
- **(b)** ensures the canonical year key exists non-empty (the exact failure shape seen in
  the field).

It never fabricates a key for a SQL that isn't installed.

---

## `Clean-EVS-Xsquare-Unit.ps1`

Discovers components **dynamically** (ARP uninstall strings, InstallShield/Inno
`unins000.exe`, services, folders, registry, DB files) rather than hard-coding version
GUIDs, so it adapts across units and versions.

**Safe by default:** with no switches it only inventories and prints what it *would* do (a
dry run). Nothing changes until `-Execute`. SQL database files are **copied to a timestamped
backup before SQL is touched**; data is deleted only with `-PurgeDatabases`.

```powershell
.\Clean-EVS-Xsquare-Unit.ps1                                    # dry run — inventory + plan
.\Clean-EVS-Xsquare-Unit.ps1 -Execute                          # remove EVS suite, KEEP SQL
.\Clean-EVS-Xsquare-Unit.ps1 -Execute -RemoveSqlServer -Reboot # full nuke + auto-resume
.\Clean-EVS-Xsquare-Unit.ps1 -Gui -Execute -RemoveSqlServer -PurgeDatabases -Reboot
```

| Parameter | Meaning |
|---|---|
| `-Execute` | Actually perform removal (otherwise read-only dry run). |
| `-RemoveSqlServer` | Also uninstall the SQL instance. **Destroys all databases on it** — rebuild/re-image only. |
| `-PurgeDatabases` | Skip the DB backup and let removal delete `*.mdf`/`*.ldf`. Requires `-RemoveSqlServer`. |
| `-KeepDependencies` | Keep Apple Bonjour + Thales Sentinel RMS (removed by default). |
| `-BackupRoot <path>` | DB backups + transcript location. Default `C:\EVS-Cleaner-Backup`. |
| `-Reboot` | Reboot + auto-resume via a one-shot SYSTEM startup task (up to 5 cycles) until SQL is fully gone. |
| `-Gui` | WinForms progress window (local runs only; falls back to console over SSH / SYSTEM). |
| `-Force` | Skip the "type YES" confirmation. |

Running the cleaner's **dry run** on a unit is also the quickest way to see the exact
footprint (services, instances, folders, ARP keys) a given XFile3 version leaves behind.

---

## Requirements

- Windows 10 / Windows 11, run as Administrator (both scripts self-elevate).
- Windows PowerShell 5.1 (in-box) or later.
- Run **locally on the unit** for full behavior — the GUI and reboot-resume can't operate
  over an SSH/session-0 context.

## Status

- **Root cause** confirmed by disassembly; the install fix has installed the suite
  successfully on a real SQL 2016 unit.
- **SQL detection** (`Get-InstalledSqlInfo`) verified against a live SQL 2016 install.
- **Paths / key names** for 2017/2019/2022 verified against Microsoft docs and a real SQL
  2019 ARP entry; the write path on an actual 2019/2022 unit is **not yet runtime-tested**
  (no such unit available) — on 2016 it's the same code already proven in the field.
