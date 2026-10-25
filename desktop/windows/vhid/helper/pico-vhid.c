/*
 * pico-vhid.exe - virtual FIDO HID helper for ctaphid_serial_bridge.py on Windows.
 *
 * Opens the pico_vhf driver (../driver), creates the HID device, then moves 64-byte reports between it and the bridge
 * (the helper protocol in desktop/common/virtual_hid.py):
 *   - output reports from the OS (browser -> token) are written to stdout, 64 bytes each, no report ID
 *   - input reports read from stdin (token -> browser), 64 bytes each, are handed to the OS
 *   - log lines go to stderr; the helper exits when stdin is closed, and the driver then removes the HID device
 *
 *   pico-vhid.exe --name "Pico FIDO2 (serial bridge)" --vid 0x1d50 --pid 0x619b
 *
 * Needs administrator rights (the driver's device is restricted to administrators). Build:
 *   gcc -O2 -o pico-vhid.exe pico-vhid.c -lsetupapi        (MinGW)
 *   cl /O2 pico-vhid.c setupapi.lib                         (MSVC)
 */
#include <windows.h>
#include <winioctl.h>     /* CTL_CODE (MinGW does not always pull it in through windows.h) */
#include <initguid.h>
#include <setupapi.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <io.h>
#include "../pico_vhf_ioctl.h"

static HANDLE dev = INVALID_HANDLE_VALUE;

static void logmsg(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fputs("pico-vhid: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

/* Path of the first present pico_vhf device interface, or NULL. */
static char *find_device(void)
{
    HDEVINFO set = SetupDiGetClassDevsA(&GUID_DEVINTERFACE_PICO_VHF, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    SP_DEVICE_INTERFACE_DATA ifd;
    SP_DEVICE_INTERFACE_DETAIL_DATA_A *detail;
    DWORD need = 0;
    char *path = NULL;

    if (set == INVALID_HANDLE_VALUE)
        return NULL;
    ifd.cbSize = sizeof(ifd);
    if (SetupDiEnumDeviceInterfaces(set, NULL, &GUID_DEVINTERFACE_PICO_VHF, 0, &ifd)) {
        SetupDiGetDeviceInterfaceDetailA(set, &ifd, NULL, 0, &need, NULL);
        detail = (SP_DEVICE_INTERFACE_DETAIL_DATA_A *)malloc(need);
        if (detail) {
            detail->cbSize = (sizeof(void *) == 8) ? 8 : 5;   /* the documented value; sizeof() depends on struct packing */
            if (SetupDiGetDeviceInterfaceDetailA(set, &ifd, detail, need, NULL, NULL))
                path = _strdup(detail->DevicePath);
            free(detail);
        }
    }
    SetupDiDestroyDeviceInfoList(set);
    return path;
}

/* DeviceIoControl on the overlapped handle, waiting for completion. Returns bytes returned, or -1. */
static long ioctl(DWORD code, void *in, DWORD inLen, void *out, DWORD outLen)
{
    OVERLAPPED ov;
    DWORD n = 0;
    memset(&ov, 0, sizeof(ov));
    ov.hEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    if (!ov.hEvent)
        return -1;
    if (!DeviceIoControl(dev, code, in, inLen, out, outLen, &n, &ov)) {
        if (GetLastError() != ERROR_IO_PENDING || !GetOverlappedResult(dev, &ov, &n, TRUE)) {
            CloseHandle(ov.hEvent);
            return -1;
        }
    }
    CloseHandle(ov.hEvent);
    return (long)n;
}

/* token -> OS: read 64-byte input reports from stdin until it is closed, then exit (the driver removes the device). */
static DWORD WINAPI stdin_reader(LPVOID arg)
{
    unsigned char report[PICO_VHF_REPORT_LEN];
    (void)arg;
    for (;;) {
        size_t got = 0;
        while (got < sizeof(report)) {
            size_t n = fread(report + got, 1, sizeof(report) - got, stdin);
            if (n == 0) {
                CloseHandle(dev);
                ExitProcess(0);
            }
            got += n;
        }
        if (ioctl(IOCTL_PICO_VHF_INPUT, report, sizeof(report), NULL, 0) < 0)
            logmsg("input report failed (error %lu)", GetLastError());
    }
}

static unsigned short number(const char *s)
{
    return (unsigned short)strtoul(s, NULL, 0);
}

int main(int argc, char **argv)
{
    PICO_VHF_CREATE ids = { 0x1D50, 0x619B };
    unsigned char report[PICO_VHF_REPORT_LEN];
    char *path;
    int i;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--vid") && i + 1 < argc) ids.VendorID = number(argv[++i]);
        else if (!strcmp(argv[i], "--pid") && i + 1 < argc) ids.ProductID = number(argv[++i]);
        else if (!strcmp(argv[i], "--name") && i + 1 < argc) i++;     /* VHF has no product string */
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            printf("usage: pico-vhid [--name NAME] [--vid 0xVVVV] [--pid 0xPPPP]  (started by ctaphid_serial_bridge.py)\n");
            return 0;
        } else {
            logmsg("unknown argument %s", argv[i]);
            return 1;
        }
    }
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);

    path = find_device();
    if (!path) {
        logmsg("the pico_vhf driver is not installed (run desktop\\windows\\vhid\\install.cmd as administrator)");
        return 1;
    }
    dev = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
    free(path);
    if (dev == INVALID_HANDLE_VALUE) {
        DWORD e = GetLastError();
        if (e == ERROR_ACCESS_DENIED)
            logmsg("access denied: run the bridge as administrator, and only one bridge at a time");
        else
            logmsg("cannot open the pico_vhf driver (error %lu)", e);
        return 1;
    }
    if (ioctl(IOCTL_PICO_VHF_CREATE, &ids, sizeof(ids), NULL, 0) < 0) {
        logmsg("cannot create the virtual HID device (error %lu)", GetLastError());
        return 1;
    }
    logmsg("virtual FIDO device %04x:%04x active", ids.VendorID, ids.ProductID);
    if (!CreateThread(NULL, 0, stdin_reader, NULL, 0, NULL)) {
        logmsg("cannot start the input thread");
        return 1;
    }

    /* OS -> token: each completed IOCTL_PICO_VHF_OUTPUT is one output report */
    for (;;) {
        long n = ioctl(IOCTL_PICO_VHF_OUTPUT, NULL, 0, report, sizeof(report));
        if (n < 0) {
            logmsg("output report failed (error %lu)", GetLastError());
            return 1;
        }
        if (n == sizeof(report)) {
            if (fwrite(report, 1, sizeof(report), stdout) != sizeof(report) || fflush(stdout))
                return 0;                       /* the bridge is gone */
        }
    }
}
