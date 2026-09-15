create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
derive_clock_uncertainty

# SW[9] asserts the reset synchronizer asynchronously. Its release passes
# through two clocked stages; keep the internal reset recovery/removal paths.
set_false_path -from [get_ports {SW[9]}] -to [get_registers {*reset_sync*}]

# Mode switches and protocol inputs enter two-stage synchronizers.
# Only the first-stage input paths are false-pathed; inter-stage paths are timed.
set_false_path -from [get_ports {SW[0] SW[1]}] -to [get_registers {*mode_meta*}]
set_false_path -from [get_ports {GPIO_0[*]}] -to [get_registers {*pin_meta*}]

# Human-visible outputs have no external timing requirement.
set_false_path -to [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]

# Bound register-to-GPIO routing instead of false-pathing protocol outputs.
# This is a prototype 20 ns path budget, NOT a slave/board setup-hold model.
# At 100 kHz SPI/I2C the firmware provides microseconds of pin timing margin.
# Review actual timing/loads and add peer-specific constraints before speeding up.
set_max_delay 20.000 -from [get_registers {*}] -to [get_ports {GPIO_0[*]}]
