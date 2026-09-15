`timescale 1ns/1ps
`default_nettype none

// KEY3=C, KEY2=H, KEY1=U, KEY0=D: one UART byte per debounced key-down.
// SW9=1 resets; SW9=0 runs. GPIO_0[0] is 3.3 V UART TX, 115200 8N1.
module de1_soc_top #(
    parameter integer DEBOUNCE_CYCLES = 500000
) (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    output wire [6:0]  HEX0,
    output wire [6:0]  HEX1,
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3,
    output wire [6:0]  HEX4,
    output wire [6:0]  HEX5,
    inout  wire [35:0] GPIO_0
);
    reg [1:0] reset_sync;
    wire rst_n = reset_sync[1];
    wire [3:0] pressed;
    reg [3:0] pending;
    reg [3:0] selected;
    reg [7:0] character;
    reg [3:0] last_key;
    reg activity_led;
    wire ready;
    wire sent;
    wire fault;
    wire tx;
    wire request = |pending;
    wire accept = request && ready;

    // Reset switch replaces KEY0 so all four keys can transmit characters.
    always @(posedge CLOCK_50 or posedge SW[9]) begin
        if (SW[9]) reset_sync <= 2'b00;
        else       reset_sync <= {reset_sync[0], 1'b1};
    end

    button_events #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) buttons (
        .clk(CLOCK_50), .rst_n(rst_n), .keys_n(KEY), .pressed(pressed)
    );

    // Simultaneous presses are served in KEY3, KEY2, KEY1, KEY0 order.
    always @* begin
        selected = 0;
        character = 0;
        if (pending[3]) begin selected = 4'b1000; character = 8'h43; end
        else if (pending[2]) begin selected = 4'b0100; character = 8'h48; end
        else if (pending[1]) begin selected = 4'b0010; character = 8'h55; end
        else if (pending[0]) begin selected = 4'b0001; character = 8'h44; end
    end

    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            pending      <= 0;
            last_key     <= 0;
            activity_led <= 0;
        end else begin
            // One pending event per key. At the default 10 ms debounce, four
            // queued bytes finish (<0.4 ms) before a key can debounce again.
            pending <= (pending & ~(accept ? selected : 4'b0)) | pressed;
            if (accept) last_key <= selected;
            if (sent) activity_led <= !activity_led;
            if (fault) activity_led <= 0;
        end
    end

    uart_program_sender sender (
        .clk(CLOCK_50), .rst_n(rst_n), .valid(request), .data(character),
        .ready(ready), .tx(tx), .sent(sent), .fault(fault)
    );

    assign GPIO_0[0] = tx;
    assign GPIO_0[35:1] = {35{1'bz}};
    // 0=enabled, 1=fault, 2=toggles per completed byte, 3=busy,
    // 9:6=last accepted key (KEY3..KEY0). 5:4 are unused.
    assign LEDR = {last_key, 2'b0, (rst_n && !ready), activity_led, fault, rst_n};
    // Active-low segments [6:0] = {g,f,e,d,c,b,a}; rightmost four spell CHUd.
    assign HEX3 = 7'b1000110; // C: a,d,e,f
    assign HEX2 = 7'b0001001; // H: b,c,e,f,g
    assign HEX1 = 7'b1000001; // U: b,c,d,e,f
    assign HEX0 = 7'b0100001; // d: b,c,d,e,g (seven-segment form of D)
    assign HEX4 = 7'b1111111;
    assign HEX5 = 7'b1111111;
    wire _unused = &{SW[8:0], 1'b0};
endmodule

`default_nettype wire
