@echo off
rem Read-only check: is the token there, does the sensor answer, how many fingers are enrolled, is the PC set up?
rem Exit code 0 = ready to use, 1 = something is missing.
rem   desktop\windows\check-token.cmd
setlocal EnableExtensions
call "%~dp0common.cmd"
set "PROBLEMS=0"

echo Pico FIDO2 token check
echo.

rem --- the PC side ---
if not defined PYTHON (
    call "%LIB%" :bad "Python 3 is not installed (https://www.python.org/downloads/windows/)"
    exit /b 1
)
call "%LIB%" :get_vhid_helper
if errorlevel 1 goto :no_helper
call "%LIB%" :ok "virtual HID helper found (%VHID_HELPER_PATH%)"
call "%LIB%" :driver_installed
if errorlevel 1 (
    call "%LIB%" :warn "virtual HID driver not installed: run desktop\windows\vhid\install.cmd as administrator"
    set "PROBLEMS=1"
) else (
    call "%LIB%" :ok "virtual HID driver installed (Root\PicoVhf)"
)
goto :token_side
:no_helper
call "%LIB%" :warn "virtual HID helper not installed: browsers cannot use the token, fingerprints work (desktop\windows\vhid\README.md)"
call "%LIB%" :driver_installed
if not errorlevel 1 call "%LIB%" :ok "virtual HID driver installed (Root\PicoVhf)"

rem --- the token side ---
:token_side
call "%LIB%" :bridge_running
if errorlevel 1 goto :serial_side
call "%LIB%" :ok "the bridge is running"
call "%LIB%" :need_cmd fido2-token "libfido2 tools for Windows, see desktop\windows\README.md"
if errorlevel 1 goto :bridge_note
call "%LIB%" :find_hid
if errorlevel 1 (
    call "%LIB%" :warn "the bridge runs but no virtual FIDO device was found (fido2-token -L may need an administrator prompt)"
    set "PROBLEMS=1"
    goto :bridge_note
)
call "%LIB%" :ok "virtual FIDO device %HID_DEV%"
call "%LIB%" :token_info
if "%TOKEN_ANSWERED%"=="1" (
    call "%LIB%" :ok "token answers: %PIN_STATE%"
) else (
    call "%LIB%" :warn "the virtual device exists but the token did not answer (unplugged? restart the bridge)"
    set "PROBLEMS=1"
)
:bridge_note
call "%LIB%" :info "Fingerprints can't be counted while the bridge runs (it uses the same serial port)."
call "%LIB%" :info "Close the bridge window (Ctrl+C there) and run this check again to count the enrolled fingers."
echo.
echo Not fully checked (bridge running).
exit /b %PROBLEMS%

:serial_side
call "%LIB%" :update_state
call "%LIB%" :show_state_line
if not "%TOKEN_OK%%SENSOR_OK%"=="11" set "PROBLEMS=1"
if "%SENSOR_OK%"=="1" if "%FINGERS%"=="0" (
    call "%LIB%" :warn "no finger enrolled: the token refuses everything until you run desktop\windows\setup-token.cmd"
    set "PROBLEMS=1"
)
if "%TOKEN_OK%"=="1" call "%LIB%" :info "The token's own keys are created automatically the first time it is used; they can't be read from the PC."

echo.
if "%PROBLEMS%"=="0" (
    echo Ready. Start the bridge with desktop\windows\start-bridge.cmd
) else (
    echo Not ready. desktop\windows\setup-token.cmd helps with fingers; see the README troubleshooting table.
)
exit /b %PROBLEMS%
