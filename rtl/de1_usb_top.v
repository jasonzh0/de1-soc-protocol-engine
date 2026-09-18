`timescale 1ns/1ps
`default_nettype none
// Experimental external-PHY adapter, NOT direct USB D+/D- wiring.
// See docs/usb.md. Attachment deliberately disabled in the default build.
module de1_usb_top #(
    parameter USB_ATTACH_ALLOWED = 0,
    parameter IMAGE_FILE = "../build/usb_ls.hex"
) (
    input wire CLOCK_50,
    input wire [3:0] KEY,
    input wire [9:0] SW,
    output wire [9:0] LEDR,
    output wire [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout wire [35:0] GPIO_0
);
    reg [1:0] reset_sync;
    wire rst_n = reset_sync[1];
    reg [1:0] attach_meta, attach_sync;
    wire boot_run, prog_we, fault, sample_toggle, stalled;
    wire [10:0] prog_addr;
    wire [15:0] prog_data;
    wire [7:0] pin_out, pin_oe, sample_data;
    wire permitted = USB_ATTACH_ALLOWED && (&attach_sync);
    wire run = boot_run && permitted;
    reg [11:0] attach_delay;
    reg [25:0] heartbeat;
    wire attached = (&attach_delay) && run && !fault && rst_n;
    wire drive = attached && (pin_oe[1:0] == 2'b11);

    always @(posedge CLOCK_50 or posedge SW[9]) begin
        if (SW[9]) reset_sync <= 0;
        else reset_sync <= {reset_sync[0], 1'b1};
    end
    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            attach_meta <= 0;
            attach_sync <= 0;
            attach_delay <= 0;
            heartbeat <= 0;
        end else begin
            // GPIO6 must be an externally conditioned 3.3 V VBUS-present signal.
            attach_meta <= {SW[8], GPIO_0[6]};
            attach_sync <= attach_meta;
            if (!run || fault) begin attach_delay <= 0; heartbeat <= 0; end
            else begin
                if (!(&attach_delay)) attach_delay <= attach_delay + 1'b1;
                heartbeat <= heartbeat + 1'b1;
            end
        end
    end
    usb_firmware_bootloader #(.IMAGE_FILE(IMAGE_FILE)) boot (
        .clk(CLOCK_50), .rst_n(rst_n), .run(boot_run), .prog_we(prog_we),
        .prog_addr(prog_addr), .prog_data(prog_data)
    );
    protocol_engine #(.PROGRAM_ADDR_WIDTH(11), .EXTENDED_ISA(1)) engine (
        .clk(CLOCK_50), .rst_n(rst_n), .run(run), .prog_we(prog_we),
        .prog_addr(prog_addr), .prog_data(prog_data),
        .pin_in({!KEY[0], 5'b0, GPIO_0[1:0]}),
        .pin_out(pin_out), .pin_oe(pin_oe), .fault(fault),
        .sample_data(sample_data), .sample_toggle(sample_toggle), .stalled(stalled)
    );
    assign GPIO_0[1:0] = 2'bzz; // PHY VP, VM (received D+, D-)
    assign GPIO_0[2] = pin_out[0]; // PHY VPO
    assign GPIO_0[3] = pin_out[1]; // PHY VMO
    assign GPIO_0[4] = !drive; // PHY active-low OE
    assign GPIO_0[5] = attached; // PHY SOFTCON: low-speed pull-up enable
    assign GPIO_0[6] = 1'bz;
    assign GPIO_0[7] = 1'b0; // PHY SPEED: low speed
    assign GPIO_0[8] = 1'b0; // PHY SUSPND: normal operation
    assign GPIO_0[35:9] = {27{1'bz}};
    assign LEDR = {heartbeat[25], 2'b0, sample_toggle, (sample_data == 1),
                   drive, attached, run, fault, boot_run};
    assign HEX0 = sample_data == 1 ? 7'h79 : 7'h40;
    assign HEX1 = 7'h7f;
    assign HEX2 = 7'h7f;
    assign HEX3 = 7'h7f;
    assign HEX4 = 7'h7f;
    assign HEX5 = 7'h41; // U
    wire _unused = &{KEY[3:1], SW[7:0], stalled, pin_out[7:2], pin_oe[7:2], 1'b0};
endmodule
`default_nettype wire
