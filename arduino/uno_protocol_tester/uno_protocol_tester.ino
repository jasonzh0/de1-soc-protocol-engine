// SPDX-License-Identifier: Apache-2.0
// Arduino Uno R3 ONLY. Use 5 V <-> 3.3 V level translation; see ../README.md.
// USB Serial = monitor/menu at 115200. AltSoftSerial = FPGA link at 31250.
// Test one protocol/wiring at a time with the FPGA held in reset while changing.
#include <Arduino.h>
#include <AltSoftSerial.h>
#include <Wire.h>
#include <avr/interrupt.h>
#include <util/atomic.h>

#if !defined(ARDUINO_AVR_UNO) || F_CPU != 16000000UL
#error "Select Arduino Uno (Uno R3 / ATmega328P, 16 MHz). This sketch is board-specific."
#endif

constexpr uint32_t FPGA_UART_BAUD = 31250;
constexpr uint8_t I2C_ADDRESS = 0x50;
constexpr uint8_t EXPECTED_UART = 0x55;
constexpr uint8_t EXPECTED_WRITE = 0xA5;
constexpr uint8_t UART_REPLY = 0x3C;
constexpr uint8_t SPI_REPLY = 0x3C;
constexpr uint8_t I2C_REPLY = 0x96;

AltSoftSerial fpgaSerial;  // Uno fixed pins: D8 RX, D9 TX; Timer1 owned here.
char activeMode = '-';
uint32_t uartRx = 0, uartBad = 0, uartTx = 0, uartTiming = 0;
uint8_t uartLast = 0;
uint32_t lastSendMs = 0, lastReportMs = 0;
volatile uint32_t spiRx = 0, spiBad = 0, i2cRx = 0, i2cBad = 0, i2cRequests = 0;
volatile uint8_t spiLast = 0, i2cLast = 0;

// The FPGA is SPI master; Arduino SPI.begin() would also select master mode.
// Use the AVR peripheral in mode 0, MSB first. No logging inside interrupts.
ISR(SPI_STC_vect) {
  const uint8_t value = SPDR;
  SPDR = SPI_REPLY;  // Prepare the next separate one-byte transaction.
  spiLast = value;
  ++spiRx;
  if (value != EXPECTED_WRITE) ++spiBad;
}

void receiveI2c(int count) {
  uint8_t seen = 0;
  bool bad = (count != 1);
  while (Wire.available()) {
    i2cLast = static_cast<uint8_t>(Wire.read());
    bad |= (i2cLast != EXPECTED_WRITE);
    ++seen;
  }
  ++i2cRx;
  if (bad || seen != 1) ++i2cBad;
}

void requestI2c() {
  Wire.write(I2C_REPLY);  // One byte; FPGA ends the read with NACK then STOP.
  ++i2cRequests;         // Callback invocation, not proof FPGA captured the byte.
}

void releaseTestPins() {
  if (activeMode == 'u') fpgaSerial.end();
  if (activeMode == 'i') Wire.end();
  SPCR = 0;
  // No Uno-side 5 V pull-ups are enabled by this function.
  const uint8_t pins[] = {8, 9, 10, 11, 12, 13, A4, A5};
  for (uint8_t pin : pins) {
    pinMode(pin, INPUT);
    digitalWrite(pin, LOW);
  }
  activeMode = '-';
}

void clearCounters() {
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
    spiRx = spiBad = i2cRx = i2cBad = i2cRequests = 0;
    spiLast = i2cLast = 0;
  }
  uartRx = uartBad = uartTx = uartTiming = 0;
  uartLast = 0;
  lastSendMs = lastReportMs = millis();
}

