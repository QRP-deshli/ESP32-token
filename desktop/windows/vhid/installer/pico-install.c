/*
 * pico-install.exe - creates / installs / removes the root-enumerated pico_vhf device (Root\PicoVhf).
 * Replaces setupapi.ps1 (the C# SetupAPI calls) so that install.cmd / uninstall.cmd need no PowerShell.
 * Does what "devcon install" / "devcon remove" do.
 *
 *   pico-install status          exit 0 if a Root\PicoVhf device exists, 2 if not
 *   pico-install create          create the (driverless) Root\PicoVhf device
 *   pico-install install X.inf   install / update the driver of Root\PicoVhf from X.inf
 *   pico-install remove          remove the device(s) and their driver package(s)
 *
 * Exit codes: 0 ok, 1 error, 2 not present (status), 10 ok but Windows asks for a reboot.
 * Needs administrator rights (except status).
 *
 * Build (MinGW-w64, 64-bit):
 *   gcc -O2 -s -static -o pico-install.exe pico-install.c -lsetupapi -lnewdev -lshell32
 */
#define WINVER 0x0A00
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <setupapi.h>
#include <devpropdef.h>
#include <newdev.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#define EXIT_OK      0
#define EXIT_ERR     1
#define EXIT_ABSENT  2
#define EXIT_REBOOT  10
#define MAX_INFS     8

static const wchar_t *HWID = L"Root\\PicoVhf";
/* {745a17a0-74d3-11d0-b6fe-00a0c90f57da} = HIDClass */
static const GUID HID_CLASS = { 0x745a17a0, 0x74d3, 0x11d0, { 0xb6, 0xfe, 0x00, 0xa0, 0xc9, 0x0f, 0x57, 0xda } };
/* DEVPKEY_Device_DriverInfPath = {a8b865dd-2e3d-4094-ad97-e593a70c75d6}, 5 (the "oemNN.inf" of the installed driver) */
static const DEVPROPKEY KEY_DRIVER_INF_PATH =
    { { 0xa8b865dd, 0x2e3d, 0x4094, { 0xad, 0x97, 0xe5, 0x93, 0xa7, 0x0c, 0x75, 0xd6 } }, 5 };

static void fail(const char *what)
{
    fprintf(stderr, "pico-install: %s failed (error %lu)\n", what, GetLastError());
}

/* does this device have Root\PicoVhf among its hardware IDs? */
static int has_hwid(HDEVINFO set, SP_DEVINFO_DATA *d)
{
    wchar_t buf[1024];
    DWORD type = 0;
    const wchar_t *p;

    memset(buf, 0, sizeof(buf));
    if (!SetupDiGetDeviceRegistryPropertyW(set, d, SPDRP_HARDWAREID, &type, (PBYTE)buf,
                                           sizeof(buf) - 2 * sizeof(wchar_t), NULL))
        return 0;
    for (p = buf; *p; p += wcslen(p) + 1)
        if (_wcsicmp(p, HWID) == 0)
            return 1;
    return 0;
}

static int cmd_status(void)
{
    HDEVINFO set = SetupDiGetClassDevsW(&HID_CLASS, NULL, NULL, DIGCF_PRESENT);
    SP_DEVINFO_DATA d;
    DWORD i;
    int found = 0;

    if (set == INVALID_HANDLE_VALUE) { fail("SetupDiGetClassDevs"); return EXIT_ERR; }
    for (i = 0; !found; i++) {
        d.cbSize = sizeof(d);
        if (!SetupDiEnumDeviceInfo(set, i, &d))
            break;
        found = has_hwid(set, &d);
    }
    SetupDiDestroyDeviceInfoList(set);
    if (found)
        printf("Root\\PicoVhf is present\n");
    return found ? EXIT_OK : EXIT_ABSENT;
}

static int cmd_create(void)
{
    HDEVINFO set = SetupDiCreateDeviceInfoList(&HID_CLASS, NULL);
    SP_DEVINFO_DATA d;
    wchar_t ids[64];
    DWORD bytes;

    if (set == INVALID_HANDLE_VALUE) { fail("SetupDiCreateDeviceInfoList"); return EXIT_ERR; }
    d.cbSize = sizeof(d);
    /* name "HIDClass" + DICD_GENERATE_ID gives ROOT\HIDCLASS\0000, like devcon does with the class name */
    if (!SetupDiCreateDeviceInfoW(set, L"HIDClass", &HID_CLASS, NULL, NULL, DICD_GENERATE_ID, &d)) {
        fail("SetupDiCreateDeviceInfo");
        goto err;
    }
    memset(ids, 0, sizeof(ids));                       /* REG_MULTI_SZ: the ID, then an empty string */
    wcscpy(ids, HWID);
    bytes = (DWORD)((wcslen(HWID) + 2) * sizeof(wchar_t));
    if (!SetupDiSetDeviceRegistryPropertyW(set, &d, SPDRP_HARDWAREID, (const BYTE *)ids, bytes)) {
        fail("SetupDiSetDeviceRegistryProperty");
        goto err;
    }
    if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, &d)) {
        fail("SetupDiCallClassInstaller(DIF_REGISTERDEVICE)");
        goto err;
    }
    SetupDiDestroyDeviceInfoList(set);
    printf("created the Root\\PicoVhf device\n");
    return EXIT_OK;
