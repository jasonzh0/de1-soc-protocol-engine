`timescale 1ns/1ps
`default_nettype none
// FPGA-only ROM adapter. No protocol processing; loads the public core port.
module usb_firmware_bootloader #(
    parameter IMAGE_FILE = "../build/usb_ls.hex"
) (
    input wire clk, rst_n,
    output reg run,
    output wire prog_we,
    output reg [10:0] prog_addr,
    output wire [15:0] prog_data
);
    reg [15:0] image [0:2047];
    reg last_written;
    initial $readmemh(IMAGE_FILE, image);
    assign prog_we = rst_n && !run && !last_written;
    assign prog_data = image[prog_addr];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prog_addr <= 0;
            last_written <= 0;
            run <= 0;
        end else if (!run) begin
            if (last_written) run <= 1;
            else if (prog_addr == 2047) last_written <= 1;
            else prog_addr <= prog_addr + 1'b1;
        end
    end
endmodule
`default_nettype wire
