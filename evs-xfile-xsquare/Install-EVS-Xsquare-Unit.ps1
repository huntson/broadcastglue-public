<#
.SYNOPSIS
    Installs the EVS XFile3 / XSquare suite on a unit, working around the installer's
    broken SQL-detection gate automatically (no separate "repair" step).

.DESCRIPTION
    The XSquare suite decides "is SQL 2016 installed?" solely by reading
    HKLM\...\Uninstall\Microsoft SQL Server SQLServer2016\UninstallString, stripping
    quotes, and testing it's non-empty. On rebuilt units that value is left as ""
    (empty quotes) after SQL setup, so the suite aborts with
    "SQL Server 2016 is required but has not been installed" even though SQL is fully
    installed and running.

    This wrapper drives the whole flow: it launches the XFile3 setup, and between passes
    it repairs that ARP UninstallString (in BOTH the 64-bit and WOW6432Node hives, since
    the 32-bit installer reads the 32-bit view first) the moment SQL is present. Pass 1
    installs SQL (and aborts at the gate); the wrapper fixes the value; pass 2 sees SQL
    and completes. The ARP write is an internal step of the install, not a manual repair.

.PARAMETER Setup
    Path to the XFile3 setup exe. If omitted, auto-detects XFile3_v*_Win10_setup.exe on
    the Desktop, then R:\XF3_Restore\Software Versions.

.PARAMETER Silent
    Run the XFile3 setup with /VERYSILENT /SUPPRESSMSGBOXES /NORESTART. Off by default
    (the EVS suite is most reliable run interactively); use only if you've confirmed
    silent works on your build.

.PARAMETER MaxPasses
    Maximum setup passes (default 3). Pass 1 installs SQL, pass 2 completes after the fix.

.PARAMETER CollectLogs
    Optional. Logs are ALWAYS captured under a transcript and a diagnostic bundle
    (transcript, our SQL detection result, the ARP UninstallString values, the EVS + SQL
    setup logs, SQL event-log entries, environment, and any exception + stack) is saved as a
    .zip on the Desktop AUTOMATICALLY whenever the install fails. On a SUCCESSFUL run the
    operator is asked with a Yes/No dialog whether to keep the bundle (declined = the staging
    folder is removed, no clutter). This switch just forces "always keep, no prompt" - useful
    for unattended/automation runs. Nothing is transmitted; the .zip is emailed back manually.

.PARAMETER NoGui
    Force console-only output. By default a live progress window (status line + progress bar +
    live log) is shown when a desktop is present; over SSH or a headless session it already
    falls back to console. Use this to suppress the window on an interactive machine.

.EXAMPLE
    .\Install-EVS-Xsquare-Unit.ps1                 # on failure: auto-saves a .zip; on success: asks
.EXAMPLE
    .\Install-EVS-Xsquare-Unit.ps1 -Setup "R:\XF3_Restore\Software Versions\XFile3_v5.4.0.7664_Win10_setup.exe"
.EXAMPLE
    .\Install-EVS-Xsquare-Unit.ps1 -CollectLogs   # always keep the diagnostic .zip, no prompt (automation)
#>
[CmdletBinding()]
param(
    [string] $Setup,
    [switch] $Silent,
    [int]    $MaxPasses = 3,
    [switch] $CollectLogs,
    [switch] $NoGui
)

$ErrorActionPreference = 'Continue'
$ProgressPreference     = 'SilentlyContinue'

