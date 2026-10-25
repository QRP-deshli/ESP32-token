/* Host tests for fp_proto/fp_core against a simulated Waveshare fingerprint sensor (behaviour per the manual). */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "fp_core.h"

typedef struct { uint32_t start, end; int finger; int used; } touch_t;
typedef struct {
    uint32_t now;
    touch_t touches[32]; int ntouch;
    int db_cap, count;
    int finger_of[4096];
    uint8_t tout;
    uint8_t rx[16]; int rxlen, rxpos; uint32_t rx_ready;
    int enr_id, enr_finger;
    int garbage, silent, corrupt_first;
    uint32_t cancel_at;
    int pumps; int cmds_seen[256];
} sim_t;

static void touch(sim_t *s, uint32_t start, uint32_t end, int finger) {
    s->touches[s->ntouch++] = (touch_t){ start, end, finger, 0 };
}

/* earliest finger present within [now, now+window]; returns finger or 0 and the completion time */
static int capture(sim_t *s, int consume, uint32_t *t_done) {
    uint32_t window = (uint32_t) s->tout * 300u;
    for (int i = 0; i < s->ntouch; i++) {
        touch_t *t = &s->touches[i];
        if (consume && t->used) continue;
        uint32_t when = t->start > s->now ? t->start : s->now;
        if (when < t->end && when <= s->now + window) {
            if (consume) t->used = 1;
            *t_done = when + 250;
            return t->finger;
        }
    }
    *t_done = s->now + window;
    return 0;
}

static void respond(sim_t *s, uint8_t cmd, uint8_t q1, uint8_t q2, uint8_t q3, uint32_t ready) {
    int n = 0;
    if (s->garbage) { s->rx[n++] = 0x00; s->rx[n++] = 0xF5; s->rx[n++] = 0x12; }
    fp_build(cmd, q1, q2, q3, s->rx + n);
    if (s->corrupt_first) { s->rx[n + 6] ^= 0x55; s->corrupt_first = 0; }
    s->rxlen = n + 8; s->rxpos = 0; s->rx_ready = ready;
}

static int find_finger(sim_t *s, int f) {
    for (int id = 1; id < 4096; id++) if (s->finger_of[id] == f) return id;
    return 0;
}

static int sim_write(void *c, const uint8_t *b, size_t len) {
    sim_t *s = c;
    if (len != 8 || b[0] != FP_START || b[7] != FP_START || b[6] != fp_chk(b)) return (int) len;
    s->cmds_seen[b[1]]++;
    if (s->silent) return (int) len;
    uint16_t id = (uint16_t)((b[2] << 8) | b[3]);
    uint32_t t; int f;
    switch (b[1]) {
        case FP_CMD_SET_TIMEOUT: s->tout = b[3]; respond(s, b[1], 0, b[3], 0, s->now + 5); break;
        case FP_CMD_COUNT:       respond(s, b[1], s->count >> 8, s->count & 0xff, 0, s->now + 5); break;
        case FP_CMD_CMP_1N:
            f = capture(s, 0, &t);
            if (!f) respond(s, b[1], 0, 0, FP_ACK_TIMEOUT, t);
            else { int u = find_finger(s, f); if (u) respond(s, b[1], u >> 8, u & 0xff, 1, t); else respond(s, b[1], 0, 0, FP_ACK_NOUSER, t); }
            break;
        case FP_CMD_ADD1:
            if (s->count >= s->db_cap) { respond(s, b[1], 0, 0, FP_ACK_FULL, s->now + 5); break; }
            if (s->finger_of[id]) { respond(s, b[1], 0, 0, FP_ACK_USER_OCCUPIED, s->now + 5); break; }
            f = capture(s, 1, &t);
            if (!f) { respond(s, b[1], 0, 0, FP_ACK_TIMEOUT, t); break; }
            s->enr_id = id; s->enr_finger = f; respond(s, b[1], 0, 0, FP_ACK_SUCCESS, t);
            break;
        case FP_CMD_ADD2:
        case FP_CMD_ADD3:
            f = capture(s, 1, &t);
            if (!f) { respond(s, b[1], 0, 0, FP_ACK_TIMEOUT, t); break; }
            if (f != s->enr_finger) { respond(s, b[1], 0, 0, FP_ACK_FAIL, t); break; }
            if (b[1] == FP_CMD_ADD3) {
                if (find_finger(s, f)) { respond(s, b[1], 0, 0, FP_ACK_FINGER_OCCUPIED, t); break; }
                s->finger_of[s->enr_id] = f; s->count++;
            }
            respond(s, b[1], 0, 0, FP_ACK_SUCCESS, t);
            break;
        case FP_CMD_DEL:
            if (s->finger_of[id]) { s->finger_of[id] = 0; s->count--; respond(s, b[1], 0, 0, 0, s->now + 5); }
            else respond(s, b[1], 0, 0, FP_ACK_FAIL, s->now + 5);
            break;
        case FP_CMD_DEL_ALL: memset(s->finger_of, 0, sizeof s->finger_of); s->count = 0; respond(s, b[1], 0, 0, 0, s->now + 5); break;
        default: break;   /* unknown: stay silent */
    }
    return (int) len;
}
static int sim_read(void *c, uint8_t *out, uint32_t timeout) {
    sim_t *s = c;
    if (s->rxpos < s->rxlen) {
        if (s->rx_ready <= s->now) { *out = s->rx[s->rxpos++]; return 1; }
        if (s->rx_ready <= s->now + timeout) { s->now = s->rx_ready; *out = s->rx[s->rxpos++]; return 1; }
    }
    s->now += timeout;
    return 0;
}
static uint32_t sim_millis(void *c) { return ((sim_t *) c)->now; }
static void sim_flush(void *c) { sim_t *s = c; if (s->rxpos < s->rxlen && s->rx_ready <= s->now) s->rxpos = s->rxlen; }
static void sim_pump(void *c) { ((sim_t *) c)->pumps++; }
static bool sim_cancelled(void *c) { sim_t *s = c; return s->cancel_at && s->now >= s->cancel_at; }

