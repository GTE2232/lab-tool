# =========================================================== 
# UIT-63 - FDIV Edition | PC Fallback Optimizer made by shivansh 
# =========================================================== 
# Target: Windows 10, low-RAM education lab machines (i5 2nd gen / 4GB DDR3 1600MHz / mechanical HDD) 
# Rename the tool by editing $ToolName / $Author below. 
#>

$ToolName = "UIT-63 - FDIV Edition"
$Author   = "shivansh"

# If you deploy this via:  irm https://your-host/UIT-63-FDIV.ps1 | iex
# set this to that exact raw URL. It's needed because a script run through
# "irm | iex" has no file on disk, so self-elevation can't just relaunch a
# file path - it needs to re-download and re-run itself in the new window.
$ScriptUrl = "PUT_YOUR_RAW_SCRIPT_URL_HERE"

# ---- Self-elevate if not running as Administrator ----
# (Right-click "Run with PowerShell" does NOT run elevated, and closes the
#  window the instant the script exits/errors - this reopens an elevated
#  window that stays open with -NoExit, and shows the UAC prompt for you.)
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
    try {
        if ($PSCommandPath) {
            Start-Process powershell.exe -ArgumentList @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") -Verb RunAs
        } elseif ($ScriptUrl -and $ScriptUrl -notmatch 'PUT_YOUR_RAW_SCRIPT_URL_HERE') {
            # Running via "irm <url> | iex" - no file path exists, so re-fetch and re-run in the elevated window
            $cmd = "irm '$ScriptUrl' | iex"
            Start-Process powershell.exe -ArgumentList @('-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) -Verb RunAs
        } else {
            Write-Host "Could not determine how to relaunch elevated (no file path, and `$ScriptUrl is not set)." -ForegroundColor Red
            Write-Host "Fix: either save this as a .ps1 file and run it directly, or set `$ScriptUrl at the top of the script to your hosted raw URL, or open PowerShell as Administrator yourself first and then run: irm <url> | iex" -ForegroundColor Red
            Read-Host "Press Enter to close"
            exit
        }
    } catch {
        Write-Host "Elevation was cancelled or failed. Right-click and choose 'Run as administrator', or run PowerShell as Administrator first." -ForegroundColor Red
        Read-Host "Press Enter to close"
    }
    exit
}

$ErrorActionPreference = 'SilentlyContinue'
$LogFile = "$env:USERPROFILE\Desktop\UIT63-EduBoost-Log.txt"
Start-Transcript -Path $LogFile -Append | Out-Null

# ---- History log of what was applied/disabled and when ----
$PrevLog = "$env:USERPROFILE\Desktop\prev.txt"
function Write-PrevLog($line) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $PrevLog -Value "[$timestamp] $line"
}

# ---- Save points (like a game save) - full tweak state snapshots taken
# after every bulk action, so you can jump back to exactly how things were ----
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
    if (Test-Path $Path) {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    }
}

function Set-SvcState($Name, [bool]$Disable) {
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $s) { return }
    try {
        if ($Disable) {
            if ($s.Status -ne 'Stopped') {
                Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
            }
            Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
        } else {
            Set-Service -Name $Name -StartupType Manual -ErrorAction Stop
            Start-Service -Name $Name -ErrorAction SilentlyContinue
        }
    } catch {
        # Set-Service can be blocked by Windows Update / policy locks on some
        # services (DoSvc in particular). Fall back to sc.exe, which sometimes
        # succeeds where Set-Service is denied, and report the real reason either way.
        $mode = if ($Disable) { 'disabled' } else { 'demand' }
        $scOut = sc.exe config $Name start= $mode 2>&1
        if ($scOut -notmatch 'SUCCESS') {
            Write-Host "  Could not change service '$Name': $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
}

function Get-SvcDisabled($Name) {
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($s) { return ($s.StartType -eq 'Disabled') }
    return $false
}

function Get-TaskDisabled($TaskPath, $TaskName) {
    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) { return ($t.State -eq 'Disabled') }
    # If the task doesn't exist on this Windows build, there's nothing to disable -
    # treat that as satisfied rather than permanently "not applied".
    return $true
}

