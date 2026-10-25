#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <assert.h>
#include "serial_proto.h"

static int feed_all(sp_decoder_t *d, const uint8_t *buf, size_t n, uint8_t *type, uint8_t *data, uint16_t *dlen) {
    int frames = 0;
    for (size_t i = 0; i < n; i++) {
        if (sp_decoder_feed(d, buf[i])) {
            frames++;
            *type = SP_FRAME_TYPE(d);
            *dlen = SP_FRAME_DLEN(d);
            memcpy(data, SP_FRAME_DATA(d), *dlen);
        }
    }
    return frames;
}

int main(void) {
    uint8_t frame[SP_MAX_FRAME], data[SP_MAX_DATA], rx[SP_MAX_DATA], type;
    uint16_t dlen;
    sp_decoder_t d;
    int fails = 0;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

    /* known CRC-16/CCITT-FALSE check value */
    CHECK(sp_crc16((const uint8_t *)"123456789", 9, 0xFFFF) == 0x29B1);

    /* 1. roundtrip all HID payload sizes + empty frame */
    for (int len = 0; len <= SP_MAX_DATA; len++) {
        for (int i = 0; i < len; i++) data[i] = (uint8_t)(i * 7 + len);
        size_t n = sp_encode(SP_T_HID, data, len, frame);
        CHECK(n == (size_t)(7 + len));
        sp_decoder_init(&d);
        CHECK(feed_all(&d, frame, n, &type, rx, &dlen) == 1);
        CHECK(type == SP_T_HID && dlen == len && memcmp(rx, data, len) == 0);
    }
    CHECK(sp_encode(SP_T_HID, data, SP_MAX_DATA + 1, frame) == 0);

    /* 2. garbage (including stray SOF bytes) before and between frames */
    uint8_t stream[1024]; size_t sn = 0;
    const uint8_t junk[] = {0x00, 0xA5, 0xA5, 0x13, 0xA5, 0x5A, 0xFF, 0xFF, 0x7F, 'b','o','o','t','\r','\n'};
    memcpy(stream + sn, junk, sizeof junk); sn += sizeof junk;
    for (int i = 0; i < 64; i++) data[i] = (uint8_t)i;
    sn += sp_encode(SP_T_HID, data, 64, stream + sn);
    memcpy(stream + sn, junk, sizeof junk); sn += sizeof junk;
    sn += sp_encode(SP_T_PING, (const uint8_t *)"hi", 2, stream + sn);
    sp_decoder_init(&d);
    int got = 0; uint8_t types[4];
    for (size_t i = 0; i < sn; i++) if (sp_decoder_feed(&d, stream[i])) types[got++] = SP_FRAME_TYPE(&d);
    CHECK(got == 2 && types[0] == SP_T_HID && types[1] == SP_T_PING);

    /* 3. corrupted byte anywhere in a frame must be rejected, next frame must still decode */
    size_t n = sp_encode(SP_T_HID, data, 64, frame);
    int rejected = 0;
    for (size_t pos = 2; pos < n; pos++) {
        uint8_t bad[SP_MAX_FRAME * 2 + 8];
        memcpy(bad, frame, n);
        bad[pos] ^= 0x40;
        size_t bn = n;
        bn += sp_encode(SP_T_PONG, (const uint8_t *)SP_PONG_ID, 6, bad + bn);
        sp_decoder_init(&d);
        int g = 0; uint8_t t0 = 0;
        for (size_t i = 0; i < bn; i++) if (sp_decoder_feed(&d, bad[i])) { g++; t0 = SP_FRAME_TYPE(&d); }
        /* either only the trailing PONG decodes, or (len-field hit) resync still finds PONG eventually */
        if (g >= 1 && t0 == SP_T_PONG) rejected++;
    }
    printf("corruption cases where corrupted frame was rejected and PONG recovered: %d/%zu\n", rejected, n - 2);
    CHECK(rejected == (int)(n - 2));

    /* 4. byte-at-a-time and split delivery behave the same (decoder is stateful across feeds) */
    sp_decoder_init(&d);
    got = 0;
    n = sp_encode(SP_T_HID, data, 64, frame);
    for (size_t i = 0; i < n; i++) got += sp_decoder_feed(&d, frame[i]);
    CHECK(got == 1);

    printf(fails ? "FAILED (%d)\n" : "all serial_proto tests passed\n", fails);
    return fails != 0;
}
