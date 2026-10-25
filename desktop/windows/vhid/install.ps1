# Installs the pico_vhf driver (virtual FIDO HID device for the serial bridge) on THIS machine. Run as administrator:
#   powershell -ExecutionPolicy Bypass -File desktop\windows\vhid\install.ps1 [-DriverDir <folder with pico_vhf.inf/.sys/.cat>]
#
# The driver is test-signed, so Windows must be in test-signing mode (asks before turning it on; needs a reboot and
# Secure Boot off). The WDK test certificate that signed the driver is added to this machine's trusted roots (asks first).
# Undo everything with uninstall.ps1.
param([string]$DriverDir = (Join-Path $PSScriptRoot 'driver\x64\Release\pico_vhf'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'setupapi.ps1')

function Confirm-Step([string]$Question) { (Read-Host "$Question [y/N]") -match '^(y|yes)$' }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run this from an administrator PowerShell.'; exit 1
}
$inf = Join-Path $DriverDir 'pico_vhf.inf'
$cat = Join-Path $DriverDir 'pico_vhf.cat'
if (-not (Test-Path $inf) -or -not (Test-Path $cat)) {
    Write-Host "No driver package in $DriverDir. Build it first (desktop\windows\vhid\README.md, 'Build')."; exit 1
}

# 1. test-signing mode
if (-not ((bcdedit /enum '{current}') -match 'testsigning\s+Yes')) {
    Write-Host 'Windows is not in test-signing mode, so it will not load a test-signed driver.'
    Write-Host 'Test-signing lowers protection against unsigned kernel code; turn it off again with uninstall.ps1.'
    if (Confirm-Step 'Turn test-signing on now (bcdedit /set testsigning on)?') {
        bcdedit /set testsigning on | Out-Null
        Write-Host 'Done. REBOOT, then run this script again. (If bcdedit refuses, turn Secure Boot off in the firmware.)'
    }
    exit 1
}

# 2. trust the certificate that signed the driver package (the WDK test certificate)
$cert = (Get-AuthenticodeSignature $cat).SignerCertificate
if (-not $cert) { Write-Host "$cat is not signed."; exit 1 }
if (-not (Test-Path "Cert:\LocalMachine\TrustedPublisher\$($cert.Thumbprint)")) {
    Write-Host "The driver is signed by: $($cert.Subject) ($($cert.Thumbprint))"
    if (-not (Confirm-Step 'Add this test certificate to the machine''s Trusted Root and Trusted Publishers stores?')) { exit 1 }
    foreach ($store in 'Root', 'TrustedPublisher') {
        $s = New-Object Security.Cryptography.X509Certificates.X509Store $store, 'LocalMachine'
        $s.Open('ReadWrite'); $s.Add($cert); $s.Close()
    }
}

# 3. the root-enumerated device and its driver
if (-not (Get-PicoVhfDevice)) {
    [PicoSetupApi]::CreateRootDevice($PicoHardwareId, 'HIDClass', $PicoHidClassGuid)
}
$reboot = [PicoSetupApi]::InstallDriver($PicoHardwareId, (Resolve-Path $inf).Path)
Write-Host 'pico_vhf installed.' $(if ($reboot) { 'Windows asks for a reboot.' } else { '' })
Write-Host 'Start the bridge from an administrator PowerShell: desktop\windows\start-bridge.ps1'
