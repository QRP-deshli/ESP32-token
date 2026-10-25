set(PICO_KEYS_SDK_DIR ${CMAKE_CURRENT_LIST_DIR}/../../../..)
set(PICO_KEYS_REQUIRES bootloader_support esp_partition efuse mbedtls mlkem512 mlkem768 mlkem1024 tinycbor)
if("$ENV{PICOKEY_USB_TRANSPORT_SERIAL}" STREQUAL "1")
    # no TinyUSB: the serial backends need these drivers instead
    list(APPEND PICO_KEYS_REQUIRES esp_driver_usb_serial_jtag esp_driver_uart esp_driver_gpio)
else()
    list(APPEND PICO_KEYS_REQUIRES esp_tinyusb)
endif()
idf_component_register(
    SRCS ${PICO_KEYS_SOURCES}
    INCLUDE_DIRS ${PICO_KEYS_SDK_DIR}/src ${PICO_KEYS_SDK_DIR}/src/fs ${PICO_KEYS_SDK_DIR}/src/rng ${PICO_KEYS_SDK_DIR}/src/usb ${PICO_KEYS_SDK_DIR}/src/led ${PICO_KEYS_SDK_DIR}/tinycbor/src ${PICO_KEYS_SDK_DIR}/mlkem/mlkem ${PICO_KEYS_SDK_DIR}/config/mlkem
    REQUIRES ${PICO_KEYS_REQUIRES}
)
idf_component_set_property(${COMPONENT_NAME} WHOLE_ARCHIVE ON)
