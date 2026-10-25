@echo off
rem ---------------------------------------------------------------------------------------------------------------
rem Shared helpers for the .cmd scripts in this folder (replacement for common.ps1).
rem
rem   call "%~dp0common.cmd"                 sets the variables below (no setlocal here, so they reach the caller)
rem   call "%LIB%" :label arg1 arg2 ...      runs one helper; text arguments in "double quotes", without ! or %
rem
rem Variables after init: LIB SCRIPTS_DIR DESKTOP_DIR BRIDGE_DIR BRIDGE_LOG BRIDGE_LOCK PYTHON
rem Helpers return 0 for "yes / ok / found" and 1 for "no / not found" unless noted.
rem ---------------------------------------------------------------------------------------------------------------
if "%~1"=="" goto :init
goto %~1

:init
set "LIB=%~f0"
set "SCRIPTS_DIR=%~dp0"
if "%SCRIPTS_DIR:~-1%"=="\" set "SCRIPTS_DIR=%SCRIPTS_DIR:~0,-1%"
for %%I in ("%SCRIPTS_DIR%\..") do set "DESKTOP_DIR=%%~fI"
set "BRIDGE_DIR=%DESKTOP_DIR%\common"
if defined PICO_BRIDGE_DIR set "BRIDGE_DIR=%PICO_BRIDGE_DIR%"
set "BRIDGE_LOG=%TEMP%\pico-fido2-bridge.log"
set "BRIDGE_LOCK=%TEMP%\pico-fido2-bridge.lock"
set "PYTHON="
where py >nul 2>&1 && set "PYTHON=py -3"
if not defined PYTHON where python >nul 2>&1 && set "PYTHON=python"
exit /b 0

rem ---- output ---------------------------------------------------------------------------------------------------
:ok
setlocal EnableDelayedExpansion
set "m=%~2"
echo [ ok ] !m!
exit /b 0

:warn
setlocal EnableDelayedExpansion
set "m=%~2"
echo [WARN] !m!
exit /b 0

:bad
setlocal EnableDelayedExpansion
set "m=%~2"
echo [FAIL] !m!
exit /b 0

:info
setlocal EnableDelayedExpansion
set "m=%~2"
echo        !m!
exit /b 0

rem ---- small utilities ------------------------------------------------------------------------------------------
rem :sleep SECONDS
:sleep
set /a "_p=%~2+1"
ping -n %_p% 127.0.0.1 >nul
exit /b 0

rem :ask_yn "question" y or n      returns: 0 = yes, 1 = no (Enter = the default; end of input = the default)
:ask_yn
set "_d=%~3"
if /i "%_d%"=="y" (set "_h=[Y/n]") else (set "_h=[y/N]")
set "_a="
set /p "_a=%~2 %_h% "
if not defined _a set "_a=%_d%"
if /i "%_a%"=="y" exit /b 0
if /i "%_a%"=="yes" exit /b 0
exit /b 1

rem :need_cmd name "hint"        returns: 0 if the command exists, else prints a [FAIL] line and returns 1
:need_cmd
where %~2 >nul 2>&1 && exit /b 0
if "%~3"=="" (call "%LIB%" :bad "'%~2' is not installed") else call "%LIB%" :bad "'%~2' is not installed (%~3)"
exit /b 1

rem :test_admin                  returns: 0 if this Command Prompt is elevated
:test_admin
fltmc >nul 2>&1
exit /b %errorlevel%

rem :get_vhid_helper             returns: sets VHID_HELPER_PATH (empty if the helper is not installed)
:get_vhid_helper
set "VHID_HELPER_PATH="
if defined PICO_VHID_HELPER if exist "%PICO_VHID_HELPER%" set "VHID_HELPER_PATH=%PICO_VHID_HELPER%"
if not defined VHID_HELPER_PATH if exist "%SCRIPTS_DIR%\vhid\pico-vhid.exe" set "VHID_HELPER_PATH=%SCRIPTS_DIR%\vhid\pico-vhid.exe"
if defined VHID_HELPER_PATH exit /b 0
exit /b 1

rem :driver_installed            returns: 0 if a Root\PicoVhf device exists (read from the registry, no tool needed)
:driver_installed
reg query "HKLM\SYSTEM\CurrentControlSet\Enum\ROOT\HIDCLASS" /s /v HardwareID 2>nul | findstr /i /c:"Root\PicoVhf" >nul
exit /b %errorlevel%

rem ---- the bridge -----------------------------------------------------------------------------------------------
rem start-bridge.cmd holds an exclusive lock on %BRIDGE_LOCK% while the bridge runs (also in another window, and as
rem long as any child process keeps the handle). Trying to append to the locked file fails: that is the test.
rem :bridge_running              returns: 0 = a bridge is running, 1 = none
:bridge_running
if not exist "%BRIDGE_LOCK%" exit /b 1
2>nul (>>"%BRIDGE_LOCK%" (call )) && exit /b 1
exit /b 0

rem Background bridge, started by setup-token.cmd (own window, minimised, titled PICO_BG_BRIDGE, log in BRIDGE_LOG).
rem :start_bridge_bg
:start_bridge_bg
type nul >"%BRIDGE_LOG%"
set "PICO_BG_LOG=%BRIDGE_LOG%"
start "PICO_BG_BRIDGE" /min "%SCRIPTS_DIR%\start-bridge.cmd"
set "PICO_BG_LOG="
exit /b 0

