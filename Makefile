.DEFAULT_GOAL := help

.PHONY: help test test-fpga test-fpga-legacy test-tt test-protocols test-template \
        test-arduino test-arduino-host check-template synth quartus \
        test-memory test-sync test-ihp-memory ihp-sram-models synth-sram \
        usb-firmware test-usb test-usb-board test-extended quartus-usb

IVERILOG ?= iverilog
VVP ?= vvp
QUARTUS_SH ?= quartus_sh
YOSYS ?= yosys
PYTHON ?= python3
ARDUINO_CLI ?= arduino-cli
USB_IDS ?=
CORE_SOURCES = src/protocol_engine.v src/program_store.v
TT_SOURCES = $(CORE_SOURCES) src/program_loader.v src/tt_um_jasonzh0_protocol_engine.v
FPGA_SOURCES = $(CORE_SOURCES) rtl/firmware_bootloader.v rtl/de1_protocol_top.v
USB_BOARD_SOURCES = $(CORE_SOURCES) rtl/usb_firmware_bootloader.v rtl/de1_usb_top.v
LEGACY_SOURCES = $(CORE_SOURCES) rtl/button_events.v rtl/uart_program_sender.v rtl/de1_soc_top.v
IHP_MODELS = build/ihp-sram/RM_IHPSG13_1P_1024x32_c2_bm_bist.v build/ihp-sram/RM_IHPSG13_1P_core_behavioral_bm_bist.v

help:
	@printf '%s\n' \
	  'Local regressions (Icarus Verilog, Make, C++17):' \
	  '  make test             Default FPGA/ASIC, legacy demo, Arduino host, ISA and memory' \
	  '  make test-sync        Clocked RAM: extended ISA, UART/SPI/I2C and USB' \
	  '  make test-usb         Legacy memory: USB at three host rates' \
	  '  make test-usb-board   Clocked USB FPGA boot and PHY adapter' \
	  '  make test-ihp-memory  IHP SRAM model regressions (downloads pinned model views)' \
	  '' \
	  'Template checks (install test/requirements.txt):' \
	  '  make check-template test-template' \
	  '' \
	  'Optional installed toolchains:' \
	  '  make synth           Generic Yosys synthesis' \
	  '  make synth-sram      IHP cell/macro mapping (downloads pinned Liberty views)' \
	  '  make quartus         Active UART/SPI/I2C FPGA project' \
	  '  make quartus-usb     Experimental USB FPGA project' \
	  '  make test-arduino    Compile Uno R3 sketch with arduino-cli' \
	  '' \
	  'See README.md and docs/ for profiles, wiring and physical-verification limits.'

# Explicit network access: default make/help and make test stay offline.
ihp-sram-models:
	bash scripts/fetch_ihp_sram.sh

test-memory:
	mkdir -p build
	$(IVERILOG) -g2012 -s tb_program_store -o build/tb_program_store test/tb_program_store.v src/program_store.v
	$(VVP) build/tb_program_store
	$(IVERILOG) -g2012 -s tb_wide_loader -o build/tb_wide_loader test/tb_wide_loader.v $(TT_SOURCES)
	$(VVP) build/tb_wide_loader
	$(IVERILOG) -g2012 -s tb_fetch_equivalence -o build/tb_fetch_equivalence test/tb_fetch_equivalence.v $(CORE_SOURCES)
	$(VVP) build/tb_fetch_equivalence

test-sync: usb-firmware
	$(IVERILOG) -g2012 -DPROGRAM_MEMORY=1 -s tb_extended_isa -o build/tb_extended_sync test/tb_extended_isa.v $(CORE_SOURCES)
	$(VVP) build/tb_extended_sync
	$(IVERILOG) -g2012 -DPROGRAM_MEMORY=1 -s tb_protocols -o build/tb_protocols_sync test/tb_protocols.v $(TT_SOURCES)
	$(VVP) build/tb_protocols_sync
	$(IVERILOG) -g2012 -DPROGRAM_MEMORY=1 -s tb_usb_ls -o build/tb_usb_sync test/tb_usb_ls.v $(CORE_SOURCES)
	$(VVP) build/tb_usb_sync
	$(VVP) build/tb_usb_sync +HOST_BIT_NS=658
	$(VVP) build/tb_usb_sync +HOST_BIT_NS=676

