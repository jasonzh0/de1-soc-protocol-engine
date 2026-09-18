`timescale 1ns/1ps
`default_nettype none
`ifndef PROGRAM_MEMORY
`define PROGRAM_MEMORY 1
`endif
module tb_program_store;
    reg clk=0, rst_n=0, write_en=0, read_en=0;
    reg [10:0] write_addr=0, read_addr=0;
    reg [15:0] write_data=0;
    wire [15:0] read_data;
    wire ready, read_valid;
    reg [15:0] expected [0:2047];
    reg [15:0] held;
    reg [31:0] seed=32'h45198ace;
    integer i, cycles;
    always #10 clk=!clk;
    program_store #(.ADDR_WIDTH(11), .BACKEND(`PROGRAM_MEMORY)) dut (
        .clk(clk), .rst_n(rst_n), .write_en(write_en), .write_addr(write_addr),
        .write_data(write_data), .read_en(read_en), .read_addr(read_addr),
        .read_data(read_data), .read_valid(read_valid), .ready(ready)
    );
    task reset_and_scrub;
        begin
            @(negedge clk); rst_n=0; write_en=0; read_en=0;
            repeat(3) @(negedge clk); rst_n=1;
            // Attempted writes during scrub must not inject executable contents.
            write_en=1; write_addr=2047; write_data=16'hdead;
            cycles=0;
            while(!ready) begin @(posedge clk); #1; cycles=cycles+1; end
            if(cycles!=1024) $fatal(1,"Unexpected scrub length %0d",cycles);
            @(negedge clk); write_en=0;
            for(i=0;i<2048;i=i+1) expected[i]=0;
        end
    endtask
    task write_word(input [10:0] address, input [15:0] data);
        begin @(negedge clk); write_en=1; read_en=0; write_addr=address; write_data=data;
            @(negedge clk); write_en=0; expected[address]=data; end
    endtask
    task read_word(input [10:0] address);
        begin @(negedge clk); read_en=1; read_addr=address;
            @(posedge clk); #1;
            if(!read_valid || read_data!==expected[address])
                $fatal(1,"Read %h got %h expected %h",address,read_data,expected[address]);
            @(negedge clk); read_en=0;
        end
    endtask
    initial begin
        reset_and_scrub(); read_word(0); read_word(2047);
        write_word(0,16'h1234); write_word(1,16'habcd);
        write_word(2047,16'h5678); write_word(2046,16'hef90);
        read_word(0); read_word(1); read_word(2046); read_word(2047);
        write_word(1,16'hbeef); read_word(0); read_word(1);
        held=read_data; read_addr=0; repeat(3) @(negedge clk);
        if(read_data!==held) $fatal(1,"Read is not registered/enable-held");
        for(i=0;i<256;i=i+1) begin
            seed=seed*1664525+1013904223;
            write_word(seed[10:0],seed[31:16]); read_word(seed[10:0]);
        end
        for(i=0;i<2048;i=i+1) read_word(i);
        // Interrupt a scrub and ensure a complete new scrub occurs after reset.
        @(negedge clk); rst_n=0; @(negedge clk); rst_n=1;
        repeat(50) @(negedge clk);
        if(ready) $fatal(1,"Scrub ended early");
        reset_and_scrub(); read_word(0); read_word(1); read_word(2047);
        $display("PASS: packed SRAM halfword masks, clocked reads, full scrub, reset interruption and address coverage");
        $finish;
    end
    initial begin #1000000; $fatal(1,"Memory test timeout"); end
endmodule
`default_nettype wire
