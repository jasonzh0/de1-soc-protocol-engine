`timescale 1ns/1ps
`default_nettype none
`ifndef PROGRAM_MEMORY
`define PROGRAM_MEMORY 1
`endif
module tb_wide_loader;
    reg clk=0, rst_n=0, ena=1;
    reg [7:0] ui=0;
    wire [7:0] status, pin_out, pin_oe;
    always #10 clk=!clk;
    tt_um_jasonzh0_protocol_engine #(.PROGRAM_ADDR_WIDTH(11), .EXTENDED_ISA(1),
        .PROGRAM_MEMORY(`PROGRAM_MEMORY)) dut (
        .clk(clk), .rst_n(rst_n), .ena(ena), .ui_in(ui), .uo_out(status),
        .uio_in(8'hff), .uio_out(pin_out), .uio_oe(pin_oe)
    );
    task command(input [2:0] op, input [3:0] data);
        begin @(negedge clk); ui={1'b0,op,data};
            @(negedge clk); ui[7]=1; @(negedge clk); ui[7]=0;
            @(negedge clk); end
    endtask
    task address(input [10:0] a);
        begin command(7,{1'b0,a[10:8]}); command(2,a[7:4]); command(1,a[3:0]); end
    endtask
    task word(input [15:0] data);
        begin command(3,data[15:12]); command(3,data[11:8]);
            command(3,data[7:4]); command(3,data[3:0]); command(4,0); end
    endtask
    task settle;
        repeat(20) @(negedge clk);
    endtask
    initial begin
        repeat(4) @(negedge clk); rst_n=1; @(negedge clk);
        if(!status[7]) $fatal(1,"Missing memory-busy status");
        command(5,0); if(!status[2] || status[0] || pin_oe) $fatal(1,"RUN accepted during scrub");
        command(0,0); word(16'h3001);
        if(!status[2]) $fatal(1,"WRITE accepted during scrub");
        wait(!status[7]); command(0,0);
        // An unwritten program must fault instead of executing unknown SRAM.
        command(5,0); settle();
        if(!status[1] || pin_oe) $fatal(1,"Unwritten fetch did not fault/release");
        command(0,0); address(0); word(16'h4400);
        command(5,0); settle();
        if(!status[1] || pin_oe) $fatal(1,"Sparse high-address hole did not fault");
        command(0,0); address(1024); word(16'h10a5); word(16'h3001); word(16'h4402);
        command(5,0); settle();
        if(status[2:0]!==1 || pin_oe!==1 || pin_out!==8'ha5) $fatal(1,"High-bank program/retention failed");
        // Running writes must neither change memory nor address/run state.
        command(4,0); if(!status[2] || !status[0]) $fatal(1,"Running write protection");
        command(0,0); address(2046); word(16'h105a); word(16'h3001);
        // Address wraps to zero after writing word 2047.
        word(16'h47fe); command(5,0); settle();
        if(status[2:0]!==1 || pin_oe!==1 || pin_out!==8'h5a) $fatal(1,"Packed boundary/wrap failed");
        command(0,0); command(7,8); command(5,0);
        if(!status[2] || status[0]) $fatal(1,"Out-of-range bank did not block RUN");
        command(0,0); command(3,1); command(5,0);
        if(!status[2] || status[0]) $fatal(1,"Partial word did not block RUN");
        command(0,0); command(5,0); settle();
        ena=0; @(negedge clk); if(pin_oe!==0) $fatal(1,"Deselection did not release");
        ena=1; settle(); if(status[0]) $fatal(1,"Reselect auto-started");
        command(5,0); settle(); if(pin_out!==8'h5a || pin_oe!==1) $fatal(1,"Deselection lost program");
        @(negedge clk); rst_n=0; ui=0; @(negedge clk);
        if(pin_oe!==0) $fatal(1,"Reset did not release");
        rst_n=1; @(negedge clk); wait(!status[7]); command(5,0); settle();
        if(!status[1] || pin_oe) $fatal(1,"Reset retained executable program");
        $display("PASS: TT wide loader busy gating, partial images, sparse faults, masked writes, wrap, halt/reset/ena and range errors");
        $finish;
    end
    initial begin #300000; $fatal(1,"Wide loader timeout"); end
endmodule
`default_nettype wire
