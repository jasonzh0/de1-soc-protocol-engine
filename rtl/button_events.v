`timescale 1ns/1ps
`default_nettype none

// One event per debounced active-low press, never on release or while held.
module button_events #(
    parameter integer DEBOUNCE_CYCLES = 500000 // 10 ms at 50 MHz; must be >= 1
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [3:0] keys_n,
    output reg  [3:0] pressed
);
    localparam integer COUNT_WIDTH =
        (DEBOUNCE_CYCLES > 1) ? $clog2(DEBOUNCE_CYCLES) : 1;
    localparam [COUNT_WIDTH-1:0] LAST = DEBOUNCE_CYCLES - 1;
    reg [3:0] key_meta;
    reg [3:0] key_sync;
    reg [3:0] stable_keys;
    reg [COUNT_WIDTH-1:0] count [0:3];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_meta    <= 4'hf;
            key_sync    <= 4'hf;
            stable_keys <= 4'hf;
            pressed     <= 0;
            for (i = 0; i < 4; i = i + 1) count[i] <= 0;
        end else begin
            key_meta <= keys_n;
            key_sync <= key_meta;
            pressed <= 0;
            for (i = 0; i < 4; i = i + 1) begin
                if (key_sync[i] == stable_keys[i]) begin
                    count[i] <= 0;
                end else if (count[i] == LAST) begin
                    stable_keys[i] <= key_sync[i];
                    count[i] <= 0;
                    if (!key_sync[i]) pressed[i] <= 1;
                end else count[i] <= count[i] + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
