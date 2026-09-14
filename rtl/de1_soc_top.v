`timescale 1ns/1ps
`default_nettype none

// DE1-SoC demo: repeatedly transmit UART 0x55, 115200 baud, 8N1.
// Use the board's 50 MHz clock. KEY[0] is active-low reset.
// GPIO_0[0] is TX; GPIO_0[0] means signal index, NOT header pin 0.
module de1_soc_top (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,
    output wire [9:0]  LEDR,
    inout  wire [35:0] GPIO_0
);
    reg [1:0] reset_sync;
    wire rst_n;
    reg [4:0] load_addr;
    reg loaded;
    reg [15:0] load_data;
    wire [7:0] pin_out;
    wire [7:0] pin_oe;
    wire fault;

    // Asynchronous reset assertion, synchronous release.
    always @(posedge CLOCK_50 or negedge KEY[0]) begin
        if (!KEY[0]) reset_sync <= 2'b00;
        else         reset_sync <= {reset_sync[0], 1'b1};
    end
    assign rst_n = reset_sync[1];

    // Board-only demo loader. A future UART/SPI host can replace this.
    // 0: DIR 1
    // 1..20: ten alternating SET / WAIT pairs (start, data, stop).
    // 21: JMP 1
    always @* begin
        if (load_addr == 0)
            load_data = 16'h3001;
        else if (load_addr == 21)
            load_data = 16'h4001;
        else if (load_addr[0])
            load_data = {4'h1, 11'b0, load_addr[1]};
        else
            load_data = 16'h21b0; // WAIT 432; SET+WAIT gives 434 clocks.
    end

    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            load_addr <= 0;
            loaded    <= 0;
        end else if (!loaded) begin
            if (load_addr == 21) loaded <= 1;
            else load_addr <= load_addr + 1'b1;
        end
    end

    protocol_engine engine (
        .clk(CLOCK_50), .rst_n(rst_n), .run(loaded),
        .prog_we(!loaded), .prog_addr(load_addr), .prog_data(load_data),
        .pin_out(pin_out), .pin_oe(pin_oe), .fault(fault)
    );

    // Hold UART idle high during loading; release pins if the core faults.
    assign GPIO_0[0] = fault ? 1'bz : (pin_oe[0] ? pin_out[0] : 1'b1);
    assign GPIO_0[35:1] = {35{1'bz}};
    assign LEDR = {8'b0, fault, loaded};
endmodule

`default_nettype wire
