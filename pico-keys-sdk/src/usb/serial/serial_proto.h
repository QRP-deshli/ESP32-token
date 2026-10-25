/*
 * Serial transport framing for Pico Keys firmware (no hardware dependencies).
 *
 * Used when the target has no USB device controller (e.g. ESP32-C6) and the
 * CTAPHID reports have to be tunnelled over a serial byte stream to a host
 * bridge that exposes them as a real HID device.
 *
 * Wire format (all multi-byte fields little endian):
 *
 *   0xA5 0x5A | LEN(2) | TYPE(1) | DATA(LEN-1) | CRC16(2)
 *
 *   LEN   = 1 + number of data bytes (so it counts TYPE but not CRC)
 *   CRC16 = CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) over LEN, TYPE, DATA
 *
 * The two start bytes plus the CRC let the receiver resynchronise after
 * garbage on the line (boot ROM output, log lines, dropped bytes).
 */
#ifndef _SERIAL_PROTO_H_
#define _SERIAL_PROTO_H_

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#define SP_SOF0           0xA5
#define SP_SOF1           0x5A

/* Frame types */
#define SP_T_PING         0x01  /* host -> device: liveness / port detection   */
#define SP_T_PONG         0x02  /* device -> host: reply to PING, DATA = id    */
#define SP_T_HID          0x10  /* both ways: one 64 byte CTAPHID report        */
#define SP_T_CCID         0x20  /* reserved for a future CCID/APDU tunnel       */
#define SP_T_FP           0x30  /* fingerprint admin (enrol/delete), both ways  */

#define SP_HID_REPORT_LEN 64
#define SP_MAX_DATA       80
#define SP_MAX_FRAME      (2 + 2 + 1 + SP_MAX_DATA + 2)

/* Identification string returned in PONG so a bridge can find the right port */
#define SP_PONG_ID        "PKSER1"

uint16_t sp_crc16(const uint8_t *data, size_t len, uint16_t crc);

/* Encode a frame into out (must hold at least SP_MAX_FRAME bytes).
 * Returns the number of bytes written or 0 if len > SP_MAX_DATA. */
size_t sp_encode(uint8_t type, const uint8_t *data, size_t len, uint8_t *out);

/* Streaming decoder: feed one byte at a time. */
typedef struct {
    uint8_t  state;
    uint16_t len;      /* LEN field                         */
    uint16_t pos;      /* bytes of body received so far     */
    uint8_t  body[1 + SP_MAX_DATA]; /* TYPE + DATA          */
    uint8_t  crc_lo;
    uint32_t crc_errors;
    uint32_t len_errors;
} sp_decoder_t;

void sp_decoder_init(sp_decoder_t *d);

/* Returns true when a complete, CRC-valid frame has just been received.
 * After a true return use d->body[0] (type) and d->body[1..] / (d->len - 1). */
bool sp_decoder_feed(sp_decoder_t *d, uint8_t byte);

#define SP_FRAME_TYPE(d)  ((d)->body[0])
#define SP_FRAME_DATA(d)  ((d)->body + 1)
#define SP_FRAME_DLEN(d)  ((uint16_t)((d)->len - 1))

#endif /* _SERIAL_PROTO_H_ */
