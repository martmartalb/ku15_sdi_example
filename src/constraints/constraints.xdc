# Oscilador sistema 200 MHz (Quad HP)
set_property PACKAGE_PIN AR32 [get_ports sys_clk_200m_p]
set_property PACKAGE_PIN AT32 [get_ports sys_clk_200m_n]
set_property IOSTANDARD LVDS [get_ports sys_clk_200m_p]
set_property IOSTANDARD LVDS [get_ports sys_clk_200m_n]
create_clock -period 5.000 -name sys_clk_200m [get_ports sys_clk_200m_p]

# Reset (KEY1, banco 91)
set_property PACKAGE_PIN A8 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]

# Puente: ENTRADA del oscilador por HP (FMC1_LA00_CC, E23/E24)
set_property PACKAGE_PIN E23 [get_ports refclk_hp_in_p]
set_property PACKAGE_PIN E24 [get_ports refclk_hp_in_n]
set_property IOSTANDARD LVDS [get_ports refclk_hp_in_p]
set_property IOSTANDARD LVDS [get_ports refclk_hp_in_n]

create_clock -period 6.734 -name refclk_hp_in [get_ports refclk_hp_in_p]

# Puente: SALIDA hacia el condensador por HP (FMC1_LA17_CC, E28/E29)
set_property PACKAGE_PIN E28 [get_ports refclk_hp_out_p]
set_property PACKAGE_PIN E29 [get_ports refclk_hp_out_n]
set_property IOSTANDARD LVDS [get_ports refclk_hp_out_p]
set_property IOSTANDARD LVDS [get_ports refclk_hp_out_n]

# Refclk re-entrante por MGT (AG12/AG11, Quad 226, sin IOSTANDARD)
set_property PACKAGE_PIN AE12 [get_ports refclk_148_5_p]
set_property PACKAGE_PIN AE11 [get_ports refclk_148_5_n]

create_clock -period 6.734 -name refclk_148_5 [get_ports refclk_148_5_p]

# MGT serie
set_property LOC GTHE4_CHANNEL_X0Y13 [get_cells {u_sdi_wrapper_fifo/u_gtwiz/inst/gen_gtwizard_gthe4_top.gtwizard_ultrascale_0_gtwizard_gthe4_inst/gen_gtwizard_gthe4.gen_channel_container[3].gen_enabled_channel.gthe4_channel_wrapper_inst/channel_inst/gthe4_channel_gen.gen_gthe4_channel_inst[0].GTHE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AF6 [get_ports gth_tx_p]
set_property PACKAGE_PIN AF5 [get_ports gth_tx_n]
set_property LOC GTHE4_CHANNEL_X0Y14 [get_cells {u_sdi_wrapper_fifo/u_gtwiz/inst/gen_gtwizard_gthe4_top.gtwizard_ultrascale_0_gtwizard_gthe4_inst/gen_gtwizard_gthe4.gen_channel_container[3].gen_enabled_channel.gthe4_channel_wrapper_inst/channel_inst/gthe4_channel_gen.gen_gthe4_channel_inst[1].GTHE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN AE4 [get_ports gth_rx_p]
set_property PACKAGE_PIN AE3 [get_ports gth_rx_n]

# LEDs (banco 91)
set_property PACKAGE_PIN D8  [get_ports led_qpll0_lock]
set_property PACKAGE_PIN D7  [get_ports led_tx_ready]
set_property PACKAGE_PIN D11 [get_ports led_rx_locked]
set_property PACKAGE_PIN D10 [get_ports led_fifo_overflow_or_underflow]
set_property IOSTANDARD LVCMOS33 [get_ports {led_qpll0_lock led_tx_ready led_rx_locked led_fifo_overflow_or_underflow}]

# Clock groups asincronos (CON el fix del bring-up para los gtwiz_userclk)
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks sys_clk_200m] \
    -group [get_clocks -include_generated_clocks refclk_hp_in] \
    -group [get_clocks -include_generated_clocks refclk_148_5] \
    -group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ "*gtwizard_ultrascale_0*TXOUTCLK"}]] \
    -group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ "*gtwizard_ultrascale_0*RXOUTCLK"}]] \
    -group [get_clocks gtwiz_userclk_tx_srcclk_out*] \
    -group [get_clocks gtwiz_userclk_rx_srcclk_out*]
    
    
    
#------------------------------------------------------------------------------
# Control del GS12190 U3 (TX driver, BNC J2)
# Banco 69 HP a 1.8V confirmado
# GPIO2 controla SLEEP del U3 (LOW = no sleep)
# GPIO3 controla DIRECCIÓN del U3 (HIGH = cable driver)
#------------------------------------------------------------------------------
set_property PACKAGE_PIN H27 [get_ports gs12190_u3_sleep_n]
set_property PACKAGE_PIN J27 [get_ports gs12190_u3_direction]

# GSPI - deseleccionado para no interferir con el modo pin
set_property PACKAGE_PIN E31 [get_ports gs12190_u3_sclk]
set_property PACKAGE_PIN J21 [get_ports gs12190_u3_sdin]
set_property PACKAGE_PIN J20 [get_ports gs12190_u3_cs_n]
set_property PACKAGE_PIN D31 [get_ports gs12190_u3_sdout]
set_property PACKAGE_PIN J31 [get_ports gs12190_u3_lock]
set_property PACKAGE_PIN J30 [get_ports gs12190_u3_los]

# IOSTANDARD para todos (mismo banco 1.8V)
set_property IOSTANDARD LVCMOS18 [get_ports {
    gs12190_u3_sleep_n 
    gs12190_u3_direction 
    gs12190_u3_sclk 
    gs12190_u3_sdin 
    gs12190_u3_cs_n 
    gs12190_u3_sdout
    gs12190_u3_lock 
    gs12190_u3_los
}]
    