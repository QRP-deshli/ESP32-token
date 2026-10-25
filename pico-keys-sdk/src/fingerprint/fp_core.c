#include "fp_core.h"
#include <string.h>

#define VERIFY_SENSOR_TOUT    5        /* sensor capture timeout in units of ~0.2-0.3 s  => about 1-1.5 s */
#define VERIFY_TXN_WAIT_MS    3000
#define ENROLL_SENSOR_TOUT    50       /* about 10-15 s per capture                                         */
#define ENROLL_TXN_WAIT_MS    18000
#define MAX_NOMATCH           5
#define ADMIN_AUTH_TIMEOUT_MS 15000
#define LIFT_SETTLE_MS        1200

fp_result_t fp_txn(const fp_io_t *io, uint8_t cmd, uint8_t p1, uint8_t p2, uint8_t p3,
                   uint32_t wait_ms, fp_resp_t *resp) {
    uint8_t frame[8];
    fp_rx_t rx;
    fp_rx_init(&rx);
    fp_build(cmd, p1, p2, p3, frame);
    if (io->flush) {
        io->flush(io->ctx);
    }
    if (io->write(io->ctx, frame, sizeof(frame)) != (int) sizeof(frame)) {
        return FPR_NO_SENSOR;
    }
    uint32_t start = io->millis(io->ctx);
    for (;;) {
        if ((uint32_t)(io->millis(io->ctx) - start) >= wait_ms) {
            return FPR_NO_SENSOR;
        }
        uint8_t b;
        if (io->read(io->ctx, &b, 10)) {
            fp_resp_t r;
            if (fp_rx_feed(&rx, b, &r) && r.cmd == cmd) {
                *resp = r;
                return FPR_OK;
            }
        }
        else if (io->pump) {
            io->pump(io->ctx);
        }
    }
}

/* Idempotent commands (set timeout, count, delete) are safe to repeat: one corrupted or lost frame on the
 * wire must not look like a missing sensor. */
static fp_result_t txn_idem(const fp_io_t *io, uint8_t cmd, uint8_t p1, uint8_t p2, uint8_t p3,
                            uint32_t wait_ms, fp_resp_t *resp) {
    fp_result_t res = fp_txn(io, cmd, p1, p2, p3, wait_ms, resp);
    if (res == FPR_NO_SENSOR) {
        res = fp_txn(io, cmd, p1, p2, p3, wait_ms, resp);
    }
    return res;
}

static fp_result_t set_capture_timeout(const fp_io_t *io, uint8_t tout) {
    fp_resp_t r;
    fp_result_t res = txn_idem(io, FP_CMD_SET_TIMEOUT, 0, tout, 0, 1000, &r);
    if (res != FPR_OK) {
        return res;
    }
    return r.q3 == FP_ACK_SUCCESS ? FPR_OK : FPR_FAIL;
}

fp_result_t fp_count(const fp_io_t *io, uint16_t *count) {
    fp_resp_t r;
    fp_result_t res = txn_idem(io, FP_CMD_COUNT, 0, 0, 0, 1000, &r);
    if (res != FPR_OK) {
        return res;
    }
    if (r.q3 != FP_ACK_SUCCESS) {
        return FPR_FAIL;
    }
    *count = (uint16_t)((r.q1 << 8) | r.q2);
    return FPR_OK;
}