function Set-TaskState($TaskPath, $TaskName, [bool]$Disable) {
    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return }
    try {
        if ($Disable) {
            Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        } else {
            Enable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-Host "  Could not change task '$TaskName': $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

# ---- Global Timer Resolution (Windows 7-style 8ms system tick) ----
# Timer resolution isn't a static registry value - it's held open by a
# running process via the multimedia timer API. Windows auto-reverts it the
# instant that process exits. This writes a small persistent script and runs
# it hidden, both immediately and at every logon, so 8ms stays held for as
# long as the tweak is enabled - killing the process (done on disable)
# releases it automatically, no separate cleanup call needed.
$TimerResDir = "$env:ProgramData\UIT63"
$TimerResScript = "$TimerResDir\TimerResEnforcer.ps1"
$TimerResTask = "UIT63-TimerResolutionEnforcer"

function Install-TimerResolutionEnforcer {
    if (-not (Test-Path $TimerResDir)) { New-Item -Path $TimerResDir -ItemType Directory -Force | Out-Null }
    $body = @'
Add-Type -Namespace UIT63 -Name Winmm -MemberDefinition @"
[DllImport("winmm.dll")]
public static extern uint timeBeginPeriod(uint uMilliseconds);
"@
[UIT63.Winmm]::timeBeginPeriod(8) | Out-Null
while ($true) { Start-Sleep -Seconds 3600 }
'@
    Set-Content -Path $TimerResScript -Value $body -Encoding UTF8

    # Kill any previous instance before starting a fresh one
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match [regex]::Escape($TimerResScript) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-File', "`"$TimerResScript`"")

    try {
        Unregister-ScheduledTask -TaskName $TimerResTask -Confirm:$false -ErrorAction SilentlyContinue
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -File `"$TimerResScript`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        Register-ScheduledTask -TaskName $TimerResTask -Action $action -Trigger $trigger `
            -Description "UIT-63 FDIV: holds an 8ms Windows 7-style global timer resolution" -Force | Out-Null
    } catch {
        Write-Host "  Could not register timer resolution startup task: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Remove-TimerResolutionEnforcer {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match [regex]::Escape($TimerResScript) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    try { Unregister-ScheduledTask -TaskName $TimerResTask -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}

function Test-TimerResolutionEnforcerRunning {
    $running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match [regex]::Escape($TimerResScript) }
    return [bool]$running
}

# P/Invoke for individual visual-effect toggles (SystemParametersInfo)
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
    $uiParam = if ($onOff) { 1 } else { 0 }
    [SPI]::SystemParametersInfo($action, $uiParam, [IntPtr]::Zero, $SPIFLAGS) | Out-Null
}

function Assert-FontSmoothingOn {
    # Standing requirement: smooth edges of screen fonts (ClearType) stays on
    # no matter what - called unconditionally at startup and after any action
    # that could hand effect selection back to Windows' own auto-heuristic.
    try {
        Set-Reg "HKCU:\Control Panel\Desktop" "FontSmoothing" "2" String
        Set-Reg "HKCU:\Control Panel\Desktop" "FontSmoothingType" 2
        Set-SPI 0x004B $true
    } catch {
        Write-Host "  Warning: could not set font smoothing - $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Register-FontSmoothingEnforcer {
    # Font smoothing has been observed reverting between sessions (likely at
    # logon, from a mechanism outside this tool's runtime). Rather than only
    # fixing it while the tool is open, this registers a scheduled task that
    # re-applies it at every logon regardless of whether the tool ever runs again.
    try {
        $taskName = "UIT63-FontSmoothingEnforcer"
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { return }
        $cmd = '-WindowStyle Hidden -NoProfile -Command "Set-ItemProperty -Path ''HKCU:\Control Panel\Desktop'' -Name FontSmoothing -Value ''2''; Set-ItemProperty -Path ''HKCU:\Control Panel\Desktop'' -Name FontSmoothingType -Value 2 -Type DWord"'
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $cmd
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Description "UIT-63 FDIV: keeps ClearType font smoothing on at every logon" -Force | Out-Null
    } catch {
        Write-Host "  Could not register font smoothing enforcer task: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Ensure-Winget {
    if (Test-Path "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe") {
        try {
            winget upgrade *>$null
            if ($LASTEXITCODE -eq 0) { return $true }
        } catch {}
    }
    Write-Host "  Winget not found or not working - attempting to install it..." -ForegroundColor DarkGray
    try {
        $releaseUrl = "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
        $asset = (Invoke-WebRequest -Uri $releaseUrl -UseBasicParsing).Content | ConvertFrom-Json |
            Select-Object -ExpandProperty assets |
            Where-Object { $_.browser_download_url -match '\.msixbundle$' } |
            Select-Object -ExpandProperty browser_download_url -First 1
        if ($asset) {
            $out = "$env:TEMP\winget-setup.msixbundle"
            Invoke-WebRequest -Uri $asset -OutFile $out -UseBasicParsing
            Add-AppxPackage -Path $out -ErrorAction Stop
            Remove-Item $out -ErrorAction SilentlyContinue
            Write-Host "  Winget installed." -ForegroundColor Green
            return $true
        }
    } catch {
        Write-Host "  Could not install winget: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
    return $false
}

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
    "Microsoft.Copilot","Microsoft.MicrosoftStickyNotes","Microsoft.MixedReality.Portal"
)
$XboxServices = @('XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc')

# ===========================================================
# TWEAK CATALOG  (Id -> Name / Tier)
# Tier: Base = always part of "Apply All"; RAM4GB = extra tier
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
    14 = @{ Name = "Diagnostic data - Basic";                     Tier = "Base" }
    15 = @{ Name = "Advertising ID - off";                        Tier = "Base" }
    16 = @{ Name = "Tailored experiences - off";                  Tier = "Base" }
    17 = @{ Name = "Windows Copilot - off";                       Tier = "Base" }
    18 = @{ Name = "Cortana - off";                                Tier = "Base" }
    19 = @{ Name = "Storage Sense - off";                          Tier = "Base" }
    20 = @{ Name = "Memory Integrity / Core Isolation - off";     Tier = "Base" }
    21 = @{ Name = "Background apps - off";                       Tier = "Base" }
    22 = @{ Name = "Power plan - High Performance";               Tier = "Base" }
    23 = @{ Name = "Custom visual effects (fonts/anim/shadow kept)"; Tier = "Base" }
    24 = @{ Name = "Transparency effects - off";                  Tier = "Base" }
    25 = @{ Name = "Explorer thumbnails - off (icons only)";      Tier = "Base" }
    26 = @{ Name = "Hibernation - off";                            Tier = "Base" }
    27 = @{ Name = "Bundled apps removed (Xbox/Teams/Clipchamp/etc)"; Tier = "Base" }
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
    42 = @{ Name = "Global Timer Resolution restored to 8ms (Win7-style)"; Tier = "Base" }
    43 = @{ Name = "Compatibility Appraiser telemetry task - off"; Tier = "Base" }
    44 = @{ Name = "OneDrive uninstalled"; Tier = "Base" }
    45 = @{ Name = "Cloud content search - off"; Tier = "Base" }
    46 = @{ Name = "SafeSearch - off"; Tier = "Base" }
    47 = @{ Name = "Search history - off"; Tier = "Base" }
    48 = @{ Name = "Inking & typing personalization - off"; Tier = "Base" }
    49 = @{ Name = "Locally relevant content via language list - off"; Tier = "Base" }
    50 = @{ Name = "Game Bar - off"; Tier = "Base" }
    51 = @{ Name = "Copilot app - uninstalled"; Tier = "Base" }
    52 = @{ Name = "Cortana leftover shortcuts - cleaned up"; Tier = "Base" }
    53 = @{ Name = "Autocorrect misspelled words - off"; Tier = "Base" }
    54 = @{ Name = "Highlight misspelled words - off"; Tier = "Base" }
    55 = @{ Name = "Show text suggestions - off"; Tier = "Base" }
    56 = @{ Name = "Multitasking (Snap) - off"; Tier = "Base" }
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
        22 { $a = powercfg /getactivescheme; return ($a -match $HighPerfGuid) }
        23 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting") -eq 3 }
        24 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "EnableTransparency") -eq 0 }
        25 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "IconsOnly") -eq 1 }
        26 { return (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\Power" "HibernateEnabled") -eq 0 }
        27 { $present = $false; foreach ($a in $BundledApps) { if (Get-AppxPackage -Name $a -ErrorAction SilentlyContinue) { $present = $true } }; return (-not $present) }
        28 { return Get-SvcDisabled 'PcaSvc' }
        29 { return (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control" "SvcHostSplitThresholdInKB") -eq 0x0F000000 }
        30 { $cs = Get-CimInstance Win32_ComputerSystem; return (-not $cs.AutomaticManagedPagefile) }
        31 {
            $out = fsutil behavior query disablelastaccess 2>$null
            return ($out -match '=\s*1\b')
        }
        32 { return (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\storahci\Parameters" "EnableMSI") -eq 1 }
        33 { return (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "NtfsMftZoneReservation") -eq 2 }
        34 { return (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "NtfsMemoryUsage") -eq 2 }
        35 {
            $out = fsutil behavior query disable8dot3 2>$null
            return ($out -match 'is:\s*1\b')
        }
        36 {
            $p = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
            return (Get-RegValue $p "AllowPrelaunch") -eq 0 -and (Get-RegValue $p "AllowTabPreloading") -eq 0 -and (Get-RegValue $p "StartupBoostEnabled") -eq 0
        }
        37 {
            $regOk = (Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableCdp") -eq 0
            $t1 = Get-TaskDisabled "\Microsoft\Windows\CloudExperienceHost\" "CreateObjectTask"
            $t2 = Get-TaskDisabled "\Microsoft\Windows\Shell\" "CreateObjectTask"
            return $regOk -and $t1 -and $t2
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
        44 { return -not (Test-Path "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") -and -not (Test-Path "$env:SystemRoot\System32\OneDriveSetup.exe") -and -not (Get-Process OneDrive -ErrorAction SilentlyContinue) }
        45 {
            return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsMSACloudSearchEnabled") -eq 0 -and
                   (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsAADCloudSearchEnabled") -eq 0
        }
        46 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SearchSettings" "SafeSearchMode") -eq 0 }
        47 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "IsDeviceSearchHistoryEnabled") -eq 0 }
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
            $present = $false
            foreach ($n in $names) { if (Get-AppxPackage -Name $n -ErrorAction SilentlyContinue) { $present = $true } }
            return (-not $present)
        }
        52 { return -not (Test-Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Cortana.lnk") -and -not (Test-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Cortana.lnk") }
        53 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableAutocorrection") -eq 0 }
        54 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableSpellchecking") -eq 0 }
        55 { return (Get-RegValue "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableTextPrediction") -eq 0 }
        56 { return (Get-RegValue "HKCU:\Control Panel\Desktop" "WindowArrangementActive") -eq "0" }
    }
    return $false
}

# ===========================================================
# APPLY
# ===========================================================
function Enable-Tweak($Id) {
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
        22 { powercfg /setactive SCHEME_MIN }
        23 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" 3
            Set-Reg "HKCU:\Control Panel\Desktop" "FontSmoothing" "2" String
            Set-Reg "HKCU:\Control Panel\Desktop" "FontSmoothingType" 2
            Set-SPI 0x004B $true    # font smoothing
            Set-SPI 0x1043 $true    # animate controls
            Set-SPI 0x1025 $true    # window shadows
            Set-Reg "HKCU:\Control Panel\Desktop\WindowMetrics" "MinAnimate" "0" String
            Set-SPI 0x1003 $false   # menu animation
            Set-SPI 0x1013 $false   # menu fade
            Set-SPI 0x1015 $false   # selection fade
            Set-SPI 0x1005 $false   # combo box animation
            Set-SPI 0x1007 $false   # listbox smooth scroll
            Set-SPI 0x101B $false   # cursor shadow
        }
        24 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "EnableTransparency" 0 }
        25 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "IconsOnly" 1 }
        26 {
            powercfg /hibernate off
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "HiberbootEnabled" 0
        }
        27 {
            foreach ($app in $BundledApps) {
                # Try current-user scope first - this is the method that reliably
                # succeeds (matches the reference script's proven approach).
                # -AllUsers is a stricter operation that fails far more often.
                try {
                    $pkg = Get-AppxPackage -Name $app -ErrorAction SilentlyContinue
                    if ($pkg) { $pkg | Remove-AppxPackage -ErrorAction SilentlyContinue }
                } catch {}

                try {
                    $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $app }
                    if ($prov) { $prov | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null }
                } catch {}

                # Still present? Try -AllUsers scope as a second attempt.
                if (Get-AppxPackage -Name $app -ErrorAction SilentlyContinue) {
                    try {
                        $pkgAll = Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue
                        if ($pkgAll) { $pkgAll | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue }
                    } catch {}
                }

                # Still present after both AppX methods? Fall back to winget,
                # bootstrapping it lazily only if we actually need it.
                if (Get-AppxPackage -Name $app -ErrorAction SilentlyContinue) {
                    if ($null -eq $Global:WingetOk) { $Global:WingetOk = Ensure-Winget }
                    if ($Global:WingetOk) {
                        try {
                            winget uninstall --id $app --silent --disable-interactivity --accept-source-agreements 2>$null 1>$null
                        } catch {}
                    }
                    if (Get-AppxPackage -Name $app -ErrorAction SilentlyContinue) {
                        Write-Host "  Could not remove $app (Windows still won't let go of it) - skipping." -ForegroundColor DarkYellow
                    } else {
                        Write-Host "  Removed $app via winget." -ForegroundColor Green
                    }
                }
            }
        }
        28 { Set-SvcState 'PcaSvc' $true }
        29 { Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control" "SvcHostSplitThresholdInKB" 0x0F000000 }
        30 {
            $cs = Get-WmiObject Win32_ComputerSystem
            $cs.AutomaticManagedPagefile = $false
            $cs.Put() | Out-Null
            $pf = Get-WmiObject Win32_PageFileSetting
            if ($pf) { $pf.InitialSize = 4096; $pf.MaximumSize = 8192; $pf.Put() | Out-Null }
            else { Set-WmiInstance -Class Win32_PageFileSetting -Arguments @{ Name = "$env:SystemDrive\pagefile.sys"; InitialSize = 4096; MaximumSize = 8192 } | Out-Null }
        }
        31 {
            fsutil behavior set disablelastaccess 1 | Out-Null
            Write-Host "  NTFS last-access updates disabled. A reboot is required for this to fully apply." -ForegroundColor Yellow
        }
        32 {
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\storahci\Parameters" "EnableMSI" 1
            Write-Host "  MSI interrupts enabled for AHCI controller. Test on one machine before wide rollout - a reboot is required." -ForegroundColor Yellow
        }
        33 {
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "NtfsMftZoneReservation" 2
            Write-Host "  MFT zone reservation increased. Best suited to drives holding very large numbers of small files - reboot required." -ForegroundColor Yellow
        }
        34 {
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "NtfsMemoryUsage" 2
            Write-Host "  NTFS metadata cache set to maximum. Reboot required." -ForegroundColor Yellow
        }
        35 {
            fsutil behavior set disable8dot3 1 | Out-Null
            Write-Host "  8.3 short filename creation disabled. Speeds up file create/delete in large folders - reboot required." -ForegroundColor Yellow
        }
        36 {
            $p = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
            Set-Reg $p "AllowPrelaunch" 0
            Set-Reg $p "AllowTabPreloading" 0
            Set-Reg $p "StartupBoostEnabled" 0
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
            $paths = @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe")
            Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            foreach ($path in $paths) {
                if (Test-Path $path) {
                    try { Start-Process $path -ArgumentList "/uninstall" -Wait -ErrorAction Stop }
                    catch { Write-Host "  OneDrive uninstall failed: $($_.Exception.Message)" -ForegroundColor DarkYellow }
                }
            }
        }
        45 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsMSACloudSearchEnabled" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsAADCloudSearchEnabled" 0
        }
        46 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SearchSettings" "SafeSearchMode" 0 }
        47 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "IsDeviceSearchHistoryEnabled" 0 }
        48 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\InputPersonalization" "RestrictImplicitInkCollection" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\InputPersonalization" "RestrictImplicitTextCollection" 1
        }
        49 { Set-Reg "HKCU:\Control Panel\International\User Profile" "HttpAcceptLanguageOptOut" 1 }
        50 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" 0
            Set-Reg "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" 0
        }
        51 {
            $names = @("Microsoft.Copilot", "Microsoft.Windows.Copilot", "MicrosoftWindows.Client.CoPilot")
            foreach ($n in $names) {
                try {
                    $pkg = Get-AppxPackage -Name $n -ErrorAction SilentlyContinue
                    if ($pkg) { $pkg | Remove-AppxPackage -ErrorAction SilentlyContinue }
                } catch {}
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
                Write-Host "  Copilot could not be fully removed via AppX cmdlets - on some Windows 11 builds it is a" -ForegroundColor DarkYellow
                Write-Host "  protected inbox component rather than a normal removable app. The taskbar button and" -ForegroundColor DarkYellow
                Write-Host "  policy access have still been disabled above." -ForegroundColor DarkYellow
            }
        }
        52 {
            $links = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Cortana.lnk", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Cortana.lnk")
            foreach ($link in $links) { if (Test-Path $link) { Remove-Item $link -Force -ErrorAction SilentlyContinue } }
        }
        53 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableAutocorrection" 0 }
        54 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableSpellchecking" 0 }
        55 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableTextPrediction" 0 }
        56 {
            Set-Reg "HKCU:\Control Panel\Desktop" "WindowArrangementActive" "0" String
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SnapAssist" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SnapFill" 0
        }
    }
}

# ===========================================================
# DISABLE / REVERT
# ===========================================================
function Disable-Tweak($Id) {
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
        14 { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 3 }
        15 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 1 }
        16 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled" 1 }
        17 { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 0 }
        18 {
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCortana" 1
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "DisableWebSearch" 0
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchUseWeb" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "BingSearchEnabled" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "CortanaConsent" 1
        }
        19 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" "01" 1 }
        20 { Set-Reg $hvciPath "Enabled" 1 }
        21 { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" "LetAppsRunInBackground" 0 }
        22 { powercfg /setactive SCHEME_BALANCED }
        23 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" 0
            Set-Reg "HKCU:\Control Panel\Desktop\WindowMetrics" "MinAnimate" "1" String
            Set-SPI 0x1003 $true
            Set-SPI 0x1013 $true
            Set-SPI 0x1015 $true
            Set-SPI 0x1005 $true
            Set-SPI 0x1007 $true
            Set-SPI 0x101B $true
            # VisualFXSetting=0 hands effect selection to Windows' own auto-heuristic,
            # which can decide to turn font smoothing off on low-spec hardware. Force
            # it back on explicitly so it's never left to that heuristic.
            Assert-FontSmoothingOn
        }
        24 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "EnableTransparency" 1 }
        25 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "IconsOnly" 0 }
        26 {
            powercfg /hibernate on
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "HiberbootEnabled" 1
        }
        27 { Write-Host "  App removal cannot be auto-reversed - reinstall from Microsoft Store if needed." -ForegroundColor Yellow }
        28 { Set-SvcState 'PcaSvc' $false }
        29 { Remove-Reg "HKLM:\SYSTEM\CurrentControlSet\Control" "SvcHostSplitThresholdInKB" }
        30 {
            $cs = Get-WmiObject Win32_ComputerSystem
            $cs.AutomaticManagedPagefile = $true
            $cs.Put() | Out-Null
        }
        31 {
            fsutil behavior set disablelastaccess 0 | Out-Null
            Write-Host "  NTFS last-access updates re-enabled. A reboot is required for this to fully apply." -ForegroundColor Yellow
        }
        32 {
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\storahci\Parameters" "EnableMSI" 0
            Write-Host "  MSI interrupts disabled (back to line-based interrupts). Reboot required." -ForegroundColor Yellow
        }
        33 {
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "NtfsMftZoneReservation" 1
            Write-Host "  MFT zone reservation reverted to default. Reboot required." -ForegroundColor Yellow
        }
        34 {
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "NtfsMemoryUsage" 0
            Write-Host "  NTFS metadata cache reverted to default. Reboot required." -ForegroundColor Yellow
        }
        35 {
            fsutil behavior set disable8dot3 0 | Out-Null
            Write-Host "  8.3 short filename creation re-enabled. Reboot required." -ForegroundColor Yellow
        }
        36 {
            $p = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
            Remove-Reg $p "AllowPrelaunch"
            Remove-Reg $p "AllowTabPreloading"
            Remove-Reg $p "StartupBoostEnabled"
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
            Write-Host "  Global timer resolution override removed - back to Windows 10/11 default per-process behavior." -ForegroundColor Green
        }
        43 { Set-TaskState "\Microsoft\Windows\Application Experience\" "Microsoft Compatibility Appraiser" $false }
        44 { Write-Host "  OneDrive removal cannot be auto-reversed - reinstall from https://www.microsoft.com/microsoft-365/onedrive/download if needed." -ForegroundColor Yellow }
        45 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsMSACloudSearchEnabled" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" "IsAADCloudSearchEnabled" 1
        }
        46 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SearchSettings" "SafeSearchMode" 1 }
        47 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "IsDeviceSearchHistoryEnabled" 1 }
        48 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\InputPersonalization" "RestrictImplicitInkCollection" 0
            Set-Reg "HKCU:\SOFTWARE\Microsoft\InputPersonalization" "RestrictImplicitTextCollection" 0
        }
        49 { Set-Reg "HKCU:\Control Panel\International\User Profile" "HttpAcceptLanguageOptOut" 0 }
        50 {
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" 1
            Set-Reg "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 1
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" 1
        }
        51 { Write-Host "  Copilot removal cannot be auto-reversed - reinstall from Microsoft Store if needed." -ForegroundColor Yellow }
        52 { Write-Host "  Shortcut cleanup cannot be auto-reversed - this is cosmetic only, no functionality is lost either way." -ForegroundColor Yellow }
        53 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableAutocorrection" 1 }
        54 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableSpellchecking" 1 }
        55 { Set-Reg "HKCU:\SOFTWARE\Microsoft\Input\Settings" "EnableTextPrediction" 1 }
        56 {
            Set-Reg "HKCU:\Control Panel\Desktop" "WindowArrangementActive" "1" String
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SnapAssist" 1
            Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SnapFill" 1
        }
    }
}

# ===========================================================
# UI
# ===========================================================
# ---- Make the console bigger and easier to read ----
function Set-ConsoleReadability {
    try {
        $Host.UI.RawUI.WindowTitle = "UIT-63 FDIV Console"
    } catch {}
    try {
        # Only widen the buffer for long lines - window size/position is left
        # as whatever the host opened with.
        $ui = $Host.UI.RawUI
        $ui.BufferSize = New-Object System.Management.Automation.Host.Size(130, 3000)
    } catch {}

    # Bump the font size up by exactly 1 from whatever it currently is,
    # rather than jumping to a fixed size.
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ConsoleFontHelper {
    [StructLayout(LayoutKind.Sequential)]
    public struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CONSOLE_FONT_INFO_EX {
        public uint cbSize;
        public uint nFont;
        public COORD dwFontSize;
        public int FontFamily;
        public int FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string FaceName;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetCurrentConsoleFontEx(IntPtr consoleOutput, bool maximumWindow, ref CONSOLE_FONT_INFO_EX consoleCurrentFontEx);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetCurrentConsoleFontEx(IntPtr consoleOutput, bool maximumWindow, ref CONSOLE_FONT_INFO_EX consoleCurrentFontEx);
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

# ---- System info, gathered once at startup (cheap to cache on slow HDDs) ----
function Get-SystemInfoOnce {
    $result = [PSCustomObject]@{
        OS          = "Unknown"
        CPU         = "Unknown"
        Cores       = "Unknown"
        RAM         = "Unknown"
        Motherboard = "Unknown"
        BIOS        = "Unknown"
    }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) { $result.OS = "$($os.Caption) (Build $($os.BuildNumber), $($os.OSArchitecture))" }
    } catch {}
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cpu) {
            $result.CPU = "$($cpu.Name)".Trim()
            $result.Cores = "$($cpu.NumberOfCores)C / $($cpu.NumberOfLogicalProcessors)T"
        }
    } catch {}
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs) { $result.RAM = "$([math]::Round($cs.TotalPhysicalMemory / 1GB, 2)) GB" }
    } catch {}
    try {
        $bb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
        if ($bb) { $result.Motherboard = "$($bb.Manufacturer) $($bb.Product)".Trim() }
    } catch {}
    try {
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        if ($bios) { $result.BIOS = "$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)".Trim() }
    } catch {}
    return $result
}

function Center-Text($text, $width) {
    $pad = [Math]::Max(0, $width - $text.Length)
    $left = [Math]::Floor($pad / 2)
    $right = $pad - $left
    return (" " * $left) + $text + (" " * $right)
}

function Show-Banner {
    param([switch]$MainMenu)
    Clear-Host
    $boxWidth = 53
    $top = "  +" + ("-" * $boxWidth) + "+"
    $bot = $top
    Write-Host ""
    Write-Host $top -ForegroundColor Cyan
    Write-Host ("  |" + (Center-Text "UIT-63 - FDIV Edition | Lab PC Optimizer" $boxWidth) + "|") -ForegroundColor White
    Write-Host $bot -ForegroundColor Cyan
    Write-Host (" " + (Center-Text "made by shivansh" ($boxWidth + 4))) -ForegroundColor DarkGray
    Write-Host ""

    if ($MainMenu -and $null -ne $Global:SysInfo) {
        Write-Host "  System Info" -ForegroundColor White
        Write-Host "  -----------" -ForegroundColor White
        Write-Host ("    OS           : {0}" -f $Global:SysInfo.OS)
        Write-Host ("    Processor    : {0}" -f $Global:SysInfo.CPU)
        Write-Host ("    Cores        : {0}" -f $Global:SysInfo.Cores)
        Write-Host ("    RAM          : {0}" -f $Global:SysInfo.RAM)
        Write-Host ("    Motherboard  : {0}" -f $Global:SysInfo.Motherboard)
        Write-Host ("    BIOS         : {0}" -f $Global:SysInfo.BIOS)
        Write-Host ""
    }

    if (Test-Path $PrevLog) {
        $lastLine = Get-Content $PrevLog -Tail 1 -ErrorAction SilentlyContinue
        if ($lastLine) {
            Write-Host "  Last activity:" -ForegroundColor DarkGray
            Write-Host "    $lastLine" -ForegroundColor DarkGray
            Write-Host ""
        }
    }
}

function Show-TweakList {
    param([switch]$Numbered)
    $ids = $TweakInfo.Keys | Sort-Object
    $currentTier = ""
    foreach ($id in $ids) {
        $info = $TweakInfo[$id]
        if ($info.Tier -ne $currentTier) {
            $currentTier = $info.Tier
            $label = if ($currentTier -eq 'Base') { "-- Base tweaks --" } else { "-- 4GB RAM tweaks --" }
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
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $states = ($TweakInfo.Keys | Sort-Object | ForEach-Object {
            "$_=$(if (Test-TweakApplied $_) { 1 } else { 0 })"
        }) -join ';'
        Add-Content -Path $SnapshotFile -Value "$timestamp|$label|$states"
    } catch {}
}

function Get-Snapshots {
    if (-not (Test-Path $SnapshotFile)) { return @() }
    return Get-Content $SnapshotFile | Where-Object { $_ -match '\|' }
}

function Register-PhotoViewerApplication {
    # This registers Windows Photo Viewer as an actual selectable Application
    # (HKCR\Applications\photoviewer.dll) - without this, it may not appear as
    # a choice at all on some Windows 10 builds, even though its file
    # association ProgIDs already exist. This is separate from - and a
    # prerequisite for - the default-association step that follows.
    if (-not (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -Scope Script | Out-Null
    }
    $cmd = '%SystemRoot%\System32\rundll32.exe "%ProgramFiles%\Windows Photo Viewer\PhotoViewer.dll", ImageView_Fullscreen %1'

    New-Item -Path "HKCR:\Applications\photoviewer.dll\shell\open\command" -Force | Out-Null
    New-Item -Path "HKCR:\Applications\photoviewer.dll\shell\open\DropTarget" -Force | Out-Null
    New-Item -Path "HKCR:\Applications\photoviewer.dll\shell\print\command" -Force | Out-Null
    New-Item -Path "HKCR:\Applications\photoviewer.dll\shell\print\DropTarget" -Force | Out-Null

    New-ItemProperty -Path "HKCR:\Applications\photoviewer.dll\shell\open" -Name "MuiVerb" -Value "@photoviewer.dll,-3043" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path "HKCR:\Applications\photoviewer.dll\shell\open\command" -Name "(Default)" -Value $cmd -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty -Path "HKCR:\Applications\photoviewer.dll\shell\open\DropTarget" -Name "Clsid" -Value "{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path "HKCR:\Applications\photoviewer.dll\shell\print\command" -Name "(Default)" -Value $cmd -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty -Path "HKCR:\Applications\photoviewer.dll\shell\print\DropTarget" -Name "Clsid" -Value "{60fd46de-f830-4894-a628-6fa81bc0190d}" -PropertyType String -Force | Out-Null
}

function Set-PhotoViewerDefault {
    # Diagnose the two most likely reasons this fails outright, before
    # attempting anything, so the failure reason is visible rather than silent.
    $dllPath = "$env:ProgramFiles\Windows Photo Viewer\PhotoViewer.dll"
    if (-not (Test-Path $dllPath)) {
        Write-Host "  PROBLEM FOUND: $dllPath does not exist on this machine." -ForegroundColor Red
        Write-Host "  Windows Photo Viewer's own program files were never installed or were" -ForegroundColor Red
        Write-Host "  removed from this Windows image. Registering it as default is pointless" -ForegroundColor Red
        Write-Host "  if the file it points to doesn't exist - nothing will actually open." -ForegroundColor Red
        Write-Host "  This is a per-machine Windows image issue, not something this script can fix." -ForegroundColor Red
        return
    }

    try {
        $edition = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    } catch { $edition = "" }
    if ($edition -match "Home") {
        Write-Host "  Note: this is Windows 10 Home. The Group Policy mechanism used to force" -ForegroundColor Yellow
        Write-Host "  a default app on an existing profile is only reliably processed on" -ForegroundColor Yellow
        Write-Host "  Pro/Education/Enterprise editions - Home edition often ignores it entirely." -ForegroundColor Yellow
        Write-Host "  Proceeding anyway, but if it doesn't take effect after a logoff/logon," -ForegroundColor Yellow
        Write-Host "  that's why - the manual Settings > Default Apps method is the only" -ForegroundColor Yellow
        Write-Host "  guaranteed-to-work path on Home edition." -ForegroundColor Yellow
    }

    Register-PhotoViewerApplication

    # The GPO-driven "default associations configuration file" mechanism -
    # this re-applies at every logon via the policy engine, which is the
    # one channel that actually overrides an EXISTING user's default app
    # choice (the one-shot DISM import only reliably works for brand-new
    # profiles since Windows 10 1809, by design - it won't touch this profile).
    $configDir = "$env:ProgramData\UIT63"
    $xmlPath = "$configDir\DefaultAppAssociations.xml"
    $backupPath = "$env:USERPROFILE\Desktop\UIT63-DefaultPhotoApp-Backup.xml"

    if (-not (Test-Path $backupPath)) {
        try { dism /Online /Export-DefaultAppAssociations:"$backupPath" | Out-Null } catch {}
    }
    if (-not (Test-Path $configDir)) { New-Item -Path $configDir -ItemType Directory -Force | Out-Null }

    $exts = @(".bmp", ".dib", ".gif", ".jfif", ".jpe", ".jpeg", ".jpg", ".jxr", ".png", ".tif", ".tiff", ".wdp")
    $lines = foreach ($e in $exts) {
        $progid = if ($e -in @(".bmp", ".dib")) { "PhotoViewer.FileAssoc.Bitmap" } else { "PhotoViewer.FileAssoc.Tiff" }
        "  <Association Identifier=`"$e`" ProgId=`"$progid`" ApplicationName=`"Windows Photo Viewer`" />"
    }
    $xml = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n<DefaultAssociations>`n$($lines -join "`n")`n</DefaultAssociations>"
    Set-Content -Path $xmlPath -Value $xml -Encoding UTF8

    # Also try the one-shot DISM import - harmless, and helps on fresh profiles
    try { dism /Online /Import-DefaultAppAssociations:"$xmlPath" 2>$null | Out-Null } catch {}

    # The part that actually sticks on an existing profile: point the policy
    # at our XML so Windows re-applies it every logon.
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "DefaultAssociationsConfiguration" $xmlPath String

    try { gpupdate /target:computer /force *>$null } catch {}

    Write-Host "  Windows Photo Viewer association policy set." -ForegroundColor Green
    Write-Host "  This takes effect at next logon (or run 'gpupdate /force' then log off/on) -" -ForegroundColor Yellow
    Write-Host "  it won't switch instantly like the other tweaks. Log off and back on, then" -ForegroundColor Yellow
    Write-Host "  verify in Settings > Apps > Default Apps." -ForegroundColor Yellow
}

function Restore-PhotosAppDefault {
    # Remove the policy so Windows stops re-forcing Photo Viewer at each logon
    Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "DefaultAssociationsConfiguration"
    try { gpupdate /target:computer /force *>$null } catch {}

    $backupPath = "$env:USERPROFILE\Desktop\UIT63-DefaultPhotoApp-Backup.xml"
    if (Test-Path $backupPath) {
        try { dism /Online /Import-DefaultAppAssociations:"$backupPath" | Out-Null } catch {}
    }
    Write-Host "  Photo Viewer policy removed. Log off and back on for the previous" -ForegroundColor Green
    Write-Host "  default (Photos app) to take effect again." -ForegroundColor Green
}

function Register-DnsEnforcer($Primary, $Secondary, $Label) {
    # DNS settings can be lost across reboots on some hardware (interface
    # index renumbering on driver reinit, or a router/domain policy
    # re-asserting DNS at boot). Rather than diagnose which one applies here,
    # this reapplies the chosen DNS at every startup, running as SYSTEM so it
    # works even before anyone logs in.
    try {
        $taskName = "UIT63-DnsEnforcer"
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        $cmd = "Get-NetAdapter | Where-Object { `$_.Status -eq 'Up' } | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex `$_.IfIndex -ServerAddresses ('$Primary','$Secondary') }"
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -NoProfile -Command `"$cmd`""
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
            -Description "UIT-63 FDIV: keeps DNS set to $Label at every boot" -Force | Out-Null
    } catch {
        Write-Host "  Could not register DNS enforcer task: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Remove-DnsEnforcer {
    try { Unregister-ScheduledTask -TaskName "UIT63-DnsEnforcer" -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}

function Set-DnsProvider($Primary, $Secondary, $Label) {
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
    if (-not $adapters) { Write-Host "  No active network adapter found." -ForegroundColor DarkGray; return }
    foreach ($a in $adapters) {
        try { Set-DnsClientServerAddress -InterfaceIndex $a.IfIndex -ServerAddresses ($Primary, $Secondary) -ErrorAction Stop }
        catch { Write-Host "  Could not set DNS on $($a.Name): $($_.Exception.Message)" -ForegroundColor DarkYellow }
    }
    Register-DnsEnforcer $Primary $Secondary $Label
    Write-Host "  DNS set to $Label ($Primary, $Secondary) on active adapter(s)." -ForegroundColor Green
    Write-Host "  Also registered a startup task to reapply this at every boot, in case it doesn't persist on its own." -ForegroundColor DarkGray
}

function Reset-DnsAutomatic {
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
    if (-not $adapters) { Write-Host "  No active network adapter found." -ForegroundColor DarkGray; return }
    foreach ($a in $adapters) {
        try { Set-DnsClientServerAddress -InterfaceIndex $a.IfIndex -ResetServerAddresses -ErrorAction Stop }
        catch { Write-Host "  Could not reset DNS on $($a.Name): $($_.Exception.Message)" -ForegroundColor DarkYellow }
    }
    Remove-DnsEnforcer
    Write-Host "  DNS reset to automatic (DHCP) on active adapter(s)." -ForegroundColor Green
}

function Set-MacRandomization([bool]$Enable) {
    $wifiAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -match '802\.11' -or $_.MediaType -match '802\.11' }
    if (-not $wifiAdapters) {
        Write-Host "  No Wi-Fi adapter found on this machine - nothing to change." -ForegroundColor DarkGray
        return
    }
    $val = if ($Enable) { "Enabled" } else { "Disabled" }
    foreach ($a in $wifiAdapters) {
        try {
            Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName "Random MAC Address" -DisplayValue $val -ErrorAction Stop
            Write-Host "  MAC randomization $val on $($a.Name)." -ForegroundColor Green
        } catch {
            Write-Host "  Could not set MAC randomization on $($a.Name) - this control is driver-dependent and not present on all Wi-Fi adapters." -ForegroundColor DarkYellow
            Write-Host "  Verify/set manually: Settings > Network & Internet > Wi-Fi > Hardware properties." -ForegroundColor DarkYellow
        }
    }
}

function Install-SingleApp($app) {
    if (Get-AppxPackage -Name $app -ErrorAction SilentlyContinue) {
        Write-Host "  $app is already installed." -ForegroundColor Yellow
        return
    }
    if ($null -eq $Global:WingetOk) { $Global:WingetOk = Ensure-Winget }
    if ($Global:WingetOk) {
        Write-Host "  Installing $app via winget (Microsoft Store source)..." -ForegroundColor Cyan
        try {
            winget install --id $app --source msstore --silent --accept-package-agreements --accept-source-agreements 2>$null 1>$null
        } catch {}
        if (Get-AppxPackage -Name $app -ErrorAction SilentlyContinue) {
            Write-Host "  Installed $app." -ForegroundColor Green
            Write-PrevLog "Reinstalled: $app"
        } else {
            Write-Host "  Could not install $app automatically - it may not be in the Store catalog under that ID." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  Winget isn't available - open the Microsoft Store app and search for $app manually." -ForegroundColor Yellow
    }
}

function Menu-InstallApps {
    while ($true) {
        Show-Banner
        Write-Host "  Install Windows Apps (apps this tool can remove)" -ForegroundColor White
        Write-Host "  ----------------------------------------------------" -ForegroundColor White
        Write-Host ""
        $sorted = $BundledApps | Sort-Object
        $num = 1
        $lookup = @{}
        foreach ($app in $sorted) {
            $installed = [bool](Get-AppxPackage -Name $app -ErrorAction SilentlyContinue)
            $tag = if ($installed) { "[INSTALLED]" } else { "[NOT INSTALLED]" }
            $color = if ($installed) { "Green" } else { "DarkGray" }
            Write-Host ("  {0,3}. {1,-40} {2}" -f $num, $app, $tag) -ForegroundColor $color
            $lookup[$num] = $app
            $num++
        }
        Write-Host ""
        Write-Host "  A. Install ALL not-installed apps in this list"
        Write-Host "  0. Back to main menu"
        Write-Host ""
        Write-Host "  Reinstall attempts via winget + Microsoft Store - success depends on" -ForegroundColor DarkGray
        Write-Host "  whether that app is still listed there. If it fails, search the Store" -ForegroundColor DarkGray
        Write-Host "  app manually for the app name as a fallback." -ForegroundColor DarkGray
        Write-Host ""
        $choice = Read-Host "Enter a number, A for all, or 0 to go back"
        if ($choice -eq '0') { return }

        if ($choice -match '^[Aa]$') {
            $toInstall = $sorted | Where-Object { -not (Get-AppxPackage -Name $_ -ErrorAction SilentlyContinue) }
            if ($toInstall.Count -eq 0) {
                Write-Host "`nEverything in this list is already installed." -ForegroundColor Yellow
            } else {
                Write-Host "`nInstalling $($toInstall.Count) app(s)..." -ForegroundColor Cyan
                foreach ($app in $toInstall) { Install-SingleApp $app }
                Write-Host "`nDone." -ForegroundColor Green
            }
            Read-Host "`nPress Enter to continue"
            continue
        }

        $idNum = 0
        if (-not ([int]::TryParse($choice, [ref]$idNum)) -or -not $lookup.ContainsKey($idNum)) {
            Write-Host "`nInvalid choice." -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }
        Write-Host ""
        Install-SingleApp $lookup[$idNum]
        Read-Host "`nPress Enter to continue"
    }
}

function Menu-AdditionalTweaks {
    while ($true) {
        Show-Banner
        Write-Host "  Additional Tweaks (optional, applied individually)" -ForegroundColor White
        Write-Host "  ----------------------------------------------------" -ForegroundColor White
        Write-Host "  1. Restore Windows Photo Viewer and set as default"
        Write-Host "  2. Revert - restore Photos app as default"
        Write-Host "  3. Set DNS to Google (8.8.8.8 / 8.8.4.4)"
        Write-Host "  4. Set DNS to Cloudflare (1.1.1.1 / 1.0.0.1)"
        Write-Host "  5. Reset DNS to automatic (DHCP)"
        Write-Host "  6. Enable MAC address randomization (Wi-Fi)"
        Write-Host "  7. Disable MAC address randomization (Wi-Fi)"
        Write-Host "  0. Back to main menu"
        Write-Host ""
        $sel = Read-Host "Select an option"
        Write-Host ""
        switch ($sel) {
            '1' {
                Set-PhotoViewerDefault
                Write-PrevLog "Additional: Photo Viewer set as default"
                Write-Host ""
                Write-Host "  Honest limitation: Windows won't let ANY script (this one or DISM/GPO" -ForegroundColor Yellow
                Write-Host "  directly) override an already-established default on an existing profile" -ForegroundColor Yellow
                Write-Host "  - that protection is intentional. Photo Viewer is now registered and" -ForegroundColor Yellow
                Write-Host "  available to pick, but the final selection needs one manual step." -ForegroundColor Yellow
                Write-Host ""
                $open = Read-Host "Open Settings > Default Apps now to pick it? (Y/N)"
                if ($open -match '^[Yy]') {
                    Start-Process "ms-settings:defaultapps"
                    Write-Host "  In Settings, search 'Windows Photo Viewer' or set it per image type (.jpg, .png, etc)." -ForegroundColor Cyan
                }
            }
            '2' {
                Restore-PhotosAppDefault
                Write-PrevLog "Additional: Photos app default restored"
                Write-Host ""
                $open = Read-Host "Open Settings > Default Apps now to pick Photos? (Y/N)"
                if ($open -match '^[Yy]') {
                    Start-Process "ms-settings:defaultapps"
                }
            }
            '3' { Set-DnsProvider "8.8.8.8" "8.8.4.4" "Google"; Write-PrevLog "Additional: DNS set to Google" }
            '4' { Set-DnsProvider "1.1.1.1" "1.0.0.1" "Cloudflare"; Write-PrevLog "Additional: DNS set to Cloudflare" }
            '5' { Reset-DnsAutomatic; Write-PrevLog "Additional: DNS reset to automatic" }
            '6' { Set-MacRandomization $true; Write-PrevLog "Additional: MAC randomization enabled" }
            '7' { Set-MacRandomization $false; Write-PrevLog "Additional: MAC randomization disabled" }
            '0' { return }
            default { continue }
        }
        Read-Host "`nPress Enter to continue"
    }
}

function Menu-Restore {
    while ($true) {
        Show-Banner
        Write-Host "  Restore to a Save Point" -ForegroundColor White
        Write-Host "  ------------------------" -ForegroundColor White
        $snapshots = Get-Snapshots
        if ($snapshots.Count -eq 0) {
            Write-Host "`n  No save points yet. Run Apply All, Apply 4GB, or Disable All" -ForegroundColor DarkGray
            Write-Host "  at least once - a save point is created automatically each time." -ForegroundColor DarkGray
            Write-Host ""
            Read-Host "Press Enter to go back"
            return
        }

        # Show most recent first
        $indexed = @()
        for ($i = 0; $i -lt $snapshots.Count; $i++) { $indexed += , @($i, $snapshots[$i]) }
        $indexed = $indexed | Sort-Object { $_[0] } -Descending

        Write-Host ""
        $displayNum = 1
        $lookup = @{}
        foreach ($entry in $indexed) {
            $parts = $entry[1] -split '\|', 3
            if ($parts.Count -lt 3) { continue }
            Write-Host ("  {0,3}. {1}  -  {2}" -f $displayNum, $parts[0], $parts[1])
            $lookup[$displayNum] = $parts[2]
            $displayNum++
        }
        Write-Host ""
        $choice = Read-Host "Enter a save point number to restore to (0 = back to main menu)"
        if ($choice -eq '0') { return }

        $idNum = 0
        if (-not ([int]::TryParse($choice, [ref]$idNum)) -or -not $lookup.ContainsKey($idNum)) {
            Write-Host "`nInvalid choice." -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }

        $stateString = $lookup[$idNum]
        $desired = @{}
        foreach ($pair in ($stateString -split ';')) {
            if ($pair -match '^(\d+)=(\d)$') { $desired[[int]$Matches[1]] = [int]$Matches[2] }
        }

        Write-Host "`nRestoring to that save point..." -ForegroundColor Cyan
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
        Read-Host "Press Enter to continue"
        return
    }
}

function Ensure-RestorePoint {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "UIT63-EduBoost" -RestorePointType "MODIFY_SETTINGS" -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    } catch {}
}

function Apply-AllBase {
    Ensure-RestorePoint
    Write-Host "`nApplying base tweaks..." -ForegroundColor Cyan
    Write-PrevLog "=== Apply All (base tweaks) started ==="
    foreach ($id in ($TweakInfo.Keys | Where-Object { $TweakInfo[$_].Tier -eq 'Base' } | Sort-Object)) {
        if (Test-TweakApplied $id) { continue }
        try {
            Enable-Tweak $id
            Write-PrevLog "Applied: $($TweakInfo[$id].Name)"
        } catch {
            Write-Host "  Failed: $($TweakInfo[$id].Name) - $($_.Exception.Message)" -ForegroundColor Red
            Write-PrevLog "FAILED: $($TweakInfo[$id].Name) - $($_.Exception.Message)"
        }
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
        try {
            Enable-Tweak $id
            Write-PrevLog "Applied: $($TweakInfo[$id].Name)"
        } catch {
            Write-Host "  Failed: $($TweakInfo[$id].Name) - $($_.Exception.Message)" -ForegroundColor Red
            Write-PrevLog "FAILED: $($TweakInfo[$id].Name) - $($_.Exception.Message)"
        }
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
            try {
                Disable-Tweak $id
                Write-PrevLog "Disabled: $($TweakInfo[$id].Name)"
            } catch {
                Write-Host "  Failed to disable: $($TweakInfo[$id].Name) - $($_.Exception.Message)" -ForegroundColor Red
                Write-PrevLog "FAILED to disable: $($TweakInfo[$id].Name) - $($_.Exception.Message)"
            }
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
        $choice = Read-Host "Enter tweak number (0 = back to main menu)"
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
            Start-Sleep -Seconds 1
        } else {
            Write-Host "`nInvalid choice." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}

function Show-ManagedDiagnostics {
    Show-Banner
    Write-Host "  Checking whether this machine is centrally managed...`n" -ForegroundColor White

    $cs = Get-WmiObject Win32_ComputerSystem
    if ($cs.PartOfDomain) {
        Write-Host "  Domain-joined: YES ($($cs.Domain))" -ForegroundColor Yellow
        Write-Host "  This machine can receive Group Policy from a domain controller." -ForegroundColor Yellow
    } else {
        Write-Host "  Domain-joined: No" -ForegroundColor Green
    }

    try {
        $dsreg = dsregcmd /status 2>$null
        $azureJoined = ($dsreg | Select-String "AzureAdJoined\s*:\s*YES")
        $mdmUrl      = ($dsreg | Select-String "MdmUrl\s*:")
        if ($azureJoined) { Write-Host "  Azure AD joined: YES" -ForegroundColor Yellow }
        if ($mdmUrl -and $mdmUrl -notmatch ':\s*$') { Write-Host "  MDM enrollment detected (Intune or similar)." -ForegroundColor Yellow }
    } catch {}

    Write-Host "`n  Checking the specific policy keys this tool writes to..." -ForegroundColor White
    $policyPaths = @(
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy",
        "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
    )
    foreach ($p in $policyPaths) {
        $exists = Test-Path $p
        $tag = if ($exists) { "present" } else { "not present" }
        Write-Host "  $p : $tag"
    }

    Write-Host "`n  For the full picture of which Group Policies are applying and from" -ForegroundColor White
    Write-Host "  where, run this in an elevated PowerShell window and open the report:" -ForegroundColor White
    Write-Host "    gpresult /h `"$env:USERPROFILE\Desktop\GPReport.html`"" -ForegroundColor Cyan
    Write-Host ""
    Read-Host "Press Enter to continue"
}

# ===========================================================
# MAIN MENU
# ===========================================================
Set-ConsoleReadability
$Global:SysInfo = Get-SystemInfoOnce
Assert-FontSmoothingOn
Register-FontSmoothingEnforcer

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
        Write-Host "  0. Exit"
        Write-Host ""
        $sel = Read-Host "Select an option"

        switch ($sel) {
            '1' { Apply-AllBase; Read-Host "`nPress Enter to continue" | Out-Null }
            '2' { Apply-All4GB;  Read-Host "`nPress Enter to continue" | Out-Null }
            '3' { Disable-AllApplied; Read-Host "`nPress Enter to continue" | Out-Null }
            '4' { Show-Banner; Show-TweakList; Read-Host "Press Enter to continue" | Out-Null }
            '5' { Menu-Individual }
            '6' { Show-ManagedDiagnostics }
            '7' { Menu-Restore }
            '8' { Menu-AdditionalTweaks }
            '9' { Menu-InstallApps }
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
