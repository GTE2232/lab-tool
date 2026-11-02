# UIT-63 - FDIV Edition | PC Fallback Optimizer made by shivansh 
# =========================================================== 
# Target: Windows 10, low-RAM education lab machines (i5 2nd gen / 4GB DDR3 1600MHz / mechanical HDD) 
#>

$ToolName = "UIT-63 - FDIV Edition"
$Author   = "shivansh"
$ScriptUrl = "PUT_YOUR_RAW_SCRIPT_URL_HERE"

# ---- Self-elevate if not running as Administrator ----
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
    try {
        if ($PSCommandPath) {
            Start-Process powershell.exe -ArgumentList @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") -Verb RunAs
        } elseif ($ScriptUrl -and $ScriptUrl -notmatch 'PUT_YOUR_RAW_SCRIPT_URL_HERE') {
            $cmd = "irm '$ScriptUrl' | iex"
            Start-Process powershell.exe -ArgumentList @('-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) -Verb RunAs
        } else {
            Write-Host "Could not determine how to relaunch elevated." -ForegroundColor Red
            Read-Host "Press Enter to close"; exit
        }
    } catch { Write-Host "Elevation cancelled or failed." -ForegroundColor Red; Read-Host "Press Enter to close" }
    exit
}

# ---- Single-instance guard ----
$Global:Uit63Mutex = $null
try {
    $Global:Uit63Mutex = New-Object System.Threading.Mutex($false, 'Global\UIT63-FDIV-SingleInstance')
    $acquired = $false
    try { $acquired = $Global:Uit63Mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) {
        Write-Host "UIT-63 FDIV is already running in another window." -ForegroundColor Yellow
        Start-Sleep -Seconds 2; exit
    }
} catch {}

$ErrorActionPreference = 'SilentlyContinue'
$LogFile = "$env:USERPROFILE\Desktop\UIT63-EduBoost-Log.txt"
Start-Transcript -Path $LogFile -Append | Out-Null

$PrevLog = "$env:USERPROFILE\Desktop\prev.txt"
function Write-PrevLog($line) {
    Add-Content -Path $PrevLog -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $line"
}
$SnapshotFile = "$env:USERPROFILE\Desktop\UIT63-Snapshots.txt"

