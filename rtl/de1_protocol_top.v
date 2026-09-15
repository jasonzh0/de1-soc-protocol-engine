`timescale 1ns/1ps
`default_nettype none

// DE1-SoC H1 adapter for the actual shared protocol engine.
// Set SW1:0 while SW9=1; SW2 selects I2C read or slow duplex UART.
// Lower SW9 to load/run. SW2 is ignored for standalone RX and SPI.
module de1_protocol_top (
    input wire CLOCK_50,
    input wire [3:0] KEY,
    input wire [9:0] SW,
    output wire [9:0] LEDR,
    output wire [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout wire [35:0] GPIO_0
);
    reg [1:0] reset_sync;
    wire rst_n = reset_sync[1];
    reg [2:0] mode_meta, mode_sync;
    wire [2:0] selected_mode;
    wire run, prog_we, fault, sample_toggle, stalled;
    wire [5:0] prog_addr;
    wire [15:0] prog_data;
    wire [7:0] pin_out, pin_oe, sample_data;
    wire drive = rst_n && run && !fault;
    reg [25:0] heartbeat;

    always @(posedge CLOCK_50 or posedge SW[9]) begin
        if (SW[9]) reset_sync <= 0;
        else reset_sync <= {reset_sync[0], 1'b1};
    end
    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            mode_meta <= 0;
            mode_sync <= 0;
            heartbeat <= 0;
        end else begin
            mode_meta <= SW[2:0];
            mode_sync <= mode_meta;
            if (run && !fault) heartbeat <= heartbeat + 1'b1;
            else heartbeat <= 0;
        end
    end

    firmware_bootloader boot (
        .clk(CLOCK_50), .rst_n(rst_n), .mode(mode_sync),
        .selected_mode(selected_mode), .run(run), .prog_we(prog_we),
        .prog_addr(prog_addr), .prog_data(prog_data)
    );
    protocol_engine engine (
        .clk(CLOCK_50), .rst_n(rst_n), .run(run),
        .prog_we(prog_we), .prog_addr(prog_addr), .prog_data(prog_data),
        .pin_in(GPIO_0[7:0]), .pin_out(pin_out), .pin_oe(pin_oe), .fault(fault),
        .sample_data(sample_data), .sample_toggle(sample_toggle), .stalled(stalled)
    );
    genvar p;
    generate for (p = 0; p < 8; p = p + 1) begin: gpio_buffer
        assign GPIO_0[p] = (drive && pin_oe[p]) ? pin_out[p] : 1'bz;
    end endgenerate
    assign GPIO_0[35:8] = {28{1'bz}};
    // LED9 heartbeat toggles every ~0.67 s, including firmware idle loops.
    // It proves clocks/run, not successful external communication.
    assign LEDR = {heartbeat[25], 2'b0, selected_mode, stalled,
                   sample_toggle, fault, (run && !fault)};

    function [6:0] hex_digit(input [3:0] value);
        begin
            case (value)
                0: hex_digit = 7'h40; 1: hex_digit = 7'h79;
                2: hex_digit = 7'h24; 3: hex_digit = 7'h30;
                4: hex_digit = 7'h19; 5: hex_digit = 7'h12;
                6: hex_digit = 7'h02; 7: hex_digit = 7'h78;
                8: hex_digit = 7'h00; 9: hex_digit = 7'h10;
                10: hex_digit = 7'h08; 11: hex_digit = 7'h03;
                12: hex_digit = 7'h46; 13: hex_digit = 7'h21;
                14: hex_digit = 7'h06; 15: hex_digit = 7'h0e;
            endcase
        end
    endfunction
    assign HEX0 = hex_digit(sample_data[3:0]);
    assign HEX1 = hex_digit(sample_data[7:4]);
    assign HEX2 = 7'h7f;
    assign HEX3 = 7'h7f;
    assign HEX4 = 7'h7f;
    assign HEX5 = hex_digit({1'b0, selected_mode});
    wire _unused = &{KEY, SW[8:3], 1'b0};
endmodule
`default_nettype wire
