/*
 * ESP-IDF glue for the fingerprint gate: UART1 byte I/O for fp_core, a lock so the FIDO path and the
 * enrolment task never talk to the sensor at the same time, and the admin task.
 */
#include "pico_keys.h"
#include "fingerprint.h"
#include "fp_core.h"
#include "serial/serial_transport.h"
#include <string.h>
#include <stdio.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "driver/uart.h"
#include "driver/gpio.h"

/* Wiring (override with -D at build time). Avoid GPIO 4,5,8,9,15 (JTAG/strapping), 12,13 (USB), 16,17 (console). */
#ifndef PICOKEY_FP_UART_NUM
#define PICOKEY_FP_UART_NUM  UART_NUM_1
#endif
#ifndef PICOKEY_FP_TX
#define PICOKEY_FP_TX        10      /* -> sensor RX */
#endif
#ifndef PICOKEY_FP_RX
#define PICOKEY_FP_RX        11      /* <- sensor TX */
#endif
#ifndef PICOKEY_FP_RST
#define PICOKEY_FP_RST       18      /* sensor RST (HIGH = powered). Use -1 if you tie RST to 3V3. */
#endif
#ifndef PICOKEY_FP_BAUD
#define PICOKEY_FP_BAUD      19200
#endif

extern bool cancel_button;
extern void execute_tasks(void);

typedef struct {
    uint8_t len;
    uint8_t data[8];
} admin_req_t;

static SemaphoreHandle_t fp_lock = NULL;
static QueueHandle_t admin_q = NULL;
static bool fp_ready = false;

/* ---- byte I/O ---- */
static int io_write(void *c, const uint8_t *b, size_t n) {
    (void) c;
    int w = uart_write_bytes(PICOKEY_FP_UART_NUM, (const char *) b, n);
    uart_wait_tx_done(PICOKEY_FP_UART_NUM, pdMS_TO_TICKS(100));
    return w;
}
static int io_read(void *c, uint8_t *b, uint32_t ms) {
    (void) c;
    return uart_read_bytes(PICOKEY_FP_UART_NUM, b, 1, pdMS_TO_TICKS(ms)) == 1;
}
static uint32_t io_millis(void *c) {
    (void) c;
    return board_millis();
}
static void io_flush(void *c) {
    (void) c;
    uart_flush_input(PICOKEY_FP_UART_NUM);
}
/* FIDO path: keep the HID transport, keepalives and CTAPHID_CANCEL alive while waiting */
static void core_pump(void *c) {
    (void) c;
    execute_tasks();
}
static bool core_cancelled(void *c) {
    (void) c;
    return cancel_button;
}
static void admin_pump(void *c) {
    (void) c;
    vTaskDelay(1);
}

static fp_io_t core_io(void) {
    fp_io_t io = { NULL, io_write, io_read, io_millis, io_flush, core_pump, core_cancelled };
    return io;
}
static fp_io_t admin_io(void) {
    fp_io_t io = { NULL, io_write, io_read, io_millis, io_flush, admin_pump, NULL };
    return io;
}

/* Pulse the module's RST pin (power-cycles its processor; enrolled fingerprints are kept in its own flash).
 * Used as a recovery step if the module stops answering, e.g. after it went to sleep. */
static void sensor_reset(void) {
#if PICOKEY_FP_RST >= 0
    gpio_set_level(PICOKEY_FP_RST, 0);
    vTaskDelay(pdMS_TO_TICKS(30));
    gpio_set_level(PICOKEY_FP_RST, 1);
    vTaskDelay(pdMS_TO_TICKS(500));
    uart_flush_input(PICOKEY_FP_UART_NUM);
#endif
}

/* ---- user verification for FIDO operations ---- */
bool fingerprint_verify_user(uint32_t timeout_ms) {
    if (!fp_ready) {
        return false;
    }
    uint32_t start = board_millis();
    while (xSemaphoreTake(fp_lock, 0) != pdTRUE) {      /* enrolment in progress */
        execute_tasks();
        vTaskDelay(1);
        if (cancel_button || (uint32_t)(board_millis() - start) >= timeout_ms) {
            return false;
        }
    }
    fp_io_t io = core_io();
    uint32_t used = (uint32_t)(board_millis() - start);
    uint16_t uid = 0;
    fp_result_t r = fp_verify(&io, used < timeout_ms ? timeout_ms - used : 0, &uid);
    if (r == FPR_NO_SENSOR && PICOKEY_FP_RST >= 0 && !cancel_button) {
        printf("fingerprint: sensor silent, resetting it and retrying once\n");
        sensor_reset();
        used = (uint32_t)(board_millis() - start);
        r = fp_verify(&io, used < timeout_ms ? timeout_ms - used : 0, &uid);
    }
    xSemaphoreGive(fp_lock);
    if (r == FPR_OK) {
        printf("fingerprint: user %u verified\n", (unsigned) uid);
        return true;
    }
    printf("fingerprint: not granted (result %d)\n", (int) r);
    return false;
}

