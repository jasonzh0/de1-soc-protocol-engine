`timescale 1ns/1ps
`default_nettype none

// FPGA-only ROM adapter. The ASIC core still has host-writable program memory;
// these initial blocks are NOT included in the Tiny Tapeout source list.
// Paths are relative to the Quartus project directory (also used by the test).
module firmware_bootloader (
    input wire clk,
    input wire rst_n,
    input wire [2:0] mode,
    output reg [2:0] selected_mode,
    output wire run,
    output wire prog_we,
    output reg [5:0] prog_addr,
    output reg [15:0] prog_data
);
    localparam SETTLE = 2'd0, LOAD = 2'd1, RUN = 2'd2;
    reg [1:0] state, settle_count;
    reg [5:0] last_word;
    reg [15:0] uart_duplex_rom [0:43];
    reg [15:0] uart_slow_rom [0:43];
    reg [15:0] uart_rx_rom [0:11];
    reg [15:0] spi_rom [0:15];
    reg [15:0] i2c_rom [0:37];
    reg [15:0] i2c_read_rom [0:46];
    initial begin
        $readmemh("../firmware/uart_duplex.hex", uart_duplex_rom);
        $readmemh("../firmware/uart_duplex_31250.hex", uart_slow_rom);
        $readmemh("../firmware/uart_rx.hex", uart_rx_rom);
        $readmemh("../firmware/spi_mode0.hex", spi_rom);
        $readmemh("../firmware/i2c_write.hex", i2c_rom);
        $readmemh("../firmware/i2c_read.hex", i2c_read_rom);
    end

    always @* begin
        prog_data = 0;
        last_word = 11;
        case (selected_mode)
            0: begin
                last_word = 43;
                if (prog_addr <= 43) prog_data = uart_duplex_rom[prog_addr];
            end
            1: if (prog_addr <= 11) prog_data = uart_rx_rom[prog_addr];
            2: begin
                last_word = 15;
                if (prog_addr <= 15) prog_data = spi_rom[prog_addr];
            end
            3: begin
                last_word = 37;
                if (prog_addr <= 37) prog_data = i2c_rom[prog_addr];
            end
            7: begin
                last_word = 46;
                if (prog_addr <= 46) prog_data = i2c_read_rom[prog_addr];
            end
            4: begin
                last_word = 43;
                if (prog_addr <= 43) prog_data = uart_slow_rom[prog_addr];
            end
        endcase
    end
    assign run = rst_n && (state == RUN);
    assign prog_we = rst_n && (state == LOAD);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= SETTLE;
            settle_count <= 0;
            selected_mode <= 0;
            prog_addr <= 0;
        end else case (state)
            SETTLE: begin
                // Allow the board's mode synchronizer to settle after reset.
                if (settle_count == 3) begin
                    // SW2 selects the alternate UART/I2C firmware profile.
                    // It is ignored for standalone RX and SPI.
                    selected_mode <= {mode[2] && ((mode[1:0] == 0) || (&mode[1:0])), mode[1:0]};
                    state <= LOAD;
                end else settle_count <= settle_count + 1'b1;
            end
            LOAD: begin
                // Last word is written on this edge with run still low.
                // The core starts execution on the following clock.
                if (prog_addr == last_word) state <= RUN;
                else prog_addr <= prog_addr + 1'b1;
            end
            default: state <= RUN;
        endcase
    end
endmodule
`default_nettype wire
