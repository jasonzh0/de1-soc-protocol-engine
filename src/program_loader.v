`timescale 1ns/1ps
`default_nettype none

// Synchronous host command interpreter. Each command_valid clock accepts one
// command. A transport adapter creates these pulses; this module knows no pads.
// Outputs connect directly to the protocol_engine programming interface.
module program_loader #(
    parameter PROGRAM_ADDR_WIDTH = 6
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,
    input  wire       command_valid,
    input  wire       program_ready,
    input  wire [2:0] command,
    input  wire [3:0] data,
    output reg        run,
    output wire       prog_we,
    output reg  [PROGRAM_ADDR_WIDTH-1:0] prog_addr,
    output reg [15:0] prog_data,
    output wire       word_ready,
    output reg        error
);
    generate if (PROGRAM_ADDR_WIDTH < 6 || PROGRAM_ADDR_WIDTH > 12) begin: invalid_configuration
        initial $error("program_loader supports 6..12 address bits");
    end endgenerate
    localparam HALT = 3'd0, ADDR_LO = 3'd1, ADDR_HI = 3'd2,
               DATA = 3'd3, WRITE = 3'd4, RUN = 3'd5, ADDR_BANK = 3'd7;
    reg [2:0] nibble_count;

    assign word_ready = (nibble_count == 4);
    // The core samples the current address/data on the WRITE command edge,
    // before this module increments the address and clears word_ready.
    assign prog_we = rst_n && enable && command_valid &&
                     (command == WRITE) && !run && word_ready && program_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run          <= 0;
            error        <= 0;
            prog_addr    <= 0;
            prog_data    <= 0;
            nibble_count <= 0;
        end else if (!enable) begin
            run          <= 0;
            error        <= 0;
            prog_addr    <= 0;
            prog_data    <= 0;
            nibble_count <= 0;
        end else if (command_valid) begin
            if (command == HALT) begin
                run          <= 0;
                error        <= 0;
                prog_addr    <= 0;
                prog_data    <= 0;
                nibble_count <= 0;
            end else if (run) begin
                // Includes the faulted state: HALT before reprogramming.
                error <= 1;
            end else begin
                case (command)
                    ADDR_LO: prog_addr[3:0] <= data;
                    ADDR_HI: begin
                        if (data < (1 << (PROGRAM_ADDR_WIDTH > 8 ? 4 : PROGRAM_ADDR_WIDTH-4)))
                            prog_addr <= (prog_addr & ~12'h0f0) | ({{8{1'b0}}, data} << 4);
                        else error <= 1;
                    end
                    ADDR_BANK: begin
                        if (PROGRAM_ADDR_WIDTH > 8 && data < (1 << (PROGRAM_ADDR_WIDTH-8)))
                            prog_addr <= (prog_addr & 12'h0ff) | ({{8{1'b0}}, data} << 8);
                        else error <= 1;
                    end
                    DATA: begin
                        if (nibble_count < 4) begin
                            prog_data <= {prog_data[11:0], data};
                            nibble_count <= nibble_count + 1'b1;
                        end else error <= 1;
                    end
                    WRITE: begin
                        if (word_ready && program_ready) begin
                            prog_addr <= prog_addr + 1'b1;
                            nibble_count <= 0;
                        end else error <= 1;
                    end
                    RUN: begin
                        if ((nibble_count == 0) && !error && program_ready) run <= 1;
                        else error <= 1;
                    end
                    default: error <= 1;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
