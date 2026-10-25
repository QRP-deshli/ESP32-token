if("$ENV{PICOKEY_USB_TRANSPORT_SERIAL}" STREQUAL "1")
    set(FIDO2_REQUIRES mbedtls efuse)
else()
    set(FIDO2_REQUIRES esp_tinyusb mbedtls efuse)
endif()
idf_component_register(
    SRCS ${SOURCES}
    INCLUDE_DIRS . ../../pico-keys-sdk/src ../../pico-keys-sdk/src/fs ../../pico-keys-sdk/src/rng ../../pico-keys-sdk/src/usb  ../../pico-keys-sdk/tinycbor/src ../../pico-fido/src ../../pico-openpgp/src
    REQUIRES ${FIDO2_REQUIRES}
)
idf_component_set_property(${COMPONENT_NAME} WHOLE_ARCHIVE ON)
