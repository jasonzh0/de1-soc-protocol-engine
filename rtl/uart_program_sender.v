`timescale 1ns/1ps
`default_nettype none

// One-byte UART adapter using the SAME portable instruction engine as the ASIC.
// Accept data on valid && ready; pulse sent after one complete 8N1 frame.
// All signals are synchronous to clk. 50 MHz / 434 = about 115200 baud.
module uart_program_sender (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       valid,
    input  wire [7:0] data,
    output wire       ready,
    output wire       tx,
    output reg        sent,
    output reg        fault
);
    localparam IDLE = 2'd0, LOAD = 2'd1, EXECUTE = 2'd2, FAILED = 2'd3;
    localparam integer BIT_CYCLES = 434;
    // Two setup instructions + 10 bit times. An 11-bit execution window
    // includes the complete stop bit and an idle-high gap before another byte.
    localparam integer RUN_CYCLES = 11 * BIT_CYCLES;
    reg [1:0] state;
    reg [7:0] byte_data;
    reg [4:0] load_addr;
    reg [15:0] load_data;
    reg [12:0] run_count;
    wire [7:0] pin_out;
    wire [7:0] pin_oe;
    wire core_fault;

    // 0: SET idle high; 1: DIR TX; 2..21: SET/WAIT for start, 8 data, stop.
    // 22: JMP 22 (idle high). Core timing is 1 cycle/SET and 433/WAIT 432.
    always @* begin
        if (load_addr == 0)      load_data = 16'h1001;
        else if (load_addr == 1) load_data = 16'h3001;
        else if (load_addr == 22) load_data = 16'h4016;
        else if (load_addr[0])  load_data = 16'h21b0;
        else if (load_addr == 2) load_data = 16'h1000;
        else if (load_addr == 20) load_data = 16'h1001;
        else load_data = {4'h1, 11'b0, byte_data[(load_addr - 4) >> 1]};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            byte_data <= 0;
            load_addr <= 0;
            run_count <= 0;
            sent      <= 0;
            fault     <= 0;
        end else begin
            sent <= 0;
            case (state)
                IDLE: if (valid) begin
                    byte_data <= data;
                    load_addr <= 0;
                    state <= LOAD;
                end
                LOAD: begin
                    if (load_addr == 22) begin
                        run_count <= 0;
                        state <= EXECUTE;
                    end else load_addr <= load_addr + 1'b1;
                end
                EXECUTE: begin
                    if (core_fault) begin
                        fault <= 1;
                        state <= FAILED;
                    end else if (run_count == RUN_CYCLES - 1) begin
                        state <= IDLE;
                        sent <= 1;
                    end else run_count <= run_count + 1'b1;
                end
                default: state <= FAILED;
            endcase
        end
    end

    protocol_engine engine (
        .clk(clk), .rst_n(rst_n), .run(state == EXECUTE),
        .prog_we(state == LOAD), .prog_addr(load_addr), .prog_data(load_data),
        .pin_out(pin_out), .pin_oe(pin_oe), .fault(core_fault)
    );
    assign ready = (state == IDLE) && rst_n;
    assign tx = ((state == EXECUTE) && pin_oe[0] && !fault) ? pin_out[0] : 1'b1;
endmodule

`default_nettype wire
