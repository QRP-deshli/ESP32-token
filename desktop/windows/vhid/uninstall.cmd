@echo off
rem Removes everything install.cmd added. Run as administrator:
rem   desktop\windows\vhid\uninstall.cmd
rem Stop the bridge first. Asks before removing the test certificate and before turning test-signing off.
setlocal EnableExtensions
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "TOOL=%HERE%\pico-install.exe"
set "CERNAME=PicoVhfTestCert"

fltmc >nul 2>&1
if errorlevel 1 (
    echo Run this from an administrator Command Prompt.
    exit /b 1
)
if not exist "%TOOL%" (
    echo pico-install.exe is missing. Build it first: desktop\windows\vhid\build.cmd tools
    exit /b 1
)

rem 1. + 2. the device(s) and the driver package(s) in the driver store
"%TOOL%" remove

rem 3. the test certificate (only the one build.cmd makes; one from another build you remove in certmgr.msc)
certutil -store TrustedPublisher "%CERNAME%" >nul 2>&1
if errorlevel 1 goto :no_cert
set "ANS="
set /p "ANS=Remove the test certificate %CERNAME% from Trusted Root and Trusted Publishers? [y/N] "
if /i not "%ANS%"=="y" if /i not "%ANS%"=="yes" goto :no_cert
certutil -delstore Root "%CERNAME%" >nul 2>&1
certutil -delstore TrustedPublisher "%CERNAME%" >nul 2>&1
echo certificate removed
:no_cert

rem 4. test-signing mode
bcdedit /enum "{current}" 2>nul | findstr /i /r /c:"testsigning *Yes" >nul
if errorlevel 1 goto :signing_off
set "ANS="
set /p "ANS=Turn test-signing off (bcdedit /set testsigning off; other test-signed drivers stop loading)? [y/N] "
if /i not "%ANS%"=="y" if /i not "%ANS%"=="yes" goto :signing_off
bcdedit /set testsigning off >nul
echo test-signing off after the next reboot
:signing_off
echo pico_vhf removed.
exit /b 0
