`timescale 1ns/1ps
`default_nettype none

// Minimal programmable pin engine: 32 instructions, 8 I/O pins.
// Instruction: [15:12] opcode, [11:0] operand.
// 1 = SET outputs, 2 = WAIT cycles, 3 = DIR output enables,
// 4 = JMP absolute address. Other opcodes halt and raise fault.
// SET, DIR and JMP take one clock. WAIT N takes N+1 clocks.
module protocol_engine (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       run,
    input  wire       prog_we,
    input  wire [4:0] prog_addr,
    input  wire [15:0] prog_data,
    output reg  [7:0] pin_out,
    output reg  [7:0] pin_oe,
    output reg        fault
);
    reg [15:0] program_mem [0:31];
    reg [4:0] pc;
    reg [11:0] wait_left;
    wire [15:0] instruction;

    assign instruction = program_mem[pc];

    // Host must halt the engine before writing its program.
    // Memory is deliberately not initialized or reset: load before run.
    always @(posedge clk) begin
        if (rst_n && prog_we && !run)
            program_mem[prog_addr] <= prog_data;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc        <= 0;
            wait_left <= 0;
            pin_out   <= 0;
            pin_oe    <= 0;
            fault     <= 0;
        end else if (!run) begin
            pc        <= 0;
            wait_left <= 0;
            pin_out   <= 0;
            pin_oe    <= 0;
            fault     <= 0;
        end else if (!fault) begin
            if (wait_left != 0) begin
                wait_left <= wait_left - 1'b1;
            end else begin
                pc <= pc + 1'b1;
                case (instruction[15:12])
                    4'h1: pin_out   <= instruction[7:0];
                    4'h2: wait_left <= instruction[11:0];
                    4'h3: pin_oe    <= instruction[7:0];
                    4'h4: pc        <= instruction[4:0];
                    default: begin
                        fault  <= 1'b1;
                        pin_oe <= 0;
                    end
                endcase
            end
        end
    end
endmodule

`default_nettype wire
