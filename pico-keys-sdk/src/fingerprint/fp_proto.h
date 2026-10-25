/*
 * Waveshare UART Fingerprint Sensor (D) - 8 byte command/response frames.
 * Pure C, no hardware dependencies (host-testable).
 *
 * Source: "UART Fingerprint Sensor (C) User Manual" (the Type D wiki says its commands are
 * mostly the same as Type C). 19200 baud, 8N1.
 *
 *   byte:  0     1    2   3   4   5  6    7
 *          0xF5  CMD  P1  P2  P3  0  CHK  0xF5        (response: Q1 Q2 Q3 instead of P1 P2 P3)
 *   CHK = XOR of bytes 1..5
 */
#ifndef _FP_PROTO_H_
#define _FP_PROTO_H_

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#define FP_START            0xF5

#define FP_CMD_ADD1         0x01
#define FP_CMD_ADD2         0x02
#define FP_CMD_ADD3         0x03
#define FP_CMD_DEL          0x04
#define FP_CMD_DEL_ALL      0x05
#define FP_CMD_COUNT        0x09
#define FP_CMD_CMP_1N       0x0C
#define FP_CMD_SET_LEVEL    0x28
#define FP_CMD_SET_TIMEOUT  0x2E

#define FP_ACK_SUCCESS          0x00
#define FP_ACK_FAIL             0x01
#define FP_ACK_FULL             0x04
#define FP_ACK_NOUSER           0x05
#define FP_ACK_USER_OCCUPIED    0x06
#define FP_ACK_FINGER_OCCUPIED  0x07
#define FP_ACK_TIMEOUT          0x08

typedef struct {
    uint8_t cmd, q1, q2, q3;
} fp_resp_t;

uint8_t fp_chk(const uint8_t *frame8);
void fp_build(uint8_t cmd, uint8_t p1, uint8_t p2, uint8_t p3, uint8_t out[8]);

/* Streaming parser for 8 byte frames; resynchronises on 0xF5 + checksum. */
typedef struct {
    uint8_t  buf[8];
    uint8_t  n;
    uint32_t bad;     /* frames rejected (checksum / tail) */
} fp_rx_t;

void fp_rx_init(fp_rx_t *r);
bool fp_rx_feed(fp_rx_t *r, uint8_t byte, fp_resp_t *out);

#endif
