`timescale 1ns/1ps
`default_nettype none

// Internal instruction-store seam. Addresses count 16-bit instructions.
// BACKEND 0: legacy asynchronous registers + validity bitmap.
// BACKEND 1: synchronous packed RAM (FPGA inference / cycle-accurate model).
// BACKEND 2: explicit IHP 1024x32 SRAM, ADDR_WIDTH must be 11.
// Synchronous backends scrub to invalid opcode 0000 after reset. Writes during
// scrub are ignored; the caller MUST wait for ready. HALT does not scrub.
module program_store #(
    parameter ADDR_WIDTH = 6,
    parameter BACKEND = 0
) (
    input wire clk, rst_n,
    input wire write_en,
    input wire [ADDR_WIDTH-1:0] write_addr,
    input wire [15:0] write_data,
    input wire read_en,
    input wire [ADDR_WIDTH-1:0] read_addr,
    output wire [15:0] read_data,
    output wire read_valid,
    output wire ready
);
    generate if (BACKEND < 0 || BACKEND > 2 || ADDR_WIDTH < 6 || ADDR_WIDTH > 12 ||
                 (BACKEND == 2 && ADDR_WIDTH != 11)) begin: invalid_configuration
        initial $error("Unsupported program_store configuration");
    end endgenerate
    generate if (BACKEND == 0) begin: legacy
        reg [15:0] words [0:(1<<ADDR_WIDTH)-1];
        reg [(1<<ADDR_WIDTH)-1:0] valid;
        always @(posedge clk) if (rst_n && write_en) words[write_addr] <= write_data;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) valid <= 0;
            else if (write_en) valid[write_addr] <= 1;
        end
        assign read_data = words[read_addr];
        assign read_valid = valid[read_addr];
        assign ready = rst_n;
    end else begin: clocked
        reg initialized;
        reg [ADDR_WIDTH-2:0] clear_addr;
        reg read_half;
        wire clearing = !initialized;
        wire enabled = rst_n && (clearing || write_en || read_en);
        wire writing = clearing || write_en;
        wire [ADDR_WIDTH-2:0] address = clearing ? clear_addr :
                                    write_en ? write_addr[ADDR_WIDTH-1:1] : read_addr[ADDR_WIDTH-1:1];
        wire [31:0] data_in = clearing ? 32'b0 : {write_data, write_data};
        wire [31:0] bit_mask = clearing ? 32'hffffffff :
                                    write_addr[0] ? 32'hffff0000 : 32'h0000ffff;
        wire [31:0] data_out;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin initialized <= 0; clear_addr <= 0; read_half <= 0; end
            else begin
                if (clearing) begin
                    if (&clear_addr) initialized <= 1;
                    else clear_addr <= clear_addr + 1'b1;
                end
                if (initialized && read_en && !write_en) read_half <= read_addr[0];
            end
        end
        if (BACKEND == 1) begin: inferred
            reg [31:0] words [0:(1<<(ADDR_WIDTH-1))-1];
            reg [31:0] output_word;
            // Registered read, no memory reset, and two half-word write enables.
            // The scrubber uses this same normal RAM port, not resettable cells.
            always @(posedge clk) if (enabled) begin
                if (writing) begin
                    if (bit_mask[0]) words[address][15:0] <= data_in[15:0];
                    if (bit_mask[16]) words[address][31:16] <= data_in[31:16];
                end else output_word <= words[address];
            end
            assign data_out = output_word;
        end else begin: ihp
            // Physical power pins are connected by the ASIC PDN flow. Provide
            // the pinned Liberty/LEF/GDS and official Verilog models externally.
            RM_IHPSG13_1P_1024x32_c2_bm_bist ram (
                .A_CLK(clk), .A_MEN(enabled), .A_WEN(writing), .A_REN(!writing),
                .A_ADDR(address), .A_DIN(data_in), .A_DOUT(data_out), .A_BM(bit_mask), .A_DLY(1'b1),
                .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0),
                .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR(10'b0),
                .A_BIST_DIN(32'b0), .A_BIST_BM(32'b0)
            );
        end
        assign read_data = read_half ? data_out[31:16] : data_out[15:0];
        // Zero-cleared instructions are invalid in both legacy and extended ISAs.
        // The core separately primes a read before executing after every RUN.
        assign read_valid = initialized;
        assign ready = rst_n && initialized;
    end endgenerate
endmodule
`default_nettype wire
