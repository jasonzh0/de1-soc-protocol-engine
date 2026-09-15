`timescale 1ns/1ps
`default_nettype none

// Tiny Tapeout digital interface. All host signals are synchronous to clk.
// ui_in = {strobe, command[2:0], data[3:0]}.
// A sampled low-to-high strobe transition executes exactly one command.
// Command 0 HALT, 1 ADDR_LO, 2 ADDR_HI, 3 DATA, 4 WRITE, 5 RUN,
// 6 READ_SELECT (0=status, 1=last captured byte); 7 invalid.
module tt_um_jasonzh0_protocol_engine (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    reg strobe_prev;
    reg ack;
    reg read_sample;
    reg read_error;
    wire running;
    wire loader_error;
    wire [5:0] write_addr;
    wire [15:0] write_word;
    wire word_ready;
    wire write_accept;
    wire command_event = ena && ui_in[7] && !strobe_prev;
    wire core_run = ena && running;
    wire [7:0] pin_out;
    wire [7:0] pin_oe;
    wire core_fault;
    wire [7:0] sample_data;
    wire sample_toggle;
    wire stalled;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            strobe_prev <= 0;
            ack         <= 0;
            read_sample <= 0;
            read_error  <= 0;
        end else if (!ena) begin
            // Deselecting the wrapper halts it and clears loader state.
            // Program memory is retained; reselecting never auto-starts it.
            strobe_prev <= 0;
            ack         <= 0;
            read_sample <= 0;
            read_error  <= 0;
        end else begin
            strobe_prev <= ui_in[7];
            if (command_event) begin
                ack <= !ack;
                if (ui_in[6:4] == 0) begin
                    read_sample <= 0;
                    read_error <= 0;
                end else if (ui_in[6:4] == 6) begin
                    if (ui_in[3:0] <= 1) read_sample <= ui_in[0];
                    else read_error <= 1;
                end
            end
        end
    end

    program_loader loader (
        .clk(clk), .rst_n(rst_n), .enable(ena),
        .command_valid(command_event && (ui_in[6:4] != 6)),
        .command(ui_in[6:4]), .data(ui_in[3:0]),
        .run(running), .prog_we(write_accept), .prog_addr(write_addr),
        .prog_data(write_word), .word_ready(word_ready), .error(loader_error)
    );

    protocol_engine core (
        .clk(clk), .rst_n(rst_n), .run(core_run),
        .prog_we(write_accept), .prog_addr(write_addr), .prog_data(write_word),
        .pin_in(uio_in), .pin_out(pin_out), .pin_oe(pin_oe), .fault(core_fault),
        .sample_data(sample_data), .sample_toggle(sample_toggle), .stalled(stalled)
    );

    // Bidirectional pad cells / FPGA I/O buffers implement the actual tri-state.
    assign uio_out = pin_out;
    assign uio_oe = (rst_n && ena && running && !core_fault) ? pin_oe : 8'b0;
    assign uo_out = (rst_n && ena) ? (read_sample ? sample_data :
                    {1'b0, stalled, sample_toggle, ack, word_ready,
                     (loader_error || read_error), core_fault,
                     (running && !core_fault)}) : 8'b0;
endmodule

`default_nettype wire