# ===========================================================
# CORE HELPERS
# ===========================================================
function Set-Reg($Path, $Name, $Value, $Type = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
function Get-RegValue($Path, $Name) {
    if (Test-Path $Path) {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $item) { return $item.$Name }
    }
    return $null
}
function Remove-Reg($Path, $Name) {
    if (Test-Path $Path) { Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue }
}
function Set-SvcState($Name, [bool]$Disable) {
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $s) { return }
    try {
        if ($Disable) {
            if ($s.Status -ne 'Stopped') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
            Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
        } else {
            Set-Service -Name $Name -StartupType Manual -ErrorAction Stop
            Start-Service -Name $Name -ErrorAction SilentlyContinue
        }
    } catch {
        $mode = if ($Disable) { 'disabled' } else { 'demand' }
        $scOut = sc.exe config $Name start= $mode 2>&1
        if ($scOut -notmatch 'SUCCESS') {
            Write-Host "  Could not change service '$Name': $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
}
function Get-SvcDisabled($Name) {
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $s) { return $true }
    return ($s.StartType -eq 'Disabled')
}
function Get-TaskDisabled($TaskPath, $TaskName) {
    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) { return ($t.State -eq 'Disabled') }
    return $true
}
function Set-TaskState($TaskPath, $TaskName, [bool]$Disable) {
    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return }
    try {
        if ($Disable) { Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null }
        else { Enable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null }
    } catch { Write-Host "  Could not change task '$TaskName': $($_.Exception.Message)" -ForegroundColor DarkYellow }
}
function New-HiddenTaskAction($VbsPath, $InnerCommandLine) {
    $dir = Split-Path $VbsPath -Parent
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $escaped = $InnerCommandLine -replace '"', '""'
    $vbs = "Set objShell = CreateObject(`"WScript.Shell`")`r`nobjShell.Run `"$escaped`", 0, False"
    Set-Content -Path $VbsPath -Value $vbs -Encoding ASCII
    return (New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$VbsPath`"")
}
function Start-Hidden($InnerCommandLine) {
    $vbsPath = "$env:TEMP\uit63-hidden-launch-$([guid]::NewGuid().ToString('N')).vbs"
    $escaped = $InnerCommandLine -replace '"', '""'
    $vbs = "Set objShell = CreateObject(`"WScript.Shell`")`r`nobjShell.Run `"$escaped`", 0, False"
    Set-Content -Path $vbsPath -Value $vbs -Encoding ASCII
    $wscriptProc = Start-Process wscript.exe -ArgumentList "`"$vbsPath`"" -WindowStyle Hidden -PassThru
    if ($wscriptProc) { $wscriptProc | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    Remove-Item $vbsPath -Force -ErrorAction SilentlyContinue
}

# ---- Global Timer Resolution ----
$TimerResDir = "$env:ProgramData\UIT63"
$TimerResScript = "$TimerResDir\TimerResEnforcer.ps1"
$TimerResPidFile = "$TimerResDir\enforcer.pid"
$TimerResTask = "UIT63-TimerResolutionEnforcer"

function Install-TimerResolutionEnforcer {
    if (-not (Test-Path $TimerResDir)) { New-Item -Path $TimerResDir -ItemType Directory -Force | Out-Null }
    $memberDef = @'
[DllImport("winmm.dll")]
public static extern uint timeBeginPeriod(uint uMilliseconds);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetProcessInformation(IntPtr hProcess, int ProcessInformationClass, uint[] ProcessInformation, int ProcessInformationSize);
'@
    $dllPath = "$TimerResDir\UIT63TimerHelper2.dll"
    if (-not (Test-Path $dllPath)) {
        try { Add-Type -Namespace UIT63 -Name Winmm -MemberDefinition $memberDef -OutputAssembly $dllPath -OutputType Library -ErrorAction Stop }
        catch { Write-Host "  Could not pre-build the timer helper - it will compile on launch instead." -ForegroundColor DarkYellow }
    }
    $body = @'
$__mtx = New-Object System.Threading.Mutex($false, 'Global\UIT63-TimerResEnforcer')
$__got = $false
try { $__got = $__mtx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $__got = $true }
if (-not $__got) { exit }
$PID | Out-File -FilePath "__PIDFILE__" -Encoding ascii -Force
if (Test-Path "__DLLPATH__") { Add-Type -Path "__DLLPATH__" }
else { Add-Type -Namespace UIT63 -Name Winmm -MemberDefinition @"
__MEMBERDEF__
"@ }
try { [UIT63.Winmm]::SetProcessInformation((Get-Process -Id $PID).Handle, 4, [uint32[]](1,4,0), 12) | Out-Null } catch {}
[UIT63.Winmm]::timeBeginPeriod(8) | Out-Null
while ($true) { Start-Sleep -Seconds 3600 }
'@
    $body = $body -replace '__PIDFILE__', $TimerResPidFile
    $body = $body -replace '__DLLPATH__', $dllPath
    $body = $body -replace '__MEMBERDEF__', $memberDef
    Set-Content -Path $TimerResScript -Value $body -Encoding UTF8

    $old = Get-TimerEnforcerProcess
    if ($old) { Stop-Process -Id $old.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $TimerResPidFile -Force -ErrorAction SilentlyContinue

    Start-Hidden "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TimerResScript`""
    $confirmed = $false
    for ($i = 0; $i -lt 10; $i++) { Start-Sleep -Seconds 1; if (Test-Path $TimerResPidFile) { $confirmed = $true; break } }
    if (-not $confirmed) { Write-Host "  Could not confirm the timer resolution process started after 10 seconds." -ForegroundColor DarkYellow }

    try {
        Unregister-ScheduledTask -TaskName $TimerResTask -Confirm:$false -ErrorAction SilentlyContinue
        $vbsPath = "$TimerResDir\TimerResLauncher.vbs"
        $action = New-HiddenTaskAction $vbsPath "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TimerResScript`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        Register-ScheduledTask -TaskName $TimerResTask -Action $action -Trigger $trigger `
            -Description "UIT-63 FDIV: holds an 8ms Windows 7-style global timer resolution" -Force | Out-Null
    } catch { Write-Host "  Could not register timer resolution startup task: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}
function Remove-TimerResolutionEnforcer {
    $old = Get-TimerEnforcerProcess
    if ($old) { Stop-Process -Id $old.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $TimerResPidFile -Force -ErrorAction SilentlyContinue
    try { Unregister-ScheduledTask -TaskName $TimerResTask -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}
function Test-TimerResolutionEnforcerRunning { return [bool](Get-TimerEnforcerProcess) }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class SPI {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
}
"@ -ErrorAction SilentlyContinue
$SPIFLAGS = [uint32](0x01 -bor 0x02)
function Set-SPI($action, [bool]$onOff) {
    [SPI]::SystemParametersInfo($action, $(if ($onOff) { 1 } else { 0 }), [IntPtr]::Zero, $SPIFLAGS) | Out-Null
}
function Assert-FontSmoothingOn {
    try {
        Set-Reg "HKCU:\Control Panel\Desktop" "FontSmoothing" "2" String
        Set-Reg "HKCU:\Control Panel\Desktop" "FontSmoothingType" 2
        Set-SPI 0x004B $true
    } catch { Write-Host "  Warning: could not set font smoothing - $($_.Exception.Message)" -ForegroundColor DarkYellow }
}

# ---- Migration 1: search box visibility ----
function Invoke-SearchBoxMigration {
    if (-not $Global:IsWin11) { return }
    $markerDir = "$env:ProgramData\UIT63"; $marker = "$markerDir\searchbox-migrated.marker"
    if (Test-Path $marker) { return }
    try {
        $searchPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"
        if ((Get-RegValue $searchPath "SearchboxTaskbarMode") -eq 0) { Set-Reg $searchPath "SearchboxTaskbarMode" 2 }
    } catch {}
    try {
        if (-not (Test-Path $markerDir)) { New-Item -Path $markerDir -ItemType Directory -Force | Out-Null }
        Set-Content -Path $marker -Value "done" -Force
    } catch {}
}

# ---- Migration 2: telemetry policy + dependent services ----
# Old Disable-Tweak 14 left AllowTelemetry=3 in place, which keeps the
# "managed by your organization" banner and greyed-out Settings toggle.
# Old Disable-Tweak 2/64 also left DiagTrack and WerSvc Disabled, which
# prevents the toggle from working even when the policy is gone. This
# one-shot migration strips the leftover policy AND re-enables those
# services so the diagnostic data UI is fully functional.
function Invoke-TelemetryPolicyMigration {
    $markerDir = "$env:ProgramData\UIT63"; $marker = "$markerDir\telemetry-migrated.marker"
    if (Test-Path $marker) { return }
    try {
        $v = Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry"
        if ($v -eq 3) {
            Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry"
            Remove-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" "AllowTelemetry"
            Set-SvcState 'DiagTrack' $false
            Set-SvcState 'WerSvc' $false
            Remove-Reg "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "Disabled"
            Remove-Reg "HKCU:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "Disabled"
        }
    } catch {}
    try {
        if (-not (Test-Path $markerDir)) { New-Item -Path $markerDir -ItemType Directory -Force | Out-Null }
        Set-Content -Path $marker -Value "done" -Force
    } catch {}
}

function Register-FontSmoothingEnforcer {
    try {
        $taskName = "UIT63-FontSmoothingEnforcer"
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        $innerCmd = 'powershell.exe -NoProfile -WindowStyle Hidden -Command "Set-ItemProperty -Path ''HKCU:\Control Panel\Desktop'' -Name FontSmoothing -Value ''2''; Set-ItemProperty -Path ''HKCU:\Control Panel\Desktop'' -Name FontSmoothingType -Value 2 -Type DWord"'
        $vbsPath = "$env:ProgramData\UIT63\FontSmoothingLauncher.vbs"
        $action = New-HiddenTaskAction $vbsPath $innerCmd
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
            -Description "UIT-63 FDIV: keeps ClearType font smoothing on at every logon" -Force | Out-Null
    } catch { Write-Host "  Could not register font smoothing enforcer task: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}
function Ensure-Winget {
    $wingetExe = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    if (Test-Path $wingetExe) {
        try { $null = & $wingetExe --version 2>$null; if ($LASTEXITCODE -eq 0) { return $true } } catch {}
    }
    Write-Host "  Winget not found or not working - attempting to install it..." -ForegroundColor DarkGray
    try {
        $asset = (Invoke-WebRequest -Uri "https://api.github.com/repos/microsoft/winget-cli/releases/latest" -UseBasicParsing).Content | ConvertFrom-Json |
            Select-Object -ExpandProperty assets | Where-Object { $_.browser_download_url -match '\.msixbundle$' } |
            Select-Object -ExpandProperty browser_download_url -First 1
        if ($asset) {
            $out = "$env:TEMP\winget-setup.msixbundle"
            Invoke-WebRequest -Uri $asset -OutFile $out -UseBasicParsing
            Add-AppxPackage -Path $out -ErrorAction Stop; Remove-Item $out -ErrorAction SilentlyContinue
            Write-Host "  Winget installed." -ForegroundColor Green; return $true
        }
    } catch { Write-Host "  Could not install winget: $($_.Exception.Message)" -ForegroundColor DarkYellow }
    return $false
}

# ===========================================================
# WINDOWS GENERATION DETECTION
# ===========================================================
$Global:WinBuild = 0
try { $Global:WinBuild = [int](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).BuildNumber } catch {}
if (-not $Global:WinBuild) { $Global:WinBuild = [System.Environment]::OSVersion.Version.Build }
$Global:IsWin11 = ($Global:WinBuild -ge 22000)
$Global:OSLabel = if ($Global:IsWin11) { "Windows 11" } else { "Windows 10" }

$hvciPath = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
$HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$BundledApps = @(
    "Microsoft.GamingApp","Microsoft.XboxGamingOverlay","Microsoft.XboxGameOverlay","Microsoft.Xbox.TCUI",
    "Microsoft.XboxSpeechToTextOverlay","Microsoft.XboxIdentityProvider","Microsoft.XboxApp",
    "MicrosoftTeams","MSTeams","Microsoft.Teams","Clipchamp.Clipchamp",
    "MicrosoftCorporationII.MicrosoftFamily","Microsoft.BingNews","Microsoft.MicrosoftSolitaireCollection",
    "Microsoft.3DBuilder","Microsoft.AppConnector","Microsoft.BingFinance","Microsoft.BingSports",
    "Microsoft.BingTranslator","Microsoft.BingWeather","Microsoft.GetHelp","Microsoft.Getstarted",
    "Microsoft.Messaging","Microsoft.Microsoft3DViewer","Microsoft.MicrosoftOfficeHub",
    "Microsoft.NetworkSpeedTest","Microsoft.News","Microsoft.Office.Lens","Microsoft.Office.OneNote",
    "Microsoft.Office.Sway","Microsoft.Office.Todo.List","Microsoft.OneConnect","Microsoft.People",
    "Microsoft.Paint3D","Microsoft.SkypeApp","Microsoft.StorePurchaseApp",
    "Microsoft.Todos","Microsoft.Wallet","Microsoft.Whiteboard","Microsoft.WindowsAlarms",
    "microsoft.windowscommunicationsapps","Microsoft.WindowsFeedbackHub","Microsoft.WindowsMaps",
    "Microsoft.WindowsSoundRecorder","Microsoft.ZuneMusic","Microsoft.ZuneVideo","Microsoft.YourPhone",
    "Microsoft.Copilot","Microsoft.MicrosoftStickyNotes","Microsoft.MixedReality.Portal","Microsoft.549981C3F5F10"
)
$BundledAppsWin11 = @("MicrosoftWindows.Client.WebExperience","Microsoft.Windows.DevHome","Microsoft.PowerAutomateDesktop","Microsoft.BingSearch")
$BundledAppsWin10 = @("Microsoft.MSPaint")
if ($Global:IsWin11) { $BundledApps = $BundledApps + $BundledAppsWin11 } else { $BundledApps = $BundledApps + $BundledAppsWin10 }
$XboxServices = @('XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc')

$CdmPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
$CdmValues = @(
    "ContentDeliveryAllowed","OemPreInstalledAppsEnabled","PreInstalledAppsEnabled","PreInstalledAppsEverEnabled",
    "SilentInstalledAppsEnabled","SystemPaneSuggestionsEnabled","SoftLandingEnabled",
    "RotatingLockScreenEnabled","RotatingLockScreenOverlayEnabled",
    "SubscribedContent-310093Enabled","SubscribedContent-338387Enabled","SubscribedContent-338388Enabled",
    "SubscribedContent-338389Enabled","SubscribedContent-338393Enabled","SubscribedContent-353694Enabled",
    "SubscribedContent-353696Enabled","SubscribedContent-353698Enabled"
)
$TelemetryTasks = @(
    @("\Microsoft\Windows\Customer Experience Improvement Program\", "Consolidator"),
    @("\Microsoft\Windows\Customer Experience Improvement Program\", "UsbCeip"),
    @("\Microsoft\Windows\Customer Experience Improvement Program\", "KernelCeipTask"),
    @("\Microsoft\Windows\Application Experience\", "ProgramDataUpdater"),
    @("\Microsoft\Windows\Feedback\Siuf\", "DmClient"),
    @("\Microsoft\Windows\Feedback\Siuf\", "DmClientOnScenarioDownload"),
    @("\Microsoft\Windows\DiskDiagnostic\", "Microsoft-Windows-DiskDiagnosticDataCollector")
)
$CtxMenuRoot = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}"
$CtxMenuKey = "$CtxMenuRoot\InprocServer32"

function Set-HighPerformancePlan {
    powercfg /setactive $HighPerfGuid 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    powercfg -duplicatescheme $HighPerfGuid $HighPerfGuid 2>$null | Out-Null
    powercfg /setactive $HighPerfGuid 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    powercfg -duplicatescheme $HighPerfGuid 2>$null | Out-Null
    $m = [regex]::Match((powercfg /list | Out-String), '([0-9a-fA-F-]{36})\s+\((High performance|Ultimate Performance)\)')
    if ($m.Success) { powercfg /setactive $m.Groups[1].Value 2>$null }
}
function Test-OneDriveInstalled {
    $exes = @("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe", "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe", "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe")
    foreach ($e in $exes) { if ($e -and (Test-Path $e)) { return $true } }
    if (Get-OneDriveUninstallString) { return $true }
    if (Get-Process OneDrive -ErrorAction SilentlyContinue) { return $true }
    return $false
}

# ---- PCIe ASPM helpers ----
$PcieSubGuid = '501a4d13-42af-4429-9fd1-a8218c268e20'
$PcieAspmGuid = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
function Get-ActivePowerSchemeGuid {
    $out = powercfg /getactivescheme 2>$null | Out-String
    $m = [regex]::Match($out, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
    if ($m.Success) { return $m.Groups[1].Value.ToLower() }
    return $null
}
function Test-PcieAspmOff {
    try {
        $guid = Get-ActivePowerSchemeGuid
        if (-not $guid) { return $false }
        $path = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$guid\$PcieSubGuid\$PcieAspmGuid"
        return ((Get-RegValue $path "ACSettingIndex") -eq 0)
    } catch { return $false }
}

# ===========================================================
# TWEAK CATALOG
# ===========================================================
$TweakInfo = @{
    1  = @{ Name = "SysMain (Superfetch) service";               Tier = "Base" }
    2  = @{ Name = "DiagTrack (Telemetry) service";               Tier = "Base" }
    3  = @{ Name = "Xbox services (Auth/GameSave/Net/Gip)";       Tier = "Base" }
    4  = @{ Name = "Delivery Optimization - HTTP only (no P2P)";  Tier = "Base" }
    5  = @{ Name = "Remote Registry service";                     Tier = "Base" }
    6  = @{ Name = "Downloaded Maps (MapsBroker)";                Tier = "Base" }
    7  = @{ Name = "Fax service";                                  Tier = "Base" }
    8  = @{ Name = "Retail Demo service";                         Tier = "Base" }
    9  = @{ Name = "WAP Push service (dmwappushservice)";         Tier = "Base" }
    10 = @{ Name = "Bing in Windows Search - off";                Tier = "Base" }
    11 = @{ Name = "Feedback frequency - Never";                  Tier = "Base" }
    12 = @{ Name = "Activity History - off";                      Tier = "Base" }
    13 = @{ Name = "Activity Upload - off";                       Tier = "Base" }
    14 = @{ Name = $(if ($Global:IsWin11) { "Diagnostic data - Required (minimum)" } else { "Diagnostic data - Basic" }); Tier = "Base" }
    15 = @{ Name = "Advertising ID - off";                        Tier = "Base" }
    16 = @{ Name = "Tailored experiences - off";                  Tier = "Base" }
    17 = @{ Name = "Windows Copilot - off";                       Tier = "Base" }
    18 = @{ Name = "Cortana - off"; Tier = "Base"; OS = "10" }
    19 = @{ Name = "Storage Sense - off";                          Tier = "Base" }
    20 = @{ Name = "Memory Integrity / Core Isolation - off";     Tier = "Base" }
    21 = @{ Name = "Background apps - off";                       Tier = "Base" }
    22 = @{ Name = "Power plan - High Performance";               Tier = "Base" }
    23 = @{ Name = "Custom visual effects (fonts/anim/shadow kept)"; Tier = "Base" }
    24 = @{ Name = "Transparency effects - off";                  Tier = "Base" }
    25 = @{ Name = "Explorer thumbnails - off (icons only)";      Tier = "Optional" }
    26 = @{ Name = "Hibernation - off";                            Tier = "Base" }
    27 = @{ Name = "Bundled apps removed";                         Tier = "Base" }
    28 = @{ Name = "Program Compatibility Assistant - off";       Tier = "RAM4GB" }
    29 = @{ Name = "SvcHost grouping threshold raised";            Tier = "RAM4GB" }
    30 = @{ Name = "Fixed pagefile (4096-8192MB)";                Tier = "RAM4GB" }
    31 = @{ Name = "Disable NTFS last-access timestamp updates"; Tier = "Base" }
    32 = @{ Name = "Enable MSI interrupts for AHCI controller";  Tier = "Base" }
    33 = @{ Name = "MFT zone reservation (many small files)";    Tier = "Base" }
    34 = @{ Name = "NTFS memory usage - maximum";                Tier = "Base" }
    35 = @{ Name = "Disable 8.3 short filenames";                Tier = "Base" }
    36 = @{ Name = "Edge preloading / startup boost - off";      Tier = "Base" }
    37 = @{ Name = "Shared experiences - off";                   Tier = "Base" }
    38 = @{ Name = "Automatic Maps updates - off";                Tier = "Base" }
    39 = @{ Name = "Location tracking - off (system-wide)";       Tier = "Base" }
    40 = @{ Name = "Mobile broadband metadata parser task - off"; Tier = "Base" }
    41 = @{ Name = "Speech model background download task - off"; Tier = "Base" }
    42 = @{ Name = "Global Timer Resolution restored to 8ms";    Tier = "Base" }
    43 = @{ Name = "Compatibility Appraiser telemetry task - off"; Tier = "Base" }
    44 = @{ Name = "OneDrive uninstalled"; Tier = "Base" }
    45 = @{ Name = "Cloud content search - off"; Tier = "Base" }
    46 = @{ Name = "SafeSearch - off"; Tier = "Base" }
    47 = @{ Name = "Search history - off"; Tier = "Base" }
    48 = @{ Name = "Inking & typing personalization - off"; Tier = "Base" }
    49 = @{ Name = "Locally relevant content via language list - off"; Tier = "Base" }
    50 = @{ Name = "Game Bar - off"; Tier = "Base" }
    51 = @{ Name = "Copilot app - uninstalled"; Tier = "Base" }
    52 = @{ Name = "Cortana leftover shortcuts - cleaned up"; Tier = "Base"; OS = "10" }
    53 = @{ Name = "Autocorrect misspelled words - off"; Tier = "Base" }
    54 = @{ Name = "Highlight misspelled words - off"; Tier = "Base" }
    55 = @{ Name = "Show text suggestions - off"; Tier = "Base" }
    56 = @{ Name = "Multitasking (Snap) - off"; Tier = "Base" }
    57 = @{ Name = "Sponsored suggestions, tips and silent app installs - off"; Tier = "Base" }
    58 = @{ Name = "Snappier menus and faster app-close at shutdown"; Tier = "Base" }
    59 = @{ Name = "Taskbar animations and Aero Peek - off"; Tier = "Base" }
    60 = @{ Name = "Game Mode - off"; Tier = "Base" }
    61 = @{ Name = "Edge background mode, sidebar and shopping - off"; Tier = "Base" }
    62 = @{ Name = "Explorer opens to This PC; recent/frequent items off"; Tier = "Base" }
    63 = @{ Name = "CEIP, feedback and disk-diagnostic telemetry tasks - off"; Tier = "Base" }
    64 = @{ Name = "Windows Error Reporting - off"; Tier = "Base" }
    65 = @{ Name = "Settings sync - off"; Tier = "Base" }
    66 = @{ Name = "News and Interests taskbar feed - off"; Tier = "Base"; OS = "10" }
    67 = @{ Name = "Taskbar clutter off (Cortana/People/Meet Now/Task View)"; Tier = "Base"; OS = "10" }
    68 = @{ Name = "Windows Ink Workspace - off"; Tier = "Base"; OS = "10" }
    69 = @{ Name = "Widgets - off"; Tier = "Base"; OS = "11" }
    70 = @{ Name = "Chat (Teams) taskbar icon - off"; Tier = "Base"; OS = "11" }
    71 = @{ Name = "Taskbar Task View button - hidden"; Tier = "Base"; OS = "11" }
    72 = @{ Name = "Classic right-click context menu restored"; Tier = "Optional"; OS = "11" }
    73 = @{ Name = "Start menu recommendations and tracking - off"; Tier = "Base"; OS = "11" }
    74 = @{ Name = "Recall / AI snapshot policy - off"; Tier = "Base"; OS = "11" }
    75 = @{ Name = "Windows Search Indexer (WSearch) - off"; Tier = "Optional" }
    76 = @{ Name = "Defender scheduled scan task - off"; Tier = "Optional" }
    77 = @{ Name = "PCIe ASPM - off (link power saving)"; Tier = "Base" }
    78 = @{ Name = "CPU scheduling - foreground priority boost"; Tier = "Base" }
}
foreach ($k in @($TweakInfo.Keys)) {
    $req = $TweakInfo[$k].OS
    if ($req -and ((($req -eq "11") -and (-not $Global:IsWin11)) -or (($req -eq "10") -and $Global:IsWin11))) {
        $TweakInfo.Remove($k)
    }
}

# ===========================================================
# STATUS CHECK
# ===========================================================
function Test-TweakApplied($Id) {
    switch ($Id) {
        1  { return Get-SvcDisabled 'SysMain' }
        2  { return Get-SvcDisabled 'DiagTrack' }
        3  { $r = $true; foreach ($s in $XboxServices) { if (-not (Get-SvcDisabled $s)) { $r = $false } }; return $r }
        4  { return (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode") -eq 0 }
        5  { return Get-SvcDisabled 'RemoteRegistry' }
        6  { return Get-SvcDisabled 'MapsBroker' }
        7  { return Get-SvcDisabled 'Fax' }
        8  { return Get-SvcDisabled 'RetailDemo' }
        9  { return Get-SvcDisabled 'dmwappushservice' }
        10 { return (Get-RegValue "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions") -eq 1 }
        11 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Siuf\Rules" "NumberOfSIUFInPeriod") -eq 0 }
        12 { return (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed") -eq 0 }
        13 { return (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "UploadUserActivities") -eq 0 }
        14 { return (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry") -eq 1 }
        15 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled") -eq 0 }
        16 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled") -eq 0 }
        17 { return (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot") -eq 1 }
        18 { return (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCortana") -eq 0 }
        19 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" "01") -eq 0 }
        20 { return (Get-RegValue $hvciPath "Enabled") -eq 0 }
        21 { return (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" "LetAppsRunInBackground") -eq 2 }
        22 { $a = powercfg /getactivescheme | Out-String; return (($a -match $HighPerfGuid) -or ($a -match 'High performance|Ultimate Performance')) }
        23 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting") -eq 3 }
        24 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "EnableTransparency") -eq 0 }
        25 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "IconsOnly") -eq 1 }
        26 { return (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\Power" "HibernateEnabled") -eq 0 }
        27 { $set = Get-InstalledAppSet; foreach ($a in $BundledApps) { if ($set.ContainsKey($a)) { return $false } }; return $true }
        28 { return Get-SvcDisabled 'PcaSvc' }
        29 { return (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control" "SvcHostSplitThresholdInKB") -eq 0x0F000000 }
        30 { $cs = Get-CimInstance Win32_ComputerSystem; return (-not $cs.AutomaticManagedPagefile) }
        31 { return ((fsutil behavior query disablelastaccess 2>$null) -match '=\s*1\b') }
        32 { return (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\storahci\Parameters" "EnableMSI") -eq 1 }
        33 { return (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "NtfsMftZoneReservation") -eq 2 }
        34 { return (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "NtfsMemoryUsage") -eq 2 }
        35 { return ((fsutil behavior query disable8dot3 2>$null) -match 'is:\s*1\b') }
        36 {
            $p = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
            return (Get-RegValue $p "AllowPrelaunch") -eq 0 -and (Get-RegValue $p "AllowTabPreloading") -eq 0 -and (Get-RegValue $p "StartupBoostEnabled") -eq 0
        }
        37 {
            $regOk = (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableCdp") -eq 0
            return $regOk -and (Get-TaskDisabled "\Microsoft\Windows\CloudExperienceHost\" "CreateObjectTask") -and (Get-TaskDisabled "\Microsoft\Windows\Shell\" "CreateObjectTask")
        }
        38 { return (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps" "AutoDownloadAndUpdateMapData") -eq 0 }
        39 { return (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableLocation") -eq 1 }
        40 { return Get-TaskDisabled "\Microsoft\Windows\Mobile Broadband Accounts\" "MNO Metadata Parser Task" }
        41 { return Get-TaskDisabled "\Microsoft\Windows\Speech\" "SpeechModelDownloadTask" }
        42 {
            $regOk = (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel" "GlobalTimerResolutionRequests") -eq 1
            return $regOk -and (Test-TimerResolutionEnforcerRunning)
        }
        43 { return Get-TaskDisabled "\Microsoft\Windows\Application Experience\" "Microsoft Compatibility Appraiser" }
        44 { return (-not (Test-OneDriveInstalled)) }
        45 {
            return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsMSACloudSearchEnabled") -eq 0 -and
                   (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsAADCloudSearchEnabled") -eq 0
        }
        46 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "SafeSearchMode") -eq 0 }
        47 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsDeviceSearchHistoryEnabled") -eq 0 }
        48 {
            return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\InputPersonalization" "RestrictImplicitInkCollection") -eq 1 -and
                   (Get-RegValue "HKCU:\SOFTWARE\Microsoft\InputPersonalization" "RestrictImplicitTextCollection") -eq 1
        }
        49 { return (Get-RegValue "HKCU:\Control Panel\International\User Profile" "HttpAcceptLanguageOptOut") -eq 1 }
        50 {
            return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled") -eq 0 -and
                   (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR") -eq 0
        }
        51 {
            $names = @("Microsoft.Copilot", "Microsoft.Windows.Copilot", "MicrosoftWindows.Client.CoPilot")
            $set = Get-InstalledAppSet
            foreach ($n in $names) { if ($set.ContainsKey($n)) { return $false } }
            return $true
        }
        52 { return -not (Test-Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Cortana.lnk") -and -not (Test-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Cortana.lnk") }
        53 {
            return ((Get-RegValue "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableAutocorrection") -eq 0) -or
                   ((Get-RegValue "HKCU:\SOFTWARE\Microsoft\Input\Settings\Hardware Keyboard" "EnableAutocorrection") -eq 0)
        }
        54 {
            return ((Get-RegValue "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableSpellchecking") -eq 0) -or
                   ((Get-RegValue "HKCU:\SOFTWARE\Microsoft\Input\Settings\Hardware Keyboard" "EnableSpellchecking") -eq 0)
        }
        55 {
            return ((Get-RegValue "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableTextPrediction") -eq 0) -or
                   ((Get-RegValue "HKCU:\SOFTWARE\Microsoft\Input\Settings\Hardware Keyboard" "EnableTextPrediction") -eq 0)
        }
        56 { return (Get-RegValue "HKCU:\Control Panel\Desktop" "WindowArrangementActive") -eq "0" }
        57 {
            return ((Get-RegValue $CdmPath "SilentInstalledAppsEnabled") -eq 0) -and
                   ((Get-RegValue $CdmPath "SystemPaneSuggestionsEnabled") -eq 0) -and
                   ((Get-RegValue $CdmPath "SubscribedContent-338388Enabled") -eq 0)
        }
        58 {
            return ((Get-RegValue "HKCU:\Control Panel\Desktop" "MenuShowDelay") -eq "100") -and
                   ((Get-RegValue "HKCU:\Control Panel\Desktop" "WaitToKillAppTimeout") -eq "3000")
        }
        59 {
            return ((Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarAnimations") -eq 0) -and
                   ((Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\DWM" "EnableAeroPeek") -eq 0)
        }
        60 {
            return ((Get-RegValue "HKCU:\SOFTWARE\Microsoft\GameBar" "AutoGameModeEnabled") -eq 0) -and
                   ((Get-RegValue "HKCU:\SOFTWARE\Microsoft\GameBar" "AllowAutoGameMode") -eq 0)
        }
        61 {
            $ep = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
            return ((Get-RegValue $ep "BackgroundModeEnabled") -eq 0) -and
                   ((Get-RegValue $ep "HubsSidebarEnabled") -eq 0) -and
                   ((Get-RegValue $ep "EdgeShoppingAssistantEnabled") -eq 0)
        }
        62 {
            $adv = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            $exp = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"
            return ((Get-RegValue $adv "LaunchTo") -eq 1) -and
                   ((Get-RegValue $exp "ShowRecent") -eq 0) -and
                   ((Get-RegValue $exp "ShowFrequent") -eq 0)
        }
        63 {
            foreach ($t in $TelemetryTasks) { if (-not (Get-TaskDisabled $t[0] $t[1])) { return $false } }
            return $true
        }
        64 { return (Get-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "Disabled") -eq 1 }
        65 { return (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" "DisableSettingSync") -eq 2 }
        66 {
            $polOff = (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" "EnableFeeds") -eq 0
            $modeOff = (Get-RegValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds" "ShellFeedsTaskbarViewMode") -eq 2
            return ($polOff -or $modeOff)
        }
        67 {
            $adv = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            return ((Get-RegValue $adv "ShowTaskViewButton") -eq 0) -and ((Get-RegValue $adv "ShowCortanaButton") -eq 0)
        }
        68 { return (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace" "AllowWindowsInkWorkspace") -eq 0 }
        69 {
            $polOff = (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests") -eq 0
            $btnOff = (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa") -eq 0
            return ($polOff -or $btnOff)
        }
        70 {
            $polOff = (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat" "ChatIcon") -eq 3
            $btnOff = (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarMn") -eq 0
            return ($polOff -or $btnOff)
        }
        71 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowTaskViewButton") -eq 0 }
        72 { return (Test-Path -LiteralPath $CtxMenuKey) }
        73 {
            $adv = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            return ((Get-RegValue $adv "Start_TrackDocs") -eq 0) -and ((Get-RegValue $adv "Start_IrisRecommendations") -eq 0)
        }
        74 { return (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis") -eq 1 }
        75 { return Get-SvcDisabled 'WSearch' }
        76 { return Get-TaskDisabled "\Microsoft\Windows\Windows Defender\" "Windows Defender Scheduled Scan" }
        77 { return Test-PcieAspmOff }
        78 { return (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation") -eq 26 }
    }
    return $false
}

# ===========================================================
# APPLY
# ===========================================================
function Enable-Tweak($Id) {
    $Global:AppxCache = $null
    switch ($Id) {
        1  { Set-SvcState 'SysMain' $true }
        2  { Set-SvcState 'DiagTrack' $true }
        3  { foreach ($s in $XboxServices) { Set-SvcState $s $true } }
        4  { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode" 0 }
        5  { Set-SvcState 'RemoteRegistry' $true }
        6  { Set-SvcState 'MapsBroker' $true }
        7  { Set-SvcState 'Fax' $true }
        8  { Set-SvcState 'RetailDemo' $true }
        9  { Set-SvcState 'dmwappushservice' $true }
        10 { Set-Reg "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" 1 }
        11 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Siuf\Rules" "NumberOfSIUFInPeriod" 0 }
        12 { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" 0 }
        13 { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "UploadUserActivities" 0 }
        14 { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 1 }
        15 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 0 }
        16 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled" 0 }
        17 { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1 }
        18 {
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCortana" 0
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "DisableWebSearch" 1
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchUseWeb" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "BingSearchEnabled" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "CortanaConsent" 0
        }
        19 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" "01" 0 }
        20 { Set-Reg $hvciPath "Enabled" 0 }
        21 { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" "LetAppsRunInBackground" 2 }
        22 { Set-HighPerformancePlan }
        23 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" 3
            Set-Reg "HKCU:\Control Panel\Desktop" "FontSmoothing" "2" String
            Set-Reg "HKCU:\Control Panel\Desktop" "FontSmoothingType" 2
            Set-SPI 0x004B $true; Set-SPI 0x1043 $true; Set-SPI 0x1025 $true
            Set-Reg "HKCU:\Control Panel\Desktop\WindowMetrics" "MinAnimate" "0" String
            Set-SPI 0x1003 $false; Set-SPI 0x1013 $false; Set-SPI 0x1015 $false
            Set-SPI 0x1005 $false; Set-SPI 0x1007 $false; Set-SPI 0x101B $false
        }
        24 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "EnableTransparency" 0 }
        25 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "IconsOnly" 1 }
        26 {
            powercfg /hibernate off
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "HiberbootEnabled" 0
        }
        27 {
            foreach ($app in $BundledApps) {
                try { $pkg = Get-AppxPackage -Name $app -ErrorAction SilentlyContinue; if ($pkg) { $pkg | Remove-AppxPackage -ErrorAction SilentlyContinue } } catch {}
                try {
                    $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $app }
                    if ($prov) { $prov | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null }
                } catch {}
                if (Get-AppxPackage -Name $app -ErrorAction SilentlyContinue) {
                    try {
                        $pkgAll = Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue
                        if ($pkgAll) { $pkgAll | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue }
                    } catch {}
                }
                if (Get-AppxPackage -Name $app -ErrorAction SilentlyContinue) {
                    if ($null -eq $Global:WingetOk) { $Global:WingetOk = Ensure-Winget }
                    if ($Global:WingetOk) {
                        try { winget uninstall --id $app --silent --disable-interactivity --accept-source-agreements 2>$null 1>$null } catch {}
                    }
                    if (Get-AppxPackage -Name $app -ErrorAction SilentlyContinue) {
                        Write-Host "  Could not remove $app - skipping." -ForegroundColor DarkYellow
                    } else { Write-Host "  Removed $app via winget." -ForegroundColor Green }
                }
            }
        }
        28 { Set-SvcState 'PcaSvc' $true }
        29 { Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control" "SvcHostSplitThresholdInKB" 0x0F000000 }
        30 {
            $cs = Get-WmiObject Win32_ComputerSystem
            $cs.AutomaticManagedPagefile = $false
            $cs.Put() | Out-Null
            $pfs = @(Get-WmiObject Win32_PageFileSetting)
            if ($pfs.Count -gt 0) {
                foreach ($pf in $pfs) { $pf.InitialSize = 4096; $pf.MaximumSize = 8192; $pf.Put() | Out-Null }
            } else {
                Set-WmiInstance -Class Win32_PageFileSetting -Arguments @{ Name = "$env:SystemDrive\pagefile.sys"; InitialSize = 4096; MaximumSize = 8192 } | Out-Null
            }
        }
        31 { fsutil behavior set disablelastaccess 1 | Out-Null; Write-Host "  NTFS last-access updates disabled. Reboot required." -ForegroundColor Yellow }
        32 { Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\storahci\Parameters" "EnableMSI" 1; Write-Host "  MSI interrupts enabled. Reboot required." -ForegroundColor Yellow }
        33 { Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "NtfsMftZoneReservation" 2; Write-Host "  MFT zone reservation increased. Reboot required." -ForegroundColor Yellow }
        34 { Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "NtfsMemoryUsage" 2; Write-Host "  NTFS metadata cache set to maximum. Reboot required." -ForegroundColor Yellow }
        35 { fsutil behavior set disable8dot3 1 | Out-Null; Write-Host "  8.3 short filenames disabled. Reboot required." -ForegroundColor Yellow }
        36 {
            $p = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
            Set-Reg $p "AllowPrelaunch" 0; Set-Reg $p "AllowTabPreloading" 0; Set-Reg $p "StartupBoostEnabled" 0
        }
        37 {
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableCdp" 0
            Set-TaskState "\Microsoft\Windows\CloudExperienceHost\" "CreateObjectTask" $true
            Set-TaskState "\Microsoft\Windows\Shell\" "CreateObjectTask" $true
        }
        38 {
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps" "AutoDownloadAndUpdateMapData" 0
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps" "AllowUntriggeredNetworkTrafficOnSettingsPage" 0
        }
        39 { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableLocation" 1 }
        40 { Set-TaskState "\Microsoft\Windows\Mobile Broadband Accounts\" "MNO Metadata Parser Task" $true }
        41 { Set-TaskState "\Microsoft\Windows\Speech\" "SpeechModelDownloadTask" $true }
        42 {
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel" "GlobalTimerResolutionRequests" 1
            Install-TimerResolutionEnforcer
            Write-Host "  Global timer resolution restored to Windows 7-style behavior, held at 8ms." -ForegroundColor Green
        }
        43 { Set-TaskState "\Microsoft\Windows\Application Experience\" "Microsoft Compatibility Appraiser" $true }
        44 {
            Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            $triggered = $false
            $uninstallStr = Get-OneDriveUninstallString
            if ($uninstallStr) {
                try {
                    if ($uninstallStr -match '^"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $exeArgs = $Matches[2] }
                    else { $parts = $uninstallStr -split ' ', 2; $exe = $parts[0]; $exeArgs = if ($parts.Count -gt 1) { $parts[1] } else { "" } }
                    if ($exeArgs -notmatch '/uninstall') { $exeArgs = "$exeArgs /uninstall".Trim() }
                    Start-Process $exe -ArgumentList $exeArgs -ErrorAction Stop
                    $triggered = $true
                } catch { Write-Host "  Could not run the registered OneDrive uninstaller: $($_.Exception.Message)" -ForegroundColor DarkYellow }
            }
            if (-not $triggered) {
                foreach ($path in @("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe")) {
                    if (Test-Path $path) {
                        try { Start-Process $path -ArgumentList "/uninstall" -ErrorAction Stop; $triggered = $true }
                        catch { Write-Host "  OneDrive uninstall failed: $($_.Exception.Message)" -ForegroundColor DarkYellow }
                    }
                }
            }
            if ($triggered) {
                $setupProc = Get-Process OneDriveSetup -ErrorAction SilentlyContinue
                if ($setupProc) { $setupProc | Wait-Process -Timeout 120 -ErrorAction SilentlyContinue }
                Start-Sleep -Milliseconds 500
            } else { Write-Host "  Could not find any OneDrive uninstaller - may already be removed." -ForegroundColor DarkYellow }
            Get-Process OneDriveSetup,OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            foreach ($lp in @("$env:LOCALAPPDATA\Microsoft\OneDrive", "$env:ProgramData\Microsoft OneDrive", "$env:SystemDrive\OneDriveTemp")) {
                if (Test-Path $lp) {
                    try { Remove-Item -Path $lp -Recurse -Force -ErrorAction Stop }
                    catch { Write-Host "  Could not remove $lp - a restart may clear it." -ForegroundColor DarkYellow }
                }
            }
            Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "OneDrive*" } |
                ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" 1
        }
        45 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsMSACloudSearchEnabled" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsAADCloudSearchEnabled" 0
        }
        46 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "SafeSearchMode" 0 }
        47 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsDeviceSearchHistoryEnabled" 0 }
        48 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\InputPersonalization" "RestrictImplicitInkCollection" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\InputPersonalization" "RestrictImplicitTextCollection" 1
        }
        49 { Set-Reg "HKCU:\Control Panel\International\User Profile" "HttpAcceptLanguageOptOut" 1 }
        50 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" 0
            Set-Reg "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\GameBar" "UseNexusForGameBarEnabled" 0
        }
        51 {
            $names = @("Microsoft.Copilot", "Microsoft.Windows.Copilot", "MicrosoftWindows.Client.CoPilot")
            foreach ($n in $names) {
                try { $pkg = Get-AppxPackage -Name $n -ErrorAction SilentlyContinue; if ($pkg) { $pkg | Remove-AppxPackage -ErrorAction SilentlyContinue } } catch {}
                try {
                    $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $n }
                    if ($prov) { $prov | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null }
                } catch {}
                if (Get-AppxPackage -Name $n -ErrorAction SilentlyContinue) {
                    try {
                        $pkgAll = Get-AppxPackage -Name $n -AllUsers -ErrorAction SilentlyContinue
                        if ($pkgAll) { $pkgAll | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue }
                    } catch {}
                }
            }
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowCopilotButton" 0
            $stillThere = $false
            foreach ($n in $names) { if (Get-AppxPackage -Name $n -ErrorAction SilentlyContinue) { $stillThere = $true } }
            if ($stillThere) {
                Write-Host "  Copilot could not be fully removed via AppX cmdlets - the taskbar button and" -ForegroundColor DarkYellow
                Write-Host "  policy access have still been disabled above." -ForegroundColor DarkYellow
            }
        }
        52 {
            foreach ($link in @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Cortana.lnk", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Cortana.lnk")) {
                if (Test-Path $link) { Remove-Item $link -Force -ErrorAction SilentlyContinue }
            }
        }
        53 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableAutocorrection" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings\Hardware Keyboard" "EnableAutocorrection" 0
        }
        54 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableSpellchecking" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings\Hardware Keyboard" "EnableSpellchecking" 0
        }
        55 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableTextPrediction" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings\Hardware Keyboard" "EnableTextPrediction" 0
        }
        56 {
            Set-Reg "HKCU:\Control Panel\Desktop" "WindowArrangementActive" "0" String
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SnapAssist" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SnapFill" 0
        }
        57 {
            foreach ($n in $CdmValues) { Set-Reg $CdmPath $n 0 }
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement" "ScoobeSystemSettingEnabled" 0
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
        }
        58 {
            Set-Reg "HKCU:\Control Panel\Desktop" "MenuShowDelay" "100" String
            Set-Reg "HKCU:\Control Panel\Desktop" "WaitToKillAppTimeout" "3000" String
            Write-Host "  Takes effect at next sign-in." -ForegroundColor Yellow
        }
        59 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarAnimations" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\DWM" "EnableAeroPeek" 0
        }
        60 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\GameBar" "AutoGameModeEnabled" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\GameBar" "AllowAutoGameMode" 0
        }
        61 {
            $ep = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
            Set-Reg $ep "BackgroundModeEnabled" 0; Set-Reg $ep "HubsSidebarEnabled" 0; Set-Reg $ep "EdgeShoppingAssistantEnabled" 0
        }
        62 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "LaunchTo" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" "ShowRecent" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" "ShowFrequent" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" "ShowCloudFilesInQuickAccess" 0
        }
        63 { foreach ($t in $TelemetryTasks) { Set-TaskState $t[0] $t[1] $true } }
        64 {
            Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "Disabled" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "Disabled" 1
            Set-SvcState 'WerSvc' $true
        }
        65 {
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" "DisableSettingSync" 2
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" "DisableSettingSyncUserOverride" 1
        }
        66 {
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" "EnableFeeds" 0
            Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds" "ShellFeedsTaskbarViewMode" 2
        }
        67 {
            $adv = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            Set-Reg $adv "ShowTaskViewButton" 0; Set-Reg $adv "ShowCortanaButton" 0; Set-Reg "$adv\People" "PeopleBand" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "HideSCAMeetNow" 1
        }
        68 { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace" "AllowWindowsInkWorkspace" 0 }
        69 {
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa" 0
        }
        70 {
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat" "ChatIcon" 3
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarMn" 0
        }
        71 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowTaskViewButton" 0 }
        72 {
            New-Item -Path $CtxMenuKey -Force | Out-Null
            New-ItemProperty -Path $CtxMenuKey -Name "(default)" -Value "" -PropertyType String -Force | Out-Null
            Write-Host "  Takes effect after Explorer restarts." -ForegroundColor Yellow
        }
        73 {
            $adv = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            Set-Reg $adv "Start_IrisRecommendations" 0; Set-Reg $adv "Start_TrackDocs" 0; Set-Reg $adv "Start_AccountNotifications" 0
        }
        74 { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1 }
        75 {
            Set-SvcState 'WSearch' $true
            Write-Host "  Windows Search Indexer stopped." -ForegroundColor Yellow
        }
        76 {
            Set-TaskState "\Microsoft\Windows\Windows Defender\" "Windows Defender Scheduled Scan" $true
            Write-Host "  Defender scheduled scan task disabled." -ForegroundColor Yellow
        }
        77 {
            $guid = Get-ActivePowerSchemeGuid
            if ($guid) {
                powercfg /setacvalueindex $guid $PcieSubGuid $PcieAspmGuid 0 2>$null
                powercfg /setdcvalueindex $guid $PcieSubGuid $PcieAspmGuid 0 2>$null
                powercfg /setactive $guid 2>$null
                Write-Host "  PCIe ASPM disabled on the active power plan." -ForegroundColor Green
            } else { Write-Host "  Could not determine the active power plan GUID." -ForegroundColor DarkYellow }
        }
        78 {
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" 26
            Write-Host "  Foreground window now gets a larger CPU quantum." -ForegroundColor Green
        }
    }
}

# ===========================================================
# DISABLE / REVERT
# ===========================================================
function Disable-Tweak($Id) {
    $Global:AppxCache = $null
    switch ($Id) {
        1  { Set-SvcState 'SysMain' $false }
        2  { Set-SvcState 'DiagTrack' $false }
        3  { foreach ($s in $XboxServices) { Set-SvcState $s $false } }
        4  { Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode" }
        5  { Set-SvcState 'RemoteRegistry' $false }
        6  { Set-SvcState 'MapsBroker' $false }
        7  { Set-SvcState 'Fax' $false }
        8  { Set-SvcState 'RetailDemo' $false }
        9  { Set-SvcState 'dmwappushservice' $false }
        10 { Set-Reg "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" 0 }
        11 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Siuf\Rules" "NumberOfSIUFInPeriod" 1 }
        12 { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" 1 }
        13 { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "UploadUserActivities" 1 }
        14 {
            # Removing the AllowTelemetry policy is the ONLY way to clear
            # the "managed by your organization" banner. But the Settings
            # toggle also needs DiagTrack and WerSvc to be running - so we
            # re-enable those services here too. Without this, disabling
            # just tweak 14 leaves the toggle greyed out because tweaks 2
            # and 64 (which disable those services) are still in effect.
            Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry"
            Remove-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" "AllowTelemetry"
            Set-SvcState 'DiagTrack' $false
            Set-SvcState 'WerSvc' $false
            Remove-Reg "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "Disabled"
            Remove-Reg "HKCU:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "Disabled"
            Write-Host "  Diagnostic data policy removed and diagnostic services re-enabled." -ForegroundColor Green
            Write-Host "  The Settings > Privacy & security > Diagnostics & feedback toggle is now user-controlled." -ForegroundColor Green
            Write-Host "  NOTE: this also re-enabled tweaks 2 (DiagTrack) and 64 (WerSvc). Re-apply those" -ForegroundColor Yellow
            Write-Host "  from the individual menu if you want them off but still want the toggle usable." -ForegroundColor Yellow
        }
        15 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 1 }
        16 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled" 1 }
        17 { Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" }
        18 {
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCortana" 1
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "DisableWebSearch" 0
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchUseWeb" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "BingSearchEnabled" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "CortanaConsent" 1
        }
        19 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" "01" 1 }
        20 { Remove-Reg $hvciPath "Enabled" }
        21 { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" "LetAppsRunInBackground" 0 }
        22 { powercfg /setactive SCHEME_BALANCED }
        23 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" 0
            Set-Reg "HKCU:\Control Panel\Desktop\WindowMetrics" "MinAnimate" "1" String
            Set-SPI 0x1003 $true; Set-SPI 0x1013 $true; Set-SPI 0x1015 $true
            Set-SPI 0x1005 $true; Set-SPI 0x1007 $true; Set-SPI 0x101B $true
            Assert-FontSmoothingOn
        }
        24 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "EnableTransparency" 1 }
        25 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "IconsOnly" 0 }
        26 {
            powercfg /hibernate on
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "HiberbootEnabled" 1
        }
        27 { Write-Host "  App removal cannot be auto-reversed." -ForegroundColor Yellow }
        28 { Set-SvcState 'PcaSvc' $false }
        29 { Remove-Reg "HKLM:\SYSTEM\CurrentControlSet\Control" "SvcHostSplitThresholdInKB" }
        30 {
            $cs = Get-WmiObject Win32_ComputerSystem
            $cs.AutomaticManagedPagefile = $true
            $cs.Put() | Out-Null
        }
        31 { fsutil behavior set disablelastaccess 0 | Out-Null; Write-Host "  NTFS last-access re-enabled. Reboot required." -ForegroundColor Yellow }
        32 { Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\storahci\Parameters" "EnableMSI" 0; Write-Host "  MSI interrupts disabled. Reboot required." -ForegroundColor Yellow }
        33 { Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "NtfsMftZoneReservation" 1; Write-Host "  MFT zone reverted. Reboot required." -ForegroundColor Yellow }
        34 { Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "NtfsMemoryUsage" 0; Write-Host "  NTFS cache reverted. Reboot required." -ForegroundColor Yellow }
        35 { fsutil behavior set disable8dot3 0 | Out-Null; Write-Host "  8.3 short filenames re-enabled. Reboot required." -ForegroundColor Yellow }
        36 {
            $p = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
            Remove-Reg $p "AllowPrelaunch"; Remove-Reg $p "AllowTabPreloading"; Remove-Reg $p "StartupBoostEnabled"
        }
        37 {
            Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableCdp"
            Set-TaskState "\Microsoft\Windows\CloudExperienceHost\" "CreateObjectTask" $false
            Set-TaskState "\Microsoft\Windows\Shell\" "CreateObjectTask" $false
        }
        38 {
            Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps" "AutoDownloadAndUpdateMapData"
            Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps" "AllowUntriggeredNetworkTrafficOnSettingsPage"
        }
        39 { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableLocation" 0 }
        40 { Set-TaskState "\Microsoft\Windows\Mobile Broadband Accounts\" "MNO Metadata Parser Task" $false }
        41 { Set-TaskState "\Microsoft\Windows\Speech\" "SpeechModelDownloadTask" $false }
        42 {
            Remove-TimerResolutionEnforcer
            Remove-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel" "GlobalTimerResolutionRequests"
            Write-Host "  Global timer resolution override removed." -ForegroundColor Green
        }
        43 { Set-TaskState "\Microsoft\Windows\Application Experience\" "Microsoft Compatibility Appraiser" $false }
        44 {
            # Just remove the policy. When absent, Windows treats the feature
            # as permitted (the default). Setting it to 0 would also work,
            # but Remove-Reg is the true "unset" state.
            Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC"
            $stub = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
            if (-not (Test-Path $stub)) { $stub = "$env:SystemRoot\System32\OneDriveSetup.exe" }
            if (Test-Path $stub) {
                Start-Process $stub -ErrorAction SilentlyContinue
                Write-Host "  OneDrive policy removed. Reinstall started from the Windows-bundled installer." -ForegroundColor Green
            } else {
                Write-Host "  OneDrive installer not found - download from https://www.microsoft.com/microsoft-365/onedrive/download" -ForegroundColor Yellow
            }
        }
        45 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsMSACloudSearchEnabled" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsAADCloudSearchEnabled" 1
        }
        46 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "SafeSearchMode" 1 }
        47 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsDeviceSearchHistoryEnabled" 1 }
        48 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\InputPersonalization" "RestrictImplicitInkCollection" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\InputPersonalization" "RestrictImplicitTextCollection" 0
        }
        49 { Set-Reg "HKCU:\Control Panel\International\User Profile" "HttpAcceptLanguageOptOut" 0 }
        50 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" 1
            Set-Reg "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 1
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\GameBar" "UseNexusForGameBarEnabled" 1
        }
        51 {
            # Remove the button override so the taskbar button reappears
            # (Windows default). The app itself was removed by Enable-Tweak
            # and must be reinstalled manually.
            Remove-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowCopilotButton"
            Write-Host "  Copilot taskbar setting restored to Windows default." -ForegroundColor Green
            Write-Host "  The Copilot app was removed by this tweak and must be reinstalled from the Microsoft Store if needed." -ForegroundColor Yellow
        }
        52 { Write-Host "  Shortcut cleanup cannot be auto-reversed - cosmetic only." -ForegroundColor Yellow }
        53 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableAutocorrection" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings\Hardware Keyboard" "EnableAutocorrection" 1
        }
        54 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableSpellchecking" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings\Hardware Keyboard" "EnableSpellchecking" 1
        }
        55 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableTextPrediction" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings\Hardware Keyboard" "EnableTextPrediction" 1
        }
        56 {
            Set-Reg "HKCU:\Control Panel\Desktop" "WindowArrangementActive" "1" String
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SnapAssist" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SnapFill" 1
        }
        57 {
            foreach ($n in $CdmValues) { Set-Reg $CdmPath $n 1 }
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement" "ScoobeSystemSettingEnabled" 1
            Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures"
        }
        58 {
            Set-Reg "HKCU:\Control Panel\Desktop" "MenuShowDelay" "400" String
            Set-Reg "HKCU:\Control Panel\Desktop" "WaitToKillAppTimeout" "5000" String
        }
        59 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarAnimations" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\DWM" "EnableAeroPeek" 1
        }
        60 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\GameBar" "AutoGameModeEnabled" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\GameBar" "AllowAutoGameMode" 1
        }
        61 {
            $ep = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
            Remove-Reg $ep "BackgroundModeEnabled"; Remove-Reg $ep "HubsSidebarEnabled"; Remove-Reg $ep "EdgeShoppingAssistantEnabled"
        }
        62 {
            $adv = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            $exp = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"
            Remove-Reg $adv "LaunchTo"; Remove-Reg $exp "ShowRecent"
            Remove-Reg $exp "ShowFrequent"; Remove-Reg $exp "ShowCloudFilesInQuickAccess"
        }
        63 { foreach ($t in $TelemetryTasks) { Set-TaskState $t[0] $t[1] $false } }
        64 {
            Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "Disabled" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "Disabled" 0
            Set-SvcState 'WerSvc' $false
        }
        65 {
            Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" "DisableSettingSync"
            Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" "DisableSettingSyncUserOverride"
        }
        66 {
            Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" "EnableFeeds"
            Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds" "ShellFeedsTaskbarViewMode" 0
        }
        67 {
            $adv = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            Set-Reg $adv "ShowTaskViewButton" 1; Set-Reg $adv "ShowCortanaButton" 1; Set-Reg "$adv\People" "PeopleBand" 1
            Remove-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "HideSCAMeetNow"
        }
        68 { Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace" "AllowWindowsInkWorkspace" }
        69 {
            # Both the policy and the button value need to be removed for the
            # Widgets taskbar toggle to be user-controlled again.
            Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests"
            Remove-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa"
        }
        70 {
            # Both the policy and the button value need to be removed for the
            # Chat taskbar toggle to be user-controlled again.
            Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat" "ChatIcon"
            Remove-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarMn"
        }
        71 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowTaskViewButton" 1
            $searchPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"
            if ((Get-RegValue $searchPath "SearchboxTaskbarMode") -eq 0) {
                Set-Reg $searchPath "SearchboxTaskbarMode" 2
            }
        }
        72 {
            Remove-Item -LiteralPath $CtxMenuRoot -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  Takes effect after Explorer restarts." -ForegroundColor Yellow
        }
        73 {
            $adv = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            Set-Reg $adv "Start_IrisRecommendations" 1; Set-Reg $adv "Start_TrackDocs" 1; Set-Reg $adv "Start_AccountNotifications" 1
        }
        74 { Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" }
        75 {
            Set-SvcState 'WSearch' $false
            Write-Host "  Windows Search Indexer re-enabled." -ForegroundColor Green
        }
        76 {
            Set-TaskState "\Microsoft\Windows\Windows Defender\" "Windows Defender Scheduled Scan" $false
            Write-Host "  Defender scheduled scan task re-enabled." -ForegroundColor Green
        }
        77 {
            $guid = Get-ActivePowerSchemeGuid
            if ($guid) {
                powercfg /setacvalueindex $guid $PcieSubGuid $PcieAspmGuid 1 2>$null
                powercfg /setdcvalueindex $guid $PcieSubGuid $PcieAspmGuid 1 2>$null
                powercfg /setactive $guid 2>$null
                Write-Host "  PCIe ASPM reverted to Moderate power savings." -ForegroundColor Green
            } else { Write-Host "  Could not determine the active power plan GUID." -ForegroundColor DarkYellow }
        }
        78 {
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" 2
            Write-Host "  Win32PrioritySeparation reverted to Windows default (2)." -ForegroundColor Green
        }
    }
}

# ===========================================================
# UI
# ===========================================================
function Clear-PendingInput {
    try { while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null } } catch {}
}
function Read-MenuChoice($Prompt) {
    Clear-PendingInput
    return ("$(Read-Host $Prompt)").Trim()
}
function Wait-Continue($Prompt = "`nPress Enter to continue (0 = back)") {
    return ((Read-MenuChoice $Prompt) -eq '0')
}
function Disable-ConsoleQuickEdit {
    try {
        Add-Type -Namespace UIT63 -Name ConMode -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
"@ -ErrorAction Stop
        $h = [UIT63.ConMode]::GetStdHandle(-10)
        [uint32]$mode = 0
        if ([UIT63.ConMode]::GetConsoleMode($h, [ref]$mode)) {
            $m = [int64]$mode
            if (($m -band 0x40) -ne 0) { $m = $m - 0x40 }
            $m = $m -bor 0x80
            [UIT63.ConMode]::SetConsoleMode($h, [uint32]$m) | Out-Null
        }
    } catch {}
}
function Get-InstalledAppSet {
    if ($Global:AppxCache -and $Global:AppxCacheTime -and (((Get-Date) - $Global:AppxCacheTime).TotalSeconds -lt 30)) {
        return $Global:AppxCache
    }
    $set = @{}
    try { Get-AppxPackage -ErrorAction SilentlyContinue | ForEach-Object { $set[$_.Name] = $true } } catch {}
    $Global:AppxCache = $set
    $Global:AppxCacheTime = Get-Date
    return $set
}
function Get-TimerEnforcerProcess {
    if (-not (Test-Path $TimerResPidFile)) { return $null }
    $raw = Get-Content $TimerResPidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $n = 0
    if (-not [int]::TryParse("$raw".Trim(), [ref]$n) -or $n -le 0) { return $null }
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $n" -ErrorAction SilentlyContinue
    if (-not $cim) { return $null }
    if ($cim.Name -notlike 'powershell*') { return $null }
    if (-not $cim.CommandLine) { return $null }
    if ($cim.CommandLine -notmatch 'TimerResEnforcer') { return $null }
    return (Get-Process -Id $n -ErrorAction SilentlyContinue)
}
function Set-ConsoleReadability {
    try { $Host.UI.RawUI.WindowTitle = "UIT-63 FDIV Console" } catch {}
    try { $ui = $Host.UI.RawUI; $ui.BufferSize = New-Object System.Management.Automation.Host.Size($ui.BufferSize.Width, 3000) } catch {}
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ConsoleFontHelper {
    [StructLayout(LayoutKind.Sequential)]
    public struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CONSOLE_FONT_INFO_EX {
        public uint cbSize; public uint nFont; public COORD dwFontSize;
        public int FontFamily; public int FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName;
    }
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetCurrentConsoleFontEx(IntPtr consoleOutput, bool maximumWindow, ref CONSOLE_FONT_INFO_EX consoleCurrentFontEx);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetCurrentConsoleFontEx(IntPtr consoleOutput, bool maximumWindow, ref CONSOLE_FONT_INFO_EX consoleCurrentFontEx);
}
"@ -ErrorAction SilentlyContinue
        $handle = [ConsoleFontHelper]::GetStdHandle(-11)
        $font = New-Object ConsoleFontHelper+CONSOLE_FONT_INFO_EX
        $font.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($font)
        if ([ConsoleFontHelper]::GetCurrentConsoleFontEx($handle, $false, [ref]$font)) {
            $font.dwFontSize.Y = [int16]($font.dwFontSize.Y + 1)
            [ConsoleFontHelper]::SetCurrentConsoleFontEx($handle, $false, [ref]$font) | Out-Null
        }
    } catch {}
}
function Get-SystemInfoOnce {
    $r = [PSCustomObject]@{ OS = "Unknown"; CPU = "Unknown"; Cores = "Unknown"; RAM = "Unknown"; Motherboard = "Unknown"; BIOS = "Unknown" }
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue; if ($os) { $r.OS = "$($os.Caption) (Build $($os.BuildNumber), $($os.OSArchitecture))" } } catch {}
    try { $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1; if ($cpu) { $r.CPU = "$($cpu.Name)".Trim(); $r.Cores = "$($cpu.NumberOfCores)C / $($cpu.NumberOfLogicalProcessors)T" } } catch {}
    try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue; if ($cs) { $r.RAM = "$([math]::Round($cs.TotalPhysicalMemory / 1GB, 2)) GB" } } catch {}
    try { $bb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue; if ($bb) { $r.Motherboard = "$($bb.Manufacturer) $($bb.Product)".Trim() } } catch {}
    try { $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue; if ($bios) { $r.BIOS = "$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)".Trim() } } catch {}
    return $r
}
function Center-Text($text, $width) {
    $pad = [Math]::Max(0, $width - $text.Length); $left = [Math]::Floor($pad / 2)
    return (" " * $left) + $text + (" " * ($pad - $left))
}
function Show-Banner {
    param([switch]$MainMenu)
    Clear-Host
    $boxWidth = 53
    $top = "  +" + ("-" * $boxWidth) + "+"
    Write-Host ""; Write-Host $top -ForegroundColor Cyan
    Write-Host ("  |" + (Center-Text "UIT-63 - FDIV Edition | Lab PC Optimizer" $boxWidth) + "|") -ForegroundColor White
    Write-Host $top -ForegroundColor Cyan
    Write-Host (" " + (Center-Text "made by shivansh" ($boxWidth + 4))) -ForegroundColor DarkGray
    Write-Host ""
    if ($MainMenu -and $null -ne $Global:SysInfo) {
        Write-Host "  System Info" -ForegroundColor White
        Write-Host "  -----------" -ForegroundColor White
        Write-Host ("    OS           : {0}" -f $Global:SysInfo.OS)
        Write-Host ("    Tweak profile: {0} (build {1})" -f $Global:OSLabel, $Global:WinBuild)
        Write-Host ("    Processor    : {0}" -f $Global:SysInfo.CPU)
        Write-Host ("    Cores        : {0}" -f $Global:SysInfo.Cores)
        Write-Host ("    RAM          : {0}" -f $Global:SysInfo.RAM)
        Write-Host ("    Motherboard  : {0}" -f $Global:SysInfo.Motherboard)
        Write-Host ("    BIOS         : {0}" -f $Global:SysInfo.BIOS)
        Write-Host ""
    }
    if (Test-Path $PrevLog) {
        $lastLine = Get-Content $PrevLog -Tail 1 -ErrorAction SilentlyContinue
        if ($lastLine) { Write-Host "  Last activity:" -ForegroundColor DarkGray; Write-Host "    $lastLine" -ForegroundColor DarkGray; Write-Host "" }
    }
}
function Show-TweakList {
    param([switch]$Numbered)
    $tierRank = @{ 'Base' = 0; 'RAM4GB' = 1; 'Optional' = 2 }
    $ids = $TweakInfo.Keys | Sort-Object -Property @{ Expression = { $tierRank[$TweakInfo[$_].Tier] } }, @{ Expression = { [int]$_ } }
    Write-Host "  Reading current status of each tweak - this can take a few seconds..." -ForegroundColor DarkGray
    $currentTier = ""
    foreach ($id in $ids) {
        $info = $TweakInfo[$id]
        if ($info.Tier -ne $currentTier) {
            $currentTier = $info.Tier
            $label = switch ($currentTier) {
                'Base'     { "-- Base tweaks --" }
                'RAM4GB'   { "-- 4GB RAM tweaks --" }
                'Optional' { "-- Optional tweaks (not applied by Apply All / Apply 4GB) --" }
                default    { "-- $currentTier --" }
            }
            Write-Host "`n  $label" -ForegroundColor White
        }
        $applied = Test-TweakApplied $id
        $tag = if ($applied) { "[APPLIED]" } else { "[NOT APPLIED]" }
        $color = if ($applied) { "Green" } else { "DarkGray" }
        $prefix = if ($Numbered) { "  {0,3}." -f $id } else { "      " }
        Write-Host ("$prefix {0,-45} {1}" -f $info.Name, $tag) -ForegroundColor $color
    }
    Write-Host ""
}
function Save-Snapshot($label) {
    try {
        $states = ($TweakInfo.Keys | Sort-Object | ForEach-Object { "$_=$(if (Test-TweakApplied $_) { 1 } else { 0 })" }) -join ';'
        Add-Content -Path $SnapshotFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')|$label|$states"
    } catch {}
}
function Get-Snapshots {
    if (-not (Test-Path $SnapshotFile)) { return @() }
    return Get-Content $SnapshotFile | Where-Object { $_ -match '\|' }
}
function Register-PhotoViewerApplication {
    if (-not (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -Scope Script | Out-Null
    }
    $cmd = '%SystemRoot%\System32\rundll32.exe "%ProgramFiles%\Windows Photo Viewer\PhotoViewer.dll", ImageView_Fullscreen %1'
    foreach ($p in @("HKCR:\Applications\photoviewer.dll\shell\open\command","HKCR:\Applications\photoviewer.dll\shell\open\DropTarget","HKCR:\Applications\photoviewer.dll\shell\print\command","HKCR:\Applications\photoviewer.dll\shell\print\DropTarget")) { New-Item -Path $p -Force | Out-Null }
    New-ItemProperty -Path "HKCR:\Applications\photoviewer.dll\shell\open" -Name "MuiVerb" -Value "@photoviewer.dll,-3043" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path "HKCR:\Applications\photoviewer.dll\shell\open\command" -Name "(Default)" -Value $cmd -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty -Path "HKCR:\Applications\photoviewer.dll\shell\open\DropTarget" -Name "Clsid" -Value "{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path "HKCR:\Applications\photoviewer.dll\shell\print\command" -Name "(Default)" -Value $cmd -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty -Path "HKCR:\Applications\photoviewer.dll\shell\print\DropTarget" -Name "Clsid" -Value "{60fd46de-f830-4894-a628-6fa81bc0190d}" -PropertyType String -Force | Out-Null
}
function Set-PhotoViewerDefault {
    $dllPath = "$env:ProgramFiles\Windows Photo Viewer\PhotoViewer.dll"
    if (-not (Test-Path $dllPath)) {
        Write-Host "  PROBLEM: $dllPath does not exist on this machine." -ForegroundColor Red
        return
    }
    try { $edition = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption } catch { $edition = "" }
    if ($edition -match "Home") { Write-Host "  Note: Home edition often ignores the GPO mechanism used here." -ForegroundColor Yellow }
    Register-PhotoViewerApplication
    $configDir = "$env:ProgramData\UIT63"
    $xmlPath = "$configDir\DefaultAppAssociations.xml"
    $backupPath = "$env:USERPROFILE\Desktop\UIT63-DefaultPhotoApp-Backup.xml"
    if (-not (Test-Path $backupPath)) { try { dism /Online /Export-DefaultAppAssociations:"$backupPath" | Out-Null } catch {} }
    if (-not (Test-Path $configDir)) { New-Item -Path $configDir -ItemType Directory -Force | Out-Null }
    $lines = foreach ($e in @(".bmp",".dib",".gif",".jfif",".jpe",".jpeg",".jpg",".jxr",".png",".tif",".tiff",".wdp")) {
        $progid = if ($e -in @(".bmp", ".dib")) { "PhotoViewer.FileAssoc.Bitmap" } else { "PhotoViewer.FileAssoc.Tiff" }
        "  <Association Identifier=`"$e`" ProgId=`"$progid`" ApplicationName=`"Windows Photo Viewer`" />"
    }
    Set-Content -Path $xmlPath -Value ("<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n<DefaultAssociations>`n$($lines -join "`n")`n</DefaultAssociations>") -Encoding UTF8
    try { dism /Online /Import-DefaultAppAssociations:"$xmlPath" 2>$null | Out-Null } catch {}
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "DefaultAssociationsConfiguration" $xmlPath String
    try { gpupdate /target:computer /force *>$null } catch {}
    Write-Host "  Windows Photo Viewer association policy set. Takes effect at next logon." -ForegroundColor Green
}
function Restore-PhotosAppDefault {
    Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "DefaultAssociationsConfiguration"
    try { gpupdate /target:computer /force *>$null } catch {}
    $backupPath = "$env:USERPROFILE\Desktop\UIT63-DefaultPhotoApp-Backup.xml"
    if (Test-Path $backupPath) { try { dism /Online /Import-DefaultAppAssociations:"$backupPath" | Out-Null } catch {} }
    Write-Host "  Photo Viewer policy removed. Log off and back on." -ForegroundColor Green
}

function Register-DnsEnforcer($PrimaryV4, $SecondaryV4, $PrimaryV6, $SecondaryV6, $Label) {
    try {
        $taskName = "UIT63-DnsEnforcer"
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        $innerCmd = "`$ok=`$false; for(`$i=0; `$i -lt 40 -and -not `$ok; `$i++){ `$ads=@(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { `$_.Status -eq 'Up' }); if(`$ads.Count -gt 0){ foreach(`$a in `$ads){ `$set=`$false; try{ Set-DnsClientServerAddress -InterfaceIndex `$a.IfIndex -ServerAddresses ('$PrimaryV4','$SecondaryV4','$PrimaryV6','$SecondaryV6') -ErrorAction Stop; `$set=`$true } catch { try{ Set-DnsClientServerAddress -InterfaceIndex `$a.IfIndex -ServerAddresses ('$PrimaryV4','$SecondaryV4') -ErrorAction Stop; Set-DnsClientServerAddress -InterfaceIndex `$a.IfIndex -ServerAddresses ('$PrimaryV6','$SecondaryV6') -ErrorAction Stop; `$set=`$true } catch {} }; if(`$set){ `$ok=`$true } } }; if(-not `$ok){ Start-Sleep -Seconds 15 } }"
        $vbsPath = "$env:ProgramData\UIT63\DnsEnforcerLauncher.vbs"
        $action = New-HiddenTaskAction $vbsPath "powershell.exe -NoProfile -WindowStyle Hidden -Command `"$innerCmd`""
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $principal `
            -Description "UIT-63 FDIV: keeps DNS set to $Label (IPv4+IPv6) at every boot" -Force | Out-Null
    } catch { Write-Host "  Could not register DNS enforcer task: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}
function Remove-DnsEnforcer { try { Unregister-ScheduledTask -TaskName "UIT63-DnsEnforcer" -Confirm:$false -ErrorAction SilentlyContinue } catch {} }
function Remove-AllUit63Tasks {
    try { Remove-TimerResolutionEnforcer } catch {}
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'TimerResEnforcer' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch {}
    try { Remove-DnsEnforcer } catch {}
    try { Unregister-ScheduledTask -TaskName "UIT63-FontSmoothingEnforcer" -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    try { Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "UIT63-*" } | ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue } } catch {}
}
function Get-OneDriveUninstallString {
    foreach ($path in @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*")) {
        $entry = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*OneDrive*" } | Select-Object -First 1
        if ($entry -and $entry.UninstallString) { return $entry.UninstallString }
    }
    return $null
}
function Set-DnsProvider($PrimaryV4, $SecondaryV4, $PrimaryV6, $SecondaryV6, $Label) {
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
    if (-not $adapters) { Write-Host "  No active network adapter found." -ForegroundColor DarkGray; return }
    foreach ($a in $adapters) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $a.IfIndex -ServerAddresses @($PrimaryV4, $SecondaryV4, $PrimaryV6, $SecondaryV6) -ErrorAction Stop
        } catch {
            try { Set-DnsClientServerAddress -InterfaceIndex $a.IfIndex -ServerAddresses @($PrimaryV4, $SecondaryV4) -ErrorAction Stop }
            catch { Write-Host "  Could not set IPv4 DNS on $($a.Name): $($_.Exception.Message)" -ForegroundColor DarkYellow }
            try { Set-DnsClientServerAddress -InterfaceIndex $a.IfIndex -ServerAddresses @($PrimaryV6, $SecondaryV6) -ErrorAction Stop }
            catch { Write-Host "  Could not set IPv6 DNS on $($a.Name): $($_.Exception.Message)" -ForegroundColor DarkYellow }
        }
    }
    Register-DnsEnforcer $PrimaryV4 $SecondaryV4 $PrimaryV6 $SecondaryV6 $Label
    Write-Host "  DNS set to $Label on active adapter(s):" -ForegroundColor Green
    Write-Host "    IPv4: $PrimaryV4, $SecondaryV4" -ForegroundColor DarkGray
    Write-Host "    IPv6: $PrimaryV6, $SecondaryV6" -ForegroundColor DarkGray
}
function Reset-DnsAutomatic {
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
    if (-not $adapters) { Write-Host "  No active network adapter found." -ForegroundColor DarkGray; return }
    foreach ($a in $adapters) {
        try { Set-DnsClientServerAddress -InterfaceIndex $a.IfIndex -ResetServerAddresses -ErrorAction Stop }
        catch { Write-Host "  Could not reset DNS on $($a.Name): $($_.Exception.Message)" -ForegroundColor DarkYellow }
    }
    Remove-DnsEnforcer
    Write-Host "  DNS reset to automatic (both IPv4 and IPv6)." -ForegroundColor Green
}
function Set-MacRandomization([bool]$Enable) {
    $wifiAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -match '802\.11' -or $_.MediaType -match '802\.11' }
    if (-not $wifiAdapters) { Write-Host "  No Wi-Fi adapter found." -ForegroundColor DarkGray; return }
    $val = if ($Enable) { "Enabled" } else { "Disabled" }
    foreach ($a in $wifiAdapters) {
        try { Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName "Random MAC Address" -DisplayValue $val -ErrorAction Stop; Write-Host "  MAC randomization $val on $($a.Name)." -ForegroundColor Green }
        catch { Write-Host "  Could not set MAC randomization on $($a.Name) - driver-dependent." -ForegroundColor DarkYellow }
    }
}
function Install-SingleApp($app) {
    $Global:AppxCache = $null
    if (Get-AppxPackage -Name $app -ErrorAction SilentlyContinue) { Write-Host "  $app already installed." -ForegroundColor Yellow; return }
    if ($null -eq $Global:WingetOk) { $Global:WingetOk = Ensure-Winget }
    if ($Global:WingetOk) {
        Write-Host "  Installing $app via winget (Microsoft Store source)..." -ForegroundColor Cyan
        try { winget install --id $app --source msstore --silent --accept-package-agreements --accept-source-agreements 2>$null 1>$null } catch {}
        if (Get-AppxPackage -Name $app -ErrorAction SilentlyContinue) { Write-Host "  Installed $app." -ForegroundColor Green; Write-PrevLog "Reinstalled: $app" }
        else { Write-Host "  Could not install $app automatically." -ForegroundColor DarkYellow }
    } else { Write-Host "  Winget isn't available - search for $app manually in Microsoft Store." -ForegroundColor Yellow }
}
function Menu-InstallApps {
    while ($true) {
        Show-Banner
        Write-Host "  Install Windows Apps (apps this tool can remove)" -ForegroundColor White
        Write-Host "  ----------------------------------------------------" -ForegroundColor White
        Write-Host ""
        $appSet = Get-InstalledAppSet; $sorted = $BundledApps | Sort-Object
        $num = 1; $lookup = @{}
        foreach ($app in $sorted) {
            $installed = $appSet.ContainsKey($app)
            $tag = if ($installed) { "[INSTALLED]" } else { "[NOT INSTALLED]" }
            $color = if ($installed) { "Green" } else { "DarkGray" }
            Write-Host ("  {0,3}. {1,-40} {2}" -f $num, $app, $tag) -ForegroundColor $color
            $lookup[$num] = $app; $num++
        }
        Write-Host ""; Write-Host "  A. Install ALL not-installed"; Write-Host "  0. Back"
        Write-Host ""
        $choice = Read-MenuChoice "Enter a number, A for all, or 0 to go back"
        if ($choice -eq '0') { return }
        if ($choice -match '^[Aa]$') {
            $toInstall = @($sorted | Where-Object { -not $appSet.ContainsKey($_) })
            if ($toInstall.Count -eq 0) { Write-Host "`nEverything installed." -ForegroundColor Yellow }
            else { Write-Host "`nInstalling $($toInstall.Count) app(s)..." -ForegroundColor Cyan; foreach ($app in $toInstall) { Install-SingleApp $app }; Write-Host "`nDone." -ForegroundColor Green }
            if (Wait-Continue) { return }
            continue
        }
        $idNum = 0
        if (-not ([int]::TryParse($choice, [ref]$idNum)) -or -not $lookup.ContainsKey($idNum)) { Write-Host "`nInvalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1; continue }
        Write-Host ""; Install-SingleApp $lookup[$idNum]
        if (Wait-Continue) { return }
    }
}
function Menu-Diagnostics {
    while ($true) {
        Show-Banner
        Write-Host "  Diagnostics and Repair" -ForegroundColor White
        Write-Host "  -----------------------" -ForegroundColor White
        Write-Host ""
        Write-Host "  1. Memory Diagnostic"
        Write-Host "  2. Disk Check - quick online scan"
        Write-Host "  3. Disk Check - full scan and fix (next restart)"
        Write-Host "  4. System File Checker (sfc /scannow)"
        Write-Host "  5. Component Store Repair (DISM RestoreHealth)"
        Write-Host "  6. Remove leftover UIT-63 scheduled tasks"
        Write-Host "  0. Back"
        Write-Host ""
        $sel = Read-MenuChoice "Select an option"; Write-Host ""
        $invalid = $false
        switch ($sel) {
            '1' { Start-Process "mdsched.exe" }
            '2' {
                try { $result = Repair-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':')) -Scan -ErrorAction Stop; Write-Host "Scan result: $($result.HealthStatus)" -ForegroundColor Green }
                catch { Write-Host "Scan failed: $($_.Exception.Message)" -ForegroundColor Red }
            }
            '3' {
                if ((Read-MenuChoice "Schedule for next restart? (Y/N)") -match '^[Yy]') {
                    try { Repair-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':')) -OfflineScanAndFix -ErrorAction Stop; Write-Host "Scheduled." -ForegroundColor Green }
                    catch { Write-Host "Could not schedule: $($_.Exception.Message)" -ForegroundColor Red }
                }
            }
            '4' { sfc /scannow }
            '5' { DISM /Online /Cleanup-Image /RestoreHealth }
            '6' {
                if ((Read-MenuChoice "Remove all UIT-63 scheduled tasks? (Y/N)") -match '^[Yy]') {
                    Remove-AllUit63Tasks
                    Write-Host "Done." -ForegroundColor Green
                }
            }
            '0' { return }
            default { $invalid = $true }
        }
        if (($sel -ne '0') -and (-not $invalid)) { if (Wait-Continue) { return } }
    }
}
function Menu-AdditionalTweaks {
    while ($true) {
        Show-Banner
        Write-Host "  Additional Tweaks (optional, applied individually)" -ForegroundColor White
        Write-Host "  ----------------------------------------------------" -ForegroundColor White
        Write-Host "  1. Restore Windows Photo Viewer and set as default"
        Write-Host "  2. Revert - restore Photos app as default"
        Write-Host "  3. Set DNS to Google (IPv4 8.8.8.8/8.8.4.4 + IPv6 2001:4860:4860::8888/::8844)"
        Write-Host "  4. Set DNS to Cloudflare (IPv4 1.1.1.1/1.0.0.1 + IPv6 2606:4700:4700::1111/::1001)"
        Write-Host "  5. Reset DNS to automatic (both IPv4 and IPv6)"
        Write-Host "  6. Enable MAC address randomization (Wi-Fi)"
        Write-Host "  7. Disable MAC address randomization (Wi-Fi)"
        Write-Host "  0. Back"
        Write-Host ""
        $sel = Read-MenuChoice "Select an option"; Write-Host ""
        $invalid = $false
        switch ($sel) {
            '1' {
                Set-PhotoViewerDefault
                Write-PrevLog "Additional: Photo Viewer set as default"
                if ((Read-MenuChoice "Open Settings > Default Apps now? (Y/N)") -match '^[Yy]') { Start-Process "ms-settings:defaultapps" }
            }
            '2' {
                Restore-PhotosAppDefault
                Write-PrevLog "Additional: Photos app default restored"
                if ((Read-MenuChoice "Open Settings > Default Apps now? (Y/N)") -match '^[Yy]') { Start-Process "ms-settings:defaultapps" }
            }
            '3' { Set-DnsProvider "8.8.8.8" "8.8.4.4" "2001:4860:4860::8888" "2001:4860:4860::8844" "Google"; Write-PrevLog "Additional: DNS set to Google (v4+v6)" }
            '4' { Set-DnsProvider "1.1.1.1" "1.0.0.1" "2606:4700:4700::1111" "2606:4700:4700::1001" "Cloudflare"; Write-PrevLog "Additional: DNS set to Cloudflare (v4+v6)" }
            '5' { Reset-DnsAutomatic; Write-PrevLog "Additional: DNS reset to automatic" }
            '6' { Set-MacRandomization $true; Write-PrevLog "Additional: MAC randomization enabled" }
            '7' { Set-MacRandomization $false; Write-PrevLog "Additional: MAC randomization disabled" }
            '0' { return }
            default { $invalid = $true }
        }
        if ($invalid) { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1; continue }
        if (Wait-Continue) { return }
    }
}
function Menu-Restore {
    while ($true) {
        Show-Banner
        Write-Host "  Restore to a Save Point" -ForegroundColor White
        Write-Host "  ------------------------" -ForegroundColor White
        $snapshots = @(Get-Snapshots)
        if ($snapshots.Count -eq 0) {
            Write-Host "`n  No save points yet." -ForegroundColor DarkGray
            Read-MenuChoice "Press Enter to go back" | Out-Null
            return
        }
        $indexed = @()
        for ($i = 0; $i -lt $snapshots.Count; $i++) { $indexed += , @($i, $snapshots[$i]) }
        $indexed = $indexed | Sort-Object { $_[0] } -Descending
        Write-Host ""
        $displayNum = 1; $lookup = @{}
        foreach ($entry in $indexed) {
            $parts = $entry[1] -split '\|', 3
            if ($parts.Count -lt 3) { continue }
            Write-Host ("  {0,3}. {1}  -  {2}" -f $displayNum, $parts[0], $parts[1])
            $lookup[$displayNum] = $parts[2]; $displayNum++
        }
        Write-Host ""
        $choice = Read-MenuChoice "Enter a save point number to restore (0 = back)"
        if ($choice -eq '0') { return }
        $idNum = 0
        if (-not ([int]::TryParse($choice, [ref]$idNum)) -or -not $lookup.ContainsKey($idNum)) { Write-Host "`nInvalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1; continue }
        $desired = @{}
        foreach ($pair in ($lookup[$idNum] -split ';')) { if ($pair -match '^(\d+)=(\d)$') { $desired[[int]$Matches[1]] = [int]$Matches[2] } }
        Write-Host "`nRestoring..." -ForegroundColor Cyan
        Ensure-RestorePoint
        foreach ($id in ($desired.Keys | Sort-Object)) {
            if (-not $TweakInfo.ContainsKey($id)) { continue }
            $want = $desired[$id] -eq 1
            $have = Test-TweakApplied $id
            if ($want -and -not $have) {
                try { Enable-Tweak $id; Write-PrevLog "Restored (applied): $($TweakInfo[$id].Name)" }
                catch { Write-Host "  Failed: $($TweakInfo[$id].Name)" -ForegroundColor Red }
            } elseif (-not $want -and $have) {
                try { Disable-Tweak $id; Write-PrevLog "Restored (disabled): $($TweakInfo[$id].Name)" }
                catch { Write-Host "  Failed: $($TweakInfo[$id].Name)" -ForegroundColor Red }
            }
        }
        Save-Snapshot "Restored to save point"
        Assert-FontSmoothingOn
        Write-Host "Restore complete." -ForegroundColor Green
        Wait-Continue "Press Enter to continue" | Out-Null
        return
    }
}
function Ensure-RestorePoint {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        $srKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore"
        $prevFreq = Get-RegValue $srKey "SystemRestorePointCreationFrequency"
        Set-Reg $srKey "SystemRestorePointCreationFrequency" 0
        Checkpoint-Computer -Description "UIT63-EduBoost" -RestorePointType "MODIFY_SETTINGS" -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        if ($null -ne $prevFreq) { Set-Reg $srKey "SystemRestorePointCreationFrequency" $prevFreq }
        else { Remove-Reg $srKey "SystemRestorePointCreationFrequency" }
    } catch {}
}
function Apply-AllBase {
    Ensure-RestorePoint
    Write-Host "`nApplying base tweaks..." -ForegroundColor Cyan
    Write-PrevLog "=== Apply All (base tweaks) started ==="
    foreach ($id in ($TweakInfo.Keys | Where-Object { $TweakInfo[$_].Tier -eq 'Base' } | Sort-Object)) {
        if (Test-TweakApplied $id) { continue }
        try { Enable-Tweak $id; Write-PrevLog "Applied: $($TweakInfo[$id].Name)" }
        catch { Write-Host "  Failed: $($TweakInfo[$id].Name) - $($_.Exception.Message)" -ForegroundColor Red; Write-PrevLog "FAILED: $($TweakInfo[$id].Name)" }
    }
    Write-PrevLog "=== Apply All (base tweaks) finished ==="
    Write-Host "Base tweaks applied." -ForegroundColor Green
    Save-Snapshot "Apply All (base)"
    Start-Sleep -Seconds 2
    Assert-FontSmoothingOn
}
function Apply-All4GB {
    Apply-AllBase
    Write-Host "`nApplying 4GB RAM optimization tier..." -ForegroundColor Cyan
    Write-PrevLog "=== Apply 4GB RAM tier started ==="
    foreach ($id in ($TweakInfo.Keys | Where-Object { $TweakInfo[$_].Tier -eq 'RAM4GB' } | Sort-Object)) {
        if (Test-TweakApplied $id) { continue }
        try { Enable-Tweak $id; Write-PrevLog "Applied: $($TweakInfo[$id].Name)" }
        catch { Write-Host "  Failed: $($TweakInfo[$id].Name) - $($_.Exception.Message)" -ForegroundColor Red; Write-PrevLog "FAILED: $($TweakInfo[$id].Name)" }
    }
    Write-PrevLog "=== Apply 4GB RAM tier finished ==="
    Write-Host "4GB RAM tweaks applied." -ForegroundColor Green
    Save-Snapshot "Apply 4GB RAM tier"
    Start-Sleep -Seconds 2
    Assert-FontSmoothingOn
}
function Disable-AllApplied {
    Write-Host "`nDisabling all applied tweaks..." -ForegroundColor Cyan
    Write-PrevLog "=== Disable All Applied started ==="
    foreach ($id in ($TweakInfo.Keys | Sort-Object)) {
        if (Test-TweakApplied $id) {
            try { Disable-Tweak $id; Write-PrevLog "Disabled: $($TweakInfo[$id].Name)" }
            catch { Write-Host "  Failed to disable: $($TweakInfo[$id].Name) - $($_.Exception.Message)" -ForegroundColor Red; Write-PrevLog "FAILED to disable: $($TweakInfo[$id].Name)" }
        }
    }
    Write-PrevLog "=== Disable All Applied finished ==="
    Write-Host "Done." -ForegroundColor Green
    Save-Snapshot "Disable All Applied"
    Start-Sleep -Seconds 2
    Assert-FontSmoothingOn
}
function Menu-Individual {
    while ($true) {
        Show-Banner
        Write-Host "  Apply/Disable individually - enter a number to toggle, 0 to go back`n" -ForegroundColor White
        Show-TweakList -Numbered
        $choice = Read-MenuChoice "Enter tweak number (0 = back)"
        if ($choice -eq '0') { return }
        $idCandidate = 0
        if ([int]::TryParse($choice, [ref]$idCandidate) -and $TweakInfo.ContainsKey($idCandidate)) {
            $id = $idCandidate
            Ensure-RestorePoint
            if (Test-TweakApplied $id) {
                Disable-Tweak $id
                Write-PrevLog "Disabled (individual): $($TweakInfo[$id].Name)"
                Write-Host "`nDisabled: $($TweakInfo[$id].Name)" -ForegroundColor Yellow
            } else {
                Enable-Tweak $id
                Write-PrevLog "Applied (individual): $($TweakInfo[$id].Name)"
                Write-Host "`nApplied: $($TweakInfo[$id].Name)" -ForegroundColor Green
            }
            Assert-FontSmoothingOn
            if (Wait-Continue) { return }
        } else { Write-Host "`nInvalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}
function Show-ManagedDiagnostics {
    Show-Banner
    Write-Host "  Checking whether this machine is centrally managed...`n" -ForegroundColor White
    $cs = Get-WmiObject Win32_ComputerSystem
    if ($cs.PartOfDomain) { Write-Host "  Domain-joined: YES ($($cs.Domain))" -ForegroundColor Yellow }
    else { Write-Host "  Domain-joined: No" -ForegroundColor Green }
    try {
        $dsreg = dsregcmd /status 2>$null
        if ($dsreg | Select-String "AzureAdJoined\s*:\s*YES") { Write-Host "  Azure AD joined: YES" -ForegroundColor Yellow }
        $mdmUrl = ($dsreg | Select-String "MdmUrl\s*:")
        if ($mdmUrl -and $mdmUrl -notmatch ':\s*$') { Write-Host "  MDM enrollment detected." -ForegroundColor Yellow }
    } catch {}
    Write-Host "`n  Checking policy keys this tool writes to..." -ForegroundColor White
    foreach ($p in @("HKLM:\SOFTWARE\Policies\Microsoft\Windows\System","HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection","HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot","HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search","HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy","HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity")) {
        Write-Host "  $p : $(if (Test-Path $p) { 'present' } else { 'not present' })"
    }
    Write-Host "`n  For full policy detail: gpresult /h `"$env:USERPROFILE\Desktop\GPReport.html`"" -ForegroundColor Cyan
    Write-Host ""
    Wait-Continue "Press Enter to continue" | Out-Null
}

# ===========================================================
# MAIN MENU
# ===========================================================
Set-ConsoleReadability
Disable-ConsoleQuickEdit
$Global:SysInfo = Get-SystemInfoOnce
Assert-FontSmoothingOn
Register-FontSmoothingEnforcer
Invoke-SearchBoxMigration
Invoke-TelemetryPolicyMigration

try {
    while ($true) {
        Show-Banner -MainMenu
        Write-Host "  Main Menu" -ForegroundColor White
        Write-Host "  ---------" -ForegroundColor White
        Write-Host "  1. Apply All (base tweaks)"
        Write-Host "  2. Apply 4GB RAM tweaks (base + RAM tier)"
        Write-Host "  3. Disable All Applied"
        Write-Host "  4. Show currently applied / not applied"
        Write-Host "  5. Apply/Disable individually"
        Write-Host "  6. Diagnose 'managed by your organization' settings"
        Write-Host "  7. Restore to a previous save point"
        Write-Host "  8. Additional tweaks (optional)"
        Write-Host "  9. Install Windows Apps"
        Write-Host "  D. Diagnostics and Repair (Memory, Disk, SFC, DISM)"
        Write-Host "  0. Exit"
        Write-Host ""
        $sel = Read-MenuChoice "Select an option"
        switch ($sel) {
            '1' { Apply-AllBase; Wait-Continue "`nPress Enter to continue" | Out-Null }
            '2' { Apply-All4GB;  Wait-Continue "`nPress Enter to continue" | Out-Null }
            '3' { Disable-AllApplied; Wait-Continue "`nPress Enter to continue" | Out-Null }
            '4' { Show-Banner; Show-TweakList; Wait-Continue "Press Enter to continue" | Out-Null }
            '5' { Menu-Individual }
            '6' { Show-ManagedDiagnostics }
            '7' { Menu-Restore }
            '8' { Menu-AdditionalTweaks }
            '9' { Menu-InstallApps }
            'D' { Menu-Diagnostics }
            'd' { Menu-Diagnostics }
            '0' {
                Stop-Transcript | Out-Null
                Write-Host "`nExiting..." -ForegroundColor DarkGray
                Start-Sleep -Milliseconds 400
                Stop-Process -Id $PID -Force
            }
            default { }
        }
    }
} catch {
    Write-Host "`nAn unexpected error occurred:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Read-Host "Press Enter to close"
}
