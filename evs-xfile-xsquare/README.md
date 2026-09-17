# EVS XFile3 / XSquare — Install & Teardown Tooling

Two PowerShell tools for rebuilding EVS Broadcast units that run the **XFile3 / XSquare**
suite on top of a bundled **SQL Server** instance:

| Script | Purpose |
|---|---|
| `Install-EVS-Xsquare-Unit.ps1` | Drives the XFile3 setup and works around the installer's broken SQL-detection gate — so the suite actually installs instead of aborting. |
| `Clean-EVS-Xsquare-Unit.ps1` | "Cleaner app" that fully removes the suite (and optionally its SQL instance) so a unit can be reinstalled clean. Safe by default. |

Both are self-contained, self-elevating, and hold no IPs, hostnames, or credentials.

---

## Getting started (do this on the unit)

You run these **on the EVS unit itself**, signed in as an administrator. No commands to
type — you double-click and follow the window.

**To install the XSquare suite:**

1. Copy **`Install-EVS-Xsquare-Unit.ps1`** onto the unit (e.g. the Desktop).
2. **Right-click it → Run with PowerShell.**
3. Click **Yes** if Windows asks for administrator permission (the "User Account Control" prompt).
4. If it asks you to pick the XFile3 setup file, browse to it and select it. Otherwise it
   finds it on its own.
5. Watch the window — it shows a progress bar and a running log. Leave it until it says
   **Done**. It may restart the setup once on its own; that's normal.
6. If anything goes wrong, it automatically saves a **log file (`.zip`) to the Desktop** and
   tells you the exact name. **Email that `.zip` file back to us** and we'll take it from there.

**To wipe a unit clean before reinstalling** (only when you intend to erase it):

1. Copy **`Clean-EVS-Xsquare-Unit.ps1`** onto the unit and **right-click → Run with PowerShell**.
2. It first shows you what it *would* remove and changes nothing — a safe preview.
3. To actually remove things you confirm in the window (type/click **YES**). ⚠️ Removing SQL
   **erases all databases on the unit** — only do this on a unit being rebuilt.
4. When it finishes it saves a **log `.zip` to the Desktop**; email it back if we asked for it.

> If Windows blocks the file with a "this came from the internet" warning: right-click the
> `.ps1` → **Properties** → tick **Unblock** → **OK**, then run it again.

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
| `-Setup <path>` | auto-detect | Path to the XFile3 setup exe. If missing, the GUI shows a file picker. |
| `-Silent` | off | Run the setup `/VERYSILENT`. The suite is most reliable run interactively. |
| `-MaxPasses <n>` | 3 | Max setup passes (pass 1 installs SQL, pass 2 completes). |
| `-NoGui` | off | Force console-only output (the GUI is on by default when a desktop is present). |

By default it shows a live progress window — status line, progress bar, and a scrolling log —
so the operator sees each step as it happens; over SSH or with `-NoGui` it falls back to
console output.

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

### Diagnostics & log collection

Logs are always captured under a transcript while the installer runs. A triage bundle (`.zip`
on the Desktop) holds the transcript, exactly what our SQL detection returned, the ARP
`UninstallString` values, the EVS + SQL setup logs, SQL event-log entries, environment, and
any wrapper exception + stack (a crash is trapped and captured, not swallowed). No CLI flag
is needed and nothing is transmitted — you email the `.zip` back for triage. The bundle is:

- **saved automatically** whenever the install fails;
- **offered via a Yes/No dialog** on a successful run (decline = the staging folder is removed);
- **forced** (no prompt) with `-CollectLogs`, for unattended/automation runs.

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
| `-NoGui` | Force console-only (the WinForms progress window is on by default on a local run). |
| `-CollectLogs` | Always keep the Desktop diagnostic `.zip`, no prompt (kept automatically if any action failed; otherwise offered via a dialog). |
| `-Gui` | Back-compat no-op; the progress window is now the default. |
| `-Force` | Skip the "type YES" confirmation. |

Like the installer, the cleaner shows the live progress window by default and drops a Desktop
diagnostic `.zip` (transcript + a snapshot of any remaining EVS/SQL services and ARP entries)
to email back — automatically on any failure, or by prompt on a clean run. The full transcript
is always written to `-BackupRoot` regardless.

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
- **Static analysis:** both scripts parse cleanly and pass PSScriptAnalyzer (only cosmetic
  style rules — e.g. `Write-Host` for the colored console — are intentionally not applied).
  This is static verification only — the WinForms UI, registry writes, and install/teardown
  flow have not been executed on Windows from here.
