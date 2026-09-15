# SPDX-License-Identifier: Apache-2.0
"""Public-pin regression shared by the template's RTL and GL flow.

No hierarchical register access or memory preload: firmware uses the same
strobe interface a real synchronous host must implement.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer


class Host:
    def __init__(self, dut):
        self.dut = dut

    async def clocks(self, count=1):
        await ClockCycles(self.dut.clk, count)
        await Timer(1, unit="ns")

    async def reset(self):
        await FallingEdge(self.dut.clk)
        self.dut.ui_in.value = 0
        self.dut.ena.value = 1
        self.dut.rst_n.value = 0
        await self.clocks(4)
        assert int(self.dut.uio_oe.value) == 0
        await FallingEdge(self.dut.clk)
        self.dut.rst_n.value = 1
        await self.clocks(4)
        assert int(self.dut.uo_out.value) == 0

    async def command(self, op, data=0, held=1):
        value = op << 4 | data
        await FallingEdge(self.dut.clk)
        self.dut.ui_in.value = value
        await self.clocks()
        ack = int(self.dut.uo_out.value) & 0x10
        await FallingEdge(self.dut.clk)
        self.dut.ui_in.value = value | 0x80
        for _ in range(held):
            await self.clocks()
            assert int(self.dut.uo_out.value) & 0x10 == ack ^ 0x10
        await FallingEdge(self.dut.clk)
        self.dut.ui_in.value = value
        await self.clocks()

    async def load(self, words):
        assert 0 < len(words) <= 64
        await self.command(0)
        for word in words:
            for shift in (12, 8, 4, 0):
                await self.command(3, word >> shift & 15)
            assert int(self.dut.uo_out.value) & 8
            await self.command(4)
            assert not int(self.dut.uo_out.value) & 8
        assert not int(self.dut.uo_out.value) & 4


def uart_program(value):
    # SET + WAIT432 = 434 clocks per UART bit. Loop starts after idle setup.
    words = [0x1001, 0x3001, 0x2008]
    for bit in [0] + [(value >> i) & 1 for i in range(8)] + [1]:
        words.extend((0x1000 | bit, 0x21B0))
    return words + [0x4003]


async def receive_uart(dut, expected):
    # Poll clocked outputs, with a bounded start-bit wait. This tests timing
    # through public pins and works without names from the synthesized core.
    for _ in range(5000):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        if int(dut.uio_oe.value) & 1 and not int(dut.uio_out.value) & 1:
            break
    else:
        raise AssertionError("UART start bit timeout")
    await ClockCycles(dut.clk, 217)
    await Timer(1, unit="ns")
    assert not int(dut.uio_out.value) & 1
    value = 0
    for i in range(8):
        await ClockCycles(dut.clk, 434)
        await Timer(1, unit="ns")
        value |= (int(dut.uio_out.value) & 1) << i
    await ClockCycles(dut.clk, 434)
    await Timer(1, unit="ns")
    assert int(dut.uio_oe.value) == 1
    assert int(dut.uio_out.value) & 1, "Missing stop bit"
    assert value == expected, f"UART received {value:#x}, expected {expected:#x}"


@cocotb.test()
async def test_program_loader_and_uart(dut):
    dut.clk.value = 0
    dut.rst_n.value = 0
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    host = Host(dut)
    await host.reset()

    # Empty program must fail safely.
    await host.command(5)
    await host.clocks(4)
    assert int(dut.uo_out.value) & 3 == 2
    assert int(dut.uio_oe.value) == 0

    # Invalid WRITE and held strobe; HALT recovers the error.
    await host.command(0)
    await host.command(4, held=4)
    assert int(dut.uo_out.value) & 4
    await host.command(0)
    assert not int(dut.uo_out.value) & 4

    await host.load([0x10A5, 0x30FF, 0x4002])
    await host.command(5)
    await host.clocks(6)
    assert int(dut.uio_out.value) == 0xA5
    assert int(dut.uio_oe.value) == 0xFF
    await host.command(4)
    assert int(dut.uo_out.value) & 4  # Running writes rejected.
    assert int(dut.uio_out.value) == 0xA5

    await FallingEdge(dut.clk)
    dut.ena.value = 0
    await host.clocks(4)
    assert int(dut.uo_out.value) == 0
    assert int(dut.uio_oe.value) == 0
    await FallingEdge(dut.clk)
    dut.ena.value = 1
    await host.clocks(4)
    assert int(dut.uo_out.value) == 0  # No automatic restart.
    await host.command(5)
    await host.clocks(6)
    assert int(dut.uio_out.value) == 0xA5  # Program retained.

    for value in (0x55, 0xAA):
        await host.load(uart_program(value))
        receiver = cocotb.start_soon(receive_uart(dut, value))
        await host.command(5)
        await receiver
        await receive_uart(dut, value)
        assert not int(dut.uo_out.value) & 6

    await host.reset()
    await host.command(5)
    await host.clocks(4)
    assert int(dut.uo_out.value) & 3 == 2  # Reset invalidated program.
    assert int(dut.uio_oe.value) == 0
