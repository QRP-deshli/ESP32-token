# Read-only check: is the token there, does the sensor answer, how many fingers are enrolled, is the PC set up?
# Exit code 0 = ready to use, 1 = something is missing.
#   powershell -ExecutionPolicy Bypass -File desktop\windows\check-token.ps1
. (Join-Path $PSScriptRoot 'common.ps1')

$problems = 0
Write-Host 'Pico FIDO2 token check'
Write-Host ''

# --- the PC side ---
if (-not $Python) { Bad "Python 3 is not installed (https://www.python.org/downloads/windows/)"; exit 1 }
$helper = Get-VhidHelper
if ($helper) { Ok "virtual HID helper configured ($helper)" }
else { Warn 'no virtual HID helper (PICO_VHID_HELPER): browsers cannot use the token yet, fingerprints work (desktop\windows\virtual-hid.md)' }

# --- the token side ---
if (Test-BridgeRunning) {
    Ok 'the bridge is running'
    if (Need-Cmd 'fido2-token' 'libfido2 tools for Windows, see desktop\windows\README.md') {
        $dev = Find-HidDevice
        if ($dev) {
            Ok "virtual FIDO device $dev"
            $infoOut = (fido2-token -I $dev 2>$null) -join "`n"
            if ($infoOut) { Ok "token answers: $(Get-PinState $infoOut)" }
            else { Warn 'the virtual device exists but the token did not answer (unplugged? restart the bridge)'; $problems = 1 }
        } else {
            Warn 'the bridge runs but no virtual FIDO device was found (fido2-token -L may need an administrator prompt)'; $problems = 1
        }
    }
    Info "Fingerprints can't be counted while the bridge runs (it uses the same serial port)."
    if (-not [Console]::IsInputRedirected -and (Ask-YN 'Stop the bridge to count the enrolled fingers?' 'n')) {
        Stop-Bridge
        Ok 'bridge stopped (restart it with desktop\windows\start-bridge.ps1)'
    } else {
        Write-Host ''; Write-Host 'Not fully checked (bridge running).'; exit $problems
    }
}

Update-State | Out-Null
Show-StateLine
if (-not ($script:TokenOk -and $script:SensorOk)) { $problems = 1 }
if ($script:SensorOk -and $script:Fingers -eq 0) {
    Warn 'no finger enrolled: the token refuses everything until you run desktop\windows\setup-token.ps1'; $problems = 1
}
if ($script:TokenOk) { Info "The token's own keys are created automatically the first time it is used; they can't be read from the PC." }

Write-Host ''
if ($problems -eq 0) { Write-Host 'Ready. Start the bridge with desktop\windows\start-bridge.ps1' }
else { Write-Host 'Not ready. desktop\windows\setup-token.ps1 helps with fingers; see the README troubleshooting table.' }
exit $problems
