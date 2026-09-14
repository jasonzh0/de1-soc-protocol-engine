`timescale 1ns/1ps
`default_nettype none

module tb_uart;
    reg clk = 0;
    reg [3:0] key = 4'b1111;
    wire [9:0] leds;
    wire [35:0] gpio;
    integer frame;
    integer bit_index;
    reg [7:0] received;
    localparam BIT_NS = 8680; // 434 clocks at 50 MHz.

    always #10 clk = !clk;

    de1_soc_top dut (.CLOCK_50(clk), .KEY(key), .LEDR(leds), .GPIO_0(gpio));

    initial begin
        #1 key[0] = 0;
        #100 key[0] = 1;
        wait (leds[0] === 1'b1);
        for (frame = 0; frame < 3; frame = frame + 1) begin
            @(negedge gpio[0]);
            #(BIT_NS / 2);
            if (gpio[0] !== 0) $fatal(1, "Invalid UART start bit");
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                #(BIT_NS);
                received[bit_index] = gpio[0];
            end
            #(BIT_NS);
            if (gpio[0] !== 1) $fatal(1, "Invalid UART stop bit");
            if (received !== 8'h55) $fatal(1, "Expected 55, got %h", received);
            if (leds[1] !== 0) $fatal(1, "Engine fault");
        end
        $display("PASS: decoded three UART frames of 0x55");
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "Simulation timeout");
    end
endmodule

`default_nettype wire
