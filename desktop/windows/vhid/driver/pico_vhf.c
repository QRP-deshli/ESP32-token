/*
 * pico_vhf.c - KMDF driver that gives the serial bridge a virtual FIDO HID device on Windows, through the Virtual
 * HID Framework (VHF, vhf.sys is installed as this device's lower filter by pico_vhf.inf).
 *
 * The helper (../helper/pico-vhid.c) talks to it with the IOCTLs in ../pico_vhf_ioctl.h. Reports are 64 bytes, no
 * report ID, matching FIDO_REPORT_DESC in desktop/common/virtual_hid.py.
 */
#include <ntddk.h>
#include <wdf.h>
#include <initguid.h>
#include <vhf.h>
#include "../pico_vhf_ioctl.h"

#define OUT_QUEUE_LEN 8

static const UCHAR FidoReportDescriptor[] = {
    0x06, 0xD0, 0xF1,        /* Usage Page (FIDO Alliance) */
    0x09, 0x01,              /* Usage (U2F/CTAP HID Authenticator Device) */
    0xA1, 0x01,              /* Collection (Application) */
    0x09, 0x20,              /*   Usage (Input Report Data) */
    0x15, 0x00,              /*   Logical Minimum (0) */
    0x26, 0xFF, 0x00,        /*   Logical Maximum (255) */
    0x75, 0x08,              /*   Report Size (8) */
    0x95, 0x40,              /*   Report Count (64) */
    0x81, 0x02,              /*   Input (Data,Var,Abs) */
    0x09, 0x21,              /*   Usage (Output Report Data) */
    0x15, 0x00,
    0x26, 0xFF, 0x00,
    0x75, 0x08,
    0x95, 0x40,
    0x91, 0x02,              /*   Output (Data,Var,Abs) */
    0xC0,                    /* End Collection */
};

typedef struct _DEVICE_CONTEXT {
    VHFHANDLE Vhf;               /* NULL while no helper has created the HID device */
    WDFQUEUE OutputWaiters;      /* manual queue: pending IOCTL_PICO_VHF_OUTPUT requests */
    WDFSPINLOCK Lock;            /* protects the output report ring */
    UCHAR Out[OUT_QUEUE_LEN][PICO_VHF_REPORT_LEN];
    ULONG OutHead, OutCount;
} DEVICE_CONTEXT, *PDEVICE_CONTEXT;
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEVICE_CONTEXT, GetContext)

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD PicoEvtDeviceAdd;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL PicoEvtIoDeviceControl;
EVT_WDF_FILE_CLEANUP PicoEvtFileCleanup;
EVT_VHF_ASYNC_OPERATION PicoEvtWriteReport;

/* Hand one output report to a waiting helper request, or keep it until the helper asks. */
static VOID DeliverOutput(PDEVICE_CONTEXT ctx)
{
    for (;;) {
        WDFREQUEST req;
        UCHAR report[PICO_VHF_REPORT_LEN];
        PVOID buf;
        NTSTATUS st;

        WdfSpinLockAcquire(ctx->Lock);
        if (ctx->OutCount == 0) {
            WdfSpinLockRelease(ctx->Lock);
            return;
        }
        if (!NT_SUCCESS(WdfIoQueueRetrieveNextRequest(ctx->OutputWaiters, &req))) {
            WdfSpinLockRelease(ctx->Lock);
            return;
        }
        RtlCopyMemory(report, ctx->Out[ctx->OutHead], PICO_VHF_REPORT_LEN);
        ctx->OutHead = (ctx->OutHead + 1) % OUT_QUEUE_LEN;
        ctx->OutCount--;
        WdfSpinLockRelease(ctx->Lock);

        st = WdfRequestRetrieveOutputBuffer(req, PICO_VHF_REPORT_LEN, &buf, NULL);
        if (NT_SUCCESS(st)) {
            RtlCopyMemory(buf, report, PICO_VHF_REPORT_LEN);
            WdfRequestCompleteWithInformation(req, STATUS_SUCCESS, PICO_VHF_REPORT_LEN);
        } else {
            WdfRequestComplete(req, st);
        }
    }
}

