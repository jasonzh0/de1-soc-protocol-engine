# Uno sketch-loop regression

Run `make test-arduino-host` from the repository root with a C++17 compiler.
The test includes the production `.ino` and invokes its menu and loop while
advancing a deterministic 32-bit clock. It checks transmitted bytes as well as
the TX count; incrementing the counter without writing will not pass.

The peripheral headers here are deliberately small host-only doubles. The
important library contract is `Print::availableForWrite() == 0`, inherited by
AltSoftSerial 1.4.0. Zero means a write may block, not that writes are forbidden:

- [AVR core 1.8.6 Print.h](https://github.com/arduino/ArduinoCore-avr/blob/1.8.6/cores/arduino/Print.h)
- [AltSoftSerial API](https://github.com/PaulStoffregen/AltSoftSerial/blob/master/AltSoftSerial.h)

The original sketch failed this test at 250 ms with `tx=0, writes=0`. Removing
the unsupported capacity guard permits four writes per second while receiving.
Compilation alone missed this because the inherited method is valid C++.

SPI/I2C and AVR interrupt/electrical behavior are not simulated by these
doubles. Keep the actual AVR compile (`make test-arduino`) and FPGA/ASIC RTL
regressions separate; neither replaces a physical duplex test.