/* ---- admin (enrol / delete) from the PC tool ---- */
static void admin_emit(void *c, const uint8_t *d, size_t l) {
    (void) c;
    serial_send_frame(SP_T_FP, d, l);
}

static void admin_status_reply(uint8_t op, uint8_t status) {
    uint8_t d[4] = { op, status, 0, 0 };
    serial_send_frame(SP_T_FP, d, sizeof(d));
}

static void admin_task(void *arg) {
    (void) arg;
    admin_req_t rq;
    fp_io_t io = admin_io();
    for (;;) {
        if (xQueueReceive(admin_q, &rq, portMAX_DELAY) != pdTRUE) {
            continue;
        }
        if (xSemaphoreTake(fp_lock, pdMS_TO_TICKS(30000)) != pdTRUE) {
            admin_status_reply(rq.data[0], FPA_BUSY);
            continue;
        }
        fp_admin_handle(&io, rq.data, rq.len, admin_emit, NULL);
        xSemaphoreGive(fp_lock);
    }
}

void fingerprint_admin_request(const uint8_t *data, uint16_t len) {
    admin_req_t rq;
    memset(&rq, 0, sizeof(rq));
    if (len == 0 || len > sizeof(rq.data)) {
        admin_status_reply(len ? data[0] : 0, FPA_BAD_REQUEST);
        return;
    }
    if (!fp_ready || admin_q == NULL) {
        admin_status_reply(data[0], FPA_NO_SENSOR);
        return;
    }
    rq.len = (uint8_t) len;
    memcpy(rq.data, data, len);
    if (xQueueSend(admin_q, &rq, 0) != pdTRUE) {
        admin_status_reply(data[0], FPA_BUSY);
    }
}

void fingerprint_init(void) {
    const uart_config_t cfg = {
        .baud_rate = PICOKEY_FP_BAUD,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    if (uart_driver_install(PICOKEY_FP_UART_NUM, 512, 0, 0, NULL, 0) != ESP_OK ||
        uart_param_config(PICOKEY_FP_UART_NUM, &cfg) != ESP_OK ||
        uart_set_pin(PICOKEY_FP_UART_NUM, PICOKEY_FP_TX, PICOKEY_FP_RX, UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE) != ESP_OK) {
        printf("fingerprint: UART setup failed, user presence will be denied\n");
        return;
    }
#if PICOKEY_FP_RST >= 0
    gpio_config_t g = {
        .pin_bit_mask = 1ULL << PICOKEY_FP_RST,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = 0,
        .pull_down_en = 0,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&g);
    gpio_set_level(PICOKEY_FP_RST, 1);
    vTaskDelay(pdMS_TO_TICKS(500));     /* let the module boot */
#endif
    fp_lock = xSemaphoreCreateMutex();
    admin_q = xQueueCreate(2, sizeof(admin_req_t));
    if (fp_lock == NULL || admin_q == NULL) {
        printf("fingerprint: out of memory\n");
        return;
    }
    xTaskCreate(admin_task, "fp_admin", 4096, NULL, tskIDLE_PRIORITY + 4, NULL);
    fp_ready = true;

    fp_io_t io = admin_io();
    uint16_t count = 0;
    if (fp_count(&io, &count) == FPR_OK) {
        printf("fingerprint: sensor ready, %u enrolled\n", (unsigned) count);
    }
    else {
        printf("fingerprint: sensor does not answer (UART%d TX=GPIO%d RX=GPIO%d %d baud) - user presence will be denied\n",
               (int) PICOKEY_FP_UART_NUM, PICOKEY_FP_TX, PICOKEY_FP_RX, PICOKEY_FP_BAUD);
    }
}
