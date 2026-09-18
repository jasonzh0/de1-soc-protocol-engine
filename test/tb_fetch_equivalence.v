`timescale 1ns/1ps
`default_nettype none
`ifndef PROGRAM_MEMORY
`define PROGRAM_MEMORY 1
`endif
// Cycle-by-cycle public-port comparison. Offset RUN by the one documented
// prefetch clock; after that, both backends must execute on identical edges.
module tb_fetch_equivalence;
    reg clk=0, rst_n=0, run_legacy=0, run_clocked=0, prog_we=0;
    reg [10:0] prog_addr=0;
    reg [15:0] prog_data=0;
    reg [7:0] pin_in=0;
    wire [7:0] out_a, oe_a, sample_a, out_b, oe_b, sample_b;
    wire fault_a, toggle_a, stalled_a, fault_b, toggle_b, stalled_b, ready;
    reg [15:0] words [0:2047];
    reg [31:0] random_state=32'h576123ab;
    integer trial, i, cycle;
    always #10 clk=!clk;
    protocol_engine #(.PROGRAM_ADDR_WIDTH(11), .EXTENDED_ISA(1)) reference_core (
        .clk(clk), .rst_n(rst_n), .run(run_legacy), .prog_we(prog_we),
        .prog_addr(prog_addr), .prog_data(prog_data), .pin_in(pin_in),
        .pin_out(out_a), .pin_oe(oe_a), .sample_data(sample_a),
        .fault(fault_a), .sample_toggle(toggle_a), .stalled(stalled_a), .program_ready()
    );
    protocol_engine #(.PROGRAM_ADDR_WIDTH(11), .EXTENDED_ISA(1), .PROGRAM_MEMORY(`PROGRAM_MEMORY)) candidate_core (
        .clk(clk), .rst_n(rst_n), .run(run_clocked), .prog_we(prog_we),
        .prog_addr(prog_addr), .prog_data(prog_data), .pin_in(pin_in),
        .pin_out(out_b), .pin_oe(oe_b), .sample_data(sample_b),
        .fault(fault_b), .sample_toggle(toggle_b), .stalled(stalled_b), .program_ready(ready)
    );
    task randomize;
        random_state=random_state*1664525+1013904223;
    endtask
    initial begin
        for(trial=0;trial<12;trial=trial+1) begin
            @(negedge clk); rst_n=0; run_legacy=0; run_clocked=0; prog_we=0;
            repeat(3) @(negedge clk); rst_n=1; wait(ready);
            for(i=0;i<2048;i=i+1) words[i]=0;
            if(trial==0) begin
                // WAIT, loops, pin waits/branches, calls, and context switching.
                words[0]=16'h10aa; words[1]=16'h30ff; words[2]=16'h2003;
                words[3]=16'h50a5; words[4]=16'h6000; words[5]=16'h7002;
                words[6]=16'he000; words[7]=16'h8003; words[8]=16'hc008;
                words[9]=16'h9008; words[10]=16'hf128; words[11]=16'hb101;
                words[12]=16'ha00b; words[13]=16'hd00b; words[14]=16'h4012;
                words[16]=16'h1011; words[17]=16'h300f; words[18]=16'hf320;
                words[19]=16'hf128; words[20]=16'h2011; words[21]=16'h4013;
                words[32]=16'h50f0; words[33]=16'h6001; words[34]=16'hb24a;
                words[35]=16'ha00c; words[36]=16'h4020;
                words[40]=16'h10cc; words[41]=16'hf200;
            end else begin
                // Initialize every scratch address used, then enter a high bank.
                for(i=0;i<16;i=i+1) begin words[2*i]=16'h0100+i; words[2*i+1]=16'h0300+i; end
                words[32]=16'h4400;
                for(i=1024;i<1152;i=i+1) begin
                    randomize();
                    case(random_state[31:28])
                        0: words[i]=16'h0100 | random_state[7:0];
                        1: words[i]=16'h0300 | random_state[3:0];
                        2: words[i]=16'h0200 | random_state[3:0];
                        3: words[i]=16'h0400 | random_state[7:0];
                        4: words[i]=16'h0500 | random_state[7:0];
                        5: words[i]=16'h0600 | random_state[7:0];
                        6: words[i]=16'h0800 | random_state[7:0];
                        7: words[i]=16'h0f00 | {14'b0,random_state[1:0]};
                        8: words[i]=16'h0e18;
                        9: words[i]=16'h4400 | {9'b0,random_state[6:0]};
                        10: words[i]=16'h0e08;
                        11: words[i]=16'h0e09;
                        12: words[i]=16'hf800 | random_state[3:0];
                        13: words[i]=16'hfa00 | random_state[3:0];
                        14: words[i]=16'h0e01;
                        15: words[i]=16'h0e02;
                    endcase
                end
                words[1152]=16'h4400;
            end
            for(i=0;i<2048;i=i+1) begin @(negedge clk); prog_we=1; prog_addr=i; prog_data=words[i]; end
            @(negedge clk); prog_we=0;
            @(negedge clk); run_clocked=1;
            @(negedge clk); run_legacy=1;
            for(cycle=0;cycle<2000;cycle=cycle+1) begin
                @(posedge clk); #1;
                if({out_a,oe_a,sample_a,fault_a,toggle_a,stalled_a} !==
                   {out_b,oe_b,sample_b,fault_b,toggle_b,stalled_b})
                    $fatal(1,"Fetch mismatch trial %0d cycle %0d",trial,cycle);
                if(fault_a) $fatal(1,"Unexpected fault in equivalence program");
                @(negedge clk); randomize(); pin_in=random_state[7:0];
            end
        end
        $display("PASS: 24000 public-port-equivalent cycles across dual-context and deterministic randomized high-bank programs");
        $finish;
    end
    initial begin #2000000; $fatal(1,"Equivalence timeout"); end
endmodule
`default_nettype wire
