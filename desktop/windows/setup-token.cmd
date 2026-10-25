@echo off
rem Interactive setup for the Pico FIDO2 token. It first shows what the token already has (fingers enrolled), then lets
rem you enrol more fingers, test or delete them, initialise the token's keys, or start over with a new token identity,
rem and finally offers to start the bridge.
rem
rem   desktop\windows\setup-token.cmd
rem
rem Run it with the token plugged into the NATIVE USB port. fpctl.py and the bridge need the same serial port, so the
rem bridge must not run in another window (the script asks you to close it). Options 5 and 6 and the bridge need the
rem virtual HID driver (desktop\windows\vhid\README.md), libfido2's fido2-token and an administrator Command Prompt.
setlocal EnableExtensions
call "%~dp0common.cmd"

echo Pico FIDO2 token setup
echo.
if not defined PYTHON (
    call "%LIB%" :bad "Python 3 is not installed (https://www.python.org/downloads/windows/)"
    exit /b 1
)
if not exist "%BRIDGE_DIR%\fpctl.py" (
    call "%LIB%" :bad "cannot find %BRIDGE_DIR%\fpctl.py"
    exit /b 1
)

rem a leftover background bridge of an earlier run is stopped silently; one in your own window you have to close
call "%LIB%" :stop_bridge_bg
:wait_bridge_closed
call "%LIB%" :bridge_running
if errorlevel 1 goto :bridge_free
call "%LIB%" :warn "The bridge is running in another window and blocks the token's serial port."
call "%LIB%" :info "Close that window (Ctrl+C there), then press Enter here. Type q to quit."
set "ANS="
set /p "ANS=> "
if /i "%ANS%"=="q" exit /b 1
goto :wait_bridge_closed
:bridge_free

call "%LIB%" :update_state
call "%LIB%" :show_state_line
if not "%TOKEN_OK%%SENSOR_OK%"=="11" goto :menu
if not "%FINGERS%"=="0" goto :menu
echo.
call "%LIB%" :info "No finger is enrolled yet, so the token would refuse everything."
call "%LIB%" :ask_yn "Enrol your first finger now?" y
if not errorlevel 1 call :enroll_flow

rem ---------------------------------------------------------------------------------------------------------------
:menu
echo.
call "%LIB%" :update_state
if not "%TOKEN_OK%%SENSOR_OK%"=="11" goto :menu_nostate
echo Token on %TOKEN_PORT%, %FINGERS% finger(s) enrolled.
goto :menu_show
:menu_nostate
call "%LIB%" :show_state_line
:menu_show
echo.
echo What do you want to do?
echo   1) Enrol a finger (the first one, or another one)
echo   2) Test a finger
echo   3) Delete one finger
echo   4) Delete ALL fingers
echo   5) Initialise the token's keys (safe to repeat)
echo   6) Create a NEW token identity (erases all registered accounts and the PIN)
echo   7) Start the bridge and use the token
echo   q) Quit
set "CHOICE="
set /p "CHOICE=Choice: "
if not defined CHOICE goto :quit
if /i "%CHOICE%"=="q" goto :quit
if "%CHOICE%"=="1" call :enroll_flow
if "%CHOICE%"=="2" call :test_flow
if "%CHOICE%"=="3" call :delete_one_flow
if "%CHOICE%"=="4" call :delete_all_flow
if "%CHOICE%"=="5" call :init_keys_flow
if "%CHOICE%"=="6" call :reset_flow
if "%CHOICE%"=="7" goto :start_now
if not "%CHOICE%"=="1" if not "%CHOICE%"=="2" if not "%CHOICE%"=="3" if not "%CHOICE%"=="4" if not "%CHOICE%"=="5" if not "%CHOICE%"=="6" call "%LIB%" :warn "unknown choice"
goto :menu

:quit
echo.
call "%LIB%" :get_vhid_helper
if errorlevel 1 goto :end
call "%LIB%" :ask_yn "Start the bridge now?" y
if errorlevel 1 goto :end
:start_now
call "%LIB%" :stop_bridge_bg
call "%SCRIPTS_DIR%\start-bridge.cmd"
exit /b %errorlevel%

:end
call "%LIB%" :stop_bridge_bg
exit /b 0

rem ===============================================================================================================
rem helpers of this script (called with a plain "call :label")
rem ===============================================================================================================

