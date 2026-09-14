.PHONY: test quartus

IVERILOG ?= iverilog
VVP ?= vvp
QUARTUS_SH ?= quartus_sh

test:
	mkdir -p build
	$(IVERILOG) -g2012 -Wall -s tb_uart -o build/tb_uart test/tb_uart.v rtl/protocol_engine.v rtl/de1_soc_top.v
	$(VVP) build/tb_uart

quartus:
	cd quartus && $(QUARTUS_SH) --flow compile de1_soc_demo