/* VHF: the OS wrote an output report (browser -> token). */
VOID PicoEvtWriteReport(PVOID clientContext, VHFOPERATIONHANDLE op, PVOID opContext, PHID_XFER_PACKET packet)
{
    PDEVICE_CONTEXT ctx = (PDEVICE_CONTEXT)clientContext;
    PUCHAR data = packet->reportBuffer;
    ULONG len = packet->reportBufferLen;
    NTSTATUS st = STATUS_SUCCESS;
    UNREFERENCED_PARAMETER(opContext);

    if (len == PICO_VHF_REPORT_LEN + 1 && data[0] == 0) {    /* leading report ID 0 */
        data++;
        len--;
    }
    if (len != PICO_VHF_REPORT_LEN) {
        st = STATUS_INVALID_BUFFER_SIZE;
    } else {
        WdfSpinLockAcquire(ctx->Lock);
        if (ctx->OutCount == OUT_QUEUE_LEN) {                /* helper not reading: drop the oldest */
            ctx->OutHead = (ctx->OutHead + 1) % OUT_QUEUE_LEN;
            ctx->OutCount--;
        }
        RtlCopyMemory(ctx->Out[(ctx->OutHead + ctx->OutCount) % OUT_QUEUE_LEN], data, PICO_VHF_REPORT_LEN);
        ctx->OutCount++;
        WdfSpinLockRelease(ctx->Lock);
        DeliverOutput(ctx);
    }
    VhfAsyncOperationComplete(op, st);
}

static VOID DeleteHid(PDEVICE_CONTEXT ctx)
{
    if (ctx->Vhf != NULL) {
        VhfDelete(ctx->Vhf, TRUE);
        ctx->Vhf = NULL;
    }
    WdfSpinLockAcquire(ctx->Lock);
    ctx->OutHead = ctx->OutCount = 0;
    WdfSpinLockRelease(ctx->Lock);
}

static NTSTATUS CreateHid(WDFDEVICE device, PDEVICE_CONTEXT ctx, const PICO_VHF_CREATE *ids)
{
    VHF_CONFIG cfg;
    NTSTATUS st;

    if (ctx->Vhf != NULL)
        return STATUS_DEVICE_BUSY;
    VHF_CONFIG_INIT(&cfg, WdfDeviceWdmGetDeviceObject(device), sizeof(FidoReportDescriptor),
                    (PUCHAR)FidoReportDescriptor);
    cfg.VhfClientContext = ctx;
    cfg.VendorID = ids->VendorID;
    cfg.ProductID = ids->ProductID;
    cfg.VersionNumber = 0x0100;
    cfg.EvtVhfAsyncOperationWriteReport = PicoEvtWriteReport;
    st = VhfCreate(&cfg, &ctx->Vhf);
    if (!NT_SUCCESS(st)) {
        ctx->Vhf = NULL;
        return st;
    }
    st = VhfStart(ctx->Vhf);
    if (!NT_SUCCESS(st))
        DeleteHid(ctx);
    return st;
}

VOID PicoEvtIoDeviceControl(WDFQUEUE queue, WDFREQUEST req, size_t outLen, size_t inLen, ULONG code)
{
    WDFDEVICE device = WdfIoQueueGetDevice(queue);
    PDEVICE_CONTEXT ctx = GetContext(device);
    NTSTATUS st;
    PVOID in;
    UNREFERENCED_PARAMETER(outLen);
    UNREFERENCED_PARAMETER(inLen);

    switch (code) {
    case IOCTL_PICO_VHF_CREATE:
        st = WdfRequestRetrieveInputBuffer(req, sizeof(PICO_VHF_CREATE), &in, NULL);
        if (NT_SUCCESS(st))
            st = CreateHid(device, ctx, (PICO_VHF_CREATE *)in);
        WdfRequestComplete(req, st);
        return;

    case IOCTL_PICO_VHF_INPUT: {
        HID_XFER_PACKET packet;
        st = WdfRequestRetrieveInputBuffer(req, PICO_VHF_REPORT_LEN, &in, NULL);
        if (NT_SUCCESS(st) && ctx->Vhf == NULL)
            st = STATUS_DEVICE_NOT_READY;
        if (NT_SUCCESS(st)) {
            packet.reportBuffer = (PUCHAR)in;          /* VHF copies the report before returning */
            packet.reportBufferLen = PICO_VHF_REPORT_LEN;
            packet.reportId = 0;
            st = VhfReadReportSubmit(ctx->Vhf, &packet);
        }
        WdfRequestComplete(req, st);
        return;
    }

    case IOCTL_PICO_VHF_OUTPUT:
        st = WdfRequestForwardToIoQueue(req, ctx->OutputWaiters);
        if (!NT_SUCCESS(st))
            WdfRequestComplete(req, st);
        else
            DeliverOutput(ctx);
        return;

    default:
        WdfRequestComplete(req, STATUS_INVALID_DEVICE_REQUEST);
    }
}

