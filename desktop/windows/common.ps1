# Shared helpers for the scripts in this folder (Windows PowerShell 5.1 and PowerShell 7). Dot-sourced by them.

$ScriptsDir = $PSScriptRoot
$DesktopDir = Split-Path -Parent $ScriptsDir
$BridgeDir = if ($env:PICO_BRIDGE_DIR) { $env:PICO_BRIDGE_DIR } else { Join-Path $DesktopDir 'common' }
$BridgeLog = Join-Path ([IO.Path]::GetTempPath()) 'pico-fido2-bridge.log'
$BridgeErrLog = "$BridgeLog.err"
$script:BridgeStartedByUs = $false

function Ok   { param([string]$m) Write-Host '[ ok ] ' -ForegroundColor Green -NoNewline; Write-Host $m }
function Warn { param([string]$m) Write-Host '[ !! ] ' -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Bad  { param([string]$m) Write-Host '[FAIL] ' -ForegroundColor Red -NoNewline; Write-Host $m }
function Info { param([string]$m) Write-Host "       $m" }

# Ask-YN "question" 'y'|'n' -> $true for yes. End of input counts as "no".
function Ask-YN {
    param([string]$Prompt, [string]$Default = 'n')
    $hint = if ($Default -eq 'y') { '[Y/n]' } else { '[y/N]' }
    $ans = Read-Host "$Prompt $hint"
    if ($null -eq $ans) { return $false }
    if ($ans -eq '') { $ans = $Default }
    return $ans -match '^(y|yes)$'
}

# The Python 3 interpreter: the py launcher if installed, else python.exe on PATH.
function Get-Python {
    if (Get-Command py -ErrorAction SilentlyContinue) { return @('py', '-3') }
    if (Get-Command python -ErrorAction SilentlyContinue) { return @('python') }
    return $null
}
$Python = Get-Python

function Need-Cmd {
    param([string]$Name, [string]$Hint = '')
    if (Get-Command $Name -ErrorAction SilentlyContinue) { return $true }
    if ($Hint) { Bad "'$Name' is not installed ($Hint)" } else { Bad "'$Name' is not installed" }
    return $false
}

# Run a Python script from $BridgeDir with arguments, return @{ Code; Output }.
function Invoke-Py {
    param([string[]]$Arguments)
    $exe = $Python[0]
    $pre = @($Python | Select-Object -Skip 1)
    Push-Location $BridgeDir
    try {
        $out = & $exe @pre @Arguments 2>&1 | ForEach-Object { "$_" }
        return @{ Code = $LASTEXITCODE; Output = ($out -join "`n") }
    } finally { Pop-Location }
}

# Run fpctl.py interactively (its output goes straight to the console). Returns the exit code.
function Invoke-Fpctl {
    param([string[]]$Arguments)
    $exe = $Python[0]
    $pre = @($Python | Select-Object -Skip 1)
    Push-Location $BridgeDir
    # Out-Host: show the output instead of returning it as part of the function's result
    try { & $exe @pre .\fpctl.py @Arguments | Out-Host; return $LASTEXITCODE } finally { Pop-Location }
}

# The virtual HID helper the bridge needs on Windows (see virtual-hid.md); $null when none is configured.
function Get-VhidHelper {
    if ($env:PICO_VHID_HELPER -and (Test-Path $env:PICO_VHID_HELPER)) { return $env:PICO_VHID_HELPER }
    return $null
}

function Get-BridgeProcess {
    Get-CimInstance Win32_Process -Filter "Name LIKE 'python%' OR Name LIKE 'py.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'ctaphid_serial_bridge\.py' }
}

function Test-BridgeRunning { return [bool](Get-BridgeProcess) }

function Stop-Bridge {
    Get-BridgeProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    for ($i = 0; $i -lt 6 -and (Test-BridgeRunning); $i++) { Start-Sleep -Milliseconds 500 }
    $script:BridgeStartedByUs = $false
}

# Stop the bridge only if one of our own functions started it.
function Clear-Bridge { if ($script:BridgeStartedByUs) { Stop-Bridge } }

# Start the bridge in the background, logging to $BridgeLog (the bridge logs on stderr).
function Start-BridgeBg {
    Set-Content -Path $BridgeLog -Value ''
    $exe = $Python[0]
    $argList = @($Python | Select-Object -Skip 1) + @('.\ctaphid_serial_bridge.py')
    Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $BridgeDir -WindowStyle Hidden `
        -RedirectStandardError $BridgeLog -RedirectStandardOutput $BridgeErrLog | Out-Null
    $script:BridgeStartedByUs = $true
}

# number of times the bridge has connected to the token since it was started
function Get-TokenConnCount {
    if (-not (Test-Path $BridgeLog)) { return 0 }
    return @(Select-String -Path $BridgeLog -Pattern 'token on' -ErrorAction SilentlyContinue).Count
}

# Wait-ConnGt BASELINE SECONDS : wait until the connection count is higher than BASELINE
function Wait-ConnGt {
    param([int]$Base, [int]$Seconds)
    for ($i = 0; $i -lt $Seconds * 2; $i++) {
        if ((Get-TokenConnCount) -gt $Base) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# the libfido2 path of the virtual FIDO device, if any
function Find-HidDevice {
    if (-not (Get-Command fido2-token -ErrorAction SilentlyContinue)) { return $null }
    $line = fido2-token -L 2>$null | Where-Object { $_ -match 'product=0x619b' } | Select-Object -First 1
    if ($line) { return ($line -replace ': vendor=.*$', '') }
    return $null
}

function Wait-Hid {
    param([int]$Seconds = 10)
    for ($i = 0; $i -lt $Seconds * 2; $i++) {
        $dev = Find-HidDevice
        if ($dev) { return $dev }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

# say whether a PIN is set, from "fido2-token -I" output
function Get-PinState {
    param([string]$InfoOutput)
    $opts = ($InfoOutput -split "`n" | Where-Object { $_ -match '^options:' } | Select-Object -First 1)
    if ($opts -match 'noclientPin') { return 'no PIN set yet' }
    if ($opts -match 'clientPin') { return 'a PIN is set' }
    return 'PIN state unknown'
}

# --- fingerprint state, read with fpctl.py (needs the bridge to be STOPPED: same serial port) -------------------------
$script:TokenOk = $false; $script:SensorOk = $false; $script:Fingers = 0; $script:TokenPort = ''; $script:FpOut = ''

function Update-State {
    $r = Invoke-Py @('.\fpctl.py', 'status')
    $script:FpOut = $r.Output
    $script:TokenOk = $false; $script:SensorOk = $false; $script:Fingers = 0; $script:TokenPort = ''
    if ($r.Output -match '(?m)^token on (.+?)\s*$') { $script:TokenPort = $Matches[1]; $script:TokenOk = $true }
    if ($r.Code -eq 0) {
        $script:SensorOk = $true
        if ($r.Output -match '(?m)^sensor OK, (\d+) fingerprint') { $script:Fingers = [int]$Matches[1] }
    }
    return $r.Code
}

function Show-StateLine {
    if (-not $script:TokenOk) {
        Bad 'no token found'
        Info 'Plug the cable into the NATIVE USB port of the ESP32-C6, wait 3 seconds, and make sure the bridge is not running.'
        Info 'The token shows up as a COM port ("USB Serial Device" or "USB JTAG/serial debug unit") in Device Manager.'
        return
    }
    Ok "token found on $($script:TokenPort)"
    if (-not $script:SensorOk) {
        $msg = ($script:FpOut -split "`n" | Where-Object { $_ -notmatch '^token on' } | Select-Object -Last 1)
        if (-not $msg) { $msg = 'no answer' }
        Bad "fingerprint sensor: $msg"
    } else {
        Ok "fingerprint sensor answers, $($script:Fingers) finger(s) enrolled"
    }
}
