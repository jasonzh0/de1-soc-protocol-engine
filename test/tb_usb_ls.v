`timescale 1ns/1ps
`default_nettype none
// Independent low-speed host BFM. Exercises the real programmable core through
// its public loading and pin interfaces. No private firmware state assertions.
module tb_usb_ls;
`ifndef PROGRAM_MEMORY
`define PROGRAM_MEMORY 0
`endif
    reg clk=0, rst_n=0, run=0, prog_we=0;
    reg [10:0] prog_addr=0;
    reg [15:0] prog_data=0;
    reg [15:0] program_image [0:2047];
    reg host_drive=0, key_pressed=0;
    reg [1:0] host_line=2;
    wire [7:0] pin_in, pin_out, pin_oe, sample_data;
    wire fault, sample_toggle, stalled;
    wire program_ready;
    wire [1:0] bus_line = host_drive ? host_line : ((pin_oe[1:0] == 3) ? pin_out[1:0] : 2'b10);
    assign pin_in = {key_pressed, 5'b0, bus_line};
    always #10 clk=!clk;
`ifdef USB_BOARD_TEST
    wire [35:0] gpio, safe_gpio;
    wire [9:0] leds;
    reg vbus_present=1;
    assign gpio[1:0]=bus_line;
    assign gpio[6]=vbus_present;
    assign safe_gpio[1:0]=2'b10;
    assign safe_gpio[6]=1;
    de1_usb_top #(.USB_ATTACH_ALLOWED(1), .IMAGE_FILE("build/usb_ls.hex")) dut (
        .CLOCK_50(clk), .KEY({3'b111,!key_pressed}), .SW({!rst_n,1'b1,8'b0}),
        .LEDR(leds), .GPIO_0(gpio), .HEX0(), .HEX1(), .HEX2(), .HEX3(), .HEX4(), .HEX5()
    );
    de1_usb_top #(.IMAGE_FILE("build/usb_ls.hex")) safe_default (
        .CLOCK_50(clk), .KEY(4'hf), .SW({!rst_n,1'b1,8'b0}),
        .LEDR(), .GPIO_0(safe_gpio), .HEX0(), .HEX1(), .HEX2(), .HEX3(), .HEX4(), .HEX5()
    );
    assign pin_out={6'b0,gpio[3:2]};
    assign pin_oe={6'b0,{2{!gpio[4]}}};
    assign sample_data={7'b0,leds[5]};
    assign sample_toggle=leds[6];
    assign fault=leds[1];
    assign stalled=0;
    assign program_ready=1;
    always @(posedge clk) if(rst_n && run) begin
        if(safe_gpio[4]!==1 || safe_gpio[5]!==0) $fatal(1,"Default build attached or drove USB");
        if(gpio[7]!==0 || gpio[8]!==0) $fatal(1,"PHY mode outputs");
    end
`elsif USB_TT_TEST
    reg [7:0] host_ui=0;
    reg reading_sample=0;
    wire [7:0] tt_status;
    tt_um_jasonzh0_protocol_engine #(.PROGRAM_ADDR_WIDTH(11), .EXTENDED_ISA(1),
        .PROGRAM_MEMORY(`PROGRAM_MEMORY)) dut (
        .clk(clk), .rst_n(rst_n), .ena(1'b1), .ui_in(host_ui), .uo_out(tt_status),
        .uio_in(pin_in), .uio_out(pin_out), .uio_oe(pin_oe)
    );
    assign fault=reading_sample ? 1'b0 : tt_status[1];
    assign stalled=reading_sample ? 1'b0 : tt_status[6];
    assign sample_toggle=reading_sample ? 1'b0 : tt_status[5];
    assign sample_data=tt_status;
    assign program_ready=!tt_status[7];
    task host_command(input [2:0] op, input [3:0] data);
        begin
            @(negedge clk); host_ui={1'b0,op,data};
            if(op==6) reading_sample=data[0];
            @(negedge clk); host_ui[7]=1; @(negedge clk); host_ui[7]=0;
            @(negedge clk);
        end
    endtask
`else
    protocol_engine #(.PROGRAM_ADDR_WIDTH(11), .EXTENDED_ISA(1), .PROGRAM_MEMORY(`PROGRAM_MEMORY)) dut (
        .clk(clk), .rst_n(rst_n), .run(run), .prog_we(prog_we),
        .prog_addr(prog_addr), .prog_data(prog_data), .pin_in(pin_in),
        .pin_out(pin_out), .pin_oe(pin_oe), .sample_data(sample_data),
        .sample_toggle(sample_toggle), .fault(fault), .stalled(stalled), .program_ready(program_ready)
    );
`endif
    always @(posedge clk) if (rst_n && run) begin
        if (fault) $fatal(1,"USB firmware execution fault at %t",$time);
        if (host_drive && pin_oe[1:0] != 0) $fatal(1,"USB bus contention");
        if (pin_oe[7:2] != 0) $fatal(1,"USB firmware drove unrelated pins");
    end
    reg [7:0] host_bytes [0:31], device_bytes [0:31], saved_bytes [0:31];
    integer received, host_bit_ns=667;
    reg corrupt_token=0, corrupt_data=0, omit_stuff=0;
    integer i, j, n;
    time host_eop_end, response_start, max_turnaround=0;
    function [15:0] crc16(input [15:0] crc, input [7:0] byte_value);
        integer b; reg [15:0] c;
        begin c=crc; for(b=0;b<8;b=b+1) c=(c>>1)^((c[0]^byte_value[b])?16'ha001:16'h0000); crc16=c; end
    endfunction
    function [4:0] token_crc(input [10:0] token);
        integer b; reg [4:0] c;
        begin c=31; for(b=0;b<11;b=b+1) c=(c>>1)^((c[0]^token[b])?5'h14:5'h00); token_crc=~c; end
    endfunction
    task send_packet(input integer length);
        integer byte_index, bit_index, ones;
        reg bit_value;
        begin
            #17; host_drive=1; host_line=2; ones=0;
            for(byte_index=0;byte_index<length;byte_index=byte_index+1)
                for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                    bit_value=host_bytes[byte_index][bit_index];
                    if(!bit_value) host_line=host_line^3;
                    #(host_bit_ns);
                    ones=bit_value?ones+1:0;
                    if(ones==6 && !omit_stuff) begin host_line=host_line^3; #(host_bit_ns); ones=0; end
                end
            host_line=0; #(2*host_bit_ns); host_line=2; host_eop_end=$time;
            #(host_bit_ns); host_drive=0;
        end
    endtask
    task check_configuration(input [7:0] value);
        begin
`ifdef USB_TT_TEST
            host_command(6,1);
`endif
            if(sample_data!==value) $fatal(1,"Configuration result %h expected %h",sample_data,value);
`ifdef USB_TT_TEST
            host_command(6,0);
`endif
        end
    endtask
    task token(input [7:0] pid, input [6:0] address, input [3:0] endpoint);
        reg [10:0] t;
        begin
            t={endpoint,address};
            if ($test$plusargs("TRACE")) $display("USB host token %h address=%0d endpoint=%0d time=%0t",pid,address,endpoint,$time);
            host_bytes[0]=8'h80; host_bytes[1]=pid;
            host_bytes[2]=t[7:0]; host_bytes[3]={token_crc(t),t[10:8]};
            if(corrupt_token) host_bytes[3]=host_bytes[3]^8'h08;
            send_packet(4);
        end
    endtask
    task data_packet(input [7:0] pid,input integer payload_length);
        integer k; reg [15:0] c;
        begin
            host_bytes[0]=8'h80; host_bytes[1]=pid; c=16'hffff;
            for(k=0;k<payload_length;k=k+1) c=crc16(c,host_bytes[k+2]);
            c=~c; host_bytes[payload_length+2]=c[7:0]; host_bytes[payload_length+3]=c[15:8];
            if(corrupt_data) host_bytes[payload_length+2]=host_bytes[payload_length+2]^1;
            send_packet(payload_length+4);
        end
    endtask
    task ack;
        begin #(host_bit_ns); host_bytes[0]=8'h80; host_bytes[1]=8'hd2; send_packet(2); #(host_bit_ns); end
    endtask
    task response;
        integer bits, ones; reg [1:0] prev; reg decoded;
        begin
            received=0; bits=0; ones=0; prev=2;
            fork : response_deadline
                begin wait(pin_oe[1:0]==3); wait(bus_line==1); end
                begin #100000; $fatal(1,"Device response missing"); end
            join_any
            disable response_deadline;
            response_start=$time;
            // Turnaround measured from end of host SE0, includes host's J cell.
            if(response_start-host_eop_end > max_turnaround) max_turnaround=response_start-host_eop_end;
            if(response_start-host_eop_end > 4200 || response_start-host_eop_end < 1320)
                $fatal(1,"Response turnaround outside internal 2..6.36 bit budget: %t",response_start-host_eop_end);
            #330;
            while(bus_line!=0) begin
                if(bus_line!==1 && bus_line!==2) $fatal(1,"Invalid USB driven line state");
                decoded=(bus_line==prev); prev=bus_line;
                if(ones==6) begin
                    if(decoded) $fatal(1,"Device bit stuffing error");
                    ones=0;
                end else begin
                    device_bytes[received][bits]=decoded;
                    bits=bits+1; ones=decoded?ones+1:0;
                    if(bits==8) begin bits=0; received=received+1; end
                    if(received>=32) $fatal(1,"Device packet too long");
                end
                #660;
            end
            if(bits!=0 || ones==6) $fatal(1,"Partial byte / missing trailing stuff");
            #660; if(bus_line!==0) $fatal(1,"Short EOP");
            #660; if(bus_line!==2) $fatal(1,"EOP missing J");
            wait(pin_oe==0);
            if(device_bytes[0]!==8'h80) $fatal(1,"SYNC %h",device_bytes[0]);
            if ($test$plusargs("TRACE")) $display("USB device response %h length=%0d time=%0t",device_bytes[1],received,$time);
        end
    endtask
    task expect_handshake(input [7:0] pid);
        begin response(); if(received!=2 || device_bytes[1]!==pid) $fatal(1,"Handshake: len=%0d pid=%h expected=%h",received,device_bytes[1],pid); end
    endtask
    task expect_data(input [7:0] pid,input integer payload_length);
        integer k; reg [15:0] c;
        begin
            response();
            if(received!=payload_length+4 || device_bytes[1]!==pid)
                $fatal(1,"DATA len=%0d pid=%h expected len=%0d pid=%h",received,device_bytes[1],payload_length+4,pid);
            c=16'hffff;
            for(k=2;k<received;k=k+1) c=crc16(c,device_bytes[k]);
            if(c!==16'hb001) $fatal(1,"DATA CRC residue %h",c);
        end
    endtask
    task setup_request(input [6:0] address,input [7:0] request_type,input [7:0] request,
                       input [15:0] value,input [15:0] index,input [15:0] length);
        begin
            #(host_bit_ns); token(8'h2d,address,0); #(host_bit_ns);
            host_bytes[2]=request_type; host_bytes[3]=request;
            host_bytes[4]=value[7:0]; host_bytes[5]=value[15:8];
            host_bytes[6]=index[7:0]; host_bytes[7]=index[15:8];
            host_bytes[8]=length[7:0]; host_bytes[9]=length[15:8];
            fork data_packet(8'hc3,8); expect_handshake(8'hd2); join
            #(host_bit_ns);
        end
    endtask
    task in_data(input [6:0] address,input [3:0] endpoint,input [7:0] pid,input integer length);
        begin fork token(8'h69,address,endpoint); expect_data(pid,length); join end
    endtask
    task status_out(input [6:0] address);
        begin
            #(host_bit_ns); token(8'he1,address,0); #(host_bit_ns);
            fork data_packet(8'h4b,0); expect_handshake(8'hd2); join
        end
    endtask
    task no_response;
        integer k;
        begin for(k=0;k<2000;k=k+1) begin @(posedge clk); if(pin_oe!=0) $fatal(1,"Unexpected response"); end end
    endtask
    initial begin
        if ($value$plusargs("HOST_BIT_NS=%d",host_bit_ns)) begin end
        $readmemh("build/usb_ls.hex",program_image);
        repeat(4) @(negedge clk); rst_n=1; @(negedge clk);
        wait(program_ready); @(negedge clk);
`ifdef USB_TT_TEST
        // Auto-increment crosses 0x0ff/0x100 and 0x3ff/0x400 via the real loader.
        for(i=0;i<2048;i=i+1) begin
            host_command(3,program_image[i][15:12]); host_command(3,program_image[i][11:8]);
            host_command(3,program_image[i][7:4]); host_command(3,program_image[i][3:0]); host_command(4,0);
            if(tt_status[2]) $fatal(1,"TT image loading error at %0d",i);
        end
        host_command(5,0); run=1;
`else
        for(i=0;i<2048;i=i+1) begin @(negedge clk); prog_we=1; prog_addr=i; prog_data=program_image[i]; end
        @(negedge clk); prog_we=0; @(negedge clk); run=1;
`endif
`ifdef USB_BOARD_TEST
        wait(gpio[5]===1);
`endif
        #20000;
        host_drive=1; host_line=0; #20000; host_line=2; #5000; host_drive=0;
        // CRC and framing failures must be silent and allow the next transaction.
        corrupt_token=1; token(8'h69,0,0); corrupt_token=0; no_response();
        token(8'h2d,0,0); #(host_bit_ns);
        for(i=2;i<10;i=i+1) host_bytes[i]=0;
        corrupt_data=1; data_packet(8'hc3,8); corrupt_data=0; no_response();
        host_bytes[2]=8'hff; host_bytes[3]=8'hff;
        omit_stuff=1; data_packet(8'hc3,2); omit_stuff=0; no_response();
        host_drive=1; host_line=1; #(host_bit_ns); host_line=3;
        #(3*host_bit_ns); host_line=2; host_drive=0; no_response();
        setup_request(0,8'h80,6,16'h0100,0,8);
        in_data(0,0,8'h4b,8);
        if(device_bytes[2]!==18 || device_bytes[3]!==1 || device_bytes[9]!==8) $fatal(1,"Device descriptor header");
        // Lost ACK must replay exactly the same DATA1.
        for(i=0;i<received;i=i+1) saved_bytes[i]=device_bytes[i];
        #(host_bit_ns); in_data(0,0,8'h4b,8);
        for(i=0;i<received;i=i+1) if(saved_bytes[i]!==device_bytes[i]) $fatal(1,"Control retry changed");
        ack(); status_out(0);
        setup_request(0,0,5,5,0,0); in_data(0,0,8'h4b,0);
        #(host_bit_ns); in_data(0,0,8'h4b,0); // address stays zero before status ACK
        ack(); token(8'h69,0,0); no_response();
        setup_request(5,8'h80,6,16'h0200,0,255);
        for(i=0;i<5;i=i+1) begin
            in_data(5,0,(i%2==0)?8'h4b:8'hc3,(i==4)?2:8);
            if(i==0 && (device_bytes[2]!==9 || device_bytes[4]!==34)) $fatal(1,"Config descriptor");
            ack();
        end
        status_out(5);
        setup_request(5,8'h81,6,16'h2200,0,255);
        for(i=0;i<8;i=i+1) begin in_data(5,0,(i%2==0)?8'h4b:8'hc3,(i==7)?7:8); ack(); end
        status_out(5);
        setup_request(5,0,9,1,0,0); in_data(5,0,8'h4b,0); ack();
        check_configuration(1);
        fork token(8'h69,5,1); expect_handshake(8'h5a); join
        key_pressed=1; #(host_bit_ns); in_data(5,1,8'hc3,8);
        if(device_bytes[4]!==4) $fatal(1,"Missing keyboard usage A");
        key_pressed=0; #(host_bit_ns); in_data(5,1,8'hc3,8); // frozen until ACK
        if(device_bytes[4]!==4) $fatal(1,"Unacknowledged key report changed");
        ack(); in_data(5,1,8'h4b,8);
        if(device_bytes[4]!==0) $fatal(1,"Missing key release"); ack();
        // EP1 NAK uses a separate buffer and must not corrupt a pending EP0 retry.
        setup_request(5,8'h80,6,16'h0200,0,16); in_data(5,0,8'h4b,8);
        for(i=0;i<received;i=i+1) saved_bytes[i]=device_bytes[i];
        #(host_bit_ns); fork token(8'h69,5,1); expect_handshake(8'h5a); join
        #(host_bit_ns); in_data(5,0,8'h4b,8);
        for(i=0;i<received;i=i+1) if(saved_bytes[i]!==device_bytes[i]) $fatal(1,"Interleaved retry corrupted");
        ack(); in_data(5,0,8'hc3,8); ack(); status_out(5);
        setup_request(5,8'ha1,2,0,0,1); in_data(5,0,8'h4b,1);
        if(device_bytes[2]!==0) $fatal(1,"Initial HID idle"); ack(); status_out(5);
        setup_request(5,8'h21,10,16'h0100,0,0); in_data(5,0,8'h4b,0); ack();
        fork token(8'h69,5,1); expect_handshake(8'h5a); join
        #4100000; in_data(5,1,8'hc3,8);
        if(device_bytes[4]!==0) $fatal(1,"Idle report value"); ack();
        setup_request(5,8'h21,11,0,0,0); in_data(5,0,8'h4b,0); ack();
        setup_request(5,8'ha1,3,0,0,1); in_data(5,0,8'h4b,1);
        if(device_bytes[2]!==0) $fatal(1,"Boot protocol not retained"); ack(); status_out(5);
        setup_request(5,8'ha1,1,16'h0100,0,8); in_data(5,0,8'h4b,8);
        if(device_bytes[4]!==0) $fatal(1,"GET_REPORT value"); ack(); status_out(5);
        setup_request(5,8'h21,9,16'h0200,0,1); token(8'he1,5,0); #(host_bit_ns);
        host_bytes[2]=2;
        fork data_packet(8'h4b,1); expect_handshake(8'hd2); join
        #(host_bit_ns); in_data(5,0,8'h4b,0); ack();
        setup_request(5,8'h80,8'hff,0,0,0);
        fork token(8'h69,5,0); expect_handshake(8'h1e); join
        // Bus reset removes the assigned address and configuration.
        #2000; host_drive=1; host_line=0; #20000; host_line=2; #5000; host_drive=0;
        check_configuration(0);
        token(8'h69,5,1); no_response();
        setup_request(0,8'h80,6,16'h0100,0,8); in_data(0,0,8'h4b,8); ack(); status_out(0);
`ifdef USB_BOARD_TEST
        vbus_present=0; repeat(5) @(negedge clk);
        if(gpio[4]!==1 || gpio[5]!==0) $fatal(1,"VBUS loss did not release/detach PHY");
`endif
        $display("PASS: USB firmware enumeration/re-enumeration, bad CRC/stuffing/SE1 recovery, retries, HID key/idle/protocol/report; host bit %0d ns; max turnaround %0t",host_bit_ns,max_turnaround);
        $finish;
    end
    initial begin #20000000; $fatal(1,"USB test timed out"); end
endmodule
`default_nettype wire
