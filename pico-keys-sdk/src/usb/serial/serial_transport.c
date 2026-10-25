/*
 * Serial transport for Pico Keys firmware (ESP-IDF). See serial_transport.h.
 */

#include "pico_keys.h"
#include "usb.h"
#include "serial_transport.h"
#include <string.h>

#ifdef ENABLE_FINGERPRINT
#include "fingerprint/fingerprint.h"
#endif
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "freertos/stream_buffer.h"

#ifdef PICOKEY_SERIAL_UART
#include "driver/uart.h"
#include "driver/gpio.h"
#ifndef PICOKEY_SERIAL_UART_NUM
#define PICOKEY_SERIAL_UART_NUM UART_NUM_1
#endif
#ifndef PICOKEY_SERIAL_UART_TX
#define PICOKEY_SERIAL_UART_TX  2   /* avoid strapping/JTAG pins (4,5,8,9,15 on C6) */
#endif
#ifndef PICOKEY_SERIAL_UART_RX
#define PICOKEY_SERIAL_UART_RX  3
#endif
#ifndef PICOKEY_SERIAL_UART_BAUD
#define PICOKEY_SERIAL_UART_BAUD 921600
#endif
#else
#include "driver/usb_serial_jtag.h"
#endif

#define SER_RX_STREAM_BYTES   4096   /* ~57 frames, absorbs bursts while hid_task sleeps */
#define SER_TX_TIMEOUT_MS     100

extern void tud_hid_set_report_cb(uint8_t itf, uint8_t report_id, hid_report_type_t report_type,
                                  uint8_t const *buffer, uint16_t bufsize);

static StreamBufferHandle_t rx_sb = NULL;
static SemaphoreHandle_t tx_lock = NULL;
static sp_decoder_t decoder;
static bool started = false;

/* ---------------------------------------------------------------- backends */

static void backend_init(void) {
#ifdef PICOKEY_SERIAL_UART
    const uart_config_t cfg = {
        .baud_rate = PICOKEY_SERIAL_UART_BAUD,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    uart_driver_install(PICOKEY_SERIAL_UART_NUM, 2048, 2048, 0, NULL, 0);
    uart_param_config(PICOKEY_SERIAL_UART_NUM, &cfg);
    uart_set_pin(PICOKEY_SERIAL_UART_NUM, PICOKEY_SERIAL_UART_TX, PICOKEY_SERIAL_UART_RX,
                 UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE);
#else
    usb_serial_jtag_driver_config_t cfg = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
    cfg.rx_buffer_size = 1024;
    cfg.tx_buffer_size = 1024;
    usb_serial_jtag_driver_install(&cfg);
#endif
}

/* Blocks up to 'wait' for at least one byte, then returns what is available. */
static int backend_read(uint8_t *buf, size_t len, TickType_t wait) {
#ifdef PICOKEY_SERIAL_UART
    int n = uart_read_bytes(PICOKEY_SERIAL_UART_NUM, buf, 1, wait);
    if (n == 1 && len > 1) {
        size_t avail = 0;
        uart_get_buffered_data_len(PICOKEY_SERIAL_UART_NUM, &avail);
        if (avail > len - 1) {
            avail = len - 1;
        }
        if (avail > 0) {
            int m = uart_read_bytes(PICOKEY_SERIAL_UART_NUM, buf + 1, avail, 0);
            if (m > 0) {
                n += m;
            }
        }
    }
    return n;
#else
    return usb_serial_jtag_read_bytes(buf, len, wait);
#endif
}

static int backend_write(const uint8_t *buf, size_t len, TickType_t wait) {
#ifdef PICOKEY_SERIAL_UART
    (void) wait;
    return uart_write_bytes(PICOKEY_SERIAL_UART_NUM, (const char *) buf, len);
#else
    return usb_serial_jtag_write_bytes(buf, len, wait);
#endif
}

/* -------------------------------------------------------------------- tx */

bool serial_send_frame(uint8_t type, const uint8_t *data, size_t len) {
    uint8_t frame[SP_MAX_FRAME];
    size_t n = sp_encode(type, data, len, frame);
    if (n == 0 || tx_lock == NULL) {
        return false;
    }
    if (xSemaphoreTake(tx_lock, pdMS_TO_TICKS(SER_TX_TIMEOUT_MS)) != pdTRUE) {
        return false;
    }
    size_t sent = 0;
    TickType_t deadline = xTaskGetTickCount() + pdMS_TO_TICKS(SER_TX_TIMEOUT_MS);
    while (sent < n) {
        int w = backend_write(frame + sent, n - sent, pdMS_TO_TICKS(20));
        if (w > 0) {
            sent += (size_t) w;
        }
        else if ((int32_t)(xTaskGetTickCount() - deadline) >= 0) {
            break; /* host not reading: report failure, hid.c will retry */
        }
    }
    xSemaphoreGive(tx_lock);
    return sent == n;
}

bool tud_hid_n_report(uint8_t itf, uint8_t report_id, const uint8_t *buffer, uint32_t n) {
    (void) itf;
    (void) report_id;
    uint8_t rep[SP_HID_REPORT_LEN] = { 0 };
    if (n > SP_HID_REPORT_LEN) {
        n = SP_HID_REPORT_LEN;
    }
    memcpy(rep, buffer, n);
    return serial_send_frame(SP_T_HID, rep, SP_HID_REPORT_LEN);
}

/* -------------------------------------------------------------------- rx */

static void rx_task(void *arg) {
    (void) arg;
    uint8_t buf[64];
    for (;;) {
        int n = backend_read(buf, sizeof(buf), pdMS_TO_TICKS(50));
        if (n > 0) {
            /* If hid_task falls behind and the buffer fills, bytes are dropped; the
             * CRC/SOF framing resynchronises and CTAPHID timeouts make the host retry. */
            xStreamBufferSend(rx_sb, buf, (size_t) n, 0);
        }
    }
}

static void handle_frame(void) {
    switch (SP_FRAME_TYPE(&decoder)) {
        case SP_T_PING:
            serial_send_frame(SP_T_PONG, (const uint8_t *) SP_PONG_ID, sizeof(SP_PONG_ID) - 1);
            break;
        case SP_T_HID:
            if (SP_FRAME_DLEN(&decoder) == SP_HID_REPORT_LEN && ITF_HID_CTAP != ITF_INVALID) {
                tud_hid_set_report_cb(ITF_HID_CTAP, 0, 0, SP_FRAME_DATA(&decoder), SP_HID_REPORT_LEN);
            }
            break;
#ifdef ENABLE_FINGERPRINT
        case SP_T_FP:
            fingerprint_admin_request(SP_FRAME_DATA(&decoder), SP_FRAME_DLEN(&decoder));
            break;
#endif
        default:
            break; /* unknown / future frame types are ignored */
    }
}

void serial_hid_task(void) {
    if (!started) {
        return;
    }
    uint8_t buf[64];
    size_t n;
    while ((n = xStreamBufferReceive(rx_sb, buf, sizeof(buf), 0)) > 0) {
        for (size_t i = 0; i < n; i++) {
            if (sp_decoder_feed(&decoder, buf[i])) {
                handle_frame();
            }
        }
    }
}

void serial_transport_init(void) {
    if (started) {
        return;
    }
    sp_decoder_init(&decoder);
    tx_lock = xSemaphoreCreateMutex();
    rx_sb = xStreamBufferCreate(SER_RX_STREAM_BYTES, 1);
    backend_init();
    xTaskCreate(rx_task, "ser_rx", 3072, NULL, tskIDLE_PRIORITY + 5, NULL);
    started = true;
}
