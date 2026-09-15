.PHONY: test test-fpga test-fpga-legacy test-tt test-protocols test-template check-template synth quartus

IVERILOG ?= iverilog
VVP ?= vvp
QUARTUS_SH ?= quartus_sh
YOSYS ?= yosys
PYTHON ?= python3

test: test-fpga test-fpga-legacy test-tt test-protocols

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
