`timescale 1ns/1ps
`default_nettype none
module tb_fpga_protocol;
    reg clk = 0;
    reg [9:0] sw = 0;
    wire [9:0] leds;
    wire [6:0] h0, h1, h2, h3, h4, h5;
    tri [35:0] gpio;
    reg rx_mode = 0, duplex_mode = 0, spi_loopback = 0, rx = 1, sda_low = 0;
    always #10 clk = !clk;
    genvar p;
    generate for (p = 0; p < 8; p = p + 1) begin: pulls
        pullup (gpio[p]);
    end endgenerate
    assign gpio[0] = rx_mode ? rx : 1'bz;
    assign gpio[1] = duplex_mode ? rx : 1'bz;
    assign gpio[0] = sda_low ? 1'b0 : 1'bz;
    assign gpio[2] = spi_loopback ? gpio[1] : 1'bz;
    de1_protocol_top dut (
        .CLOCK_50(clk), .KEY(4'hf), .SW(sw), .LEDR(leds),
        .HEX0(h0), .HEX1(h1), .HEX2(h2), .HEX3(h3), .HEX4(h4), .HEX5(h5),
        .GPIO_0(gpio)
    );
    task clocks(input integer n);
        repeat(n) begin @(posedge clk); #1; end
    endtask
    task boot(input [2:0] mode);
        begin
            @(negedge clk); sw = 10'h200 | mode;
            rx_mode = (mode[1:0] == 1); duplex_mode = (mode[1:0] == 0);
            spi_loopback = (mode[1:0] == 2); rx = 1; sda_low = 0;
            clocks(5);
            if (leds[1:0] !== 0) $fatal(1, "Reset must stop engine and clear fault");
            @(negedge clk); sw[9] = 0;
            wait(leds[0] === 1); #1;
            if (leds[6:4] !== {mode[2] && ((mode[1:0] == 0) || (&mode[1:0])), mode[1:0]})
                $fatal(1, "Wrong latched FPGA mode");
            if (gpio[35:8] !== {28{1'bz}}) $fatal(1, "Unused GPIO must stay tri-stated");
            if ({h2,h3,h4} !== {3{7'h7f}}) $fatal(1, "Unused displays must be blank");
        end
    endtask
    task tx_receive(input integer bit_cycles = 434);
        integer b;
        reg [7:0] value;
        begin
            @(negedge gpio[0]); clocks(bit_cycles / 2);
            for (b=0; b<8; b=b+1) begin clocks(bit_cycles); value[b] = gpio[0]; end
            clocks(bit_cycles);
            if (value !== 8'h55 || gpio[0] !== 1) $fatal(1, "FPGA UART TX config failed");
        end
    endtask
    task rx_send(input integer bit_cycles = 434);
        integer b;
        reg [7:0] value;
        begin
            value = 8'h3c;
            @(negedge clk); rx = 0;
            repeat(bit_cycles) @(negedge clk);
            for (b=0; b<8; b=b+1) begin rx = value[b]; repeat(bit_cycles) @(negedge clk); end
            rx = 1; repeat(bit_cycles) @(negedge clk);
            clocks(5);
            if (leds[2:0] !== 3'b101 || h1 !== 7'h30 || h0 !== 7'h46)
                $fatal(1, "FPGA UART RX readback/display failed");
        end
    endtask
    task i2c_ack_peer;
        integer byte_index, b;
        reg [7:0] value;
        begin
            @(negedge gpio[0]);
            if (gpio[1] !== 1) $fatal(1, "FPGA I2C missing START");
            for (byte_index=0; byte_index<2; byte_index=byte_index+1) begin
                for (b=7; b>=0; b=b-1) begin @(posedge gpio[1]); #1; value[b]=gpio[0]; end
                if (value !== ((byte_index == 0) ? 8'ha0 : 8'ha5))
                    $fatal(1, "FPGA I2C firmware/address mismatch");
                @(negedge gpio[1]); #1; sda_low=1;
                @(posedge gpio[1]); @(negedge gpio[1]); #1; sda_low=0;
            end
            wait(leds[2] === 1); #1;
            if (leds[1:0] !== 1 || gpio[1:0] !== 2'b11 || {h1,h0} !== {2{7'h40}})
                $fatal(1, "FPGA I2C completion/display failed");
        end
    endtask
    task i2c_read_peer;
        integer b;
        reg [7:0] address, reply;
        begin
            reply = 8'h96;
            @(negedge gpio[0]);
            for (b=7; b>=0; b=b-1) begin @(posedge gpio[1]); #1; address[b]=gpio[0]; end
            if (address !== 8'ha1) $fatal(1, "FPGA I2C read address");
            @(negedge gpio[1]); #1; sda_low=1;
            @(posedge gpio[1]); @(negedge gpio[1]); #1;
            for (b=7; b>=0; b=b-1) begin
                sda_low = !reply[b];
                @(posedge gpio[1]); @(negedge gpio[1]); #1;
            end
            sda_low=0;
            @(posedge gpio[1]); #1;
            if (gpio[0] !== 1) $fatal(1, "FPGA I2C read final NACK");
            wait(leds[2] === 1); #1;
            if (leds[1:0] !== 1 || gpio[1:0] !== 2'b11 || h1 !== 7'h10 || h0 !== 7'h02)
                $fatal(1, "FPGA I2C receive/display failed");
        end
    endtask
    initial begin
        boot(0); if (h5 !== 7'h40) $fatal(1, "Mode 0 display");
        fork
            begin tx_receive(); tx_receive(); end
            begin #137; rx_send(); end
        join
        if (!leds[3]) $fatal(1, "Duplex RX wait LED while TX runs");
        boot(1); if (h5 !== 7'h79) $fatal(1, "Mode 1 display"); clocks(10);
        if (!leds[3]) $fatal(1, "UART RX wait LED"); rx_send();
        boot(2); if (h5 !== 7'h24) $fatal(1, "Mode 2 display");
        wait(leds[2] === 1); clocks(8);
        if (leds[1] || h1 !== 7'h08 || h0 !== 7'h12 || gpio[3:0] !== 4'b1110)
            $fatal(1, "SPI loopback result/idle pins");
        @(negedge clk); sw[1:0] = 0; clocks(100);
        if (leds[5:4] !== 2 || h5 !== 7'h24) $fatal(1, "Mode changed without reset");
        fork
            i2c_ack_peer();
            boot(3);
        join
        if (h5 !== 7'h30) $fatal(1, "Mode 3 display");
        fork
            i2c_read_peer();
            boot(7);
        join
        if (h5 !== 7'h78 || leds[6] !== 1) $fatal(1, "I2C read mode indication");
        @(negedge clk); sw[2] = 0; clocks(50);
        if (h5 !== 7'h78 || leds[6] !== 1) $fatal(1, "I2C direction changed without reset");
        boot(7); wait(leds[1] === 1); clocks(5);
        if (gpio[1:0] !== 2'b11 || leds[2]) $fatal(1, "I2C read NACK should not capture");
        // No slave on next run: report NACK/fault and release both bus lines.
        boot(3); wait(leds[1] === 1); clocks(5);
        if (leds[0] || gpio[1:0] !== 2'b11) $fatal(1, "FPGA NACK fault/drive safety");
        // Reset and change back to UART; boot adapter must reload successfully.
        boot(4);
        fork
            begin tx_receive(1600); tx_receive(1600); end
            begin #237; rx_send(1600); end
        join
        if (h5 !== 7'h19 || leds[6] !== 1) $fatal(1, "Uno UART profile indication");
        boot(5);
        if (h5 !== 7'h79 || leds[6] !== 0) $fatal(1, "SW2 must be ignored for standalone RX");
        $display("PASS: FPGA full-duplex UART, SPI exchange, I2C read/write, mode latching and fault recovery");
        $finish;
    end
    initial begin #3000000; $fatal(1, "FPGA protocol boot timeout"); end
endmodule
`default_nettype wire
