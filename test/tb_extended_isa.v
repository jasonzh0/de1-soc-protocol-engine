`timescale 1ns/1ps
`default_nettype none
// Non-USB programs verify reusable extension semantics through public ports.
module tb_extended_isa;
`ifndef PROGRAM_MEMORY
`define PROGRAM_MEMORY 0
`endif
    reg clk=0, rst_n=0, run=0, prog_we=0;
    reg [10:0] prog_addr=0;
    reg [15:0] prog_data=0;
    wire [7:0] pin_out, pin_oe, sample_data;
    wire fault, sample_toggle, stalled;
    wire program_ready;
    wire default_fault;
    wire [7:0] default_oe;
    integer address=0;
    always #10 clk=!clk;
    protocol_engine #(.PROGRAM_ADDR_WIDTH(11), .EXTENDED_ISA(1), .PROGRAM_MEMORY(`PROGRAM_MEMORY), .CLOCK_HZ(50000000)) dut (
        .clk(clk), .rst_n(rst_n), .run(run), .prog_we(prog_we), .prog_addr(prog_addr),
        .prog_data(prog_data), .pin_in(8'h5a), .pin_out(pin_out), .pin_oe(pin_oe),
        .sample_data(sample_data), .sample_toggle(sample_toggle), .fault(fault), .stalled(stalled), .program_ready(program_ready)
    );
    protocol_engine default_profile (
        .clk(clk), .rst_n(rst_n), .run(run), .prog_we(prog_we), .prog_addr(prog_addr[5:0]),
        .prog_data(prog_data), .pin_in(8'h5a), .pin_out(), .pin_oe(default_oe),
        .sample_data(), .sample_toggle(), .fault(default_fault), .stalled()
    );
    task reset;
        begin @(negedge clk); rst_n=0; run=0; prog_we=0;
            repeat(3) @(negedge clk); rst_n=1; address=0;
            wait(program_ready); @(negedge clk); end
    endtask
    task emit(input [15:0] word);
        begin @(negedge clk); prog_we=1; prog_addr=address; prog_data=word; address=address+1; end
    endtask
    task start;
        begin @(negedge clk); prog_we=0; @(negedge clk); run=1; end
    endtask
    task expect_result(input [7:0] value);
        begin repeat(100) @(negedge clk);
            if(fault || sample_data!==value || !sample_toggle)
                $fatal(1,"Extended ISA result %h expected %h fault %b",sample_data,value,fault);
        end
    endtask
    initial begin
        reset(); emit(16'h4400); // full-width branch above the legacy 64-word range
        address=1024; emit(16'h01fe); emit(16'h0307); emit(16'h0403); // A=1, carry
        emit(16'h0f02); emit(16'h0000); // carry skip protects against invalid opcode
        emit(16'hf807); // XOR scratch[7]: FF
        emit(16'h0909); emit(16'h0b00); emit(16'h0100); emit(16'h0a00);
        emit(16'h0800); emit(16'h0f01); emit(16'h0000); // not equal
        emit(16'hf600); // wide call to 512
        emit(16'h0e18); emit(16'h440f); // publish once, self loop at 1039
        address=512; emit(16'h0e07); emit(16'hf200); // invert FF -> zero, return to high PC
        start(); expect_result(0);

        reset();
        // Reflected CRC-16/ARC seed 0, polynomial A001, message 01 => C0C1.
        emit(16'h0101); emit(16'h0e13); emit(16'h01a0); emit(16'h0e14);
        emit(16'h0100); emit(16'h0e11); emit(16'h0e12); emit(16'h0e20);
        emit(16'h0101); emit(16'h03ff); emit(16'h09ff); emit(16'hfe08);
        emit(16'h0e16); emit(16'h08c1); emit(16'h0f00); emit(16'h0000);
        emit(16'h0e17); emit(16'h08c0); emit(16'h0f00); emit(16'h0000);
        emit(16'h0e06); emit(16'h0f00); emit(16'h0000); // index wrapped FF -> 0
        emit(16'h0208); emit(16'h0801); emit(16'h0f00); emit(16'h0000);
        emit(16'h0e22); emit(16'h0e16); emit(16'h0e18); emit(16'h401e);
        start(); expect_result(0);

        reset(); emit(16'h3001); emit(16'hf303); emit(16'h0101); emit(16'h4003);
        start(); repeat(20) @(negedge clk);
        if(!fault || pin_oe!==0) $fatal(1,"Extension must fault in dual-context mode");
        reset(); emit(16'h3001); emit(16'hf402); emit(16'hf403);
        start(); repeat(20) @(negedge clk);
        if(!fault || pin_oe!==0) $fatal(1,"Nested wide call must fault/release");
        reset(); emit(16'h3001); emit(16'h0101); emit(16'h0e18); emit(16'h4003);
        start(); expect_result(1);
        if(!default_fault || default_oe!==0) $fatal(1,"Default profile enabled extended opcode");
        $display("PASS: extended memory/ALU/flags, wide branch/call/return, programmable CRC, index wrap, context/call faults");
        $finish;
    end
    initial begin #500000; $fatal(1,"Extended ISA test timeout"); end
endmodule
`default_nettype wire
