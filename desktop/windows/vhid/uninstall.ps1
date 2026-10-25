# Removes everything install.ps1 added. Run as administrator:
#   powershell -ExecutionPolicy Bypass -File desktop\windows\vhid\uninstall.ps1
# Stop the bridge first. Asks before removing the test certificate and before turning test-signing off.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'setupapi.ps1')

function Confirm-Step([string]$Question) { (Read-Host "$Question [y/N]") -match '^(y|yes)$' }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run this from an administrator PowerShell.'; exit 1
}

# 1. the device(s)
foreach ($d in Get-PicoVhfDevice) {
    pnputil /remove-device "$($d.InstanceId)" | Out-Null
    Write-Host "removed device $($d.InstanceId)"
}

# 2. the driver package(s) in the driver store
$drivers = Get-WindowsDriver -Online -ErrorAction SilentlyContinue | Where-Object { $_.OriginalFileName -like '*pico_vhf.inf' }
$cert = $null
foreach ($drv in $drivers) {
    $catalog = Join-Path (Split-Path $drv.OriginalFileName) 'pico_vhf.cat'
    if (Test-Path $catalog) { $cert = (Get-AuthenticodeSignature $catalog).SignerCertificate }
    pnputil /delete-driver $drv.Driver /uninstall /force | Out-Null
    Write-Host "removed driver package $($drv.Driver)"
}

# 3. the test certificate
if ($cert -and (Confirm-Step "Remove the test certificate $($cert.Subject) from Trusted Root and Trusted Publishers?")) {
    foreach ($store in 'Root', 'TrustedPublisher') {
        $s = New-Object Security.Cryptography.X509Certificates.X509Store $store, 'LocalMachine'
        $s.Open('ReadWrite'); $s.Remove($cert); $s.Close()
    }
    Write-Host 'certificate removed'
}

# 4. test-signing mode
if (((bcdedit /enum '{current}') -match 'testsigning\s+Yes') -and
        (Confirm-Step 'Turn test-signing off (bcdedit /set testsigning off; other test-signed drivers stop loading)?')) {
    bcdedit /set testsigning off | Out-Null
    Write-Host 'test-signing off after the next reboot'
}
Write-Host 'pico_vhf removed.'