static fp_io_t io_for(sim_t *s) {
    return (fp_io_t){ s, sim_write, sim_read, sim_millis, sim_flush, sim_pump, sim_cancelled };
}
static void sim_init(sim_t *s) { memset(s, 0, sizeof *s); s->db_cap = 150; s->tout = 5; }

static int fails = 0;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

/* progress/emit recorders */
typedef struct { uint8_t d[64][4]; int n; } rec_t;
static void rec_emit(void *c, const uint8_t *d, size_t l) { rec_t *r = c; if (l == 4 && r->n < 64) memcpy(r->d[r->n++], d, 4); }

static uint8_t steps[16][2]; static int ns;
static void step_cb(void *c, uint8_t st, uint8_t a) { (void) c; if (ns < 16) { steps[ns][0] = st; steps[ns][1] = a; ns++; } }

static void enroll_via_sim(sim_t *s, int id, int finger) {   /* helper: enrol finger directly */
    fp_io_t io = io_for(s);
    uint32_t t0 = s->now;
    touch(s, t0 + 100, t0 + 600, finger); touch(s, t0 + 3000, t0 + 3500, finger); touch(s, t0 + 6000, t0 + 6500, finger);
    CHECK(fp_enroll(&io, (uint16_t) id, NULL, NULL) == FPR_OK);
    s->ntouch = 0;
}