fp_result_t fp_verify(const fp_io_t *io, uint32_t timeout_ms, uint16_t *user_id) {
    uint32_t start = io->millis(io->ctx);
    fp_result_t res = set_capture_timeout(io, VERIFY_SENSOR_TOUT);
    if (res != FPR_OK) {
        return res;
    }
    int nomatch = 0;
    for (;;) {
        if (io->cancelled && io->cancelled(io->ctx)) {
            return FPR_CANCELLED;
        }
        if ((uint32_t)(io->millis(io->ctx) - start) >= timeout_ms) {
            return FPR_TIMEOUT;
        }
        fp_resp_t r;
        res = fp_txn(io, FP_CMD_CMP_1N, 0, 0, 0, VERIFY_TXN_WAIT_MS, &r);
        if (res != FPR_OK) {
            return res;
        }
        uint16_t id = (uint16_t)((r.q1 << 8) | r.q2);
        /* Q3 carries the permission (1..3) on success, which collides with ACK_FAIL = 1:
         * a real match always has a non-zero user id. */
        if (id != 0 && r.q3 >= 1 && r.q3 <= 3) {
            if (user_id) {
                *user_id = id;
            }
            return FPR_OK;
        }
        if (r.q3 == FP_ACK_NOUSER) {
            if (++nomatch >= MAX_NOMATCH) {
                return FPR_NO_MATCH;
            }
        }
        /* ACK_TIMEOUT / ACK_FAIL (poor image): just try again until our own deadline */
    }
}

static void settle(const fp_io_t *io, uint32_t ms) {
    uint32_t start = io->millis(io->ctx);
    while ((uint32_t)(io->millis(io->ctx) - start) < ms) {
        uint8_t b;
        if (!io->read(io->ctx, &b, 10) && io->pump) {
            io->pump(io->ctx);
        }
    }
}

fp_result_t fp_enroll(const fp_io_t *io, uint16_t user_id, fp_progress_t cb, void *cb_ctx) {
    if (user_id < 1 || user_id > FP_MAX_USER_ID) {
        return FPR_FAIL;
    }
    fp_result_t res = set_capture_timeout(io, ENROLL_SENSOR_TOUT);
    if (res != FPR_OK) {
        return res;
    }
    static const uint8_t cmds[3] = { FP_CMD_ADD1, FP_CMD_ADD2, FP_CMD_ADD3 };
    for (uint8_t i = 0; i < 3; i++) {
        if (cb) {
            cb(cb_ctx, FP_PROG_PLACE, (uint8_t)(i + 1));
        }
        fp_resp_t r;
        res = fp_txn(io, cmds[i], (uint8_t)(user_id >> 8), (uint8_t)(user_id & 0xff), FP_USER_PERMISSION,
                     ENROLL_TXN_WAIT_MS, &r);
        if (res == FPR_OK) {
            switch (r.q3) {
                case FP_ACK_SUCCESS:         res = FPR_OK; break;
                case FP_ACK_FULL:            res = FPR_FULL; break;
                case FP_ACK_USER_OCCUPIED:
                case FP_ACK_FINGER_OCCUPIED: res = FPR_EXISTS; break;
                case FP_ACK_TIMEOUT:         res = FPR_TIMEOUT; break;
                default:                     res = FPR_FAIL; break;
            }
        }
        if (res != FPR_OK) {
            break;
        }
        if (i < 2) {
            if (cb) {
                cb(cb_ctx, FP_PROG_LIFT, (uint8_t)(i + 1));
            }
            settle(io, LIFT_SETTLE_MS);
        }
    }
    (void) set_capture_timeout(io, VERIFY_SENSOR_TOUT);   /* best effort: back to the short verify timeout */
    return res;
}

fp_result_t fp_delete(const fp_io_t *io, uint16_t user_id) {
    fp_resp_t r;
    fp_result_t res = txn_idem(io, FP_CMD_DEL, (uint8_t)(user_id >> 8), (uint8_t)(user_id & 0xff), 0, 2000, &r);
    if (res != FPR_OK) {
        return res;
    }
    return r.q3 == FP_ACK_SUCCESS ? FPR_OK : FPR_FAIL;
}

fp_result_t fp_delete_all(const fp_io_t *io) {
    fp_resp_t r;
    fp_result_t res = txn_idem(io, FP_CMD_DEL_ALL, 0, 0, 0, 2000, &r);
    if (res != FPR_OK) {
        return res;
    }
    return r.q3 == FP_ACK_SUCCESS ? FPR_OK : FPR_FAIL;
}

