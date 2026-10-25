@echo off
rem Builds the Windows virtual HID pieces without PowerShell scripts and without MSBuild.
rem
rem   desktop\windows\vhid\build.cmd tools     pico-vhid.exe and pico-install.exe with MinGW-w64 (winlibs): gcc on PATH
rem   desktop\windows\vhid\build.cmd driver    pico_vhf.sys, .inf, .cat, .cer: cl and link from Visual Studio, plus the WDK
rem   desktop\windows\vhid\build.cmd           both
rem
rem The driver package lands in driver\x64\Release\pico_vhf\ (where install.cmd looks) and is test-signed with a
rem certificate CN=PicoVhfTestCert that is created in your personal store the first time.
rem
rem Optional environment variables:
rem   WDKVER=10.0.26100.0   WDK/SDK version folder (default: the newest one that has shared\vhf.h)
rem   KMDF_VER=1.15         KMDF version (default 1.15, which every Windows 10/11 has)
rem   WERROR=1              treat compiler warnings as errors, like the original .vcxproj
rem   SIGN_CERT_NAME=...    test certificate name (install.cmd and uninstall.cmd expect the default)
setlocal EnableExtensions EnableDelayedExpansion
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "WHAT=%~1"
if "%WHAT%"=="" set "WHAT=all"

if /i "%WHAT%"=="tools" goto :do_tools
if /i "%WHAT%"=="driver" goto :do_driver
if /i "%WHAT%"=="all" goto :do_all
echo usage: build.cmd [tools or driver or all]
exit /b 1

:do_all
call :tools
if errorlevel 1 exit /b 1
call :driver
exit /b %errorlevel%
:do_tools
call :tools
exit /b %errorlevel%
:do_driver
call :driver
exit /b %errorlevel%

rem ===============================================================================================================
rem user-mode tools with MinGW-w64
rem ===============================================================================================================
:tools
where gcc >nul 2>&1
if errorlevel 1 (
    echo gcc not found on PATH. Install winlibs MinGW-w64, the x86_64 build, from https://winlibs.com and add its bin folder to PATH.
    exit /b 1
)
set "GCCM="
for /f "delims=" %%M in ('gcc -dumpmachine') do set "GCCM=%%M"
echo !GCCM! | findstr /i /c:"x86_64" >nul
if errorlevel 1 (
    echo This gcc targets !GCCM!. The driver is 64-bit, so use the x86_64 winlibs build.
    exit /b 1
)
echo [tools] pico-vhid.exe
gcc -O2 -Wall -s -static -o "%HERE%\pico-vhid.exe" "%HERE%\helper\pico-vhid.c" -lsetupapi
if errorlevel 1 exit /b 1
echo [tools] pico-install.exe
gcc -O2 -Wall -s -static -o "%HERE%\pico-install.exe" "%HERE%\installer\pico-install.c" -lsetupapi -lnewdev -lshell32
if errorlevel 1 exit /b 1
echo [tools] done: %HERE%\pico-vhid.exe and %HERE%\pico-install.exe
exit /b 0

rem ===============================================================================================================
rem the KMDF/VHF driver with MSVC cl and link (not MSBuild) and the WDK
rem ===============================================================================================================
:driver
call :find_wdk
if errorlevel 1 exit /b 1
call :find_msvc
if errorlevel 1 exit /b 1
call :find_tool stampinf.exe STAMPINF
call :find_tool Inf2Cat.exe INF2CAT
call :find_tool signtool.exe SIGNTOOL
call :find_tool makecert.exe MAKECERT
if not defined STAMPINF goto :missing_tool
if not defined INF2CAT goto :missing_tool
if not defined SIGNTOOL goto :missing_tool
if not defined SIGN_CERT_NAME set "SIGN_CERT_NAME=PicoVhfTestCert"

set "OUT=%HERE%\driver\x64\Release"
set "OBJ=%OUT%\obj"
set "PKG=%OUT%\pico_vhf"
if exist "%PKG%" rmdir /s /q "%PKG%"
mkdir "%OBJ%" 2>nul
mkdir "%PKG%"