err:
    SetupDiDestroyDeviceInfoList(set);
    return EXIT_ERR;
}

static int cmd_install(const wchar_t *inf)
{
    wchar_t full[MAX_PATH];
    BOOL reboot = FALSE;

    if (!GetFullPathNameW(inf, MAX_PATH, full, NULL)) { fail("GetFullPathName"); return EXIT_ERR; }
    if (GetFileAttributesW(full) == INVALID_FILE_ATTRIBUTES) {
        fprintf(stderr, "pico-install: %ls not found\n", full);
        return EXIT_ERR;
    }
    if (!UpdateDriverForPlugAndPlayDevicesW(NULL, HWID, full, INSTALLFLAG_FORCE, &reboot)) {
        fail("UpdateDriverForPlugAndPlayDevices");
        return EXIT_ERR;
    }
    printf("driver installed\n");
    return reboot ? EXIT_REBOOT : EXIT_OK;
}

static int cmd_remove(void)
{
    HDEVINFO set = SetupDiGetClassDevsW(&HID_CLASS, NULL, NULL, 0);     /* also devices that are not present */
    SP_DEVINFO_DATA d;
    wchar_t infs[MAX_INFS][MAX_PATH];
    int ninf = 0, removed = 0, reboot = 0, i, rc = EXIT_OK;
    DWORD idx;

    if (set == INVALID_HANDLE_VALUE) { fail("SetupDiGetClassDevs"); return EXIT_ERR; }
    for (idx = 0; ; idx++) {
        wchar_t inf[MAX_PATH];
        DEVPROPTYPE type = 0;
        SP_DEVINSTALL_PARAMS_W params;

        d.cbSize = sizeof(d);
        if (!SetupDiEnumDeviceInfo(set, idx, &d))
            break;
        if (!has_hwid(set, &d))
            continue;
        memset(inf, 0, sizeof(inf));
        if (SetupDiGetDevicePropertyW(set, &d, &KEY_DRIVER_INF_PATH, &type, (PBYTE)inf, sizeof(inf) - sizeof(wchar_t),
                                      NULL, 0) && inf[0] && ninf < MAX_INFS)
            wcscpy(infs[ninf++], inf);                    /* remember "oemNN.inf" before the device is gone */
        if (SetupDiCallClassInstaller(DIF_REMOVE, set, &d)) {
            removed++;
            memset(&params, 0, sizeof(params));
            params.cbSize = sizeof(params);
            if (SetupDiGetDeviceInstallParamsW(set, &d, &params) && (params.Flags & (DI_NEEDRESTART | DI_NEEDREBOOT)))
                reboot = 1;
        } else {
            fail("SetupDiCallClassInstaller(DIF_REMOVE)");
            rc = EXIT_ERR;
        }
    }
    SetupDiDestroyDeviceInfoList(set);
    printf("removed %d device(s)\n", removed);

    for (i = 0; i < ninf; i++) {
        if (SetupUninstallOEMInfW(infs[i], SUOI_FORCEDELETE, NULL))
            printf("removed driver package %ls\n", infs[i]);
        else
            fprintf(stderr, "pico-install: could not remove %ls (error %lu)\n", infs[i], GetLastError());
    }
    if (rc == EXIT_OK && reboot)
        rc = EXIT_REBOOT;
    return rc;
}

int main(void)
{
    int argc = 0, rc;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);

    if (!argv || argc < 2) goto usage;
    if (!_wcsicmp(argv[1], L"status"))                    rc = cmd_status();
    else if (!_wcsicmp(argv[1], L"create"))               rc = cmd_create();
    else if (!_wcsicmp(argv[1], L"install") && argc >= 3) rc = cmd_install(argv[2]);
    else if (!_wcsicmp(argv[1], L"remove"))               rc = cmd_remove();
    else goto usage;
    return rc;
usage:
    fprintf(stderr, "usage: pico-install status | create | install <file.inf> | remove\n");
    return EXIT_ERR;
}
