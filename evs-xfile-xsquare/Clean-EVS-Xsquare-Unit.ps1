<#
.SYNOPSIS
    "Cleaner app" that fully removes the EVS Xsquare / XFile3 suite (and, optionally,
    its bundled SQL Server instance) from a unit so it can be reinstalled clean.

    Grounded on the real layout observed on an EVS unit (XFA478360, Xsquare 3.16.5 +
    XFile3 05.04 + SQL Server 2016 default instance MSSQLSERVER). It discovers
    components dynamically (ARP uninstall strings, InstallShield/Inno unins000.exe,
    services, folders, registry, DB files) rather than hard-coding version GUIDs, so
    it works across units/versions.

.DESCRIPTION
    SAFE BY DEFAULT. With no switches it only INVENTORIES and prints what it *would*
    do (dry run). Nothing is changed until you pass -Execute.

    Data protection: SQL database files (*.mdf/*.ldf) are COPIED to a timestamped
    backup before SQL is touched. Nothing deletes database data unless you add
    -PurgeDatabases. A full transcript is written to the backup folder.

.PARAMETER Execute
    Actually perform the removal. Without it, the script is a read-only dry run.

.PARAMETER RemoveSqlServer
    Also uninstall the entire SQL Server 2016 default instance. THIS DESTROYS ALL
    DATABASES ON THAT INSTANCE (Xsquare, NC, Authentication, ReportServer, plus any
    other DB on MSSQLSERVER). Only for units being fully rebuilt/re-imaged.

.PARAMETER PurgeDatabases
    Do NOT back up DB files first; let removal delete them. Requires -RemoveSqlServer.

.PARAMETER KeepDependencies
    Do NOT remove the EVS third-party deps. By default a full clean also removes Apple
    Bonjour and the Thales Sentinel RMS License Manager (both installed for EVS).

.PARAMETER BackupRoot
    Where DB backups + the transcript log go. Default C:\EVS-Cleaner-Backup.

.PARAMETER Reboot
    Reboot automatically when needed and AUTO-RESUME after boot. With -RemoveSqlServer,
    if SQL packages remain locked / a reboot is pending, the script registers a one-shot
    startup task (SYSTEM), reboots, and re-runs itself (up to 5 cycles) until SQL is fully
    gone, then clears the SQL registry remnants and removes the task.

.PARAMETER Gui
    Retained for back-compat. The GUI progress window (WinForms: status line + progress bar +
    live log) is now shown BY DEFAULT on a local interactive run; over SSH or in the SYSTEM
    resume pass it safely falls back to console. Without -Force the confirmation is a Yes/No
    dialog instead of a console prompt. Use -NoGui to force console-only.

.PARAMETER NoGui
    Force console-only output (disable the default GUI progress window).

.PARAMETER CollectLogs
    Always keep the Desktop diagnostic .zip (transcript(s) + a snapshot of remaining EVS/SQL
    services and ARP entries), no prompt. The bundle is kept automatically if any action failed;
    on a clean interactive run it is otherwise offered via a Yes/No dialog. Nothing is
    transmitted - the .zip is emailed back manually. (The full transcript is always written to
    -BackupRoot regardless.)

.PARAMETER Force
    Skip the "type YES" confirmation before destructive execution.

.EXAMPLE
    .\Clean-EVS-Xsquare-Unit.ps1                       # dry run: inventory + planned actions
.EXAMPLE
    .\Clean-EVS-Xsquare-Unit.ps1 -Execute             # remove EVS suite, KEEP SQL Server
.EXAMPLE
    .\Clean-EVS-Xsquare-Unit.ps1 -Execute -RemoveSqlServer -Reboot   # full nuke + reboot
.EXAMPLE
    .\Clean-EVS-Xsquare-Unit.ps1 -Gui -Execute -RemoveSqlServer -PurgeDatabases -Reboot   # local full nuke with progress window
#>
[CmdletBinding()]
param(
    [switch] $Execute,
    [switch] $RemoveSqlServer,
    [switch] $PurgeDatabases,
    [switch] $KeepDependencies,
    [string] $BackupRoot = "C:\EVS-Cleaner-Backup",
    [switch] $Reboot,
    [switch] $Gui,          # retained for back-compat; GUI is now on by default (see -NoGui)
    [switch] $NoGui,        # force console-only (GUI defaults on when a desktop is present)
    [switch] $CollectLogs,  # always keep the Desktop diagnostic .zip, no prompt (automation)
    [switch] $Force
)

$ErrorActionPreference = 'Continue'
$ProgressPreference     = 'SilentlyContinue'
$ScriptVersion          = '0.1.0'   # keep in sync with evs-xfile-xsquare/VERSION + CHANGELOG

# ---------------------------------------------------------------- self-elevate
$principal = New-Object Security.Principal.WindowsPrincipal(
                 [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Re-launching elevated..." -ForegroundColor Yellow
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" } }
        else { $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value)`"" }
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

# ---------------------------------------------------------------- helpers
function Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan; Update-GuiStatus $m 10; Write-GuiLog "==> $m" }
function Info($m){ Write-Host "    $m"; Write-GuiLog "    $m" }
function Warn($m){ Write-Host "    $m" -ForegroundColor Yellow; Write-GuiLog "    $m" }
function Good($m){ Write-Host "    $m" -ForegroundColor Green; Write-GuiLog "    $m" }

# Every state-changing action funnels through here: dry run just prints the plan.
function Act([string]$desc, [scriptblock]$do){
    if ($Execute) { Info "DO   : $desc"; try { & $do } catch { $script:errCount++; Warn "  ! $($_.Exception.Message)" } }
    else          { Warn "PLAN : $desc" }
}

$UninstKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

# Match sets (dynamic discovery, not hard-coded GUIDs)
$EvsArpRx  = 'EVS |Xsquare|XSecure|XNetMonitor|VIA Licensing'
# Broad enough to catch every bundled SQL version (2014/2016/2017/2019/2022) + shared bits,
# so leftover SQL2019 pieces from prior attempts get removed too.
$SqlArpRx  = 'SQL Server 20\d\d|Microsoft SQL Server 20\d\d|SQL Server 2012 Native Client|ODBC Driver 1\d for SQL Server|SQL Server 2008 Setup Support Files|Data-Tier Application Framework|Batch Parser|Shared Management Objects|SQL Server (Connection Info|Common Files|Database Engine|XEvent|DMF|SQL Diagnostics|Full text|RsFx Driver|VSS Writer|T-SQL|Setup)'
$EvsSvcRx  = 'EVS|Xsquare|NotificationService|VIA Licensing|FileTransferAgent'
$SqlSvcRx  = 'MSSQL|SQLSERVERAGENT|SQLTELEMETRY|SQLWriter|SQLBrowser|MSSQLFDLauncher|ReportServer'

$ResumeTask = 'EVSCleanerResume'                          # startup task that resumes after a reboot
$CountFile  = Join-Path $BackupRoot 'resume-count.txt'    # caps the reboot/resume loop

function Get-Arp([string]$rx){
    Get-ItemProperty $UninstKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match $rx -and ($_.UninstallString -or $_.QuietUninstallString) }
}

# EVS services matched by INSTALL PATH (most reliable) OR by name/displayname.
# Path match catches services whose names don't say "EVS" (DiscoveryClient, XTGateway,
# TruckManager Server, etc.). Excludes Windows/3rd-party binaries outside the EVS dirs.
function Get-EvsServices {
    Get-CimInstance Win32_Service | Where-Object {
        $_.PathName -match 'EVS Broadcast Equipment' -or
        $_.Name -match $EvsSvcRx -or $_.DisplayName -match $EvsSvcRx
    }
}

# ---------------------------------------------------------------- logging
if (-not (Test-Path $BackupRoot)) { New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log   = Join-Path $BackupRoot "cleaner-$stamp.log"
$script:errCount = 0                                       # action failures, for auto-keeping logs
Start-Transcript -Path $log -Append | Out-Null

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " EVS Xsquare / XFile3 unit cleaner   host=$env:COMPUTERNAME  $(Get-Date)" -ForegroundColor Cyan
Write-Host " Mode: $(if($Execute){'EXECUTE'}else{'DRY RUN (no changes)'})   RemoveSqlServer=$RemoveSqlServer   PurgeDatabases=$PurgeDatabases" -ForegroundColor Cyan
Write-Host " Log:  $log" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# ---------------------------------------------------------------- GUI (optional, local runs only)
$script:Gui = (-not $NoGui) -and [Environment]::UserInteractive   # on by default; -NoGui or headless => console
$script:form = $null; $script:pb = $null; $script:lbl = $null; $script:logbox = $null; $script:btn = $null
if ($script:Gui) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $script:form = New-Object System.Windows.Forms.Form
        $script:form.Text = 'EVS / SQL Unit Cleaner'
        $script:form.Size = New-Object System.Drawing.Size(780,470)
        $script:form.StartPosition = 'CenterScreen'
        $script:form.TopMost = $true
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
function Write-GuiLog([string]$line) {
    if (-not $script:Gui) { return }
    try { $script:logbox.AppendText($line + "`r`n"); [System.Windows.Forms.Application]::DoEvents() } catch { $null = $_ }
}
function Update-GuiStatus([string]$s, [int]$bump = 0) {
    if (-not $script:Gui) { return }
    try {
        if ($s)          { $script:lbl.Text = $s }
        if ($bump -gt 0) { $script:pb.Value = [Math]::Min(100, $script:pb.Value + $bump) }
        [System.Windows.Forms.Application]::DoEvents()
    } catch { $null = $_ }
}
# Yes/No dialog: $true/$false interactively, $null when headless (SYSTEM resume / SSH).
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
function Show-GuiNote($text, $title) {
    if (-not [Environment]::UserInteractive) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [void][System.Windows.Forms.MessageBox]::Show($text, $title,
                 [System.Windows.Forms.MessageBoxButtons]::OK,
                 [System.Windows.Forms.MessageBoxIcon]::Information)
    } catch { $null = $_ }
}

# ---------------------------------------------------------------- 0. inventory
function Inventory([string]$title){
    Step "INVENTORY: $title"
    Info "-- EVS/Xsquare ARP entries --"
    Get-Arp $EvsArpRx | Select-Object DisplayName,DisplayVersion | Sort-Object DisplayName |
        ForEach-Object { Info ("   {0}  {1}" -f $_.DisplayName,$_.DisplayVersion) }
    Info "-- EVS services --"
    Get-EvsServices | ForEach-Object { Info ("   [{0,-9}] {1}" -f $_.State,$_.Name) }
    Info "-- EVS folders --"
    @('C:\Program Files\EVS Broadcast Equipment','C:\Program Files (x86)\EVS Broadcast Equipment',
      'C:\ProgramData\EVS Broadcast Equipment') | ForEach-Object { if(Test-Path $_){ Info "   $_" } }
    Info "-- EVS registry roots --"
    @('HKLM:\SOFTWARE\EVS Broadcast Equipment','HKLM:\SOFTWARE\WOW6432Node\EVS Broadcast Equipment',
      'HKCU:\SOFTWARE\EVS Broadcast Equipment') | ForEach-Object { if(Test-Path $_){ Info "   $_" } }
    Info "-- SQL instance / services --"
    (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction SilentlyContinue).InstalledInstances |
        ForEach-Object { Info "   instance: $_" }
    Get-CimInstance Win32_Service | Where-Object { $_.Name -match $SqlSvcRx } |
        ForEach-Object { Info ("   [{0,-9}] {1}" -f $_.State,$_.Name) }
}
Inventory "before"

if ($Execute -and -not $Force) {
    $warnTxt = if ($RemoveSqlServer) { "This will REMOVE the EVS suite AND the entire SQL Server instance (ALL DATABASES)." }
               else                  { "This will REMOVE the EVS Xsquare/XFile3 suite (SQL Server left in place)." }
    if ($script:Gui) {
        $r = [System.Windows.Forms.MessageBox]::Show($warnTxt + "`n`nProceed?", 'Confirm full clean',
             [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { Warn "Aborted by user."; Stop-Transcript | Out-Null; exit }
    } else {
        Warn $warnTxt
        $ans = Read-Host "Type YES to proceed"
        if ($ans -ne 'YES') { Warn "Aborted by user."; Stop-Transcript | Out-Null; exit }
    }
}

# ---------------------------------------------------------------- 1. back up DB files
$sqlInst = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue).MSSQLSERVER
$dataDir = if ($sqlInst) { "C:\Program Files\Microsoft SQL Server\$sqlInst\MSSQL\DATA" } else { $null }
if ($dataDir -and (Test-Path $dataDir) -and -not $PurgeDatabases) {
    Step "Backing up SQL database files (mdf/ldf) -> $BackupRoot\SQL_DATA"
    $dbBk = Join-Path $BackupRoot "SQL_DATA"
    Act "copy *.mdf/*.ldf from $dataDir to $dbBk" {
        New-Item -ItemType Directory -Force -Path $dbBk | Out-Null
        Get-ChildItem $dataDir -Include *.mdf,*.ldf -File -Recurse |
            Where-Object { $_.Name -notmatch '^(master|model|msdb|tempdb|mssql|MSDB)' } |
            ForEach-Object { Copy-Item $_.FullName -Destination $dbBk -Force }
        Good ("   backed up: " + ((Get-ChildItem $dbBk -File).Count) + " files")
    }
} elseif ($PurgeDatabases) { Warn "PurgeDatabases set: DB files will NOT be backed up." }

# ---------------------------------------------------------------- 2. stop EVS services + kill processes
Step "Stopping and disabling EVS services"
Get-EvsServices | ForEach-Object {
    $n = $_.Name
    Act "stop+disable service '$n'" {
        Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
        Set-Service  -Name $n -StartupType Disabled -ErrorAction SilentlyContinue
    }
}
Step "Killing EVS processes still running from the install dirs"
Act "stop processes under *\EVS Broadcast Equipment\" {
    Get-Process | Where-Object { $_.Path -like 'C:\Program Files*\EVS Broadcast Equipment\*' } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 3. uninstall EVS components
Step "Uninstalling EVS components via ARP (silent)"
Get-Arp $EvsArpRx | Sort-Object DisplayName | ForEach-Object {
    $name = $_.DisplayName
    if ($_.QuietUninstallString) {
        Act "uninstall '$name' (quiet string)" {
            Start-Process -FilePath cmd.exe -ArgumentList '/c', $_.QuietUninstallString -Wait -WindowStyle Hidden
        }
    } elseif ($_.UninstallString -match '\{[0-9A-Fa-f-]+\}') {
        $guid = $Matches[0]
        Act "msiexec /x $guid ('$name')" { Start-Process msiexec.exe -ArgumentList "/x $guid /qn /norestart" -Wait }
    } else {
        Act "uninstall '$name' (silent inno)" {
            Start-Process -FilePath cmd.exe -ArgumentList '/c', "$($_.UninstallString) /VERYSILENT /SUPPRESSMSGBOXES /NORESTART" -Wait -WindowStyle Hidden
        }
    }
}
# Catch any component whose uninstaller isn't in ARP: run every unins000.exe under the EVS dirs.
Step "Running any remaining EVS unins000.exe uninstallers"
@('C:\Program Files\EVS Broadcast Equipment','C:\Program Files (x86)\EVS Broadcast Equipment') |
  Where-Object { Test-Path $_ } |
  ForEach-Object { Get-ChildItem $_ -Recurse -Filter 'unins*.exe' -ErrorAction SilentlyContinue } |
  ForEach-Object {
    $exe = $_.FullName
    Act "run '$exe' /VERYSILENT" { Start-Process -FilePath $exe -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait }
  }

# ---------------------------------------------------------------- 4. uninstall SQL Server (optional)
if ($RemoveSqlServer) {
    Step "Stopping SQL services"
    Get-CimInstance Win32_Service | Where-Object { $_.Name -match $SqlSvcRx } | ForEach-Object {
        $n = $_.Name
        Act "stop service '$n'" { Stop-Service -Name $n -Force -ErrorAction SilentlyContinue }
    }
    Step "Uninstalling SQL Server 2016 (msiexec sweep, up to 3 passes for dependency ordering)"
    for ($pass = 1; $pass -le 3; $pass++) {
        $sqlArp = Get-Arp $SqlArpRx
        if (-not $sqlArp) { Good "   no SQL ARP entries remain"; break }
        Info "   pass $pass : $($sqlArp.Count) SQL package(s) left"
        foreach ($e in $sqlArp) {
            if ($e.UninstallString -match '\{[0-9A-Fa-f-]+\}') {
                $guid = $Matches[0]
                Act "msiexec /x $guid ('$($e.DisplayName)')" { Start-Process msiexec.exe -ArgumentList "/x $guid /qn /norestart" -Wait }
            }
        }
        if (-not $Execute) { break }   # dry run: don't loop
    }
} else {
    Warn "SQL Server left in place (no -RemoveSqlServer). Re-run the EVS installer to recreate its DBs."
}

# ---------------------------------------------------------------- 5. delete leftover services
Step "Deleting any leftover EVS services"
Get-EvsServices | ForEach-Object {
    $n = $_.Name
    Act "sc.exe delete '$n'" { & sc.exe delete "$n" | Out-Null }
}
if ($RemoveSqlServer) {
    Get-CimInstance Win32_Service | Where-Object { $_.Name -match $SqlSvcRx } | ForEach-Object {
        $n = $_.Name
        Act "sc.exe delete '$n'" { & sc.exe delete "$n" | Out-Null }
    }
}

# ---------------------------------------------------------------- 6. remove residual folders
Step "Removing residual folders"
$folders = @(
    'C:\Program Files\EVS Broadcast Equipment',
    'C:\Program Files (x86)\EVS Broadcast Equipment',
    'C:\ProgramData\EVS Broadcast Equipment'
)
Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $folders += "$($_.FullName)\AppData\Local\EVS"
    $folders += "$($_.FullName)\AppData\Roaming\Evs Broadcast Equipment"
}
# NB: SQL Server folders are removed later (phase 8.6) only AFTER every SQL package is
# uninstalled - deleting them here would make msiexec /x fail with 1807 and orphan the ARP entries.
foreach ($f in $folders) {
    if (Test-Path $f) { Act "remove folder '$f'" { Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction SilentlyContinue } }
}

# ---------------------------------------------------------------- 7. remove registry roots
Step "Removing EVS registry roots"
@('HKLM:\SOFTWARE\EVS Broadcast Equipment','HKLM:\SOFTWARE\WOW6432Node\EVS Broadcast Equipment',
  'HKCU:\SOFTWARE\EVS Broadcast Equipment') | ForEach-Object {
    if (Test-Path $_) { Act "remove reg key '$_'" { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue } }
}
if ($RemoveSqlServer -and (Test-Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server')) {
    Warn "Left HKLM\SOFTWARE\Microsoft\Microsoft SQL Server for the SQL uninstaller to clear; remove manually only if a reinstall complains."
}

# ---------------------------------------------------------------- 8. firewall + Bonjour (optional)
Step "Removing EVS/Xsquare firewall rules"
Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'EVS|Xsquare' } | ForEach-Object {
    $d = $_.DisplayName
    Act "remove firewall rule '$d'" { $_ | Remove-NetFirewallRule -ErrorAction SilentlyContinue }
}
if (-not $KeepDependencies) {
    Step "Removing EVS third-party dependencies (Bonjour, Sentinel RMS)"
    # Apple Bonjour (EVS NotificationCenter mDNS)
    Get-Arp 'Bonjour' | ForEach-Object {
        if ($_.UninstallString -match '\{[0-9A-Fa-f-]+\}') {
            $guid = $Matches[0]
            Act "uninstall Bonjour ($guid)" { Start-Process msiexec.exe -ArgumentList "/x $guid /qn /norestart" -Wait }
        }
    }
    # Thales Sentinel RMS License Manager (EVS licensing)
    Get-Arp 'Sentinel RMS' | ForEach-Object {
        if ($_.QuietUninstallString) {
            Act "uninstall '$($_.DisplayName)'" { Start-Process cmd.exe -ArgumentList '/c', $_.QuietUninstallString -Wait -WindowStyle Hidden }
        } elseif ($_.UninstallString -match '\{[0-9A-Fa-f-]+\}') {
            $guid = $Matches[0]
            Act "msiexec /x $guid (Sentinel RMS)" { Start-Process msiexec.exe -ArgumentList "/x $guid /qn /norestart" -Wait }
        }
    }
    Act "stop+delete 'Sentinel RMS License Manager' service" {
        Stop-Service 'Sentinel RMS License Manager' -Force -ErrorAction SilentlyContinue
        & sc.exe delete 'Sentinel RMS License Manager' | Out-Null
    }
    @('C:\Program Files\Bonjour','C:\Program Files (x86)\Bonjour',
      'C:\Program Files (x86)\Common Files\Thales\Sentinel RMS License Manager') |
      Where-Object { Test-Path $_ } | ForEach-Object { $f=$_; Act "remove folder '$f'" { Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction SilentlyContinue } }
}

# ---------------------------------------------------------------- 8.6 SQL finish + reboot-resume
if ($Execute -and $RemoveSqlServer) {
    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
               [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)

    # A genuine pending-file reboot means msiexec queued deletes that only finish on
    # reboot -> reboot once and resume. Orphaned ARP entries are NOT a reason to reboot
    # (rebooting never clears them); they are handled directly below.
    if ($pending -and $Reboot) {
        $count = 0; if (Test-Path $CountFile) { $count = [int](Get-Content $CountFile) }
        if ($count -lt 5) {
            Step "Reboot pending from SQL removal - scheduling resume + reboot (cycle $($count+1)/5)"
            Act "register startup resume task + reboot" {
                New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
                Set-Content -Path $CountFile -Value ($count + 1)
                $rsArg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Execute -RemoveSqlServer -PurgeDatabases -Force -Reboot" + $(if ($KeepDependencies) { ' -KeepDependencies' } else { '' })
                $a  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $rsArg
                $t  = New-ScheduledTaskTrigger -AtStartup
                $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
                Register-ScheduledTask -TaskName $ResumeTask -Action $a -Trigger $t -Principal $pr -Force | Out-Null
            }
            Act "reboot now (auto-resumes after boot)" { Stop-Transcript | Out-Null; Restart-Computer -Force }
            return
        } else {
            Warn "Reboot cap reached (5 cycles); continuing to orphan cleanup."
        }
    }

    # Anything still registered after the msiexec sweep (and any reboot) is an ORPHANED
    # ARP entry: the product is physically gone but its Uninstall key lingers, and
    # msiexec cannot remove it (returns 1605). Delete the registry keys directly.
    $orphans = @(Get-Arp $SqlArpRx)
    if ($orphans.Count) {
        Step "Deleting $($orphans.Count) orphaned SQL ARP registry entries"
        foreach ($o in $orphans) { $kp = $o.PSPath; Act "delete ARP key '$($o.DisplayName)'" { Remove-Item -LiteralPath $kp -Recurse -Force -ErrorAction SilentlyContinue } }
    }

    # Remove leftover SQL management WMI namespaces (root\Microsoft\SqlServer\ComputerManagement1x).
    # EVS's SQL detection queries these; a stale one (e.g. ComputerManagement15 from a prior
    # SQL2019 attempt) makes the XSquare suite's IsAppInstalled check false-negative and abort.
    Step "Removing leftover SQL WMI namespaces (ComputerManagement*)"
    Get-CimInstance -Namespace "root\Microsoft\SqlServer" -ClassName __NAMESPACE -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "ComputerManagement" } | ForEach-Object {
            $nm = $_.Name
            Act "remove WMI namespace root\Microsoft\SqlServer\$nm" { Remove-CimInstance -InputObject $_ -ErrorAction SilentlyContinue }
        }

    $sqlLeft = @(Get-Arp $SqlArpRx).Count
    if ($sqlLeft -eq 0) {
        Step "SQL fully removed - clearing folders, registry roots + resume task"
        Act "remove SQL Server folders" {
            Remove-Item 'C:\Program Files\Microsoft SQL Server','C:\Program Files (x86)\Microsoft SQL Server' -Recurse -Force -ErrorAction SilentlyContinue
        }
        Act "remove SQL registry roots" {
            Remove-Item 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server' -Recurse -Force -ErrorAction SilentlyContinue
        }
        Act "remove resume task" { Unregister-ScheduledTask -TaskName $ResumeTask -Confirm:$false -ErrorAction SilentlyContinue }
        Remove-Item $CountFile -Force -ErrorAction SilentlyContinue
    } else {
        Warn "$sqlLeft SQL ARP entries could not be removed - manual check needed."
    }
}

# ---------------------------------------------------------------- 9. verify + finish
Inventory "after"
Step "DONE"
Good "Transcript: $log"
if (-not $Execute) { Warn "This was a DRY RUN. Re-run with -Execute (add -RemoveSqlServer for a full nuke) to apply." }
if ($Reboot -and $Execute -and -not $RemoveSqlServer) { Act "reboot now" { Stop-Transcript | Out-Null; Restart-Computer -Force } }

# ---------------------------------------------------------------- 9.5 diagnostic bundle (Desktop)
# Same idea as the installer: a Desktop .zip (the cleaner transcript(s) + a state snapshot of
# what remains) to email back. Kept automatically if any action failed or -CollectLogs is set;
# otherwise offered via a Yes/No dialog. Skipped on a non-interactive pass (SYSTEM reboot-resume
# / SSH) so it never litters the SYSTEM profile's Desktop.
try { Stop-Transcript | Out-Null } catch { $null = $_ }
$script:zipPath = $null
if ([Environment]::UserInteractive) {
    $keep = ($script:errCount -gt 0) -or $CollectLogs
    if (-not $keep) {
        if ((Confirm-Gui "Cleaner finished.`n`nSave a diagnostic log bundle to the Desktop?" "EVS Cleaner") -eq $true) { $keep = $true }
    }
    if ($keep) {
        try {
            $dstamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $dbDir  = Join-Path ([Environment]::GetFolderPath('Desktop')) "EVS-Cleaner-Logs-$env:COMPUTERNAME-$dstamp"
            New-Item -ItemType Directory -Force -Path $dbDir | Out-Null
            Get-ChildItem $BackupRoot -Filter 'cleaner-*.log' -ErrorAction SilentlyContinue | Copy-Item -Destination $dbDir -ErrorAction SilentlyContinue
            @(
                "Script ver : $ScriptVersion"
                "Computer   : $env:COMPUTERNAME"
                "When       : $(Get-Date -Format s)"
                "Execute    : $Execute   RemoveSqlServer: $RemoveSqlServer   PurgeDatabases: $PurgeDatabases"
                "Action errs: $script:errCount"
            ) | Set-Content (Join-Path $dbDir 'summary.txt')
            Get-EvsServices | Select-Object State,Name,PathName | Format-List | Out-String | Set-Content (Join-Path $dbDir 'evs-services-remaining.txt')
            Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $SqlSvcRx } |
                Select-Object State,Name | Format-List | Out-String | Set-Content (Join-Path $dbDir 'sql-services-remaining.txt')
            Get-ItemProperty $UninstKeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match ($EvsArpRx + '|' + $SqlArpRx) } |
                Select-Object DisplayName,UninstallString | Format-List | Out-String | Set-Content (Join-Path $dbDir 'arp-remaining.txt')
            $dzip = "$dbDir.zip"
            if (Test-Path $dzip) { Remove-Item $dzip -Force }
            Compress-Archive -Path (Join-Path $dbDir '*') -DestinationPath $dzip -Force
            Remove-Item $dbDir -Recurse -Force -ErrorAction SilentlyContinue
            $script:zipPath = $dzip
            # tell the operator plainly what happened and exactly where the file is
            Step "SUMMARY - please read"
            if ($script:errCount -gt 0) { Warn "Cleaner finished with $script:errCount action error(s) - review the log." }
            else                        { Good "Cleaner finished with no action errors." }
            Good "A diagnostic log bundle was saved to your Desktop:"
            Good "    $dzip"
            Info "The full transcript also remains in: $BackupRoot"
            Info "WHAT TO DO NEXT: email that .zip file back for triage."
            Show-GuiNote ("EVS / SQL unit cleaner" + "`n`n" +
                "Action errors: $script:errCount" + "`n`n" +
                "A diagnostic log bundle was saved to your Desktop:`n$dzip`n`n" +
                "The full transcript also remains in:`n$BackupRoot`n`n" +
                "Please EMAIL that .zip file back for triage.") "EVS Cleaner - diagnostic logs saved to your Desktop"
        } catch { Warn "could not build diagnostic zip: $($_.Exception.Message)" }
    } else {
        Good "Cleaner finished. No diagnostic bundle kept (declined); the full transcript remains in $BackupRoot."
    }
}

if ($script:Gui -and $script:form) {
    $cfinal = if ($script:zipPath) { "Done - diagnostic .zip on your Desktop (see log); email it back, then close." }
              else                 { "Done - transcript in $BackupRoot.  Close this window." }
    Update-GuiStatus $cfinal 100
    try { $script:pb.Value = 100; $script:btn.Enabled = $true } catch { $null = $_ }
    while ($script:form -and $script:form.Visible) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 120 }
}
