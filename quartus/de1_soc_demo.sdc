create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
derive_clock_uncertainty

# KEY[0] asserts the reset synchronizer asynchronously. Its release passes
# through two clocked stages; keep the internal reset recovery/removal paths.
set_false_path -from [get_ports {KEY[0]}] -to [get_registers {*reset_sync*}]

# LEDs and UART TX have no external sampling clock related to CLOCK_50.
# These exceptions cover external output timing only; internal paths remain
# timed at 50 MHz. UART bit duration is checked in simulation.
# Revisit these exceptions when implementing synchronous external protocols.
set_false_path -to [get_ports {LEDR[*] GPIO_0[*]}]