/* ------------------------------------------------------------------ admin protocol */

typedef struct {
    fp_emit_t emit;
    void *ectx;
    uint8_t op;
} admin_t;

static void reply(const admin_t *a, uint8_t status, uint8_t x, uint8_t y) {
    uint8_t d[4] = { a->op, status, x, y };
    a->emit(a->ectx, d, sizeof(d));
}

static uint8_t to_status(fp_result_t r) {
    switch (r) {
        case FPR_OK:        return FPA_OK;
        case FPR_NO_SENSOR: return FPA_NO_SENSOR;
        case FPR_TIMEOUT:   return FPA_TIMEOUT;
        case FPR_NO_MATCH:  return FPA_NO_MATCH;
        case FPR_FULL:      return FPA_FULL;
        case FPR_EXISTS:    return FPA_EXISTS;
        default:            return FPA_FAIL;
    }
}

static void progress_cb(void *ctx, uint8_t step, uint8_t arg) {
    reply((const admin_t *) ctx, FPA_PROGRESS, step, arg);
}

/* Once any finger is enrolled, changing the enrolment needs a match from an enrolled finger. */
static bool authorise(const fp_io_t *io, const admin_t *a) {
    uint16_t count = 0;
    fp_result_t r = fp_count(io, &count);
    if (r != FPR_OK) {
        reply(a, to_status(r), 0, 0);
        return false;
    }
    if (count == 0) {
        return true;
    }
    reply(a, FPA_PROGRESS, FPA_STEP_AUTH, 0);
    uint16_t uid;
    r = fp_verify(io, ADMIN_AUTH_TIMEOUT_MS, &uid);
    if (r == FPR_OK) {
        return true;
    }
    reply(a, (r == FPR_NO_SENSOR) ? FPA_NO_SENSOR : FPA_DENIED, 0, 0);
    return false;
}

void fp_admin_handle(const fp_io_t *io, const uint8_t *req, size_t len, fp_emit_t emit, void *emit_ctx) {
    admin_t a = { emit, emit_ctx, len ? req[0] : 0 };
    uint16_t count = 0, id = 0;
    fp_result_t r;
    if (len == 0) {
        reply(&a, FPA_BAD_REQUEST, 0, 0);
        return;
    }
    switch (req[0]) {
        case FPA_OP_STATUS:
            r = fp_count(io, &count);
            reply(&a, to_status(r), (uint8_t)(count >> 8), (uint8_t)(count & 0xff));
            break;
        case FPA_OP_ENROLL:
            if (len != 3) { reply(&a, FPA_BAD_REQUEST, 0, 0); break; }
            id = (uint16_t)((req[1] << 8) | req[2]);
            if (id < 1 || id > FP_MAX_USER_ID) { reply(&a, FPA_BAD_REQUEST, 0, 0); break; }
            if (!authorise(io, &a)) { break; }
            r = fp_enroll(io, id, progress_cb, &a);
            reply(&a, to_status(r), req[1], req[2]);
            break;
        case FPA_OP_DELETE:
            if (len != 3) { reply(&a, FPA_BAD_REQUEST, 0, 0); break; }
            id = (uint16_t)((req[1] << 8) | req[2]);
            if (!authorise(io, &a)) { break; }
            r = fp_delete(io, id);
            reply(&a, to_status(r), req[1], req[2]);
            break;
        case FPA_OP_DELETE_ALL:
            if (!authorise(io, &a)) { break; }
            r = fp_delete_all(io);
            reply(&a, to_status(r), 0, 0);
            break;
        case FPA_OP_TEST:
            reply(&a, FPA_PROGRESS, FPA_STEP_AUTH, 0);
            r = fp_verify(io, ADMIN_AUTH_TIMEOUT_MS, &id);
            reply(&a, to_status(r), (uint8_t)(id >> 8), (uint8_t)(id & 0xff));
            break;
        default:
            reply(&a, FPA_BAD_REQUEST, 0, 0);
            break;
    }
}
