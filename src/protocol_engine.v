`timescale 1ns/1ps
`default_nettype none

// Single programmable engine, shared by FPGA and ASIC. See docs/isa.md.
// Default: 64 x 16-bit instructions, eight pins, two-context round-robin.
// Experimental FPGA byte-processing profile: docs/isa-extended.md.
// No fixed UART/SPI/I2C execution blocks. Protocols are uploaded firmware.
module protocol_engine #(
    parameter PROGRAM_ADDR_WIDTH = 6,
    parameter EXTENDED_ISA = 0,
    parameter CLOCK_HZ = 50000000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       run,
    input  wire       prog_we,
    input  wire [PROGRAM_ADDR_WIDTH-1:0] prog_addr,
    input  wire [15:0] prog_data,
    input  wire [7:0] pin_in,
    output reg  [7:0] pin_out,
    output reg  [7:0] pin_oe,
    output reg        fault,
    output reg  [7:0] sample_data,
    output reg        sample_toggle,
    output wire       stalled
);
    // Reject unsupported parameter combinations at elaboration in simulation.
    // Valid configurations remove this generate branch during synthesis.
    generate if (PROGRAM_ADDR_WIDTH < 6 || PROGRAM_ADDR_WIDTH > 12 ||
                 CLOCK_HZ < 2000 || CLOCK_HZ % 1000 != 0) begin: invalid_configuration
        initial $error("Unsupported program width or CLOCK_HZ; see docs/isa-extended.md");
    end endgenerate
    // ISA v1.1 encodings. These names describe the firmware interface; changing
    // an encoding or instruction latency requires coordinated firmware changes.
    localparam [3:0]
        OP_SET      = 4'h1,
        OP_WAIT     = 4'h2,
        OP_DIR      = 4'h3,
        OP_JMP      = 4'h4,
        OP_LOAD_TX  = 4'h5,
        OP_OUT      = 4'h6,
        OP_IN       = 4'h7,
        OP_COUNT    = 4'h8,
        OP_LOOP     = 4'h9,
        OP_WAIT_PIN = 4'ha,
        OP_JMP_PIN  = 4'hb,
        OP_SET_PIN  = 4'hc,
        OP_DIR_PIN  = 4'hd,
        OP_CAPTURE  = 4'he,
        OP_SYS      = 4'hf;
    localparam [15:0] SYS_CLEAR_RX = 16'hf000, SYS_RETURN = 16'hf200;
    // SYS address-bearing instructions use bits [5:0] as their target.
    localparam [5:0] SYS_CALL_GROUP = 6'b000100,
                     SYS_START_CTX_GROUP = 6'b001100;

    // Shared instruction store; default 1024 data bits plus validity state.
    // An RTL array is not a hard SRAM macro; generic synthesis maps this to FFs.
    localparam PROGRAM_WORDS = 1 << PROGRAM_ADDR_WIDTH;
    reg [15:0] program_mem [0:PROGRAM_WORDS-1];
    reg [PROGRAM_WORDS-1:0] program_valid;
    // Private state for two hardware threads, not two execution units.
    // context_id selects the only thread that can execute on this clock edge.
    reg [PROGRAM_ADDR_WIDTH-1:0] pc [0:1];
    reg [11:0] wait_left [0:1];
    reg [7:0] pin_meta, pin_sync;
    reg [7:0] tx_shift [0:1], rx_shift [0:1], loop_count [0:1];
    reg [PROGRAM_ADDR_WIDTH-1:0] return_pc [0:1];
    reg [1:0] return_valid, waiting_pin;
    reg context_id, dual_active;
    integer c;
    wire [15:0] instruction;

    // Optional single-context byte-processing extension. No packet IDs,
    // descriptors, endpoints or USB state machine live in this datapath.
    // EXTENDED_ISA=0 constant-folds this state out of the submission design.
    reg [7:0] accumulator, index_reg;
    reg [7:0] scratch [0:255]; // firmware initializes before reading
    reg zero_flag, carry_flag;
    reg [15:0] crc_value, crc_polynomial;
    reg [15:0] crc_seed0, crc_poly0, crc_seed1, crc_poly1;
    reg [7:0] toggle_mask;
    reg [3:0] stuffing_limit, serial_ones, serial_count;
    reg previous_serial_bit, serial_error;
    wire decoded_bit = !(accumulator[0] ^ previous_serial_bit);
    wire insert_bit = (stuffing_limit != 0) && (serial_ones == stuffing_limit);
    wire encoded_bit = insert_bit ? 1'b0 : tx_shift[0][0];
    reg [7:0] tick_period, tick_counter, tick_sample;
    reg tick_active, tick_pending, tick_overrun;
    reg edge_align;
    reg [2:0] edge_pin;
    reg [7:0] previous_pins;
    wire sampling_edge = edge_align && (pin_sync[edge_pin] != previous_pins[edge_pin]);
    localparam MS_DIVIDER_WIDTH = $clog2(CLOCK_HZ / 1000);
    reg [MS_DIVIDER_WIDTH-1:0] millisecond_divider;
    reg [15:0] milliseconds, interval_start, interval_limit;
    wire [15:0] interval_elapsed = milliseconds - interval_start;
    wire interval_due = (interval_limit != 0) && (interval_elapsed >= interval_limit);
    reg [8:0] arithmetic;
    wire [7:0] scratch_index = index_reg + instruction[7:0];
    function [15:0] crc_byte(input [15:0] state, input [15:0] polynomial, input [7:0] value);
        integer bit_index;
        reg [15:0] next_crc;
        begin
            next_crc = state;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                next_crc = (next_crc >> 1) ^ ((next_crc[0] ^ value[bit_index]) ? polynomial : 16'b0);
            crc_byte = next_crc;
        end
    endfunction

    assign instruction = program_mem[pc[context_id]];
    wire sampled_pin = pin_sync[instruction[2:0]];
    wire shift_bit = instruction[4] ? tx_shift[context_id][7] : tx_shift[context_id][0];
    // Registered per context: a waiting context never blocks its sibling.
    assign stalled = rst_n && run && !fault && (|waiting_pin);

    // There is only one internal clock. External protocol pins need not meet
    // its setup/hold times (e.g. UART from the independently clocked Uno).
    // This is asynchronous-input synchronization, not a crossing between the
    // contexts. Both stages run on clk every cycle, even in two-context mode.
    // Independent bit synchronizers do not make an asynchronous bus atomic.
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
            accumulator <= 0; index_reg <= 0; zero_flag <= 0; carry_flag <= 0;
            crc_value <= 0; crc_polynomial <= 0; toggle_mask <= 0;
            crc_seed0 <= 0; crc_poly0 <= 0; crc_seed1 <= 0; crc_poly1 <= 0;
            stuffing_limit <= 0; serial_ones <= 0; serial_count <= 0;
            previous_serial_bit <= 0; serial_error <= 0;
            tick_period <= 0; tick_counter <= 0; tick_sample <= 0;
            tick_active <= 0; tick_pending <= 0; tick_overrun <= 0;
            edge_align <= 0; edge_pin <= 0; previous_pins <= 0;
            millisecond_divider <= 0; milliseconds <= 0; interval_start <= 0; interval_limit <= 0;
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
            accumulator <= 0; index_reg <= 0; zero_flag <= 0; carry_flag <= 0;
            crc_value <= 0; crc_polynomial <= 0; toggle_mask <= 0;
            crc_seed0 <= 0; crc_poly0 <= 0; crc_seed1 <= 0; crc_poly1 <= 0;
            stuffing_limit <= 0; serial_ones <= 0; serial_count <= 0;
            previous_serial_bit <= 0; serial_error <= 0;
            tick_period <= 0; tick_counter <= 0; tick_sample <= 0;
            tick_active <= 0; tick_pending <= 0; tick_overrun <= 0;
            edge_align <= 0; edge_pin <= 0; previous_pins <= 0;
            millisecond_divider <= 0; milliseconds <= 0; interval_start <= 0; interval_limit <= 0;
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
            if (EXTENDED_ISA) begin
                if (millisecond_divider == CLOCK_HZ / 1000 - 1) begin
                    millisecond_divider <= 0;
                    milliseconds <= milliseconds + 1'b1;
                end else millisecond_divider <= millisecond_divider + 1'b1;
                previous_pins <= pin_sync;
                if (tick_active) begin
                    if (sampling_edge) tick_counter <= (tick_period >> 1) - 1'b1;
                    else if (tick_counter == 0) begin
                        tick_counter <= tick_period - 1'b1;
                        tick_sample <= pin_sync;
                        tick_pending <= 1;
                        if (tick_pending) tick_overrun <= 1;
                    end else tick_counter <= tick_counter - 1'b1;
                end
            end
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
                    4'h0: begin
                        if (!EXTENDED_ISA || dual_active) begin fault <= 1; pin_oe <= 0; end
                        else case (instruction[11:8])
                            1: begin accumulator <= instruction[7:0]; zero_flag <= (instruction[7:0] == 0); end
                            2: begin accumulator <= scratch[instruction[7:0]]; zero_flag <= (scratch[instruction[7:0]] == 0); end
                            3: scratch[instruction[7:0]] <= accumulator;
                            4: begin
                                arithmetic = {1'b0, accumulator} + {1'b0, instruction[7:0]};
                                accumulator <= arithmetic[7:0]; carry_flag <= arithmetic[8]; zero_flag <= (arithmetic[7:0] == 0);
                            end
                            5: begin accumulator <= accumulator & instruction[7:0]; zero_flag <= ((accumulator & instruction[7:0]) == 0); end
                            6: begin accumulator <= accumulator ^ instruction[7:0]; zero_flag <= (accumulator == instruction[7:0]); end
                            7: begin accumulator <= accumulator | instruction[7:0]; zero_flag <= ((accumulator | instruction[7:0]) == 0); end
                            8: begin zero_flag <= (accumulator == instruction[7:0]); carry_flag <= (accumulator < instruction[7:0]); end
                            9: index_reg <= instruction[7:0];
                            10: begin accumulator <= scratch[scratch_index]; zero_flag <= (scratch[scratch_index] == 0); end
                            11: scratch[scratch_index] <= accumulator;
                            12: index_reg <= index_reg + instruction[7:0];
                            13: tick_period <= instruction[7:0];
                            14: case (instruction[7:0])
                                'h00: begin accumulator <= pin_sync; zero_flag <= (pin_sync == 0); end
                                'h01: pin_out <= accumulator;
                                'h02: pin_oe <= accumulator;
                                'h03: begin accumulator <= rx_shift[0]; zero_flag <= (rx_shift[0] == 0); end
                                'h04: begin tx_shift[0] <= accumulator; serial_count <= 0; end
                                'h05: index_reg <= accumulator;
                                'h06: begin accumulator <= index_reg; zero_flag <= (index_reg == 0); end
                                'h07: begin accumulator <= ~accumulator; zero_flag <= (&accumulator); end
                                'h08: begin accumulator <= accumulator >> 1; carry_flag <= accumulator[0]; zero_flag <= (accumulator[7:1] == 0); end
                                'h09: begin accumulator <= accumulator << 1; carry_flag <= accumulator[7]; zero_flag <= (accumulator[6:0] == 0); end
                                'h0a: begin serial_count <= 0; rx_shift[0] <= 0; end
                                'h0b: begin
                                    previous_serial_bit <= accumulator[0];
                                    if (insert_bit) begin
                                        serial_ones <= 0;
                                        if (decoded_bit) serial_error <= 1;
                                    end else begin
                                        rx_shift[0] <= {decoded_bit, rx_shift[0][7:1]};
                                        serial_count <= serial_count + 1'b1;
                                        serial_ones <= decoded_bit ? serial_ones + 1'b1 : 0;
                                    end
                                end
                                'h0c: begin
                                    if (!encoded_bit) pin_out <= pin_out ^ toggle_mask;
                                    serial_ones <= encoded_bit ? serial_ones + 1'b1 : 0;
                                    if (!insert_bit) begin
                                        tx_shift[0] <= {1'b0, tx_shift[0][7:1]};
                                        serial_count <= serial_count + 1'b1;
                                    end
                                end
                                'h0e: begin tick_active <= 1; tick_counter <= tick_period - 1'b1; tick_pending <= 0; tick_overrun <= 0; end
                                'h0f: begin
                                    if (!tick_pending) pc[0] <= pc[0];
                                    else begin accumulator <= tick_sample; zero_flag <= (tick_sample == 0); tick_pending <= 0; end
                                end
                                'h10: begin tick_active <= 0; tick_pending <= 0; end
                                'h11: crc_value[7:0] <= accumulator;
                                'h12: crc_value[15:8] <= accumulator;
                                'h13: crc_polynomial[7:0] <= accumulator;
                                'h14: crc_polynomial[15:8] <= accumulator;
                                'h15: crc_value <= crc_byte(crc_value, crc_polynomial, accumulator);
                                'h16: begin accumulator <= crc_value[7:0]; zero_flag <= (crc_value[7:0] == 0); end
                                'h17: begin accumulator <= crc_value[15:8]; zero_flag <= (crc_value[15:8] == 0); end
                                'h18: begin sample_data <= accumulator; sample_toggle <= !sample_toggle; end
                                'h19: begin previous_serial_bit <= accumulator[0]; serial_count <= 0; serial_ones <= 0; serial_error <= 0; end
                                'h1a: begin serial_ones <= 0; serial_count <= 0; serial_error <= 0; end
                                'h1c: begin tick_pending <= 0; tick_overrun <= 0; end
                                'h1d: loop_count[0] <= accumulator;
                                'h1e: begin accumulator <= {4'b0, serial_count}; zero_flag <= (serial_count == 0); end
                                'h20: begin crc_seed0 <= crc_value; crc_poly0 <= crc_polynomial; end
                                'h21: begin crc_seed1 <= crc_value; crc_poly1 <= crc_polynomial; end
                                'h22: begin crc_value <= crc_seed0; crc_polynomial <= crc_poly0; end
                                'h23: begin crc_value <= crc_seed1; crc_polynomial <= crc_poly1; end
                                'h32: interval_limit[7:0] <= accumulator;
                                'h33: interval_limit[15:8] <= accumulator;
                                'h34: interval_start <= milliseconds;
                                default: begin
                                    if (instruction[7:4] == 4'h4) begin
                                        if (instruction[3]) begin
                                            accumulator <= accumulator << instruction[2:0];
                                            zero_flag <= ((accumulator << instruction[2:0]) & 8'hff) == 0;
                                        end else begin
                                            accumulator <= accumulator >> instruction[2:0];
                                            zero_flag <= (accumulator >> instruction[2:0]) == 0;
                                        end
                                    end else begin fault <= 1; pin_oe <= 0; end
                                end
                            endcase
                            15: case (instruction[7:0])
                                0: if (zero_flag) pc[0] <= pc[0] + 2'd2;
                                1: if (!zero_flag) pc[0] <= pc[0] + 2'd2;
                                2: if (carry_flag) pc[0] <= pc[0] + 2'd2;
                                3: if (!carry_flag) pc[0] <= pc[0] + 2'd2;
                                4: if (serial_count == 8) pc[0] <= pc[0] + 2'd2;
                                5: if (serial_count != 8) pc[0] <= pc[0] + 2'd2;
                                6: if (serial_error) pc[0] <= pc[0] + 2'd2;
                                7: if (!serial_error) pc[0] <= pc[0] + 2'd2;
                                8: if (insert_bit) pc[0] <= pc[0] + 2'd2;
                                9: if (!insert_bit) pc[0] <= pc[0] + 2'd2;
                                10: if (tick_overrun) pc[0] <= pc[0] + 2'd2;
                                11: if (!tick_overrun) pc[0] <= pc[0] + 2'd2;
                                12: if (interval_due) pc[0] <= pc[0] + 2'd2;
                                13: if (!interval_due) pc[0] <= pc[0] + 2'd2;
                                default: begin fault <= 1; pin_oe <= 0; end
                            endcase
                            default: begin fault <= 1; pin_oe <= 0; end
                        endcase
                    end
                    OP_SET: pin_out <= instruction[7:0];
                    OP_WAIT: wait_left[context_id] <= instruction[11:0];
                    OP_DIR: pin_oe <= instruction[7:0];
                    OP_JMP: pc[context_id] <= instruction[PROGRAM_ADDR_WIDTH-1:0];
                    OP_LOAD_TX: tx_shift[context_id] <= instruction[7:0];
                    OP_OUT: begin
                        if (instruction[3]) begin
                            // Open drain: bit 0 drives low, bit 1 releases.
                            pin_out[instruction[2:0]] <= 0;
                            pin_oe[instruction[2:0]] <= !shift_bit;
                        end else pin_out[instruction[2:0]] <= shift_bit;
                        tx_shift[context_id] <= instruction[4] ?
                                    {tx_shift[context_id][6:0], 1'b0} : {1'b0, tx_shift[context_id][7:1]};
                    end
                    OP_IN: rx_shift[context_id] <= instruction[4] ?
                                     {rx_shift[context_id][6:0], sampled_pin} :
                                     {sampled_pin, rx_shift[context_id][7:1]};
                    OP_COUNT: loop_count[context_id] <= instruction[7:0];
                    OP_LOOP: begin
                        if (loop_count[context_id] > 1) begin
                            loop_count[context_id] <= loop_count[context_id] - 1'b1;
                            pc[context_id] <= instruction[PROGRAM_ADDR_WIDTH-1:0];
                        end else loop_count[context_id] <= 0;
                    end
                    OP_WAIT_PIN: if (sampled_pin != instruction[3]) begin
                        pc[context_id] <= pc[context_id];
                        waiting_pin[context_id] <= 1;
                    end
                    OP_JMP_PIN: if (sampled_pin == instruction[3]) pc[context_id] <= instruction[9:4];
                    OP_SET_PIN: pin_out[instruction[2:0]] <= instruction[3];
                    OP_DIR_PIN: pin_oe[instruction[2:0]] <= instruction[3];
                    OP_CAPTURE: begin
                        sample_data <= rx_shift[context_id];
                        sample_toggle <= !sample_toggle;
                    end
                    OP_SYS: begin
                        if (EXTENDED_ISA && !dual_active && (instruction[11:10] == 2'b01) && !return_valid[0]) begin
                            return_pc[0] <= pc[0] + 1'b1; return_valid[0] <= 1;
                            pc[0] <= instruction[9:0];
                        end else if (EXTENDED_ISA && !dual_active && (instruction[11:8] >= 8)) begin
                            case (instruction[11:8])
                                8: begin accumulator <= accumulator ^ scratch[instruction[7:0]]; zero_flag <= (accumulator == scratch[instruction[7:0]]); end
                                9: begin
                                    arithmetic = {1'b0, accumulator} + {1'b0, scratch[instruction[7:0]]};
                                    accumulator <= arithmetic[7:0]; carry_flag <= arithmetic[8]; zero_flag <= (arithmetic[7:0] == 0);
                                end
                                10: begin zero_flag <= (accumulator == scratch[instruction[7:0]]); carry_flag <= (accumulator < scratch[instruction[7:0]]); end
                                11: toggle_mask <= instruction[7:0];
                                12: stuffing_limit <= {1'b0, instruction[2:0]};
                                13: begin edge_align <= instruction[7]; edge_pin <= instruction[2:0]; end
                                14: begin
                                    // Indexed byte copy with a running programmable CRC.
                                    // Useful for any checked serial packet, not USB-specific.
                                    scratch[instruction[7:0]] <= scratch[index_reg];
                                    accumulator <= scratch[index_reg];
                                    crc_value <= crc_byte(crc_value, crc_polynomial, scratch[index_reg]);
                                    index_reg <= index_reg + 1'b1;
                                end
                                default: begin fault <= 1; pin_oe <= 0; end
                            endcase
                        end else if (instruction == SYS_CLEAR_RX) rx_shift[context_id] <= 0;
                        else if ((instruction[11:6] == SYS_CALL_GROUP) && !return_valid[context_id]) begin
                            return_pc[context_id] <= pc[context_id] + 1'b1;
                            return_valid[context_id] <= 1;
                            pc[context_id] <= instruction[5:0];
                        end else if ((instruction == SYS_RETURN) && return_valid[context_id]) begin
                            pc[context_id] <= return_pc[context_id];
                            return_valid[context_id] <= 0;
                        end else if ((instruction[11:6] == SYS_START_CTX_GROUP) && !dual_active) begin
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
