/*
 * pico_vhf_ioctl.h - interface between the pico_vhf driver and the pico-vhid helper (user mode).
 *
 * The helper opens the driver's device interface (exclusive, administrators only) and:
 *   IOCTL_PICO_VHF_CREATE  in: PICO_VHF_CREATE      creates the virtual FIDO HID device (VhfCreate + VhfStart)
 *   IOCTL_PICO_VHF_INPUT   in: 64-byte report        token -> OS (VhfReadReportSubmit)
 *   IOCTL_PICO_VHF_OUTPUT  out: 64-byte report       OS -> token; pends until the OS writes an output report
 * Closing the handle deletes the HID device again, so it only exists while the bridge runs (like Linux uhid).
 */
#ifndef PICO_VHF_IOCTL_H
#define PICO_VHF_IOCTL_H

/* {6f1e2c6b-8a0d-4a55-9d0e-3b1f2f6f5a01} */
DEFINE_GUID(GUID_DEVINTERFACE_PICO_VHF,
            0x6f1e2c6b, 0x8a0d, 0x4a55, 0x9d, 0x0e, 0x3b, 0x1f, 0x2f, 0x6f, 0x5a, 0x01);

#define PICO_VHF_REPORT_LEN 64

#define PICO_VHF_DEVICE_TYPE 0x8F1D
#define IOCTL_PICO_VHF_CREATE CTL_CODE(PICO_VHF_DEVICE_TYPE, 0x800, METHOD_BUFFERED, FILE_WRITE_ACCESS)
#define IOCTL_PICO_VHF_INPUT  CTL_CODE(PICO_VHF_DEVICE_TYPE, 0x801, METHOD_BUFFERED, FILE_WRITE_ACCESS)
#define IOCTL_PICO_VHF_OUTPUT CTL_CODE(PICO_VHF_DEVICE_TYPE, 0x802, METHOD_BUFFERED, FILE_READ_ACCESS)

typedef struct _PICO_VHF_CREATE {
    unsigned short VendorID;
    unsigned short ProductID;
} PICO_VHF_CREATE;

#endif
