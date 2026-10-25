/*
 * Fingerprint gate for user presence (ESP32 serial-transport build).
 * Hardware: Waveshare UART Fingerprint Sensor (D) on UART1, 19200 8N1.
 */
#ifndef _FINGERPRINT_H_
#define _FINGERPRINT_H_

#include <stdint.h>
#include <stdbool.h>

/* Configure UART + RST pin and start the admin task. Call once at startup. */
void fingerprint_init(void);

/* Blocks (while servicing the transport) until an enrolled finger is matched.
 * true = matched, false = timeout / cancelled / not matched / sensor missing (fail closed). */
bool fingerprint_verify_user(uint32_t timeout_ms);

/* Admin request from the PC tool (SP_T_FP frame payload). Never blocks; the reply goes out as SP_T_FP frames. */
void fingerprint_admin_request(const uint8_t *data, uint16_t len);

#endif