rem Stops only a bridge that start_bridge_bg started (a bridge in your own window is closed with Ctrl+C there).
rem :stop_bridge_bg
:stop_bridge_bg
taskkill /f /t /fi "WINDOWTITLE eq PICO_BG_BRIDGE" >nul 2>&1
set "_i=0"
:sbb_wait
call "%LIB%" :bridge_running || exit /b 0
set /a "_i+=1"
if %_i% geq 6 exit /b 0
call "%LIB%" :sleep 1
goto :sbb_wait

rem number of "token on" lines in the background bridge's log returns: CONN
:conn_count
set "CONN=0"
if not exist "%BRIDGE_LOG%" exit /b 0
for /f %%N in ('find /c "token on" ^< "%BRIDGE_LOG%"') do set "CONN=%%N"
exit /b 0

rem :wait_conn_gt BASELINE SECONDS   returns: 0 once CONN is higher than BASELINE, 1 on timeout
:wait_conn_gt
set "_i=0"
:wcg_loop
call "%LIB%" :conn_count
if %CONN% gtr %~2 exit /b 0
set /a "_i+=1"
if %_i% gtr %~3 exit /b 1
call "%LIB%" :sleep 1
goto :wcg_loop

rem ---- the virtual FIDO device (needs libfido2's fido2-token) ----------------------------------------------------
rem :find_hid                    returns: sets HID_DEV to the libfido2 path of the virtual device
:find_hid
set "HID_DEV="
where fido2-token >nul 2>&1 || exit /b 1
for /f "tokens=1 delims=:" %%P in ('fido2-token -L 2^>nul ^| findstr /c:"product=0x619b"') do set "HID_DEV=%%P"
if defined HID_DEV exit /b 0
exit /b 1

rem :wait_hid SECONDS            returns: 0 once find_hid succeeds
:wait_hid
set "_j=0"
:wh_loop
call "%LIB%" :find_hid && exit /b 0
set /a "_j+=1"
if %_j% gtr %~2 exit /b 1
call "%LIB%" :sleep 1
goto :wh_loop

rem :token_info                  returns: runs "fido2-token -I %HID_DEV%"; sets TOKEN_ANSWERED (0/1), PIN_STATE, INFO_OUT
:token_info
set "TOKEN_ANSWERED=0"
set "PIN_STATE=PIN state unknown"
set "INFO_OUT=%TEMP%\pico-fido-info.txt"
fido2-token -I "%HID_DEV%" >"%INFO_OUT%" 2>&1
findstr /b /c:"proto:" "%INFO_OUT%" >nul 2>&1 && set "TOKEN_ANSWERED=1"
findstr /b /c:"options:" "%INFO_OUT%" 2>nul | findstr /c:"noclientPin" >nul && (set "PIN_STATE=no PIN set yet" & exit /b 0)
findstr /b /c:"options:" "%INFO_OUT%" 2>nul | findstr /c:"clientPin" >nul && set "PIN_STATE=a PIN is set"
exit /b 0

rem ---- fingerprint state, read with fpctl.py (the bridge must be STOPPED: same serial port) ----------------------
rem :update_state                returns: sets TOKEN_OK SENSOR_OK FINGERS TOKEN_PORT FP_OUT FP_RC (returns fpctl's exit code)
:update_state
set "TOKEN_OK=0"
set "SENSOR_OK=0"
set "FINGERS=0"
set "TOKEN_PORT="
set "FP_OUT=%TEMP%\pico-fpctl-status.txt"
pushd "%BRIDGE_DIR%" || exit /b 1
%PYTHON% fpctl.py status >"%FP_OUT%" 2>&1
set "FP_RC=%errorlevel%"
popd
for /f "tokens=3" %%P in ('findstr /b /c:"token on " "%FP_OUT%"') do (set "TOKEN_PORT=%%P" & set "TOKEN_OK=1")
if not "%FP_RC%"=="0" exit /b %FP_RC%
set "SENSOR_OK=1"
for /f "tokens=3" %%N in ('findstr /b /c:"sensor OK, " "%FP_OUT%"') do set "FINGERS=%%N"
exit /b 0

:show_state_line
if "%TOKEN_OK%"=="1" goto :ssl_token
call "%LIB%" :bad "no token found"
call "%LIB%" :info "Plug the cable into the NATIVE USB port of the ESP32-C6, wait 3 seconds, and make sure the bridge is not running."
call "%LIB%" :info "The token shows up as a COM port (USB Serial Device or USB JTAG/serial debug unit) in Device Manager."
exit /b 0
:ssl_token
call "%LIB%" :ok "token found on %TOKEN_PORT%"
if "%SENSOR_OK%"=="1" goto :ssl_sensor
set "_m=no answer"
for /f "delims=" %%L in ('findstr /v /b /c:"token on " "%FP_OUT%" 2^>nul') do set "_m=%%L"
call "%LIB%" :bad "fingerprint sensor: %_m%"
exit /b 0
:ssl_sensor
call "%LIB%" :ok "fingerprint sensor answers, %FINGERS% finger(s) enrolled"
exit /b 0
