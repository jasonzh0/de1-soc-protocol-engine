`timescale 1ns/1ps
`default_nettype none

// Tests use only the chip's public pins: no private memory/register accesses.
module tb_tiny_tapeout;
    reg clk = 0;
    reg rst_n = 1;
    reg ena = 1;
    reg [7:0] ui = 0;
    wire [7:0] status;
    wire [7:0] pin_out;
    wire [7:0] pin_oe;
    tri [7:0] pads;
    genvar pin;
    generate for (pin = 0; pin < 8; pin = pin + 1) begin: pad_model
        assign pads[pin] = pin_oe[pin] ? pin_out[pin] : 1'bz;
    end endgenerate
    pullup (pads[0]);

    always #10 clk = !clk;
    tt_um_jasonzh0_protocol_engine dut (
        .clk(clk), .rst_n(rst_n), .ena(ena), .ui_in(ui), .uo_out(status),
        .uio_in(pads), .uio_out(pin_out), .uio_oe(pin_oe)
    );

    task clocks;
        input integer count;
        begin repeat (count) begin @(posedge clk); #1; end end
    endtask

    task reset_chip;
        begin
            @(negedge clk); rst_n = 0; ui = 0; ena = 1;
            #1;
            if (pin_oe !== 0) $fatal(1, "Reset must immediately release pins");
            clocks(2);
            @(negedge clk); rst_n = 1;
            clocks(2);
            if (status !== 0) $fatal(1, "Reset status is not zero");
        end
    endtask

    task command;
        input [2:0] op;
        input [3:0] data;
        input integer high_clocks;
        reg previous_ack;
        integer i;
        begin
            @(negedge clk); ui = {1'b0, op, data};
            clocks(1);
            previous_ack = status[4];
            @(negedge clk); ui = {1'b1, op, data};
            for (i = 0; i < high_clocks; i = i + 1) begin
                clocks(1);
                if (status[4] !== !previous_ack)
                    $fatal(1, "Command must acknowledge exactly once per strobe");
            end
            @(negedge clk); ui = {1'b0, op, data};
            clocks(1);
        end
    endtask

    task set_address;
        input [5:0] address;
        begin
            command(2, {2'b0, address[5:4]}, 1);
            command(1, address[3:0], 1);
        end
    endtask

    task write_word;
        input [15:0] word;
        begin
            command(3, word[15:12], 1);
            command(3, word[11:8], 1);
            command(3, word[7:4], 1);
            command(3, word[3:0], 1);
            if (status[3] !== 1) $fatal(1, "Four nibbles must form a ready word");
            command(4, 0, 1);
            if (status[3] !== 0) $fatal(1, "WRITE must consume the staged word");
        end
    endtask

    task check_fault;
        begin
            clocks(8);
            if (status[1:0] !== 2'b10 || pin_oe !== 0)
                $fatal(1, "Fault must latch, stop status, and release pins");
        end
    endtask

    task halt;
        begin
            command(0, 0, 1);
            clocks(2);
            if (status[3:0] !== 0 || pin_oe !== 0)
                $fatal(1, "HALT must clear run/fault/error/partial data and release pins");
        end
    endtask

    task receive_uart;
        input [7:0] expected;
        integer bit_index;
        reg [7:0] received;
        begin
            @(negedge pads[0]);
            #4340;
            if (pads[0] !== 0) $fatal(1, "Bad start bit");
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                #8680;
                received[bit_index] = pads[0];
            end
            #8680;
            if (pads[0] !== 1 || pin_oe !== 8'h01)
                $fatal(1, "Bad stop bit or output direction");
            if (received !== expected)
                $fatal(1, "UART expected %h got %h", expected, received);
        end
    endtask

    integer i;
    initial begin
        reset_chip;
        // No dependence on simulator/FPGA power-up memory values.
        command(5, 0, 1);
        check_fault;
        halt;

        // Partial words, invalid commands, and invalid high addresses fail.
        command(3, 1, 1);
        command(4, 0, 1);
        if (status[2] !== 1) $fatal(1, "Partial WRITE must fail");
        command(5, 0, 1);
        if (status[0] !== 0) $fatal(1, "RUN must reject pending data/error");
        halt;
        command(2, 4, 1);
        if (status[2] !== 1) $fatal(1, "Out-of-range address must fail");
        halt;
        command(7, 0, 1);
        if (status[2] !== 1) $fatal(1, "Reserved command must fail");
        halt;

        // Held strobe is one DATA command; a fifth nibble is rejected.
        command(3, 1, 4);
        command(3, 0, 1);
        command(3, 10, 1);
        command(3, 5, 1);
        if (status[3:2] !== 2'b10) $fatal(1, "Expected exactly four staged nibbles");
        command(3, 0, 1);
        if (status[2] !== 1) $fatal(1, "Fifth nibble must fail");
        halt;

        // Write 63, auto-increment/wrap to 0; execute both address ranges.
        set_address(63);
        write_word(16'h10a5); // address 63: SET A5
        write_word(16'h30ff); // address 0: DIR FF
        set_address(1);
        write_word(16'h403f); // address 1: JMP 63 (then PC wraps back to 0)
        command(5, 0, 1);
        clocks(10);
        if (pads !== 8'ha5 || pin_oe !== 8'hff || status[2:0] !== 3'b001)
            $fatal(1, "Address high bit/wrap or program execution failed");

        // A write attempt while running cannot change the program/output.
        command(4, 0, 1);
        if (status[2:0] !== 3'b101 || pads !== 8'ha5)
            $fatal(1, "Running writes must be rejected without stopping execution");
        halt;
        command(5, 0, 1);
        clocks(10);
        if (pads !== 8'ha5) $fatal(1, "HALT must preserve program memory");

        // Deselect releases pads immediately, ignores commands, and halts.
        @(negedge clk); ena = 0; ui = 8'hd0;
        #1;
        if (pin_oe !== 0 || status !== 0) $fatal(1, "Disabled pad gating failed");
        clocks(3);
        @(negedge clk); ui = 0; ena = 1;
        clocks(3);
        if (status[3:0] !== 0 || pin_oe !== 0) $fatal(1, "Reselect must stay halted");
        command(5, 0, 1);
        clocks(10);
        if (pads !== 8'ha5) $fatal(1, "Deselection must preserve program memory");

        // Reset invalidates a previously loaded program; no stale execution.
        reset_chip;
        command(5, 0, 1);
        check_fault;
        halt;
        write_word(16'h3010);
        write_word(16'h0000); // explicit invalid opcode after enabling a pin
        command(5, 0, 1);
        check_fault;
        halt;

        // DIR mask controls individual pads; released pins remain high-Z.
        write_word(16'h10a5);
        write_word(16'h30f0);
        write_word(16'h4002);
        command(5, 0, 1);
        clocks(8);
        if (pin_oe !== 8'hf0 || pads[7:4] !== 4'ha || pads[3:1] !== 3'bzzz)
            $fatal(1, "Per-pin output enable mapping failed");
        halt;

        // Load and decode a full UART program through the TT host pins.
        write_word(16'h1001); // idle value before driving
        write_word(16'h3001); // DIR TX
        write_word(16'h2008); // initial idle delay
        for (i = 0; i < 10; i = i + 1) begin
            if ((i % 2) == 0) write_word(16'h1000);
            else              write_word(16'h1001);
            write_word(16'h21b0); // 432 extra clocks, 434 total per bit
        end
        write_word(16'h4003);
        command(5, 0, 1);
        receive_uart(8'h55);
        receive_uart(8'h55);
        receive_uart(8'h55);
        if (status[2:0] !== 3'b001) $fatal(1, "UART run faulted");
        halt;

        // Program replacement through the same pins: emit 0xAA next.
        write_word(16'h1001);
        write_word(16'h3001);
        write_word(16'h2008);
        for (i = 0; i < 10; i = i + 1) begin
            if (i == 0)       write_word(16'h1000);
            else if (i == 9)  write_word(16'h1001);
            else if (i % 2)   write_word(16'h1000);
            else              write_word(16'h1001);
            write_word(16'h21b0);
        end
        write_word(16'h4003);
        command(5, 0, 1);
        receive_uart(8'haa);
        receive_uart(8'haa);
        $display("PASS: TT loading, commands, faults, reset, enable, pins, and UART reprogramming");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "Tiny Tapeout test timeout");
    end
endmodule

`default_nettype wire
