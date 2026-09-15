`timescale 1ns/1ps
`default_nettype none

// Single programmable engine, shared by FPGA and ASIC. See docs/isa.md.
// 64 x 16-bit instructions, eight pins, optional two-context round-robin.
// No fixed UART/SPI/I2C execution blocks. Protocols are uploaded firmware.
module protocol_engine (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       run,
    input  wire       prog_we,
    input  wire [5:0] prog_addr,
    input  wire [15:0] prog_data,
    input  wire [7:0] pin_in,
    output reg  [7:0] pin_out,
    output reg  [7:0] pin_oe,
    output reg        fault,
    output reg  [7:0] sample_data,
    output reg        sample_toggle,
    output wire       stalled
);
    reg [15:0] program_mem [0:63];
    reg [63:0] program_valid;
    reg [5:0] pc [0:1];
    reg [11:0] wait_left [0:1];
    reg [7:0] pin_meta, pin_sync;
    reg [7:0] tx_shift [0:1], rx_shift [0:1], loop_count [0:1];
    reg [5:0] return_pc [0:1];
    reg [1:0] return_valid, waiting_pin;
    reg context_id, dual_active;
    integer c;
    wire [15:0] instruction;

    assign instruction = program_mem[pc[context_id]];
    wire sampled_pin = pin_sync[instruction[2:0]];
    wire shift_bit = instruction[4] ? tx_shift[context_id][7] : tx_shift[context_id][0];
    // Registered per context: a waiting context never blocks its sibling.
    assign stalled = rst_n && run && !fault && (|waiting_pin);

    // Asynchronous protocol pins cross two flip-flops before instructions
    // observe them. Firmware must budget synchronization and sampling latency.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pin_meta <= 0;
            pin_sync <= 0;
        end else begin
            pin_meta <= pin_in;
            pin_sync <= pin_meta;
        end
    end

    // Host must halt the engine before writing its program.
    // Memory bits are not reset. Valid bits prevent executing unwritten words.
    always @(posedge clk) begin
        if (rst_n && prog_we && !run)
            program_mem[prog_addr] <= prog_data;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            program_valid <= 0;
        else if (prog_we && !run)
            program_valid[prog_addr] <= 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (c = 0; c < 2; c = c + 1) begin
                pc[c] <= 0;
                wait_left[c] <= 0;
                tx_shift[c] <= 0;
                rx_shift[c] <= 0;
                loop_count[c] <= 0;
                return_pc[c] <= 0;
            end
            pin_out   <= 0;
            pin_oe    <= 0;
            fault     <= 0;
            return_valid <= 0;
            waiting_pin <= 0;
            context_id <= 0;
            dual_active <= 0;
            sample_data <= 0;
            sample_toggle <= 0;
        end else if (!run) begin
            for (c = 0; c < 2; c = c + 1) begin
                pc[c] <= 0;
                wait_left[c] <= 0;
                tx_shift[c] <= 0;
                rx_shift[c] <= 0;
                loop_count[c] <= 0;
                return_pc[c] <= 0;
            end
            pin_out   <= 0;
            pin_oe    <= 0;
            fault     <= 0;
            return_valid <= 0;
            waiting_pin <= 0;
            context_id <= 0;
            dual_active <= 0;
            // A published result survives HALT so the host can read it.
        end else if (!fault) begin
            // One decoder / execution datapath. Single-context firmware keeps
            // its original cycle timing. After START_CTX, each gets every
            // other clock, even when its sibling is waiting.
            context_id <= dual_active ? !context_id : 1'b0;
            if (wait_left[context_id] != 0) begin
                wait_left[context_id] <= wait_left[context_id] - 1'b1;
            end else if (!program_valid[pc[context_id]]) begin
                fault  <= 1'b1;
                pin_oe <= 0;
            end else begin
                pc[context_id] <= pc[context_id] + 1'b1;
                waiting_pin[context_id] <= 0;
                case (instruction[15:12])
                    4'h1: pin_out   <= instruction[7:0];
                    4'h2: wait_left[context_id] <= instruction[11:0];
                    4'h3: pin_oe    <= instruction[7:0];
                    4'h4: pc[context_id] <= instruction[5:0];
                    4'h5: tx_shift[context_id] <= instruction[7:0];
                    4'h6: begin
                        if (instruction[3]) begin
                            // Open drain: bit 0 drives low, bit 1 releases.
                            pin_out[instruction[2:0]] <= 0;
                            pin_oe[instruction[2:0]] <= !shift_bit;
                        end else pin_out[instruction[2:0]] <= shift_bit;
                        tx_shift[context_id] <= instruction[4] ?
                                    {tx_shift[context_id][6:0], 1'b0} : {1'b0, tx_shift[context_id][7:1]};
                    end
                    4'h7: rx_shift[context_id] <= instruction[4] ?
                                     {rx_shift[context_id][6:0], sampled_pin} :
                                     {sampled_pin, rx_shift[context_id][7:1]};
                    4'h8: loop_count[context_id] <= instruction[7:0];
                    4'h9: begin
                        if (loop_count[context_id] > 1) begin
                            loop_count[context_id] <= loop_count[context_id] - 1'b1;
                            pc[context_id] <= instruction[5:0];
                        end else loop_count[context_id] <= 0;
                    end
                    4'ha: if (sampled_pin != instruction[3]) begin
                        pc[context_id] <= pc[context_id];
                        waiting_pin[context_id] <= 1;
                    end
                    4'hb: if (sampled_pin == instruction[3]) pc[context_id] <= instruction[9:4];
                    4'hc: pin_out[instruction[2:0]] <= instruction[3];
                    4'hd: pin_oe[instruction[2:0]] <= instruction[3];
                    4'he: begin
                        sample_data <= rx_shift[context_id];
                        sample_toggle <= !sample_toggle;
                    end
                    4'hf: begin
                        if (instruction == 16'hf000) rx_shift[context_id] <= 0;
                        else if ((instruction[11:6] == 6'b000100) && !return_valid[context_id]) begin
                            return_pc[context_id] <= pc[context_id] + 1'b1;
                            return_valid[context_id] <= 1;
                            pc[context_id] <= instruction[5:0];
                        end else if ((instruction == 16'hf200) && return_valid[context_id]) begin
                            pc[context_id] <= return_pc[context_id];
                            return_valid[context_id] <= 0;
                        end else if ((instruction[11:6] == 6'b001100) && !dual_active) begin
                            // F300 | address: start context 1 once per RUN.
                            // Other child registers are already zero from HALT.
                            pc[1] <= instruction[5:0];
                            dual_active <= 1;
                            context_id <= 1;
                        end else begin
                            // One return slot, not a silently wrapping stack.
                            fault <= 1;
                            pin_oe <= 0;
                        end
                    end
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
