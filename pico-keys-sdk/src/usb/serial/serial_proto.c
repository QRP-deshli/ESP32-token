/*
 * Serial transport framing for Pico Keys firmware. See serial_proto.h.
 */

#include "serial_proto.h"
#include <string.h>

enum {
    ST_SOF0 = 0,
    ST_SOF1,
    ST_LEN0,
    ST_LEN1,
    ST_BODY,
    ST_CRC0,
    ST_CRC1
};

uint16_t sp_crc16(const uint8_t *data, size_t len, uint16_t crc) {
    while (len--) {
        crc ^= (uint16_t)(*data++) << 8;
        for (int i = 0; i < 8; i++) {
            crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
        }
    }
    return crc;
}

size_t sp_encode(uint8_t type, const uint8_t *data, size_t len, uint8_t *out) {
    if (len > SP_MAX_DATA) {
        return 0;
    }
    uint16_t flen = (uint16_t)(1 + len);
    size_t n = 0;
    out[n++] = SP_SOF0;
    out[n++] = SP_SOF1;
    out[n++] = (uint8_t)(flen & 0xff);
    out[n++] = (uint8_t)(flen >> 8);
    out[n++] = type;
    if (len > 0) {
        memcpy(out + n, data, len);
        n += len;
    }
    uint16_t crc = sp_crc16(out + 2, n - 2, 0xFFFF);
    out[n++] = (uint8_t)(crc & 0xff);
    out[n++] = (uint8_t)(crc >> 8);
    return n;
}

void sp_decoder_init(sp_decoder_t *d) {
    memset(d, 0, sizeof(*d));
    d->state = ST_SOF0;
}

bool sp_decoder_feed(sp_decoder_t *d, uint8_t b) {
    switch (d->state) {
        case ST_SOF0:
            if (b == SP_SOF0) {
                d->state = ST_SOF1;
            }
            break;
        case ST_SOF1:
            if (b == SP_SOF1) {
                d->state = ST_LEN0;
            }
            else if (b != SP_SOF0) {
                d->state = ST_SOF0;
            }
            break;
        case ST_LEN0:
            d->len = b;
            d->state = ST_LEN1;
            break;
        case ST_LEN1:
            d->len |= (uint16_t)b << 8;
            if (d->len < 1 || d->len > 1 + SP_MAX_DATA) {
                d->len_errors++;
                d->state = ST_SOF0;
            }
            else {
                d->pos = 0;
                d->state = ST_BODY;
            }
            break;
        case ST_BODY:
            d->body[d->pos++] = b;
            if (d->pos == d->len) {
                d->state = ST_CRC0;
            }
            break;
        case ST_CRC0:
            d->crc_lo = b;
            d->state = ST_CRC1;
            break;
        case ST_CRC1: {
            d->state = ST_SOF0;
            uint8_t hdr[2] = { (uint8_t)(d->len & 0xff), (uint8_t)(d->len >> 8) };
            uint16_t crc = sp_crc16(hdr, 2, 0xFFFF);
            crc = sp_crc16(d->body, d->len, crc);
            if (crc == (uint16_t)(d->crc_lo | ((uint16_t)b << 8))) {
                return true;
            }
            d->crc_errors++;
            break;
        }
        default:
            d->state = ST_SOF0;
            break;
    }
    return false;
}