set "I_SHARED=%KITS%\Include\%WDKVER%\shared"
set "I_KM=%KITS%\Include\%WDKVER%\km"
set "I_CRT=%KITS%\Include\%WDKVER%\km\crt"
set "I_KMDF=%KITS%\Include\wdf\kmdf\%KMDF_VER%"
set "L_KM=%KITS%\Lib\%WDKVER%\km\x64"
set "L_KMDF=%KITS%\Lib\wdf\kmdf\x64\%KMDF_VER%"
for /f "tokens=1,2 delims=." %%a in ("%KMDF_VER%") do (set "KMAJ=%%a" & set "KMIN=%%b")

set "CFLAGS=/nologo /c /kernel /GS- /Gz /Zp8 /W4 /Zi /O2 /Oi /Gy /Zc:wchar_t /Zc:forScope /Zc:inline /fp:precise"
if "%WERROR%"=="1" set "CFLAGS=%CFLAGS% /WX"
set "DEFS=/D_WIN64 /D_AMD64_ /DAMD64 /DWINNT=1 /DWINVER=0x0A00 /D_WIN32_WINNT=0x0A00 /DNTDDI_VERSION=0x0A000004"
set "DEFS=%DEFS% /DKMDF_VERSION_MAJOR=%KMAJ% /DKMDF_VERSION_MINOR=%KMIN% /DDEPRECATE_DDK_FUNCTIONS=1"

echo [driver] compile pico_vhf.c  (WDK %WDKVER%, KMDF %KMDF_VER%)
cl %CFLAGS% %DEFS% /I"%I_SHARED%" /I"%I_KM%" /I"%I_CRT%" /I"%I_KMDF%" /Fo"%OBJ%\pico_vhf.obj" /Fd"%OBJ%\pico_vhf.pdb" "%HERE%\driver\pico_vhf.c"
if errorlevel 1 goto :fail

echo [driver] link pico_vhf.sys
link /nologo /DRIVER /SUBSYSTEM:NATIVE /ENTRY:FxDriverEntry /NODEFAULTLIB /KERNEL /MACHINE:X64 /RELEASE /NXCOMPAT /DYNAMICBASE /MANIFEST:NO /OPT:REF /OPT:ICF /MERGE:_TEXT=.text /MERGE:_PAGE=PAGE /SECTION:INIT,d /IGNORE:4078 /IGNORE:4221 /DEBUG /PDB:"%OUT%\pico_vhf.pdb" /OUT:"%PKG%\pico_vhf.sys" /LIBPATH:"%L_KM%" /LIBPATH:"%L_KMDF%" "%OBJ%\pico_vhf.obj" ntoskrnl.lib hal.lib BufferOverflowFastFailK.lib WdfDriverEntry.lib WdfLdr.lib vhfkm.lib
if errorlevel 1 goto :fail

echo [driver] stamp pico_vhf.inf
copy /y "%HERE%\driver\pico_vhf.inf" "%PKG%\pico_vhf.inf" >nul
"%STAMPINF%" -f "%PKG%\pico_vhf.inf" -d * -a amd64 -k %KMDF_VER% -v *
if errorlevel 1 goto :fail

rem the test-signing certificate: found or created in the personal store of the current user, and exported to
rem pico_vhf.cer. One PowerShell command does it (certutil name matching and makecert were unreliable).
echo [driver] test certificate CN=%SIGN_CERT_NAME%
powershell -NoProfile -ExecutionPolicy Bypass -Command "$n='CN=%SIGN_CERT_NAME%'; $c=Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $n -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } | Select-Object -First 1; if(-not $c){ Write-Host '         creating a new self-signed code-signing certificate'; $c=New-SelfSignedCertificate -Type CodeSigningCert -Subject $n -CertStoreLocation Cert:\CurrentUser\My -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(10) }; Export-Certificate -Cert $c -FilePath '%PKG%\pico_vhf.cer' -Type CERT | Out-Null; Set-Content -Path '%OUT%\cert-thumbprint.txt' -Value $c.Thumbprint -Encoding ASCII"
if not exist "%PKG%\pico_vhf.cer" goto :fail
set "CERT_SHA1="
for /f "usebackq delims=" %%T in ("%OUT%\cert-thumbprint.txt") do set "CERT_SHA1=%%T"
if not defined CERT_SHA1 goto :fail
:cer_done

echo [driver] sign pico_vhf.sys, make and sign pico_vhf.cat
"%SIGNTOOL%" sign /fd sha256 /s My /sha1 %CERT_SHA1% "%PKG%\pico_vhf.sys"
if errorlevel 1 goto :fail
"%INF2CAT%" /driver:"%PKG%" /os:10_X64 /uselocaltime
if errorlevel 1 goto :fail
"%SIGNTOOL%" sign /fd sha256 /s My /sha1 %CERT_SHA1% "%PKG%\pico_vhf.cat"
if errorlevel 1 goto :fail

