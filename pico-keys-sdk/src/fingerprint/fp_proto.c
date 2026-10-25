#include "fp_proto.h"
#include <string.h>

uint8_t fp_chk(const uint8_t *f) {
    return (uint8_t)(f[1] ^ f[2] ^ f[3] ^ f[4] ^ f[5]);
}

void fp_build(uint8_t cmd, uint8_t p1, uint8_t p2, uint8_t p3, uint8_t out[8]) {
    out[0] = FP_START;
    out[1] = cmd;
    out[2] = p1;
    out[3] = p2;
    out[4] = p3;
    out[5] = 0;
    out[6] = fp_chk(out);
    out[7] = FP_START;
}

void fp_rx_init(fp_rx_t *r) {
    memset(r, 0, sizeof(*r));
}

bool fp_rx_feed(fp_rx_t *r, uint8_t b, fp_resp_t *out) {
    if (r->n == 0 && b != FP_START) {
        return false;
    }
    r->buf[r->n++] = b;
    if (r->n < 8) {
        return false;
    }
    if (r->buf[7] == FP_START && r->buf[6] == fp_chk(r->buf)) {
        out->cmd = r->buf[1];
        out->q1 = r->buf[2];
        out->q2 = r->buf[3];
        out->q3 = r->buf[4];
        r->n = 0;
        return true;
    }
    r->bad++;
    /* resync: restart at the next start byte inside what we have */
    uint8_t i;
    for (i = 1; i < 8; i++) {
        if (r->buf[i] == FP_START) {
            break;
        }
    }
    if (i < 8) {
        memmove(r->buf, r->buf + i, (size_t)(8 - i));
        r->n = (uint8_t)(8 - i);
    }
    else {
        r->n = 0;
    }
    return false;
}
