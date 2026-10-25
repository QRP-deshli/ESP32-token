/*
 * Serial transport for Pico Keys firmware on chips without a USB device
 * controller (ESP32-C6). Replaces the TinyUSB HID path: CTAPHID reports are
 * carried in frames (see serial_proto.h) over either
 *   - the native USB-Serial/JTAG port (default, shows up as /dev/ttyACM*), or
 *   - a plain UART (build with -DPICOKEY_SERIAL_UART=1).
 *
 * It provides the same entry points hid.c expects from TinyUSB
 * (tud_hid_n_report) and feeds received reports into tud_hid_set_report_cb.
 */
#ifndef _SERIAL_TRANSPORT_H_
#define _SERIAL_TRANSPORT_H_

#include <stdint.h>
#include <stdbool.h>
#include "serial_proto.h"

#if defined(USB_ITF_CCID)
#error "USB_TRANSPORT_SERIAL only tunnels CTAPHID for now: configure with -DENABLE_OATH_APP=OFF -DENABLE_OTP_APP=OFF (CMake does this automatically)"
#endif

/* TinyUSB's type, used by hid.c callbacks */
typedef uint8_t hid_report_type_t;

/* Install the serial driver and start the receive task. Safe to call twice. */
void serial_transport_init(void);

/* Called from hid_task(): drains received frames, answers PINGs and hands HID
 * reports to tud_hid_set_report_cb(). Never blocks. */
void serial_hid_task(void);

/* Send one frame (thread safe). Used by the fingerprint admin task for its replies. */
bool serial_send_frame(uint8_t type, const uint8_t *data, size_t len);

/* TinyUSB-compatible transmit of one 64 byte HID report. */
bool tud_hid_n_report(uint8_t itf, uint8_t report_id, const uint8_t *buffer, uint32_t n);

#endif /* _SERIAL_TRANSPORT_H_ */
