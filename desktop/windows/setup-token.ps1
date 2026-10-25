# Interactive setup for the Pico FIDO2 token. It first shows what the token already has (fingers enrolled), then lets
# you enrol more fingers, test or delete them, initialise the token's keys, or start over with a new token identity,
# and finally offers to start the bridge.
#
#   powershell -ExecutionPolicy Bypass -File desktop\windows\setup-token.ps1
#
# Run it with the token plugged into the NATIVE USB port. It stops a running bridge (the bridge and fpctl.py need the
# same serial port). Options 5 and 6 and the bridge need the virtual HID driver (desktop\windows\vhid\README.md) and an administrator
# PowerShell.
. (Join-Path $PSScriptRoot 'common.ps1')

function Need-FidoTools { return (Need-Cmd 'fido2-token' 'libfido2 tools for Windows, see desktop\windows\README.md') }

function Need-Helper {
    if (-not (Get-VhidHelper)) {
        Bad 'the virtual HID driver and helper are not installed, and this needs the bridge.'
        Info 'See desktop\windows\vhid\README.md.'
        return $false
    }
    if (-not (Test-Admin)) { Bad 'this needs an administrator PowerShell (bridge and fido2-token).'; return $false }
    return $true
}

function Show-State { Update-State | Out-Null; Show-StateLine }

function Read-Id {
    param([string]$Prompt)
    $id = Read-Host $Prompt
    if ($id -notmatch '^\d+$') { Bad 'not a number'; return $null }
    return $id
}

# ---------------------------------------------------------------------------------------------------------------------
function Enroll-Flow {
    Update-State | Out-Null
    if (-not ($script:TokenOk -and $script:SensorOk)) { Show-StateLine; return }
    if ($script:Fingers -gt 0) {
        Info "$($script:Fingers) finger(s) are already enrolled. To add one you first touch the sensor with an ENROLLED finger."
        if (-not (Ask-YN 'Enrol another finger?' 'n')) { return }
    } else {
        Info 'No finger is enrolled yet. The first one needs no authorisation. Three touches, lifting in between.'
    }
    $rc = Invoke-Fpctl @('enroll')
    if ($rc -ne 0) {
        Info 'If it says the ID is already in use (after deleting fingers the numbers have gaps), pick a free ID.'
        if (Ask-YN 'Try again with a specific ID (1..4095)?' 'n') {
            $id = Read-Id 'ID'
            if ($null -eq $id) { return }
            $rc = Invoke-Fpctl @('enroll', '--id', $id)
        }
    }
    Update-State | Out-Null
    if ($rc -eq 0) {
        Ok "now $($script:Fingers) finger(s) enrolled"
        if ($script:Fingers -eq 1) { Info 'Tip: enrol a second finger as a backup (menu option 1 again).' }
    }
}

function Test-Flow {
    Update-State | Out-Null
    if (-not $script:SensorOk) { Show-StateLine; return }
    Invoke-Fpctl @('test') | Out-Null
}

function Delete-OneFlow {
    Update-State | Out-Null
    if (-not $script:SensorOk) { Show-StateLine; return }
    if ($script:Fingers -eq 0) { Info 'No fingers enrolled.'; return }
    Info 'Fingers are numbered in the order you enrolled them (1, 2, ...). You must authorise with an enrolled finger.'
    $id = Read-Id "ID to delete (1..$($script:Fingers))"
    if ($null -eq $id) { return }
    if ($script:Fingers -eq 1) {
        Warn 'This is your only finger: afterwards the token refuses everything until you enrol a new one.'
    }
    if (-not (Ask-YN "Delete finger $id?" 'n')) { return }
    Invoke-Fpctl @('delete', $id) | Out-Null
    Update-State | Out-Null; Info "$($script:Fingers) finger(s) left."
}

function Delete-AllFlow {
    Update-State | Out-Null
    if (-not $script:SensorOk) { Show-StateLine; return }
    if ($script:Fingers -eq 0) { Info 'No fingers enrolled.'; return }
    Warn "This removes ALL $($script:Fingers) fingerprint(s). The token will refuse everything until you enrol again."
    Invoke-Fpctl @('delete-all') | Out-Null   # asks you to type 'yes' itself
    Update-State | Out-Null; Info "$($script:Fingers) finger(s) left."
}

# Run the bridge in the background, wait for it to find the token.
function Bridge-Up {
    Start-BridgeBg
    if (-not (Wait-ConnGt 0 10)) {
        Bad "the bridge could not reach the token (see $BridgeLog)"
        Stop-Bridge
        return $false
    }
    return $true
}

