# Daily start of the serial bridge: makes your PC see the token as a USB FIDO key.
# Leave this window open while you use the token; Ctrl+C stops it.
#   powershell -ExecutionPolicy Bypass -File desktop\windows\start-bridge.ps1        normal
#   powershell -ExecutionPolicy Bypass -File desktop\windows\start-bridge.ps1 -v     also print every packet
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $Python) { Bad 'Python 3 is not installed (https://www.python.org/downloads/windows/)'; exit 1 }
if (Test-BridgeRunning) {
    Bad 'the bridge is already running (in another window?)'
    Info 'Stop it with Ctrl+C there, or run:  Get-CimInstance Win32_Process | ? CommandLine -match ctaphid_serial_bridge | % { Stop-Process $_.ProcessId }'
    exit 1
}
if (-not (Get-VhidHelper)) {
    Bad 'no virtual HID helper configured, so browsers cannot see the token on Windows yet.'
    Info 'Set PICO_VHID_HELPER to a helper program (see desktop\windows\virtual-hid.md).'
    Info 'Fingerprint management works without the bridge: desktop\windows\setup-token.ps1'
    exit 1
}

Ok 'starting the bridge. Keep this window open; it prints >>> TOUCH THE FINGERPRINT SENSOR NOW <<< when needed.'
$exe = $Python[0]
$pre = @($Python | Select-Object -Skip 1)
Push-Location $BridgeDir
try { & $exe @pre .\ctaphid_serial_bridge.py @args; exit $LASTEXITCODE } finally { Pop-Location }
