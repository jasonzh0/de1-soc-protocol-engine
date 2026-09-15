#pragma once
#include "Arduino.h"

class AltSoftSerial : public TestPrint {
public:
    std::deque<uint8_t> incoming;
    std::vector<uint8_t> outgoing;
    uint32_t baud = 0;
    bool enabled = false;
    void begin(uint32_t value) { baud = value; enabled = true; }
    void end() { enabled = false; }
    int available() { return static_cast<int>(incoming.size()); }
    int read() {
        if (incoming.empty()) return -1;
        const auto value = incoming.front();
        incoming.pop_front();
        return value;
    }
    bool overflow() { return false; }
    size_t write(uint8_t value) {
        if (!enabled) return 0;
        outgoing.push_back(value);
        return 1;
    }
    // Deliberately no availableForWrite override, just like version 1.4.0.
};