echo [driver] done: %PKG%
echo          next, as administrator: desktop\windows\vhid\install.cmd
exit /b 0

:missing_tool
echo stampinf.exe, Inf2Cat.exe or signtool.exe not found under %KITS%\bin\%WDKVER%. Install the WDK that matches the Windows SDK.
exit /b 1
:fail
echo [driver] FAILED, see the messages above.
exit /b 1

rem ---------------------------------------------------------------------------------------------------------------
rem Windows Kits root, version folders and KMDF version: sets KITS WDKVER KMDF_VER
:find_wdk
set "KITS=%ProgramFiles(x86)%\Windows Kits\10"
if defined WDKContentRoot set "KITS=%WDKContentRoot%"
if "%KITS:~-1%"=="\" set "KITS=%KITS:~0,-1%"
if not exist "%KITS%\Include" goto :nosdk
if defined WDKVER goto :wdkver_set
for /d %%D in ("%KITS%\Include\10.*") do if exist "%%~fD\shared\vhf.h" set "WDKVER=%%~nxD"
:wdkver_set
if not defined WDKVER goto :nowdk
if not exist "%KITS%\Include\%WDKVER%\shared\vhf.h" goto :nowdk
if not defined KMDF_VER set "KMDF_VER=1.15"
if not exist "%KITS%\Include\wdf\kmdf\%KMDF_VER%\wdf.h" goto :nokmdf
if not exist "%KITS%\Lib\wdf\kmdf\x64\%KMDF_VER%\WdfDriverEntry.lib" goto :nokmdf
if not exist "%KITS%\Lib\%WDKVER%\km\x64\vhfkm.lib" goto :novhflib
exit /b 0
:novhflib
echo vhfkm.lib not found in %KITS%\Lib\%WDKVER%\km\x64. The WDK libraries are missing or are another version.
dir /b /s "%KITS%\Lib\vhfkm.lib" 2^>nul
exit /b 1
:nosdk
echo No Windows Kits folder with an Include directory at %KITS%.
echo Install the Windows 10/11 SDK ^(Visual Studio Installer, or the standalone SDK^) and then the matching WDK. See README-tools.pdf.
exit /b 1
:nowdk
echo The Windows SDK is under %KITS%, but no version folder there has shared\vhf.h, which comes with the WDK.
echo Include folders found:
dir /b /ad "%KITS%\Include\10.*" 2>nul
echo Install the Windows Driver Kit with the SAME version number as one of these SDK folders, then run this again.
echo ^(WDK download: https://learn.microsoft.com/windows-hardware/drivers/download-the-wdk^)
echo If the WDK is installed somewhere else, set WDKContentRoot to its Windows Kits\10 folder.
exit /b 1
:nokmdf
echo KMDF %KMDF_VER% headers or libraries are missing under %KITS%. Set KMDF_VER to a version that is installed.
exit /b 1

rem :find_tool exe-name VARIABLE   looks in bin\WDKVER\x64 and x86
:find_tool
set "%~2="
for %%A in (x64 x86) do if not defined %~2 if exist "%KITS%\bin\%WDKVER%\%%A\%~1" set "%~2=%KITS%\bin\%WDKVER%\%%A\%~1"
exit /b 0

rem cl and link for x64: from the current Developer Command Prompt, else found with vswhere
:find_msvc
where cl >nul 2>&1
if not errorlevel 1 goto :msvc_have
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :nomsvc
set "VSDIR="
for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%I"
if not defined VSDIR goto :nomsvc
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul
:msvc_have
where cl >nul 2>&1
if errorlevel 1 goto :nomsvc
if not defined VSCMD_ARG_TGT_ARCH exit /b 0
if /i "%VSCMD_ARG_TGT_ARCH%"=="x64" exit /b 0
echo This prompt builds for %VSCMD_ARG_TGT_ARCH%. Open the "x64 Native Tools Command Prompt for VS" instead.
exit /b 1
:nomsvc
echo cl.exe not found. Install Visual Studio with "Desktop development with C++", or run this from the x64 Native Tools Command Prompt.
exit /b 1
