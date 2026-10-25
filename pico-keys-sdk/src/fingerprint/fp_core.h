/*
 * Fingerprint sensor logic on top of an abstract byte I/O (so it runs on the ESP32 and in host tests).
 */
#ifndef _FP_CORE_H_
#define _FP_CORE_H_

#include "fp_proto.h"

typedef struct {
    void *ctx;
    int      (*write)(void *ctx, const uint8_t *buf, size_t len);        /* returns bytes written            */
    int      (*read)(void *ctx, uint8_t *byte, uint32_t timeout_ms);     /* 1 = got a byte, 0 = timed out    */
    uint32_t (*millis)(void *ctx);
    void     (*flush)(void *ctx);                                        /* drop pending rx bytes (optional) */
    void     (*pump)(void *ctx);                                         /* called while idle-waiting (optional) */
    bool     (*cancelled)(void *ctx);                                    /* optional                         */
} fp_io_t;

typedef enum {
    FPR_OK = 0,
    FPR_FAIL,
    FPR_NO_SENSOR,   /* no valid answer from the module (not wired, powered, or wrong baud) */
    FPR_TIMEOUT,     /* nobody touched the sensor in time                                    */
    FPR_NO_MATCH,    /* finger(s) presented but not enrolled                                 */
    FPR_CANCELLED,
    FPR_FULL,
    FPR_EXISTS       /* user id or this finger is already enrolled                           */
} fp_result_t;

#define FP_USER_PERMISSION   1       /* permission byte stored with each user (we do not use it) */
#define FP_MAX_USER_ID       0xFFF

/* progress steps reported during enrolment */
#define FP_PROG_PLACE        1       /* arg = capture number 1..3 */
#define FP_PROG_LIFT         2
typedef void (*fp_progress_t)(void *ctx, uint8_t step, uint8_t arg);

fp_result_t fp_txn(const fp_io_t *io, uint8_t cmd, uint8_t p1, uint8_t p2, uint8_t p3,
                   uint32_t wait_ms, fp_resp_t *resp);
fp_result_t fp_count(const fp_io_t *io, uint16_t *count);
/* 1:N match. Returns FPR_OK and the matched user id, FPR_TIMEOUT, FPR_NO_MATCH (5 rejected touches),
 * FPR_CANCELLED or FPR_NO_SENSOR. */
fp_result_t fp_verify(const fp_io_t *io, uint32_t timeout_ms, uint16_t *user_id);
fp_result_t fp_enroll(const fp_io_t *io, uint16_t user_id, fp_progress_t cb, void *cb_ctx);
fp_result_t fp_delete(const fp_io_t *io, uint16_t user_id);
fp_result_t fp_delete_all(const fp_io_t *io);

/* ---- admin protocol (carried in SP_T_FP frames from the PC tool) ----
 * request : [op, args...]            reply : [op, status, a, b]                                   */
#define FPA_OP_STATUS        1       /* -> OK, count_hi, count_lo                                  */
#define FPA_OP_ENROLL        2       /* args: id_hi id_lo                                          */
#define FPA_OP_DELETE        3       /* args: id_hi id_lo                                          */
#define FPA_OP_DELETE_ALL    4
#define FPA_OP_TEST          5       /* one 1:N verification, OK carries the matched id            */

#define FPA_OK               0
#define FPA_FAIL             1
#define FPA_NO_SENSOR        2
#define FPA_TIMEOUT          3
#define FPA_FULL             4
#define FPA_EXISTS           5
#define FPA_NO_MATCH         6
#define FPA_DENIED           7       /* authorisation by an enrolled finger failed                 */
#define FPA_BAD_REQUEST      8
#define FPA_BUSY             9
#define FPA_PROGRESS         0x80    /* a = FPA_STEP_*, b = argument                               */

#define FPA_STEP_PLACE       FP_PROG_PLACE
#define FPA_STEP_LIFT        FP_PROG_LIFT
#define FPA_STEP_AUTH        3       /* touch with an already enrolled finger to authorise         */

typedef void (*fp_emit_t)(void *ctx, const uint8_t *data, size_t len);

/* Runs one admin request to completion, calling emit() for progress and the final reply.
 * Changing or erasing fingerprints requires a successful match first once any finger is enrolled;
 * the very first enrolment (empty sensor) needs no authorisation. */
void fp_admin_handle(const fp_io_t *io, const uint8_t *req, size_t len, fp_emit_t emit, void *emit_ctx);

#endif