int main(void) {
    sim_t s; fp_io_t io; uint16_t uid, count;

    /* ---- protocol layer ---- */
    { uint8_t f[8]; fp_build(FP_CMD_CMP_1N, 0, 0, 0, f);
      CHECK(f[0] == 0xF5 && f[1] == 0x0C && f[6] == 0x0C && f[7] == 0xF5);
      fp_build(FP_CMD_ADD1, 0x01, 0x02, 0x01, f); CHECK(f[6] == (0x01 ^ 0x01 ^ 0x02 ^ 0x01)); }
    { fp_rx_t rx; fp_rx_init(&rx); fp_resp_t r; uint8_t f[8]; int got = 0;
      fp_build(0x09, 0, 3, 0, f);
      const uint8_t junk[] = { 0x00, 0xF5, 0xF5, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0xF5 };
      for (size_t i = 0; i < sizeof junk; i++) fp_rx_feed(&rx, junk[i], &r);
      for (int i = 0; i < 8; i++) if (fp_rx_feed(&rx, f[i], &r)) got++;
      CHECK(got == 1 && r.cmd == 9 && r.q2 == 3);
      f[6] ^= 1; got = 0; for (int i = 0; i < 8; i++) if (fp_rx_feed(&rx, f[i], &r)) got++;
      CHECK(got == 0 && rx.bad >= 1);
      srand(1); for (int i = 0; i < 200000; i++) fp_rx_feed(&rx, (uint8_t) rand(), &r); }   /* fuzz, ASAN-clean */

    /* ---- count / no sensor ---- */
    sim_init(&s); io = io_for(&s);
    CHECK(fp_count(&io, &count) == FPR_OK && count == 0);
    sim_init(&s); s.silent = 1; io = io_for(&s);
    CHECK(fp_count(&io, &count) == FPR_NO_SENSOR);
    CHECK(fp_verify(&io, 15000, &uid) == FPR_NO_SENSOR);

    /* ---- enrol + verify ---- */
    sim_init(&s); io = io_for(&s);
    { rec_t rec = {0};
      touch(&s, 100, 600, 7); touch(&s, 3000, 3500, 7); touch(&s, 6000, 6500, 7);
      ns = 0;
      CHECK(fp_enroll(&io, 1, step_cb, NULL) == FPR_OK);
      CHECK(ns == 5 && steps[0][0] == FP_PROG_PLACE && steps[0][1] == 1 && steps[1][0] == FP_PROG_LIFT &&
            steps[4][0] == FP_PROG_PLACE && steps[4][1] == 3);
      CHECK(fp_count(&io, &count) == FPR_OK && count == 1);
      CHECK(s.tout == 5);                         /* verify timeout restored after enrolment */
      (void) rec; }
    s.ntouch = 0; touch(&s, s.now + 500, s.now + 20000, 7);
    CHECK(fp_verify(&io, 15000, &uid) == FPR_OK && uid == 1);

    /* wrong finger: rejected after repeated NOUSER, never OK */
    s.ntouch = 0; touch(&s, s.now + 100, s.now + 60000, 9);
    CHECK(fp_verify(&io, 15000, &uid) == FPR_NO_MATCH);

    /* nobody touches: TIMEOUT near the deadline, not earlier */
    s.ntouch = 0; { uint32_t t0 = s.now; CHECK(fp_verify(&io, 4000, &uid) == FPR_TIMEOUT);
                    CHECK(s.now - t0 >= 4000 && s.now - t0 < 4000 + 3500); }

    /* touch arrives late but inside the window */
    s.ntouch = 0; touch(&s, s.now + 9000, s.now + 12000, 7);
    CHECK(fp_verify(&io, 15000, &uid) == FPR_OK && uid == 1);

    /* cancel (CTAPHID_CANCEL) stops the wait within one sensor window */
    s.ntouch = 0; s.cancel_at = s.now + 2000; { uint32_t t0 = s.now;
      CHECK(fp_verify(&io, 15000, &uid) == FPR_CANCELLED); CHECK(s.now - t0 < 2000 + 3500); } s.cancel_at = 0;

    /* line noise and one corrupted response do not break verification */
    s.garbage = 1; s.corrupt_first = 1; s.ntouch = 0; touch(&s, s.now + 100, s.now + 60000, 7);
    CHECK(fp_verify(&io, 15000, &uid) == FPR_OK && uid == 1); s.garbage = 0;

    /* ---- enrol edge cases ---- */
    sim_init(&s); io = io_for(&s); enroll_via_sim(&s, 1, 7);
    { uint32_t t0 = s.now;    /* same finger again under another id -> EXISTS */
      touch(&s, t0 + 100, t0 + 600, 7); touch(&s, t0 + 3000, t0 + 3500, 7); touch(&s, t0 + 6000, t0 + 6500, 7);
      CHECK(fp_enroll(&io, 2, NULL, NULL) == FPR_EXISTS); s.ntouch = 0; }
    { uint32_t t0 = s.now;    /* existing user id -> EXISTS */
      touch(&s, t0 + 100, t0 + 600, 8);
      CHECK(fp_enroll(&io, 1, NULL, NULL) == FPR_EXISTS); s.ntouch = 0; }
    { uint32_t t0 = s.now;    /* finger changes between captures -> FAIL */
      touch(&s, t0 + 100, t0 + 600, 8); touch(&s, t0 + 3000, t0 + 3500, 9);
      CHECK(fp_enroll(&io, 3, NULL, NULL) == FPR_FAIL); s.ntouch = 0; }
    { uint32_t t0 = s.now;    /* no finger at all -> TIMEOUT */
      CHECK(fp_enroll(&io, 3, NULL, NULL) == FPR_TIMEOUT); (void) t0; }
    s.db_cap = 1; { uint32_t t0 = s.now; touch(&s, t0 + 100, t0 + 600, 8);
      CHECK(fp_enroll(&io, 4, NULL, NULL) == FPR_FULL); s.ntouch = 0; }
    CHECK(fp_enroll(&io, 0, NULL, NULL) == FPR_FAIL && fp_enroll(&io, 0x1000, NULL, NULL) == FPR_FAIL);

    /* ---- delete ---- */
    CHECK(fp_delete(&io, 1) == FPR_OK && fp_count(&io, &count) == FPR_OK && count == 0);
    CHECK(fp_delete(&io, 1) == FPR_FAIL);
    enroll_via_sim(&s, 5, 3); CHECK(fp_delete_all(&io) == FPR_OK && fp_count(&io, &count) == FPR_OK && count == 0);

    /* ---- admin protocol: bootstrap, authorisation, denial ---- */
    sim_init(&s); io = io_for(&s); { rec_t rec = {0};
      const uint8_t st[] = { FPA_OP_STATUS };
      fp_admin_handle(&io, st, 1, rec_emit, &rec);
      CHECK(rec.n == 1 && rec.d[0][0] == FPA_OP_STATUS && rec.d[0][1] == FPA_OK && rec.d[0][3] == 0);
      /* first enrolment on an empty sensor needs no authorisation */
      rec.n = 0; touch(&s, 100, 600, 7); touch(&s, 3000, 3500, 7); touch(&s, 6000, 6500, 7);
      const uint8_t en1[] = { FPA_OP_ENROLL, 0, 1 };
      fp_admin_handle(&io, en1, 3, rec_emit, &rec);
      CHECK(rec.n == 6 && rec.d[0][1] == FPA_PROGRESS && rec.d[0][2] == FPA_STEP_PLACE &&
            rec.d[5][1] == FPA_OK && rec.d[5][3] == 1);
      /* second enrolment: wrong finger for authorisation -> DENIED, nothing enrolled */
      rec.n = 0; s.ntouch = 0; { uint32_t t0 = s.now; touch(&s, t0 + 100, t0 + 90000, 9); }
      const uint8_t en2[] = { FPA_OP_ENROLL, 0, 2 };
      fp_admin_handle(&io, en2, 3, rec_emit, &rec);
      CHECK(rec.n == 2 && rec.d[0][1] == FPA_PROGRESS && rec.d[0][2] == FPA_STEP_AUTH && rec.d[1][1] == FPA_DENIED);
      CHECK(fp_count(&io, &count) == FPR_OK && count == 1);
      /* delete-all with wrong finger denied; right finger ok */
      rec.n = 0; const uint8_t da[] = { FPA_OP_DELETE_ALL };
      fp_admin_handle(&io, da, 1, rec_emit, &rec); CHECK(rec.d[rec.n - 1][1] == FPA_DENIED);
      rec.n = 0; s.ntouch = 0; { uint32_t t0 = s.now; touch(&s, t0 + 100, t0 + 90000, 7); }
      fp_admin_handle(&io, da, 1, rec_emit, &rec); CHECK(rec.d[rec.n - 1][1] == FPA_OK);
      CHECK(fp_count(&io, &count) == FPR_OK && count == 0);
      /* malformed requests */
      rec.n = 0; const uint8_t bad1[] = { FPA_OP_ENROLL, 0 }, bad2[] = { 0x77 }, bad3[] = { FPA_OP_ENROLL, 0, 0 };
      fp_admin_handle(&io, bad1, 2, rec_emit, &rec); fp_admin_handle(&io, bad2, 1, rec_emit, &rec);
      fp_admin_handle(&io, bad3, 3, rec_emit, &rec); fp_admin_handle(&io, bad1, 0, rec_emit, &rec);
      CHECK(rec.n == 4 && rec.d[0][1] == FPA_BAD_REQUEST && rec.d[1][1] == FPA_BAD_REQUEST &&
            rec.d[2][1] == FPA_BAD_REQUEST && rec.d[3][1] == FPA_BAD_REQUEST);
      /* no sensor */
      s.silent = 1; rec.n = 0; fp_admin_handle(&io, st, 1, rec_emit, &rec); CHECK(rec.d[0][1] == FPA_NO_SENSOR); }

    printf(fails ? "FAILED (%d)\n" : "all fingerprint core tests passed\n", fails);
    return fails != 0;
}
