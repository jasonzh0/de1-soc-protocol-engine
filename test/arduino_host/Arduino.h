#pragma once
// Host-only test doubles: no AVR timing, interrupts or electrical simulation.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <vector>

#define F(value) value
constexpr uint8_t INPUT = 0, OUTPUT = 1, LOW = 0;
constexpr uint8_t SS = 10, MOSI = 11, MISO = 12, SCK = 13;
constexpr uint8_t A4 = 18, A5 = 19, SDA = A4, SCL = A5;
constexpr uint8_t SPE = 6, SPIE = 7;
#define _BV(bit) (1U << (bit))
inline uint8_t SPDR = 0, SPCR = 0, SPSR = 0;
inline uint32_t testMillis = 0;
inline uint32_t millis() { return testMillis; }
inline void pinMode(uint8_t, uint8_t) {}
inline void digitalWrite(uint8_t, uint8_t) {}

class TestPrint {
public:
    // Arduino AVR Print default, inherited by AltSoftSerial 1.4.0.
    // Zero means a write MAY block, not that transmission is forbidden.
    virtual int availableForWrite() { return 0; }
    virtual ~TestPrint() = default;
};

class TestSerial : public TestPrint {
public:
    std::deque<uint8_t> incoming;
    void begin(uint32_t) {}
    int available() { return static_cast<int>(incoming.size()); }
    int read() {
        if (incoming.empty()) return -1;
        const auto value = incoming.front();
        incoming.pop_front();
        return value;
    }
    int availableForWrite() override { return 64; }
    void println(const char *) {}
    size_t write(const uint8_t *, size_t size) { return size; }
};
inline TestSerial Serial;
