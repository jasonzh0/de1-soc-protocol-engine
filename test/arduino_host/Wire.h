#pragma once
#include "Arduino.h"
class TestWire {
public:
    void begin(uint8_t) {}
    void end() {}
    void onReceive(void (*)(int)) {}
    void onRequest(void (*)()) {}
    int available() { return 0; }
    int read() { return -1; }
    size_t write(uint8_t) { return 1; }
};
inline TestWire Wire;
