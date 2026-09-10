# diag_windows_edl.ps1 — check if EDL 9008 is usable on Windows
#
# Background: PICO 4 (SM8650 / kona) EDL mode enumerates as USB VID:PID 05c6:9008
# (Qualcomm 9008, "Android Bootloader"). On a stock Windows install this is
# either not seen at all or it shows up under the wrong INF. The device stays
# silent unless the port is bound to a USB driver that speaks the QDL/9008
# protocol. WinUSB is the one that works without any extra drivers.
#
# What this script does:
#   1. List any EDL-class device currently attached (by VID:PID).
#   2. Report which driver is bound to it.
#   3. Tell you whether you can proceed (WinUSB) or need to switch.
#
# Requirements: run as Administrator. Tested on Windows 10 22H2 and 11.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\diag_windows_edl.ps1
#   powershell -ExecutionPolicy Bypass -File .\diag_windows_edl.ps1 -Fix   # rebind to WinUSB

param(
    [switch]$Fix
)

$ErrorActionPreference = 'Continue'

# 9008 is the canonical EDL PID. Some PICO variants also report 900a / 0003.
$EDL_PIDS = @('9008','900a','900b','0003','0008','000a')
$QUALCOMM_VID = '05c6'

function Get-USBDeviceByVIDPID {
    param([string]$vid, [string]$pid)
    Get-PnpDevice | Where-Object {
        $_.InstanceId -match "(?i)$vid&$pid"
    }
}

function Get-DeviceDriver {
    param([PnpDevice]$dev)
    $props = Get-CimInstance Win32_PnPEntity -Filter "DeviceID='$($dev.InstanceId)'"
    return $props
}

function Rebind-To-WinUSB {
    param([PnpDevice]$dev)
    # devcon.exe ships with WDK / Visual Studio; fall back to pnputil if absent.
    $devcon = (Get-Command devcon.exe -ErrorAction SilentlyContinue)
    if ($devcon) {
        & $devcon.exe reinstall "$($dev.InstanceId)"
        return $LASTEXITCODE -eq 0
    }
    # pnputil can install a WinUSB OEM INF over an existing binding.
    $oemInf = Join-Path $env:SystemRoot 'INF\oemwinusb.inf'
    if (-not (Test-Path $oemInf)) {
        Write-Host "oemwinusb.inf not found at $oemInf" -ForegroundColor Yellow
        return $false
    }
    & pnputil /install-device-oem "$($dev.InstanceId)" | Out-Null
    & pnputil /install "$oemInf" | Out-Null
    return $LASTEXITCODE -eq 0
}

Write-Host ""
Write-Host "=== PICO 4 EDL 9008 diagnostic ===" -ForegroundColor Cyan
Write-Host ""

# 1. Are we running as admin?
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    (New-Object Security.Principal.WindowsIdentity)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[!] Run as Administrator for accurate results." -ForegroundColor Yellow
    Write-Host ""
}

# 2. Find any EDL device attached.
$found = @()
foreach ($pid in $EDL_PIDS) {
    $devs = Get-USBDeviceByVIDPID -vid $QUALCOMM_VID -pid $pid
    if ($devs) { $found += $devs }
}

# 3. Also catch the "Unknown device" / "Android Composite ADB" fallbacks.
$unknownEdl = Get-PnpDevice | Where-Object {
    $_.FriendlyName -match '(?i)(unknown device|android|qualcomm|bootloader|9008)' -and
    $_.InstanceId -match "(?i)$QUALCOMM_VID"
}
if ($unknownEdl) { $found += $unknownEdl }

# 4. De-duplicate by instance id.
$found = $found | Select-Object -Unique -Property InstanceId |
    ForEach-Object {
        $id = $_.InstanceId
        if ($_.PSObject.Properties.Name -contains 'PnpDevice') { $_.PnpDevice }
        else { Get-PnpDevice -InstanceId $id -ErrorAction SilentlyContinue }
    } | Where-Object { $_ }

if (-not $found -or $found.Count -eq 0) {
    Write-Host "No EDL-class device attached." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Possible causes:"
    Write-Host "  - PICO 4 is not in EDL mode yet. Enter it with:"
    Write-Host "      fastboot oem edl"
    Write-Host "    (requires an unlocked bootloader and a rooted device)."
    Write-Host ""
    Write-Host "  - Cable or USB port is bad / powered down. Try another cable/port."
    Write-Host ""
    Write-Host "  - PICO 4 has a different VID on your build. Re-plug and run:"
    Write-Host "      pnputil /enumerate-devices"
    Write-Host "    and grep for any 05c6:* device."
    Write-Host ""
    exit 1
}

Write-Host "Found $($found.Count) EDL-class device(s):" -ForegroundColor Green
Write-Host ""

foreach ($dev in $found) {
    $props = Get-DeviceDriver -dev $dev
    $driver = if ($props) { $props.Driver -or 'unknown' } else { 'unknown' }
    $status = $dev.Status
    $class  = $dev.Class

    Write-Host "  Instance:   $($dev.InstanceId)"
    Write-Host "  Friendly:   $($dev.FriendlyName)"
    Write-Host "  Class:      $class"
    Write-Host "  Status:     $status"
    Write-Host "  Driver:     $driver"
    Write-Host ""

    $driverOk = $driver -match '(?i)(WinUSB|usbd\*|Microsoft\*usb)'
    if ($driverOk) {
        Write-Host "  [OK] Bound to WinUSB — flashing tools should see this port." -ForegroundColor Green
    } else {
        Write-Host "  [!!] NOT bound to WinUSB. Flashing tools (QFIL, EDLFlash, Firehose) will not see this port." -ForegroundColor Red
        Write-Host "       Fix: use zadig.exe to replace the driver with WinUSB, or:"
        Write-Host "             .\diag_windows_edl.ps1 -Fix"
    }
    Write-Host ""

    if ($Fix -and $status -ne 'OK') {
        if ($isAdmin) {
            Write-Host "  Attempting rebind..."
            if (Rebind-To-WinUSB -dev $dev) {
                Write-Host "  Rebind requested. Replug the device." -ForegroundColor Green
            } else {
                Write-Host "  Rebind failed. Fall back to zadig.exe." -ForegroundColor Red
            }
        } else {
            Write-Host "  Rebind needs admin privileges." -ForegroundColor Yellow
        }
    }
}

Write-Host "If you still cannot see the port, grab the driver with zadig.exe:"
Write-Host "  1. Open zadig.exe"
Write-Host "  2. Device -> List All Devices"
Write-Host "  3. Find the 05c6:9008 entry"
Write-Host "  4. Install Driver -> WinUSB"
Write-Host ""
