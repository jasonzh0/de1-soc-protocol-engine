`timescale 1ns/1ps
`default_nettype none

module tb_uart;
    reg clk = 0;
    reg [3:0] key = 4'hf;
    reg [9:0] switches = 0;
    wire [9:0] leds;
    wire [35:0] gpio;
    wire [6:0] hex0, hex1, hex2, hex3, hex4, hex5;
    reg [7:0] received [0:31];
    reg [7:0] byte_value;
    integer received_count = 0;
    integer bit_index;
    integer k;
    integer before_count;
    localparam BIT_NS = 8680;

    always #10 clk = !clk;
    // Accelerate debounce only; transmit/decode at the real 115200 baud rate.
    de1_soc_top #(.DEBOUNCE_CYCLES(8)) dut (
        .CLOCK_50(clk), .KEY(key), .SW(switches), .LEDR(leds), .GPIO_0(gpio),
        .HEX0(hex0), .HEX1(hex1), .HEX2(hex2), .HEX3(hex3), .HEX4(hex4), .HEX5(hex5)
    );

    task clocks;
        input integer n;
        begin repeat (n) begin @(posedge clk); #1; end end
    endtask

    // Continuous receiver records every frame, including unintended repeats.
    initial forever begin
        @(negedge gpio[0]);
        if (!switches[9]) begin
            #(BIT_NS/2);
            if (gpio[0] !== 0) $fatal(1, "Invalid start bit");
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                #(BIT_NS);
                byte_value[bit_index] = gpio[0];
            end
            #(BIT_NS);
            if (gpio[0] !== 1) $fatal(1, "Invalid stop bit");
            if (received_count == 32) $fatal(1, "Unexpected repeated frames");
            received[received_count] = byte_value;
            received_count = received_count + 1;
        end
    end

    task await_count;
        input integer count;
        integer timeout;
        begin
            timeout = 0;
            while (received_count < count && timeout < 30000) begin
                clocks(1);
                timeout = timeout + 1;
            end
            if (received_count != count) $fatal(1, "Expected %0d frames, got %0d", count, received_count);
            clocks(1000); // allow the complete stop bit and sender's idle gap
            if (leds[1] !== 0) $fatal(1, "Core fault");
            if (leds[2] !== (count % 2)) $fatal(1, "Activity LED must toggle per completed byte");
        end
    endtask

    initial begin
        #1 switches[9] = 1;
        clocks(5);
        @(negedge clk); switches[9] = 0;
        clocks(20);
        if (leds[0] !== 1 || gpio[0] !== 1) $fatal(1, "Expected enabled/idle after switch reset");
        // Active-low segment masks: C (a,d,e,f), H (b,c,e,f,g),
        // U (b,c,d,e,f), d (b,c,d,e,g); the other two displays are blank.
        if ({hex5,hex4,hex3,hex2,hex1,hex0} !== {7'h7f,7'h7f,7'h46,7'h09,7'h41,7'h21})
            $fatal(1, "Seven-segment display must spell CHUd");
        clocks(6000);
        if (received_count != 0) $fatal(1, "Startup must not transmit");

        // Short contact chatter never reaches the eight-clock debounce window.
        repeat (3) begin
            @(negedge clk); key[3] = 0;
            clocks(2);
            @(negedge clk); key[3] = 1;
            clocks(2);
        end
        clocks(6000);
        if (received_count != 0) $fatal(1, "Bounce must not transmit");

        for (k = 3; k >= 0; k = k - 1) begin
            before_count = received_count;
            @(negedge clk); key[k] = 0;
            await_count(before_count + 1);
            case (k)
                3: if (received[before_count] !== "C") $fatal(1, "KEY3 must send C");
                2: if (received[before_count] !== "H") $fatal(1, "KEY2 must send H");
                1: if (received[before_count] !== "U") $fatal(1, "KEY1 must send U");
                0: if (received[before_count] !== "D") $fatal(1, "KEY0 must send D, not reset");
            endcase
            if (leds[9:6] !== (4'b0001 << k)) $fatal(1, "Last-key indicator mismatch");
            clocks(10000); // hold longer than two UART frames
            if (received_count != before_count + 1) $fatal(1, "Held key repeated");
            @(negedge clk); key[k] = 1;
            clocks(6000);
            if (received_count != before_count + 1) $fatal(1, "Release transmitted a byte");
        end

        // A fresh press after release is a new event.
        @(negedge clk); key[0] = 0;
        await_count(5);
        if (received[4] !== "D") $fatal(1, "Repress must send D again");
        @(negedge clk); key[0] = 1;
        clocks(20);

        // Simultaneous keys must all be retained and sent in priority order.
        @(negedge clk); key = 0;
        await_count(9);
        if ({received[5],received[6],received[7],received[8]} !== "CHUD")
            $fatal(1, "Simultaneous keys must send CHUD");
        clocks(10000);
        if (received_count != 9) $fatal(1, "Held simultaneous keys repeated");
        @(negedge clk); key = 4'hf;
        clocks(6000);
        if (received_count != 9) $fatal(1, "Simultaneous release transmitted");
        @(negedge clk); switches[9] = 1;
        #1;
        if (leds !== 0 || gpio[0] !== 1) $fatal(1, "SW9 reset must clear status and idle TX");
        $display("PASS: CHUD key-down UART, debounce, no held/release repeats, queued presses, LEDs and displays");
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "Key/UART simulation timeout");
    end
endmodule

`default_nettype wire