void selectMode(char mode) {
  releaseTestPins();
  clearCounters();
  activeMode = mode;
  if (mode == 'u') {
    fpgaSerial.begin(FPGA_UART_BAUD);
    digitalWrite(8, LOW);  // Disable any RX pull-up; translator supplies idle.
    Serial.println(F("UART: D8=RX D9=TX, 31250. FPGA SW2:0=100, then reset."));
  } else if (mode == 's') {
    pinMode(MISO, OUTPUT); // D12. MUST level-shift this 5 V output to the FPGA.
    pinMode(MOSI, INPUT);  // D11
    pinMode(SCK, INPUT);   // D13; do not use LED_BUILTIN while testing SPI.
    pinMode(SS, INPUT);    // D10. Keep CS high during reset with a 3.3 V-side pull-up.
    ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
      // Clear a possible pending flag from the previous selection first.
      volatile uint8_t discard = SPSR;
      discard = SPDR;
      (void)discard;
      SPCR = _BV(SPE) | _BV(SPIE); // Slave, CPOL=0, CPHA=0, MSB first.
      SPDR = SPI_REPLY;
    }
    Serial.println(F("SPI slave: D10=CS D11=MOSI D12=MISO D13=SCK. FPGA mode 010."));
  } else if (mode == 'i') {
    Wire.onReceive(receiveI2c);
    Wire.onRequest(requestI2c);
    Wire.begin(I2C_ADDRESS);
    // AVR Wire enables 5 V internal pull-ups by default. Use external pull-ups
    // on BOTH sides of a proper bidirectional I2C level shifter instead.
    digitalWrite(SDA, LOW);
    digitalWrite(SCL, LOW);
    Serial.println(F("I2C device 0x50: A4=SDA A5=SCL. FPGA 011 write / 111 read."));
  } else {
    activeMode = '-';
    Serial.println(F("Idle: test pins released. Hold FPGA SW9 high before rewiring."));
  }
}

void reportStatus() {
  char line[64];
  if (activeMode == 'u') {
    // Keep USB logging bounded and nonblocking so it cannot starve link RX.
    snprintf(line, sizeof(line), "U rx=%lu bad=%lu tx=%lu e=%lu %02X\n",
             static_cast<unsigned long>(uartRx), static_cast<unsigned long>(uartBad),
             static_cast<unsigned long>(uartTx), static_cast<unsigned long>(uartTiming),
             static_cast<unsigned>(uartLast));
  } else {
    uint32_t rx, bad, requests;
    uint8_t last;
    ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
      rx = (activeMode == 's') ? spiRx : i2cRx;
      bad = (activeMode == 's') ? spiBad : i2cBad;
      requests = i2cRequests;
      last = (activeMode == 's') ? spiLast : i2cLast;
    }
    snprintf(line, sizeof(line), "%c rx=%lu bad=%lu requests=%lu last=%02X\n",
             (activeMode == 's') ? 'S' : 'I', static_cast<unsigned long>(rx),
             static_cast<unsigned long>(bad), static_cast<unsigned long>(requests),
             static_cast<unsigned>(last));
  }
  const size_t length = strlen(line);
  if (Serial.availableForWrite() >= static_cast<int>(length))
    Serial.write(reinterpret_cast<const uint8_t *>(line), length);
}

void setup() {
  Serial.begin(115200);
  releaseTestPins();
  Serial.println(F("Uno R3 protocol tester. LEVEL SHIFT 5 V <-> 3.3 V!"));
  Serial.println(F("Hold FPGA SW9=1 while choosing mode/wiring; lower it AFTER setup."));
  Serial.println(F("Commands: u UART / s SPI / i I2C / q idle / c clear counters."));
}

void loop() {
  if (Serial.available()) {
    const char command = static_cast<char>(Serial.read());
    if (command == 'u' || command == 's' || command == 'i') selectMode(command);
    else if (command == 'q') selectMode('-');
    else if (command == 'c') clearCounters();
  }
  const uint32_t now = millis();
  if (activeMode == 'u') {
    while (fpgaSerial.available()) {
      uartLast = static_cast<uint8_t>(fpgaSerial.read());
      ++uartRx;
      if (uartLast != EXPECTED_UART) ++uartBad;
    }
    if (fpgaSerial.overflow()) ++uartTiming;
    // Send while FPGA TX is already streaming: this exercises true duplex.
    // FPGA captures 3C and toggles LEDR2; TX remains independently fixed at 55.
    if (now - lastSendMs >= 250) {
      fpgaSerial.write(UART_REPLY);
      ++uartTx;
      lastSendMs = now;
    }
  }
  if (activeMode != '-' && now - lastReportMs >= 1000) {
    reportStatus();
    lastReportMs = now;
  }
}
