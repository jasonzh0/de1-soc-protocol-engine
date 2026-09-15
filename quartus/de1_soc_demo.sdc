create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
derive_clock_uncertainty

# SW[9] asserts the reset synchronizer asynchronously. Its release passes
# through two clocked stages; keep the internal reset recovery/removal paths.
set_false_path -from [get_ports {SW[9]}] -to [get_registers {*reset_sync*}]

# Asynchronous buttons feed only the first stage of a two-register input
# synchronizer. Keep the path between synchronizer stages timed.
set_false_path -from [get_ports {KEY[*]}] -to [get_registers {*key_meta*}]

# LEDs, seven-segment displays and UART TX have no external sampling clock.
# These exceptions cover external output timing only; internal paths remain
# timed at 50 MHz. UART bit duration is checked in simulation.
# Revisit these exceptions when implementing synchronous external protocols.
set_false_path -to [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*] GPIO_0[*]}]