test-ihp-memory: ihp-sram-models usb-firmware
	$(IVERILOG) -g2012 -DFUNCTIONAL -DPROGRAM_MEMORY=2 -s tb_program_store -o build/tb_store_ihp test/tb_program_store.v src/program_store.v $(IHP_MODELS)
	$(VVP) build/tb_store_ihp
	$(IVERILOG) -g2012 -DFUNCTIONAL -DPROGRAM_MEMORY=2 -s tb_wide_loader -o build/tb_loader_ihp test/tb_wide_loader.v $(TT_SOURCES) $(IHP_MODELS)
	$(VVP) build/tb_loader_ihp
	$(IVERILOG) -g2012 -DFUNCTIONAL -DPROGRAM_MEMORY=2 -s tb_fetch_equivalence -o build/tb_fetch_ihp test/tb_fetch_equivalence.v $(CORE_SOURCES) $(IHP_MODELS)
	$(VVP) build/tb_fetch_ihp
	$(IVERILOG) -g2012 -DFUNCTIONAL -DPROGRAM_MEMORY=2 -s tb_extended_isa -o build/tb_extended_ihp test/tb_extended_isa.v $(CORE_SOURCES) $(IHP_MODELS)
	$(VVP) build/tb_extended_ihp
	$(IVERILOG) -g2012 -DFUNCTIONAL -DPROGRAM_MEMORY=2 -s tb_protocols -o build/tb_protocols_ihp test/tb_protocols.v $(TT_SOURCES) $(IHP_MODELS)
	$(VVP) build/tb_protocols_ihp
	$(IVERILOG) -g2012 -DFUNCTIONAL -DPROGRAM_MEMORY=2 -s tb_usb_ls -o build/tb_usb_ihp test/tb_usb_ls.v $(CORE_SOURCES) $(IHP_MODELS)
	$(VVP) build/tb_usb_ihp
	$(VVP) build/tb_usb_ihp +HOST_BIT_NS=658
	$(VVP) build/tb_usb_ihp +HOST_BIT_NS=676
	$(IVERILOG) -g2012 -DFUNCTIONAL -DPROGRAM_MEMORY=2 -DUSB_TT_TEST -s tb_usb_ls -o build/tb_usb_tt_ihp test/tb_usb_ls.v $(TT_SOURCES) $(IHP_MODELS)
	$(VVP) build/tb_usb_tt_ihp

synth-sram: ihp-sram-models
	$(YOSYS) -Q -T -l build/asic_sram_mapped.log -s scripts/synth_sram.ys

usb-firmware:
	mkdir -p build
	$(CXX) -std=c++17 -Wall -Wextra -Werror firmware/usb_ls/build_firmware.cpp -o build/build_usb_firmware
	build/build_usb_firmware build/usb_ls.hex build/usb_ls.lst $(USB_IDS)

test-usb: usb-firmware
	$(IVERILOG) -g2012 -Wall -s tb_usb_ls -o build/tb_usb_ls test/tb_usb_ls.v $(CORE_SOURCES)
	$(VVP) build/tb_usb_ls
	$(VVP) build/tb_usb_ls +HOST_BIT_NS=658
	$(VVP) build/tb_usb_ls +HOST_BIT_NS=676

test-usb-board: usb-firmware
	$(IVERILOG) -g2012 -Wall -DUSB_BOARD_TEST -s tb_usb_ls -o build/tb_usb_board test/tb_usb_ls.v $(USB_BOARD_SOURCES)
	$(VVP) build/tb_usb_board

quartus-usb: usb-firmware
	cd quartus && $(QUARTUS_SH) --flow compile de1_soc_usb

test: test-fpga test-fpga-legacy test-tt test-protocols test-arduino-host test-extended test-memory

test-extended:
	mkdir -p build
	$(IVERILOG) -g2012 -Wall -s tb_extended_isa -o build/tb_extended_isa test/tb_extended_isa.v $(CORE_SOURCES)
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
	$(IVERILOG) -g2012 -Wall -s tb_uart -o build/tb_uart test/tb_uart.v $(LEGACY_SOURCES)
	$(VVP) build/tb_uart

test-fpga:
	mkdir -p build
	$(IVERILOG) -g2012 -Wall -s tb_fpga_protocol -o build/tb_fpga_protocol test/tb_fpga_protocol.v $(FPGA_SOURCES)
	cd quartus && $(VVP) ../build/tb_fpga_protocol

test-tt:
	mkdir -p build
	$(IVERILOG) -g2012 -Wall -s tb_tiny_tapeout -o build/tb_tiny_tapeout test/tb_tiny_tapeout.v $(TT_SOURCES)
	$(VVP) build/tb_tiny_tapeout

test-protocols:
	mkdir -p build
	$(IVERILOG) -g2012 -Wall -s tb_protocols -o build/tb_protocols test/tb_protocols.v $(TT_SOURCES)
	$(VVP) build/tb_protocols

quartus:
	cd quartus && $(QUARTUS_SH) --flow compile de1_soc_demo

synth:
	mkdir -p build
	$(YOSYS) -Q -T -l build/synthesis.log -s scripts/synth.ys