/* The helper closed its handle (bridge stopped or crashed): remove the HID device, fail its pending reads. */
VOID PicoEvtFileCleanup(WDFFILEOBJECT file)
{
    PDEVICE_CONTEXT ctx = GetContext(WdfFileObjectGetDevice(file));
    DeleteHid(ctx);
    WdfIoQueuePurgeSynchronously(ctx->OutputWaiters);
    WdfIoQueueStart(ctx->OutputWaiters);
}

NTSTATUS PicoEvtDeviceAdd(WDFDRIVER driver, PWDFDEVICE_INIT init)
{
    WDF_OBJECT_ATTRIBUTES attrs;
    WDF_FILEOBJECT_CONFIG fileCfg;
    WDF_IO_QUEUE_CONFIG qcfg;
    DECLARE_CONST_UNICODE_STRING(sddl, L"D:P(A;;GA;;;SY)(A;;GA;;;BA)");   /* SYSTEM and administrators only */
    WDFDEVICE device;
    PDEVICE_CONTEXT ctx;
    NTSTATUS st;
    UNREFERENCED_PARAMETER(driver);

    st = WdfDeviceInitAssignSDDLString(init, &sddl);
    if (!NT_SUCCESS(st))
        return st;
    WdfDeviceInitSetExclusive(init, TRUE);                  /* one bridge at a time */
    WDF_FILEOBJECT_CONFIG_INIT(&fileCfg, WDF_NO_EVENT_CALLBACK, WDF_NO_EVENT_CALLBACK, PicoEvtFileCleanup);
    WdfDeviceInitSetFileObjectConfig(init, &fileCfg, WDF_NO_OBJECT_ATTRIBUTES);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attrs, DEVICE_CONTEXT);
    st = WdfDeviceCreate(&init, &attrs, &device);
    if (!NT_SUCCESS(st))
        return st;
    ctx = GetContext(device);
    ctx->Vhf = NULL;
    ctx->OutHead = ctx->OutCount = 0;

    WDF_OBJECT_ATTRIBUTES_INIT(&attrs);
    attrs.ParentObject = device;
    st = WdfSpinLockCreate(&attrs, &ctx->Lock);
    if (!NT_SUCCESS(st))
        return st;

    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&qcfg, WdfIoQueueDispatchParallel);
    qcfg.EvtIoDeviceControl = PicoEvtIoDeviceControl;
    st = WdfIoQueueCreate(device, &qcfg, WDF_NO_OBJECT_ATTRIBUTES, WDF_NO_HANDLE);
    if (!NT_SUCCESS(st))
        return st;

    WDF_IO_QUEUE_CONFIG_INIT(&qcfg, WdfIoQueueDispatchManual);
    st = WdfIoQueueCreate(device, &qcfg, WDF_NO_OBJECT_ATTRIBUTES, &ctx->OutputWaiters);
    if (!NT_SUCCESS(st))
        return st;

    return WdfDeviceCreateDeviceInterface(device, &GUID_DEVINTERFACE_PICO_VHF, NULL);
}

NTSTATUS DriverEntry(PDRIVER_OBJECT driverObject, PUNICODE_STRING registryPath)
{
    WDF_DRIVER_CONFIG cfg;
    WDF_DRIVER_CONFIG_INIT(&cfg, PicoEvtDeviceAdd);
    return WdfDriverCreate(driverObject, registryPath, WDF_NO_OBJECT_ATTRIBUTES, &cfg, WDF_NO_HANDLE);
}
