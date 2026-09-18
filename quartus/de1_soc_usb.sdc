create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
derive_clock_uncertainty
set_false_path -from [get_ports {SW[9]}] -to [get_registers {*reset_sync*}]
set_false_path -from [get_ports {SW[8] GPIO_0[6]}] -to [get_registers {*attach_meta*}]
set_false_path -from [get_ports {KEY[0] GPIO_0[0] GPIO_0[1]}] -to [get_registers {*pin_meta*}]
set_false_path -to [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]
# Provisional digital path budget, not a USB compliance or PHY timing model.
# Retain timing on every synchronizer inter-stage path.
set_max_delay 20.000 -from [get_registers {*}] -to [get_ports {GPIO_0[*]}]
