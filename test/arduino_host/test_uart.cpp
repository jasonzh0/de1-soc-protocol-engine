// Execute the production sketch, not a copied transmit condition.
#include <cstdlib>
#include "../../arduino/uno_protocol_tester/uno_protocol_tester.ino"

static void require(bool condition, const char *message) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s (tx=%u, writes=%zu)\n", message,
                     static_cast<unsigned>(uartTx), fpgaSerial.outgoing.size());
        std::exit(1);
    }
}

static void command(char value) {
    Serial.incoming.push_back(static_cast<uint8_t>(value));
    loop();
}

static void tick(uint32_t now) {
    testMillis = now;
    // A continuously receiving peer must not prevent periodic TX.
    fpgaSerial.incoming.push_back(0x55);
    loop();
}

int main() {
    setup();
    command('u');
    require(fpgaSerial.baud == 31250, "UART link baud");
    require(fpgaSerial.availableForWrite() == 0, "model AltSoftSerial's inherited zero");
    for (uint32_t now = 1; now < 250; ++now) tick(now);
    require(fpgaSerial.outgoing.empty(), "no early transmission");
    tick(250);
    require(uartTx == 1 && fpgaSerial.outgoing.size() == 1,
            "first 3C byte must be queued at 250 ms even when availableForWrite is zero");
    for (uint32_t now = 251; now <= 1000; ++now) tick(now);
    require(uartTx == 4 && fpgaSerial.outgoing.size() == 4, "four writes per second");
    require(uartRx == 1000 && uartBad == 0 && uartLast == 0x55, "RX continues during TX");
    for (const auto value : fpgaSerial.outgoing) require(value == 0x3c, "TX payload is 3C");

    command('c');
    require(uartTx == 0 && uartRx == 0 && fpgaSerial.enabled, "clear preserves UART mode");
    for (uint32_t now = 1001; now <= 1250; ++now) tick(now);
    require(uartTx == 1 && fpgaSerial.outgoing.size() == 5, "TX resumes after counter clear");
    command('q');
    tick(1500);
    require(!fpgaSerial.enabled && fpgaSerial.outgoing.size() == 5, "idle stops TX");

    testMillis = UINT32_MAX - 100;
    command('u');
    tick(148); // 249 ms across unsigned millis() wrap
    require(uartTx == 0, "no early TX across millis wrap");
    tick(149); // 250 ms across wrap
    require(uartTx == 1 && fpgaSerial.outgoing.size() == 6, "TX survives millis wrap");
    std::puts("PASS: actual Uno sketch TX with availableForWrite=0, concurrent RX, clear, idle, millis wrap");
}