function Init-KeysFlow {
    if (-not (Need-Helper) -or -not (Need-FidoTools)) { return }
    Info "This sends the token its first FIDO message. On a brand-new token that is the moment it creates its keys"
    Info "(the ESP32 monitor shows 'KEY DEVICE is empty. Generating...'). On a token that has them nothing changes."
    if (-not (Ask-YN 'Go ahead?' 'y')) { return }
    if (-not (Bridge-Up)) { return }
    $dev = Wait-Hid 10
    if (-not $dev) { Bad 'no virtual FIDO device appeared'; Stop-Bridge; return }
    $out = (fido2-token -I $dev 2>&1 | ForEach-Object { "$_" }) -join "`n"
    if ($out -match '(?m)^proto:') { Ok "the token answered ($dev): $(Get-PinState $out)" }
    else { Bad "the token did not answer: $(($out -split "`n") | Select-Object -Last 1)" }
    Stop-Bridge
}

function Reset-Flow {
    if (-not (Need-Helper) -or -not (Need-FidoTools)) { return }
    Write-Host ''
    Warn 'NEW TOKEN IDENTITY (FIDO reset)'
    Info 'This erases every account registered on the token and its PIN, and creates a new device key.'
    Info 'Websites where you used it will no longer recognise it. Your FINGERPRINTS are not touched.'
    Info 'The token only accepts a reset in the first 10 seconds after it is powered up, and it asks for a finger.'
    $ans = Read-Host 'Type RESET to continue'
    if ($ans -cne 'RESET') { Info 'cancelled'; return }

    if (-not (Bridge-Up)) { return }
    $base = Get-TokenConnCount
    Write-Host ''
    Write-Host 'Now UNPLUG the token''s USB cable, plug it back in, wait about 3 seconds, then press Enter.'
    Read-Host | Out-Null
    if (-not (Wait-ConnGt $base 8)) { Bad 'the bridge did not see the token come back'; Stop-Bridge; return }
    $dev = Wait-Hid 5
    if (-not $dev) { Bad 'no virtual FIDO device appeared'; Stop-Bridge; return }
    Write-Host 'Touch the sensor with an ENROLLED finger now ...'
    fido2-token -R $dev
    $rc = $LASTEXITCODE
    Stop-Bridge
    if ($rc -eq 0) { Ok 'reset done: the token has a new identity. Set a new PIN when a website asks.' }
    else { Bad 'the reset failed. If it says NOT_ALLOWED the 10-second window had passed: choose this option again.' }
}

# ---------------------------------------------------------------------------------------------------------------------
function Start-BridgeNow {
    & (Join-Path $ScriptsDir 'start-bridge.ps1')
    exit $LASTEXITCODE
}

function Main-Menu {
    while ($true) {
        Write-Host ''
        Update-State | Out-Null
        if ($script:TokenOk -and $script:SensorOk) {
            Write-Host "Token on $($script:TokenPort), $($script:Fingers) finger(s) enrolled."
        } else {
            Show-StateLine
        }
        Write-Host @'

What do you want to do?
  1) Enrol a finger (the first one, or another one)
  2) Test a finger
  3) Delete one finger
  4) Delete ALL fingers
  5) Initialise the token's keys (safe to repeat)
  6) Create a NEW token identity (erases all registered accounts and the PIN)
  7) Start the bridge and use the token
  q) Quit
'@
        $choice = Read-Host 'Choice'
        switch ($choice) {
            '1' { Enroll-Flow }
            '2' { Test-Flow }
            '3' { Delete-OneFlow }
            '4' { Delete-AllFlow }
            '5' { Init-KeysFlow }
            '6' { Reset-Flow }
            '7' { Start-BridgeNow }
            { $_ -in @('q', 'Q', '') } { return }
            default { Warn 'unknown choice' }
        }
    }
}

# --- main -------------------------------------------------------------------------------------------------------------
try {
    Write-Host 'Pico FIDO2 token setup'
    Write-Host ''
    if (-not $Python) { Bad 'Python 3 is not installed (https://www.python.org/downloads/windows/)'; exit 1 }
    if (-not (Test-Path (Join-Path $BridgeDir 'fpctl.py'))) { Bad "cannot find $BridgeDir\fpctl.py"; exit 1 }

    if (Test-BridgeRunning) {
        Warn "The bridge is running and blocks the token's serial port."
        if (Ask-YN 'Stop it now?' 'y') { Stop-Bridge; Ok 'bridge stopped' } else { Bad 'cannot continue while it runs'; exit 1 }
    }

    Show-State
    if ($script:TokenOk -and $script:SensorOk -and $script:Fingers -eq 0) {
        Write-Host ''
        Info 'No finger is enrolled yet, so the token would refuse everything.'
        if (Ask-YN 'Enrol your first finger now?' 'y') { Enroll-Flow }
    }
    Main-Menu
    Write-Host ''
    if ((Get-VhidHelper) -and (Ask-YN 'Start the bridge now?' 'y')) { Start-BridgeNow }
} finally {
    Clear-Bridge
}
