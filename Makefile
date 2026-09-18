.PHONY: test test-fpga test-fpga-legacy test-tt test-protocols test-template test-arduino test-arduino-host check-template synth quartus

IVERILOG ?= iverilog
VVP ?= vvp
QUARTUS_SH ?= quartus_sh
YOSYS ?= yosys
PYTHON ?= python3
ARDUINO_CLI ?= arduino-cli

.PHONY: usb-firmware test-usb test-usb-board test-extended quartus-usb
USB_IDS ?=
usb-firmware:
	mkdir -p build
	$(CXX) -std=c++17 -Wall -Wextra -Werror firmware/usb_ls/build_firmware.cpp -o build/build_usb_firmware
	build/build_usb_firmware build/usb_ls.hex build/usb_ls.lst $(USB_IDS)

test-usb: usb-firmware
	$(IVERILOG) -g2012 -Wall -s tb_usb_ls -o build/tb_usb_ls test/tb_usb_ls.v src/protocol_engine.v
	$(VVP) build/tb_usb_ls
	$(VVP) build/tb_usb_ls +HOST_BIT_NS=658
	$(VVP) build/tb_usb_ls +HOST_BIT_NS=676

test-usb-board: usb-firmware
	$(IVERILOG) -g2012 -Wall -DUSB_BOARD_TEST -s tb_usb_ls -o build/tb_usb_board test/tb_usb_ls.v src/protocol_engine.v rtl/usb_firmware_bootloader.v rtl/de1_usb_top.v
	$(VVP) build/tb_usb_board

quartus-usb: usb-firmware
	cd quartus && $(QUARTUS_SH) --flow compile de1_soc_usb

test: test-fpga test-fpga-legacy test-tt test-protocols test-arduino-host test-extended

test-extended:
	mkdir -p build
	$(IVERILOG) -g2012 -Wall -s tb_extended_isa -o build/tb_extended_isa test/tb_extended_isa.v src/protocol_engine.v
	$(VVP) build/tb_extended_isa

# Host regression runs the real sketch loop with deterministic peripheral doubles.
test-arduino-host:
	mkdir -p build
	$(CXX) -std=c++17 -Wall -Wextra -Werror -DARDUINO_AVR_UNO -DF_CPU=16000000UL -Itest/arduino_host test/arduino_host/test_uart.cpp -o build/test_arduino_uart
	build/test_arduino_uart

# Optional hardware-peer compile; install pinned AVR core / AltSoftSerial first.
test-arduino:
	$(ARDUINO_CLI) compile --fqbn arduino:avr:uno --warnings all --build-path $(CURDIR)/build/arduino arduino/uno_protocol_tester

# Install test/requirements.txt first. The template GDS action calls test/Makefile
# directly with GATES=yes after supplying its CMOS5L netlist and PDK models.
test-template:
	$(MAKE) -C test
	$(PYTHON) scripts/check_test_results.py test/results.xml

check-template:
	$(PYTHON) scripts/check_template.py

test-fpga-legacy:
	mkdir -p build
	$(IVERILOG) -g2012 -Wall -s tb_uart -o build/tb_uart test/tb_uart.v src/protocol_engine.v rtl/button_events.v rtl/uart_program_sender.v rtl/de1_soc_top.v
	$(VVP) build/tb_uart

test-fpga:
	mkdir -p build
	$(IVERILOG) -g2012 -Wall -s tb_fpga_protocol -o build/tb_fpga_protocol test/tb_fpga_protocol.v src/protocol_engine.v rtl/firmware_bootloader.v rtl/de1_protocol_top.v
	cd quartus && $(VVP) ../build/tb_fpga_protocol

test-tt:
	mkdir -p build
	$(IVERILOG) -g2012 -Wall -s tb_tiny_tapeout -o build/tb_tiny_tapeout test/tb_tiny_tapeout.v src/protocol_engine.v src/program_loader.v src/tt_um_jasonzh0_protocol_engine.v
	$(VVP) build/tb_tiny_tapeout

test-protocols:
	mkdir -p build
	$(IVERILOG) -g2012 -Wall -s tb_protocols -o build/tb_protocols test/tb_protocols.v src/protocol_engine.v src/program_loader.v src/tt_um_jasonzh0_protocol_engine.v
	$(VVP) build/tb_protocols

quartus:
	cd quartus && $(QUARTUS_SH) --flow compile de1_soc_demo

synth:
	mkdir -p build
	$(YOSYS) -Q -T -l build/synthesis.log -s scripts/synth.ys
