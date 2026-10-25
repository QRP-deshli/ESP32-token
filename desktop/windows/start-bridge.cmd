@echo off
rem Daily start of the serial bridge: makes your PC see the token as a USB FIDO key.
rem Leave this window open while you use the token; Ctrl+C stops it (answer Y if asked to terminate the batch job).
rem   desktop\windows\start-bridge.cmd          normal
rem   desktop\windows\start-bridge.cmd -v       also print every packet
setlocal EnableExtensions
call "%~dp0common.cmd"

if not defined PYTHON (
    call "%LIB%" :bad "Python 3 is not installed (https://www.python.org/downloads/windows/)"
    exit /b 1
)
call "%LIB%" :bridge_running
if not errorlevel 1 (
    call "%LIB%" :bad "the bridge is already running (in another window?)"
    call "%LIB%" :info "Stop it with Ctrl+C in that window."
    exit /b 1
)
call "%LIB%" :get_vhid_helper
if errorlevel 1 (
    call "%LIB%" :bad "the virtual HID driver and helper are not installed, so browsers cannot see the token."
    call "%LIB%" :info "See desktop\windows\vhid\README.md. Fingerprint management works without them: setup-token.cmd"
    exit /b 1
)
call "%LIB%" :test_admin
if errorlevel 1 (
    call "%LIB%" :bad "the bridge needs an administrator Command Prompt on Windows (the virtual HID driver only lets administrators in)."
    exit /b 1
)

call "%LIB%" :ok "starting the bridge. Keep this window open; it prints >>> TOUCH THE FINGERPRINT SENSOR NOW <<< when needed."

rem Handle 9 is the lock that :bridge_running tests; it is held until the bridge (and its helper) have ended.
rem setup-token.cmd starts this script with PICO_BG_LOG set to get the bridge's log (stderr) in a file.
if defined PICO_BG_LOG (
    9>"%BRIDGE_LOCK%" 2>"%PICO_BG_LOG%" call :run %*
) else (
    9>"%BRIDGE_LOCK%" call :run %*
)
exit /b %errorlevel%

:run
pushd "%BRIDGE_DIR%" || exit /b 1
%PYTHON% ctaphid_serial_bridge.py %*
set "RC=%errorlevel%"
popd
exit /b %RC%