rem run fpctl.py interactively (output goes to the console); returns its exit code
:run_fpctl
pushd "%BRIDGE_DIR%" || exit /b 1
%PYTHON% fpctl.py %*
set "FPRC=%errorlevel%"
popd
exit /b %FPRC%

rem :read_id "prompt"  returns: sets ID (digits only); returns 1 if the input was not a number
:read_id
set "ID="
set /p "ID=%~1: "
if not defined ID goto :rid_bad
for /f "delims=0123456789" %%X in ("%ID%") do goto :rid_bad
exit /b 0
:rid_bad
call "%LIB%" :bad "not a number"
set "ID="
exit /b 1

rem the helper + administrator prerequisites of the bridge
:need_helper
call "%LIB%" :get_vhid_helper
if not errorlevel 1 goto :nh_admin
call "%LIB%" :bad "the virtual HID driver and helper are not installed, and this needs the bridge."
call "%LIB%" :info "See desktop\windows\vhid\README.md."
exit /b 1
:nh_admin
call "%LIB%" :test_admin
if not errorlevel 1 exit /b 0
call "%LIB%" :bad "this needs an administrator Command Prompt (bridge and fido2-token)."
exit /b 1

rem start the bridge in the background and wait for it to find the token
:bridge_up
call "%LIB%" :start_bridge_bg
call "%LIB%" :wait_conn_gt 0 10
if not errorlevel 1 exit /b 0
call "%LIB%" :bad "the bridge could not reach the token (see %BRIDGE_LOG%)"
call "%LIB%" :stop_bridge_bg
exit /b 1

rem ---------------------------------------------------------------------------------------------------------------
:enroll_flow
call "%LIB%" :update_state
if "%TOKEN_OK%%SENSOR_OK%"=="11" goto :ef_ok
call "%LIB%" :show_state_line
exit /b 0
:ef_ok
if "%FINGERS%"=="0" goto :ef_first
call "%LIB%" :info "%FINGERS% finger(s) are already enrolled. To add one you first touch the sensor with an ENROLLED finger."
call "%LIB%" :ask_yn "Enrol another finger?" n
if errorlevel 1 exit /b 0
goto :ef_go
:ef_first
call "%LIB%" :info "No finger is enrolled yet. The first one needs no authorisation. Three touches, lifting in between."
:ef_go
call :run_fpctl enroll
set "RC=%errorlevel%"
if "%RC%"=="0" goto :ef_done
call "%LIB%" :info "If it says the ID is already in use (after deleting fingers the numbers have gaps), pick a free ID."
call "%LIB%" :ask_yn "Try again with a specific ID (1..4095)?" n
if errorlevel 1 exit /b 0
call :read_id "ID"
if errorlevel 1 exit /b 0
call :run_fpctl enroll --id %ID%
set "RC=%errorlevel%"
:ef_done
call "%LIB%" :update_state
if not "%RC%"=="0" exit /b 0
call "%LIB%" :ok "now %FINGERS% finger(s) enrolled"
if "%FINGERS%"=="1" call "%LIB%" :info "Tip: enrol a second finger as a backup (menu option 1 again)."
exit /b 0

:test_flow
call "%LIB%" :update_state
if "%SENSOR_OK%"=="1" goto :tf_go
call "%LIB%" :show_state_line
exit /b 0
:tf_go
call :run_fpctl test
exit /b 0

:delete_one_flow
call "%LIB%" :update_state
if "%SENSOR_OK%"=="1" goto :d1_ok
call "%LIB%" :show_state_line
exit /b 0
:d1_ok
if not "%FINGERS%"=="0" goto :d1_have
call "%LIB%" :info "No fingers enrolled."
exit /b 0
:d1_have
call "%LIB%" :info "Fingers are numbered in the order you enrolled them (1, 2, ...). You must authorise with an enrolled finger."
call :read_id "ID to delete (1..%FINGERS%)"
if errorlevel 1 exit /b 0
if "%FINGERS%"=="1" call "%LIB%" :warn "This is your only finger: afterwards the token refuses everything until you enrol a new one."
call "%LIB%" :ask_yn "Delete finger %ID%?" n
if errorlevel 1 exit /b 0
call :run_fpctl delete %ID%
call "%LIB%" :update_state
call "%LIB%" :info "%FINGERS% finger(s) left."
exit /b 0

