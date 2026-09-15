.PHONY: test test-fpga test-tt synth quartus

IVERILOG ?= iverilog
VVP ?= vvp
QUARTUS_SH ?= quartus_sh
YOSYS ?= yosys

test: test-fpga test-tt

test-fpga:
	mkdir -p build
	$(IVERILOG) -g2012 -Wall -s tb_uart -o build/tb_uart test/tb_uart.v src/protocol_engine.v rtl/button_events.v rtl/uart_program_sender.v rtl/de1_soc_top.v
	$(VVP) build/tb_uart

test-tt:
	mkdir -p build
	$(IVERILOG) -g2012 -Wall -s tb_tiny_tapeout -o build/tb_tiny_tapeout test/tb_tiny_tapeout.v src/protocol_engine.v src/program_loader.v src/tt_um_jasonzh0_protocol_engine.v
	$(VVP) build/tb_tiny_tapeout

quartus:
	cd quartus && $(QUARTUS_SH) --flow compile de1_soc_demo

synth:
	mkdir -p build
	$(YOSYS) -Q -T -l build/synthesis.log -s scripts/synth.ys
