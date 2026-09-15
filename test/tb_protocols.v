`timescale 1ns/1ps
`default_nettype none

// Firmware is loaded over public TT pins. External peer models independently
// decode UART/SPI/I2C signals; no private DUT state is read or written.
module tb_protocols;
    reg clk = 0, rst_n = 1, ena = 1;
    reg [7:0] ui = 0;
    wire [7:0] status, pin_out, pin_oe;
    tri [7:0] pads;
    reg spi_mode = 0, i2c_mode = 0, uart_rx_mode = 0;
    reg miso = 0, serial_rx = 1, sda_low = 0, scl_low = 0;
    reg expected_ack = 0, read_sample = 0;
    reg [15:0] firmware [0:63];
    integer i;
    genvar p;
    generate for (p = 0; p < 8; p = p + 1) begin: pad_model
        assign pads[p] = pin_oe[p] ? pin_out[p] : 1'bz;
        pullup (pads[p]);
    end endgenerate
    assign pads[0] = sda_low ? 1'b0 : 1'bz;
    assign pads[1] = scl_low ? 1'b0 : 1'bz;
    assign pads[2] = spi_mode ? miso : 1'bz;
    assign pads[0] = uart_rx_mode ? serial_rx : 1'bz;
    always #10 clk = !clk;

    tt_um_jasonzh0_protocol_engine dut (
        .clk(clk), .rst_n(rst_n), .ena(ena), .ui_in(ui), .uo_out(status),
        .uio_in(pads), .uio_out(pin_out), .uio_oe(pin_oe)
    );
    always @(posedge clk) begin
        #1;
        if (rst_n && i2c_mode && ((pin_out & pin_oe) !== 0))
            $fatal(1, "I2C must never actively drive high");
    end

    task clocks(input integer n);
        repeat (n) begin @(posedge clk); #1; end
    endtask

    task reset_chip;
        begin
            @(negedge clk);
            rst_n = 0; ui = 0; ena = 1;
            spi_mode = 0; i2c_mode = 0; uart_rx_mode = 0;
            sda_low = 0; scl_low = 0; serial_rx = 1;
            expected_ack = 0; read_sample = 0;
            clocks(4);
            if (pin_oe !== 0) $fatal(1, "Reset must release pins");
            @(negedge clk); rst_n = 1;
            clocks(4);
        end
    endtask

    task command(input [2:0] op, input [3:0] data);
        begin
            @(negedge clk); ui = {1'b0, op, data};
            clocks(1);
            @(negedge clk); ui = {1'b1, op, data};
            expected_ack = !expected_ack;
            if (op == 0) read_sample = 0;
            if ((op == 6) && (data <= 1)) read_sample = data[0];
            clocks(1);
            if (!read_sample && (status[4] !== expected_ack))
                $fatal(1, "Missing host acknowledgment");
            @(negedge clk); ui = {1'b0, op, data};
            clocks(1);
        end
    endtask

    task write_word(input [15:0] word);
        begin
            command(3, word[15:12]); command(3, word[11:8]);
            command(3, word[7:4]); command(3, word[3:0]); command(4, 0);
        end
    endtask

    task load_file(input [1023:0] path, input integer count);
        integer a;
        begin
            command(0, 0);
            $readmemh(path, firmware, 0, count - 1);
            for (a = 0; a < count; a = a + 1) write_word(firmware[a]);
            if (status[2]) $fatal(1, "Firmware loading failed");
        end
    endtask

    task check_result(input [7:0] expected);
        begin
            clocks(8);
            if (status[6:5] !== 2'b01 || status[2:0] !== 3'b001)
                $fatal(1, "Program did not publish successfully: %h", status);
            command(6, 1);
            if (status !== expected) $fatal(1, "Result %h expected %h", status, expected);
            command(0, 0);
            command(6, 1);
            if (status !== expected) $fatal(1, "HALT must preserve captured result");
            command(6, 0);
        end
    endtask

    task uart_peer(input [7:0] expected);
        integer b;
        reg [7:0] received;
        begin
            @(negedge pads[0]);
            clocks(217);
            if (pads[0] !== 0) $fatal(1, "Missing UART start");
            for (b = 0; b < 8; b = b + 1) begin
                clocks(434); received[b] = pads[0];
            end
            clocks(434);
            if ((received !== expected) || (pads[0] !== 1))
                $fatal(1, "UART byte/stop incorrect: %h", received);
        end
    endtask

    task send_uart(input [7:0] value, input good_stop);
        integer b;
        begin
            @(negedge clk); serial_rx = 0;
            repeat (434) @(negedge clk);
            for (b = 0; b < 8; b = b + 1) begin
                serial_rx = value[b];
                repeat (434) @(negedge clk);
            end
            serial_rx = good_stop;
            repeat (434) @(negedge clk);
            serial_rx = 1;
            clocks(8);
        end
    endtask

    task spi_peer(input [7:0] tx_expected, input [7:0] reply);
        integer b;
        reg [7:0] received;
        time rise_time, previous_rise;
        begin
            miso = reply[7];
            @(negedge pads[3]);
            for (b = 7; b >= 0; b = b - 1) begin
                @(posedge pads[0]);
                rise_time = $time;
                if ((b != 7) && (rise_time - previous_rise != 10000))
                    $fatal(1, "SPI SCK must be 100 kHz");
                previous_rise = rise_time;
                #1;
                if (pads[3] !== 0) $fatal(1, "SPI CS must remain asserted");
                received[b] = pads[1];
                @(negedge pads[0]);
                if ($time - rise_time != 5000) $fatal(1, "SPI high half must be 250 clocks");
                #1; if (b > 0) miso = reply[b-1];
            end
            @(posedge pads[3]);
            if (received !== tx_expected) $fatal(1, "SPI MOSI %h", received);
            if (pads[0] !== 0) $fatal(1, "SPI must end with idle-low clock");
        end
    endtask

    task i2c_peer(input integer nack_byte, input stretch);
        integer byte_index, b;
        reg [7:0] received;
        begin: peer
            @(negedge pads[0]);
            if (pads[1] !== 1) $fatal(1, "I2C START requires SCL high");
            for (byte_index = 0; byte_index < 2; byte_index = byte_index + 1) begin
                for (b = 7; b >= 0; b = b - 1) begin
                    @(posedge pads[1]); #1; received[b] = pads[0];
                end
                if (received !== ((byte_index == 0) ? 8'ha0 : 8'ha5))
                    $fatal(1, "I2C address/data mismatch: %h", received);
                @(negedge pads[1]); #1;
                sda_low = (byte_index != nack_byte);
                if (stretch && byte_index == 0) begin
                    scl_low = 1;
                    clocks(700);
                    if (status[6] !== 1 || pin_oe[1] !== 0)
                        $fatal(1, "Engine must stall with SCL released during stretch");
                    clocks(300);
                    @(negedge clk); scl_low = 0;
                end
                @(posedge pads[1]); #1;
                if (byte_index == nack_byte) begin
                    clocks(300);
                    if (status[1:0] !== 2'b10 || pin_oe !== 0)
                        $fatal(1, "I2C NACK must fault and release bus");
                    disable peer;
                end
                if (pads[0] !== 0) $fatal(1, "Missing slave ACK");
                @(negedge pads[1]); #1; sda_low = 0;
            end
            // Ignore SDA transitions during SCL low; find the actual STOP.
            begin: stop_wait
                forever begin
                    @(posedge pads[0]);
                    if (pads[1] === 1) disable stop_wait;
                end
            end
            clocks(8);
            if (pin_oe !== 0 || pads[1:0] !== 2'b11)
                $fatal(1, "I2C STOP must release both pins");
        end
    endtask

    initial begin
        reset_chip();
        load_file("firmware/uart_tx.hex", 12);
        fork
            begin uart_peer(8'h55); uart_peer(8'h55); end
            command(5, 0);
        join
        if (status[2:0] !== 1) $fatal(1, "UART TX execution fault");

        // UART input, including LSB-first shifting and stop-bit rejection.
        for (i = 0; i < 3; i = i + 1) begin
            reset_chip(); load_file("firmware/uart_rx.hex", 12);
            uart_rx_mode = 1;
            command(5, 0); clocks(10);
            if (status[6] !== 1) $fatal(1, "UART RX must wait for start");
            send_uart((i == 0) ? 8'h96 : 8'h00, i != 2);
            if (i == 2) begin
                if (status[1:0] !== 2'b10 || pin_oe !== 0)
                    $fatal(1, "UART framing error must fault");
            end else check_result((i == 0) ? 8'h96 : 8'h00);
        end

        // MSB-first full-duplex exchange, including zero and all-one replies.
        for (i = 0; i < 3; i = i + 1) begin
            reset_chip(); load_file("firmware/spi_mode0.hex", 16);
            spi_mode = 1;
            fork
                spi_peer(8'ha5, (i == 0) ? 8'h3c : ((i == 1) ? 8'h00 : 8'hff));
                command(5, 0);
            join
            check_result((i == 0) ? 8'h3c : ((i == 1) ? 8'h00 : 8'hff));
        end

        // ACK both bytes, stretch, then independently NACK address/data.
        for (i = 0; i < 4; i = i + 1) begin
            reset_chip(); load_file("firmware/i2c_write.hex", 38);
            i2c_mode = 1;
            fork
                i2c_peer((i < 2) ? -1 : (i - 2), i == 1);
                command(5, 0);
            join
            if (i < 2) check_result(0);
        end

        // A stuck bus is a documented wait, not an invented timeout; host
        // can always HALT it. Invalid READ_SELECT reports an error.
        reset_chip(); load_file("firmware/i2c_write.hex", 38);
        i2c_mode = 1; scl_low = 1;
        command(5, 0); clocks(100);
        if (status[6] !== 1 || pin_oe !== 0) $fatal(1, "Stuck bus handling");
        command(0, 0); clocks(2);
        if (status[6:5] !== 0 || status[2:0] !== 0) $fatal(1, "HALT wait recovery");
        command(6, 2);
        if (status[2] !== 1) $fatal(1, "Bad read selector must flag error");
        command(0, 0);
        if (status[2] !== 0) $fatal(1, "HALT read-error recovery");

        // A return without a call and a nested call must fail safely.
        reset_chip(); write_word(16'hf200); command(5, 0); clocks(4);
        if (status[1:0] !== 2'b10) $fatal(1, "Unmatched return must fault");
        reset_chip(); write_word(16'hf101); write_word(16'hf101);
        command(5, 0); clocks(4);
        if (status[1:0] !== 2'b10) $fatal(1, "Nested call must fault");

        $display("PASS: firmware UART TX/RX, SPI mode 0, I2C ACK/NACK/stretch, readback and call safety");
        $finish;
    end
    initial begin #5000000; $fatal(1, "Protocol test timeout"); end
endmodule

`default_nettype wire