:delete_all_flow
call "%LIB%" :update_state
if "%SENSOR_OK%"=="1" goto :da_ok
call "%LIB%" :show_state_line
exit /b 0
:da_ok
if not "%FINGERS%"=="0" goto :da_have
call "%LIB%" :info "No fingers enrolled."
exit /b 0
:da_have
call "%LIB%" :warn "This removes ALL %FINGERS% fingerprint(s). The token will refuse everything until you enrol again."
set "ANS="
set /p "ANS=Delete ALL fingerprints? type yes: "
if "%ANS%"=="yes" goto :da_go
call "%LIB%" :info "cancelled"
exit /b 0
:da_go
call :run_fpctl delete-all --yes
call "%LIB%" :update_state
call "%LIB%" :info "%FINGERS% finger(s) left."
exit /b 0

rem ---------------------------------------------------------------------------------------------------------------
:init_keys_flow
call :need_helper
if errorlevel 1 exit /b 0
call "%LIB%" :need_cmd fido2-token "libfido2 tools for Windows, see desktop\windows\README.md"
if errorlevel 1 exit /b 0
call "%LIB%" :info "This sends the token its first FIDO message. On a brand-new token that is the moment it creates its keys"
call "%LIB%" :info "(the ESP32 monitor shows 'KEY DEVICE is empty. Generating...'). On a token that has them nothing changes."
call "%LIB%" :ask_yn "Go ahead?" y
if errorlevel 1 exit /b 0
call :bridge_up
if errorlevel 1 exit /b 0
call "%LIB%" :wait_hid 10
if not errorlevel 1 goto :ik_dev
call "%LIB%" :bad "no virtual FIDO device appeared"
call "%LIB%" :stop_bridge_bg
exit /b 0
:ik_dev
call "%LIB%" :token_info
if not "%TOKEN_ANSWERED%"=="1" goto :ik_noanswer
call "%LIB%" :ok "the token answered (%HID_DEV%): %PIN_STATE%"
goto :ik_stop
:ik_noanswer
set "_l=no output"
for /f "delims=" %%L in ('type "%INFO_OUT%"') do set "_l=%%L"
call "%LIB%" :bad "the token did not answer: %_l%"
:ik_stop
call "%LIB%" :stop_bridge_bg
exit /b 0

:reset_flow
call :need_helper
if errorlevel 1 exit /b 0
call "%LIB%" :need_cmd fido2-token "libfido2 tools for Windows, see desktop\windows\README.md"
if errorlevel 1 exit /b 0
echo.
call "%LIB%" :warn "NEW TOKEN IDENTITY (FIDO reset)"
call "%LIB%" :info "This erases every account registered on the token and its PIN, and creates a new device key."
call "%LIB%" :info "Websites where you used it will no longer recognise it. Your FINGERPRINTS are not touched."
call "%LIB%" :info "The token only accepts a reset in the first 10 seconds after it is powered up, and it asks for a finger."
set "ANS="
set /p "ANS=Type RESET to continue: "
if "%ANS%"=="RESET" goto :rs_go
call "%LIB%" :info "cancelled"
exit /b 0
:rs_go
call :bridge_up
if errorlevel 1 exit /b 0
call "%LIB%" :conn_count
set "BASE=%CONN%"
echo.
rem no Enter to press: the script notices the replug itself, so none of the 10 seconds is lost waiting for a key
echo Now UNPLUG the token's USB cable and plug it back in (within 60 seconds).
call "%LIB%" :wait_conn_gt %BASE% 60
if not errorlevel 1 goto :rs_back
call "%LIB%" :bad "the bridge did not see the token come back"
call "%LIB%" :stop_bridge_bg
exit /b 0
:rs_back
call "%LIB%" :wait_hid 5
if not errorlevel 1 goto :rs_dev
call "%LIB%" :bad "no virtual FIDO device appeared"
call "%LIB%" :stop_bridge_bg
exit /b 0
:rs_dev
echo Touch the sensor with an ENROLLED finger now ...
fido2-token -R "%HID_DEV%"
set "RC=%errorlevel%"
call "%LIB%" :stop_bridge_bg
if "%RC%"=="0" goto :rs_ok
call "%LIB%" :bad "the reset failed. If it says NOT_ALLOWED the 10-second window had passed: choose this option again."
exit /b 0
:rs_ok
call "%LIB%" :ok "reset done: the token has a new identity. Set a new PIN when a website asks."
exit /b 0
