@echo off
rem Installs the pico_vhf driver (virtual FIDO HID device for the serial bridge) on THIS machine. Run as administrator:
rem   desktop\windows\vhid\install.cmd [folder with pico_vhf.inf, .sys, .cat and .cer]
rem
rem Needs pico-install.exe (build.cmd tools) and the driver package (build.cmd driver).
rem The driver is test-signed, so Windows must be in test-signing mode (asks before turning it on; needs a reboot and
rem Secure Boot off). The test certificate that signed the driver is added to this machine's trusted stores (asks first).
rem Undo everything with uninstall.cmd.
setlocal EnableExtensions
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "PKG=%HERE%\driver\x64\Release\pico_vhf"
if not "%~1"=="" set "PKG=%~f1"
set "TOOL=%HERE%\pico-install.exe"
set "CERNAME=PicoVhfTestCert"
set "CER=%PKG%\pico_vhf.cer"

fltmc >nul 2>&1
if errorlevel 1 (
    echo Run this from an administrator Command Prompt.
    exit /b 1
)
if not exist "%PKG%\pico_vhf.inf" goto :nopkg
if not exist "%PKG%\pico_vhf.cat" goto :nopkg
if not exist "%PKG%\pico_vhf.sys" goto :nopkg
if not exist "%TOOL%" (
    echo pico-install.exe is missing. Build it first: desktop\windows\vhid\build.cmd tools
    exit /b 1
)

rem 1. test-signing mode
bcdedit /enum "{current}" 2>nul | findstr /i /r /c:"testsigning *Yes" >nul
if not errorlevel 1 goto :signing_ok
echo Windows is not in test-signing mode, so it will not load a test-signed driver.
echo Test-signing lowers protection against unsigned kernel code; turn it off again with uninstall.cmd.
echo If your Windows is not in English this check may be wrong; then answer n and turn it on yourself.
set "ANS="
set /p "ANS=Turn test-signing on now (bcdedit /set testsigning on)? [y/N] "
if /i not "%ANS%"=="y" if /i not "%ANS%"=="yes" exit /b 1
bcdedit /set testsigning on
if errorlevel 1 (
    echo bcdedit refused. Turn Secure Boot off in the firmware, then run this script again.
    exit /b 1
)
echo Done. REBOOT, then run this script again.
exit /b 1
:signing_ok

rem 2. trust the certificate that signed the driver package
if exist "%CER%" goto :have_cer
echo No pico_vhf.cer in the package ^(it was not built with build.cmd^). Extracting the signer certificate from
echo pico_vhf.cat with a one-line PowerShell command ...
powershell -NoProfile -Command "$c=(Get-AuthenticodeSignature '%PKG%\pico_vhf.cat').SignerCertificate; if(-not $c){exit 1}; Export-Certificate -Cert $c -FilePath '%CER%' -Type CERT | Out-Null"
if errorlevel 1 (
    echo Could not read a certificate from pico_vhf.cat. The package is not signed.
    exit /b 1
)
:have_cer
certutil -store TrustedPublisher "%CERNAME%" >nul 2>&1
if not errorlevel 1 goto :cert_ok
echo The driver is signed by:
certutil -dump "%CER%" | findstr /c:"CN="
set "ANS="
set /p "ANS=Add this test certificate to the machine's Trusted Root and Trusted Publishers stores? [y/N] "
if /i not "%ANS%"=="y" if /i not "%ANS%"=="yes" exit /b 1
certutil -addstore -f Root "%CER%" >nul
if errorlevel 1 goto :cert_fail
certutil -addstore -f TrustedPublisher "%CER%" >nul
if errorlevel 1 goto :cert_fail
goto :cert_ok
:cert_fail
echo certutil could not add the certificate.
exit /b 1
:cert_ok

rem 3. the root-enumerated device and its driver
"%TOOL%" status >nul 2>&1
if not errorlevel 1 goto :device_ok
"%TOOL%" create
if errorlevel 1 exit /b 1
:device_ok
"%TOOL%" install "%PKG%\pico_vhf.inf"
set "RC=%errorlevel%"
if "%RC%"=="0" goto :installed
if "%RC%"=="10" goto :installed_reboot
echo The driver install failed, see the message above. Device Manager and pnputil /enum-devices /problem may say more.
exit /b 1
:installed_reboot
echo pico_vhf installed. Windows asks for a reboot.
goto :done
:installed
echo pico_vhf installed.
:done
echo Start the bridge from an administrator Command Prompt: desktop\windows\start-bridge.cmd
exit /b 0

:nopkg
echo No complete driver package in %PKG%.
echo Build it first: desktop\windows\vhid\build.cmd driver
exit /b 1