# ---------------------------------------------------------------- self-elevate
$principal = New-Object Security.Principal.WindowsPrincipal(
                 [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" } }
        else { $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value)`"" }
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

function Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan;  Gui-Status $m; Gui-Log "==> $m" }
function Info($m){ Write-Host "    $m";                          Gui-Log "    $m" }
function Warn($m){ Write-Host "    $m" -ForegroundColor Yellow;  Gui-Log "    $m" }
function Good($m){ Write-Host "    $m" -ForegroundColor Green;   Gui-Log "    $m" }

# ---------------------------------------------------------------- live progress window
# A WinForms window (status line + progress bar + live log) shows by default when a desktop
# is present; -NoGui or a headless/SSH context falls back to console output. Same DoEvents
# pattern as the cleaner: work runs on the UI thread and pumps messages between steps (the
# window is inert only while the EVS setup itself is running, which has its own UI then).
$script:Gui  = (-not $NoGui) -and [Environment]::UserInteractive
$script:form = $null; $script:pb = $null; $script:lbl = $null; $script:logbox = $null; $script:btn = $null
if ($script:Gui) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $script:form = New-Object System.Windows.Forms.Form
        $script:form.Text = 'EVS XFile3 / XSquare Installer'
        $script:form.Size = New-Object System.Drawing.Size(780,470)
        $script:form.StartPosition = 'CenterScreen'
        $script:lbl = New-Object System.Windows.Forms.Label
        $script:lbl.Location = New-Object System.Drawing.Point(12,12); $script:lbl.Size = New-Object System.Drawing.Size(744,22)
        $script:lbl.Text = 'Starting...'
        $script:pb = New-Object System.Windows.Forms.ProgressBar
        $script:pb.Location = New-Object System.Drawing.Point(12,38); $script:pb.Size = New-Object System.Drawing.Size(744,24)
        $script:pb.Minimum = 0; $script:pb.Maximum = 100; $script:pb.Value = 0
        $script:logbox = New-Object System.Windows.Forms.TextBox
        $script:logbox.Location = New-Object System.Drawing.Point(12,72); $script:logbox.Size = New-Object System.Drawing.Size(744,318)
        $script:logbox.Multiline = $true; $script:logbox.ScrollBars = 'Vertical'; $script:logbox.ReadOnly = $true
        $script:logbox.Font = New-Object System.Drawing.Font('Consolas',9)
        $script:btn = New-Object System.Windows.Forms.Button
        $script:btn.Location = New-Object System.Drawing.Point(656,398); $script:btn.Size = New-Object System.Drawing.Size(100,28)
        $script:btn.Text = 'Close'; $script:btn.Enabled = $false
        $script:btn.Add_Click({ if ($script:form) { $script:form.Close() } })
        $script:form.Controls.AddRange(@($script:lbl,$script:pb,$script:logbox,$script:btn))
        $script:form.Show(); $script:form.Refresh(); [System.Windows.Forms.Application]::DoEvents()
    } catch {
        $script:Gui = $false
        Write-Host "GUI init failed ($($_.Exception.Message)); using console output." -ForegroundColor Yellow
    }
}
function Gui-Log([string]$line) {
    if (-not $script:Gui) { return }
    try { $script:logbox.AppendText($line + "`r`n"); [System.Windows.Forms.Application]::DoEvents() } catch {}
}
function Gui-Status([string]$s, [int]$bump = 5) {
    if (-not $script:Gui) { return }
    try {
        if ($s)          { $script:lbl.Text = $s }
        if ($bump -gt 0) { $script:pb.Value = [Math]::Min(95, $script:pb.Value + $bump) }
        [System.Windows.Forms.Application]::DoEvents()
    } catch {}
}
# Yes/No dialog. Returns $true/$false when a desktop is present, $null when headless
# (SSH / no interactive session) so the caller can apply a non-interactive default.
function Confirm-Gui($text, $title) {
    if (-not [Environment]::UserInteractive) { return $null }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $r = [System.Windows.Forms.MessageBox]::Show($text, $title,
                 [System.Windows.Forms.MessageBoxButtons]::YesNo,
                 [System.Windows.Forms.MessageBoxIcon]::Question)
        return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
    } catch { return $null }
}
function Notify-Gui($text, $title) {
    if (-not [Environment]::UserInteractive) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [void][System.Windows.Forms.MessageBox]::Show($text, $title,
                 [System.Windows.Forms.MessageBoxButtons]::OK,
                 [System.Windows.Forms.MessageBoxIcon]::Information)
    } catch {}
}

# ---------------------------------------------------------------- locate setup
if (-not $Setup) {
    $cands = @()
    $cands += Get-ChildItem "$env:USERPROFILE\Desktop" -Recurse -Filter 'XFile3_v*_Win10_setup.exe' -ErrorAction SilentlyContinue
    $cands += Get-ChildItem 'R:\XF3_Restore\Software Versions' -Filter 'XFile3_v*_Win10_setup.exe' -ErrorAction SilentlyContinue
    $Setup = ($cands | Where-Object { $_.FullName -notmatch '__MACOSX' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
if ((-not $Setup -or -not (Test-Path $Setup)) -and $script:Gui) {
    # let the operator browse to it instead of failing
    try {
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title  = 'Select the XFile3 setup .exe'
        $ofd.Filter = 'XFile3 setup (*.exe)|*.exe|All files (*.*)|*.*'
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $Setup = $ofd.FileName }
    } catch {}
}
if (-not $Setup -or -not (Test-Path $Setup)) {
    Warn "XFile3 setup exe not found. Pass -Setup <path> or pick it when prompted."
    if ($script:Gui) { Notify-Gui "No XFile3 setup .exe selected - nothing to install." "EVS Installer" }
    exit 1
}
Step "Using setup: $Setup"

# ---------------------------------------------------------------- the fix
# Detect whichever SQL Server the bundled suite actually installed (2016/2017/2019/
# 2022...), reading it live from the registry rather than assuming 2016. Returns the
# instance, folder number (130/140/150/160), release year, version, and a REAL
# existing exe path to stamp into the ARP value.
function Get-InstalledSqlInfo {
    $inst = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if (-not (Test-Path $inst)) { return $null }
    $p = Get-ItemProperty -Path $inst -ErrorAction SilentlyContinue
    $mssql = $p.MSSQLSERVER                                        # default instance
    if (-not $mssql) {
        $mssql = ($p.PSObject.Properties | Where-Object { $_.Value -match '^MSSQL\d+\.' } |
                  Select-Object -First 1).Value
    }
    if (-not $mssql) { return $null }                             # e.g. MSSQL15.MSSQLSERVER
    $major  = [int]($mssql -replace '^MSSQL(\d+)\..*$','$1')      # 13,14,15,16
    $folder = $major * 10                                         # 130,140,150,160
    $yearMap = @{ 13='2016'; 14='2017'; 15='2019'; 16='2022' }
    $year = $yearMap[$major]; if (-not $year) { $year = "20$major" }   # best-effort for future majors
    $base = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$mssql"
    $ver = (Get-ItemProperty "$base\MSSQLServer\CurrentVersion" -Name CurrentVersion -ErrorAction SilentlyContinue).CurrentVersion
    if (-not $ver) { $ver = (Get-ItemProperty "$base\Setup" -Name Version -ErrorAction SilentlyContinue).Version }
    if (-not $ver) { $ver = "$major.0.0.0" }
    # a real, non-empty value the gate can read; RemoveQuotes() must leave something
    # behind. The gate only tests non-emptiness - it never executes this path.
    $cand = @(
        "C:\Program Files\Microsoft SQL Server\$folder\Setup Bootstrap\SQLServer$year\x64\SetupARP.exe",
        "C:\Program Files\Microsoft SQL Server\$folder\Setup Bootstrap\SQL$year\x64\SetupARP.exe"
    )
    # any SetupARP on disk, but sort the one under the detected folder ($folder) first
    $cand += (Get-ChildItem 'C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\*\x64\SetupARP.exe' -ErrorAction SilentlyContinue |
              Select-Object -Expand FullName | Sort-Object { $_ -notmatch "\\$folder\\" })
    $cand += "C:\Program Files\Microsoft SQL Server\$mssql\MSSQL\Binn\sqlservr.exe"
    $arpExe = $cand | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $arpExe) { $arpExe = $cand[0] }                      # last resort: a non-empty path string
    return @{ Instance=$mssql; Folder=$folder; Year=$year; Version=$ver; ArpExe=$arpExe }
}

# Repair the SQL-detection ARP value the suite's gate reads (both registry views),
# version-agnostic. The suite gates "is SQL installed?" on RemoveQuotes(UninstallString)
# <> ""; on a rebuilt unit that value is left "" after SQL setup churn, so the suite
# aborts "SQL Server is required..." though SQL is present and running. This:
#   (a) sweeps every existing SQL-Server / SMO uninstall key and fixes any whose
#       UninstallString is empty (catches whatever leaf name the installed version uses,
#       incl. the SMO GUID - no hardcoded 2016 key), and
#   (b) ensures the canonical "Microsoft SQL Server SQLServer<year>" key exists non-empty
#       when the engine is present (that was the exact broken shape seen on .64).
# It never fabricates a key for a SQL that isn't installed (that would falsely pass the
# gate, then fail a later step). Exact leaf name in (b) is verified for 2016; for newer
# majors it follows the same naming pattern - the sweep in (a) covers it if it differs.
function Repair-SqlArpUninstallString {
    $sql = Get-InstalledSqlInfo
    if (-not $sql) { return $false }   # SQL not installed yet; nothing to repair
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    Info "detected SQL $($sql.Year) ($($sql.Instance), v$($sql.Version)); ARP stamp -> $($sql.ArpExe)"

    function Set-EmptyArp($key, $name, $ver, $exe) {
        $cur = (Get-ItemProperty -Path $key -Name UninstallString -ErrorAction SilentlyContinue).UninstallString
        $stripped = if ($cur) { $cur.Trim('"').Trim() } else { '' }
        if ($stripped -ne '') { return $false }   # already valid, leave it
        Set-ItemProperty -Path $key -Name UninstallString -Value $exe -Type String
        New-ItemProperty -Path $key -Name DisplayName    -Value $name -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name DisplayVersion -Value $ver  -PropertyType String -Force | Out-Null
        Info "repaired empty UninstallString: $name  ($key)"
        return $true
    }

    $fixed = $false
    # (a) version-agnostic sweep of existing SQL/SMO uninstall keys with an empty value
    # NOTE: a plain foreach (not Get-ChildItem | ForEach-Object) so that $fixed assignments
    # update THIS function's variable; a ForEach-Object script block runs in a child scope
    # where the write would be lost and the return value wrong.
    foreach ($h in $hives) {
        foreach ($item in (Get-ChildItem $h -ErrorAction SilentlyContinue)) {
            $leaf = $item.PSChildName
            $dn   = (Get-ItemProperty $item.PSPath -Name DisplayName -ErrorAction SilentlyContinue).DisplayName
            # leaf names vary: "...SQLServer2016" (2016) vs "...SQL2019"/"...SQL2022"
            # (2019/2022). Match "SQL Server" + any 4-digit year, plus SMO.
            if ($leaf -match 'SQL Server .*20\d\d|Shared Management Objects' -or
                $dn   -match 'SQL Server .*20\d\d|Shared Management Objects') {
                $nm = if ($dn) { $dn } else { "Microsoft $leaf" }
                if (Set-EmptyArp $item.PSPath $nm $sql.Version $sql.ArpExe) { $fixed = $true }
            }
        }
    }
    # (b) ensure the canonical year key exists non-empty (the .64 failure shape).
    # The exact leaf differs by version - 2016 = "...SQLServer2016", 2019/2022 =
    # "...SQL2019"/"...SQL2022" (verified via a real SQL 2019 ARP entry). We can't see
    # which leaf the newer suite gates on, so ensure BOTH variants; the extra one is a
    # harmless cosmetic ARP entry pointing at a real SetupARP (the cleaner removes it).
    $leafYears = @("Microsoft SQL Server SQLServer$($sql.Year)", "Microsoft SQL Server SQL$($sql.Year)")
    foreach ($leafYear in $leafYears) {
        foreach ($h in $hives) {
            $k = Join-Path $h $leafYear
            if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
            if (Set-EmptyArp $k "Microsoft SQL Server $($sql.Year) (64-bit)" $sql.Version $sql.ArpExe) { $fixed = $true }
        }
    }
    return $fixed
}

function Is-XsquareInstalled {
    [bool](Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match 'Xsquare' -or $_.DisplayName -match 'EVS Xsquare Service' })
}

# ---------------------------------------------------------------- diagnostics
# Gather everything needed to triage a failure of EITHER the EVS installer or this
# wrapper: environment, what our SQL detection returned, the ARP UninstallString values
# (so a bad detection / failed write is visible), the EVS + SQL setup logs, SQL event-log
# entries, and any wrapper exception + stack. Written into $dir; the caller zips it.
function Collect-DiagBundle($dir, $setupExit, $err) {
    if (-not $dir) { return }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    @(
        "Computer   : $env:COMPUTERNAME"
        "User       : $env:USERNAME"
        "When       : $(Get-Date -Format s)"
        "OS         : $($os.Caption) build $($os.BuildNumber)"
        "PowerShell : $($PSVersionTable.PSVersion)"
        "ExecPolicy : $(Get-ExecutionPolicy)"
        "Setup exe  : $Setup"
        "Setup exit : $setupExit"
    ) | Set-Content (Join-Path $dir 'environment.txt')

    # what our own detection produced (a misdetection shows up here)
    $sql = Get-InstalledSqlInfo
    if ($sql) { ($sql.GetEnumerator() | ForEach-Object { '{0,-9}: {1}' -f $_.Key, $_.Value }) | Set-Content (Join-Path $dir 'sql-detection.txt') }
    else { 'Get-InstalledSqlInfo returned NULL (no SQL instance detected)' | Set-Content (Join-Path $dir 'sql-detection.txt') }

    # the exact values the installer's gate reads - before/after our write is visible here
    $hives = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
               'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    $arp = foreach ($h in $hives) {
        Get-ChildItem $h -ErrorAction SilentlyContinue | ForEach-Object {
            $pp = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($_.PSChildName -match 'SQL' -or $pp.DisplayName -match 'SQL Server') {
                [pscustomobject]@{
                    Hive            = if ($h -match 'WOW6432Node') { 'WOW6432' } else { '64-bit' }
                    Key             = $_.PSChildName
                    DisplayName     = $pp.DisplayName
                    UninstallString = $pp.UninstallString
                }
            }
        }
    }
    $arp | Format-List | Out-String | Set-Content (Join-Path $dir 'arp-uninstallstrings.txt')

    if ($err) { (($err | Out-String) + "`n--- stack ---`n" + $err.ScriptStackTrace) | Set-Content (Join-Path $dir 'error.txt') }

    $evslog = 'C:\EVSLogs\Xsquare\Install\XSquareInstall.log'
    if (Test-Path $evslog) { Copy-Item $evslog $dir -ErrorAction SilentlyContinue }

    Get-ChildItem 'C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object {
            Copy-Item $_.FullName (Join-Path $dir "SQLSummary-$($_.Directory.Parent.Parent.Name).txt") -ErrorAction SilentlyContinue
        }

    try {
        Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='MSSQLSERVER' } -MaxEvents 100 -ErrorAction SilentlyContinue |
            Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List | Out-String |
            Set-Content (Join-Path $dir 'sql-eventlog.txt')
    } catch {}
}

# ---------------------------------------------------------------- drive the install
$setupArgs = @()
if ($Silent) { $setupArgs = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') }

# Always run under a transcript into a staging folder on the Desktop. Whether we keep it
# is decided at the end (kept automatically on failure, or by a Yes/No dialog on success);
# on a success the operator declines, the staging folder is deleted so nothing is littered.
$stamp        = Get-Date -Format 'yyyyMMdd-HHmmss'
$bundleDir    = Join-Path ([Environment]::GetFolderPath('Desktop')) "EVS-Install-Logs-$env:COMPUTERNAME-$stamp"
New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null
$transcribing = $false
try { Start-Transcript -Path (Join-Path $bundleDir 'transcript.txt') -Force | Out-Null; $transcribing = $true } catch {}

$setupExit = $null
$runError  = $null
$result    = 'unknown'
try {
    for ($pass = 1; $pass -le $MaxPasses; $pass++) {
        Step "Pass $pass/$MaxPasses"

        # apply the fix up-front each pass (no-op until SQL is present)
        if (Repair-SqlArpUninstallString) { Good "SQL ARP gate value repaired before this pass." }
        else { Info "SQL not present yet / ARP value already valid - nothing to repair." }

        Step "Launching XFile3 setup (waiting for it to finish)"
        $proc = Start-Process -FilePath $Setup -ArgumentList $setupArgs -Wait -PassThru
        $setupExit = $proc.ExitCode
        Info "setup exit code: $setupExit"

        if (Is-XsquareInstalled) { Good "XSquare suite is installed (services present) - DONE."; $result = 'installed'; break }

        if ($pass -lt $MaxPasses) {
            Warn "Suite not installed after pass $pass (expected on pass 1 - it installs SQL then aborts at the gate). Re-running with the ARP fix applied."
        } else {
            $result = 'failed'
            Warn "Reached max passes without the XSquare service appearing."
            Warn "Check C:\EVSLogs\Xsquare\Install\XSquareInstall.log for the last [IsAppInstalled] result."
        }
    }

    Step "Final state"
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.PathName -match 'EVS Broadcast Equipment' -or $_.Name -match 'Xsquare|NotificationService|XTGateway' } |
        Select-Object State,Name | Format-Table -Auto | Out-String | Write-Host
}
catch {
    $runError = $_
    $result   = 'error'
    Warn "Wrapper error: $($_.Exception.Message)"
}
finally {
    if ($transcribing) { try { Stop-Transcript | Out-Null } catch {} }

    $failed = ($result -ne 'installed')
    # Keep the logs automatically on failure; on success keep only if the operator says yes
    # to the dialog (or -CollectLogs forces it for automation). Never needs a CLI flag.
    $keep = $failed -or $CollectLogs
    if (-not $keep) {
        if ((Confirm-Gui "Install completed successfully.`n`nSave a diagnostic log bundle to the Desktop anyway?" "EVS Installer") -eq $true) { $keep = $true }
    }

    if ($keep) {
        Step "Collecting diagnostic bundle"
        try { Collect-DiagBundle $bundleDir $setupExit $runError } catch { Warn "bundle collection issue: $($_.Exception.Message)" }
        $zip = "$bundleDir.zip"
        try {
            if (Test-Path $zip) { Remove-Item $zip -Force }
            Compress-Archive -Path (Join-Path $bundleDir '*') -DestinationPath $zip -Force
            Remove-Item $bundleDir -Recurse -Force -ErrorAction SilentlyContinue
            Good "Diagnostic bundle: $zip"
            $msg = if ($failed) {
                "Install did not complete (result=$result).`n`nDiagnostic logs saved to:`n$zip`n`nPlease email that .zip back for triage."
            } else {
                "Diagnostic logs saved to:`n$zip`n`nEmail that .zip back for triage."
            }
            Notify-Gui $msg "EVS Installer - logs saved"
        } catch { Warn "could not zip bundle: $($_.Exception.Message)  (folder kept: $bundleDir)" }
    } else {
        Remove-Item $bundleDir -Recurse -Force -ErrorAction SilentlyContinue   # success + declined: no litter
    }
}

# ---------------------------------------------------------------- keep the window up
if ($script:Gui -and $script:form) {
    $final = if ($result -eq 'installed') { 'Done - XSquare installed. Close this window.' }
             else { "Finished (result=$result). Review the log, then close this window." }
    Gui-Status $final 0
    try { $script:pb.Value = 100 } catch {}
    try { $script:btn.Enabled = $true } catch {}
    while ($script:form -and $script:form.Visible) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 120 }
}
