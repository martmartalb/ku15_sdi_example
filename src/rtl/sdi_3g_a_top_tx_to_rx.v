//==============================================================================
// sdi_3g_a_top_tx_to_rx.v
//
// TOP para el TEST TX-to-RX (loopback fisico J2 -> cable -> J3).
//   TX genera patron -> J2 -> [cable BNC] -> J3 -> RX decodifica -> ILA.
//
// Reusa la infraestructura de reloj del passthrough (puente 148.5).
// Instancia sdi_3g_a_pattern (TX generador + RX decodificador, full-duplex).
//==============================================================================

module sdi_3g_a_top_tx_to_rx #(
    parameter PATTERN_MODE = 0          // 0 = color plano, 1 = barras
)(
    input  wire        sys_clk_200m_p,
    input  wire        sys_clk_200m_n,
    input  wire        sys_rst_n,

    // Puente de reloj 148.5
    input  wire        refclk_hp_in_p,     // E23
    input  wire        refclk_hp_in_n,     // E24
    output wire        refclk_hp_out_p,    // E28
    output wire        refclk_hp_out_n,    // E29
    input  wire        refclk_148_5_p,     // AG12 (MGT226_CLK0)
    input  wire        refclk_148_5_n,     // AG11 (MGT226_CLK0)

    // Pares MGT serie
    input  wire        gth_rx_p,           // X0Y12 RX = AE4 (J3)
    input  wire        gth_rx_n,           // X0Y12 RX = AE3
    output wire        gth_tx_p,           // X0Y13 TX = AF6 (J2)
    output wire        gth_tx_n,           // X0Y13 TX = AF5

    // LEDs (active-LOW)
    output wire        led_qpll0_lock,
    output wire        led_tx_ready,
    output wire        led_rx_locked,                  // lock del RX decodificador
    output wire        led_fifo_overflow_or_underflow, // libre en este test

    // GS12190 U3 (TX driver, J2)
    output wire        gs12190_u3_sleep_n,
    output wire        gs12190_u3_direction,
    output wire        gs12190_u3_sclk,
    output wire        gs12190_u3_sdin,
    output wire        gs12190_u3_cs_n,
    input  wire        gs12190_u3_sdout,
    input  wire        gs12190_u3_lock,
    input  wire        gs12190_u3_los,

    // GS12190 U8 (RX equalizer, J3)
    output wire        gs12190_u8_sleep_n,
    output wire        gs12190_u8_direction,
    output wire        gs12190_u8_sclk,
    output wire        gs12190_u8_sdin,
    output wire        gs12190_u8_cs_n,
    input  wire        gs12190_u8_sdout,
    input  wire        gs12190_u8_lock,
    input  wire        gs12190_u8_los
);

    
    //--------------------------------------------------------------------------
    // 1) Oscilador de sistema 200 MHz (LVDS -> single-ended)
    //--------------------------------------------------------------------------
    wire sys_clk_200m;
 
    IBUFDS #(
        .IBUF_LOW_PWR ("FALSE"),
        .IOSTANDARD   ("LVDS")
    ) u_ibufds_sysclk (
        .I  (sys_clk_200m_p),
        .IB (sys_clk_200m_n),
        .O  (sys_clk_200m)
    );
 
    //--------------------------------------------------------------------------
    // 2) Free-running 100 MHz (200 / 2)
    //--------------------------------------------------------------------------
    wire clk_freerun_100m;
 
    BUFGCE_DIV #(
        .BUFGCE_DIVIDE   (2),
        .IS_CE_INVERTED  (1'b0),
        .IS_CLR_INVERTED (1'b0),
        .IS_I_INVERTED   (1'b0)
    ) u_bufgce_div_freerun (
        .I   (sys_clk_200m),
        .CE  (1'b1),
        .CLR (1'b0),
        .O   (clk_freerun_100m)
    );
 
    //--------------------------------------------------------------------------
    // 3) Puente de reloj 148.5 MHz (clock forwarding)
    //--------------------------------------------------------------------------
    // 3.1) Receptor diferencial del oscilador por HP
    wire clk_hp_ibuf;
 
    IBUFDS #(
        .IBUF_LOW_PWR ("FALSE"),
        .IOSTANDARD   ("LVDS")
    ) u_ibufds_hp (
        .I  (refclk_hp_in_p),
        .IB (refclk_hp_in_n),
        .O  (clk_hp_ibuf)
    );
 
    // 3.2) Buffer global
    wire clk_hp_global;
 
    BUFG u_bufg_hp (
        .I (clk_hp_ibuf),
        .O (clk_hp_global)
    );
 
    // 3.3) ODDRE1 (D1=1, D2=0 reproduce la onda de C)
    wire clk_fwd;
 
    ODDRE1 #(
        .IS_C_INVERTED  (1'b0),
        .IS_D1_INVERTED (1'b0),
        .IS_D2_INVERTED (1'b0),
        .SRVAL          (1'b0)
    ) u_oddre1_clkfwd (
        .Q  (clk_fwd),
        .C  (clk_hp_global),
        .D1 (1'b1),
        .D2 (1'b0),
        .SR (1'b0)
    );
 
    // 3.4) Transmisor diferencial hacia HP
    OBUFDS #(
        .IOSTANDARD ("LVDS")
    ) u_obufds_hp (
        .I  (clk_fwd),
        .O  (refclk_hp_out_p),
        .OB (refclk_hp_out_n)
    );
 
    //--------------------------------------------------------------------------
    // 4) Refclk MGT 148.5 re-entrante (AG12/AG11) -> gtrefclk00
    //--------------------------------------------------------------------------
    wire refclk_148_5;
 
    IBUFDS_GTE4 #(
        .REFCLK_EN_TX_PATH  (1'b0),
        .REFCLK_HROW_CK_SEL (2'b00),
        .REFCLK_ICNTL_RX    (2'b00)
    ) u_ibufds_gte4_refclk (
        .I     (refclk_148_5_p),
        .IB    (refclk_148_5_n),
        .CEB   (1'b0),
        .O     (refclk_148_5),
        .ODIV2 ()
    );

    //--------------------------------------------------------------------------
    // 5) Reset sync
    //--------------------------------------------------------------------------
    reg [3:0] rst_sync = 4'b0000;
    always @(posedge clk_freerun_100m or negedge sys_rst_n) begin
        if (!sys_rst_n) rst_sync <= 4'b0000;
        else            rst_sync <= {rst_sync[2:0], 1'b1};
    end
    wire sys_rst_n_sync = rst_sync[3];

    //--------------------------------------------------------------------------
    // 6) Patron TX + RX decodificador (full-duplex)
    //--------------------------------------------------------------------------
    wire tx_ready, rx_locked, gth_qpll0_lock;
    wire [1:0] gth_powergood;

    sdi_3g_a_tx_pattern u_pattern (
        .clk_freerun_100m       (clk_freerun_100m),
        .refclk_148_5           (refclk_148_5),
        .sys_rst_n              (sys_rst_n_sync),
        .gs12190_u3_lock        (gs12190_u3_lock),
        .gs12190_u3_los         (gs12190_u3_los),
        .gs12190_u8_lock        (gs12190_u8_lock),
        .gs12190_u8_los         (gs12190_u8_los),
        .gth_rx_p               (gth_rx_p),
        .gth_rx_n               (gth_rx_n),
        .gth_tx_p               (gth_tx_p),
        .gth_tx_n               (gth_tx_n),
        .tx_ready               (tx_ready),
        .gth_qpll0_lock         (gth_qpll0_lock),
        .gth_powergood          (gth_powergood),
        .tx_selfcheck_locked_o  (rx_locked),     // <- el lock del RX va al wire rx_locked
        .tx_usrclk_o            ()
    );

    //--------------------------------------------------------------------------
    // 7) LEDs (active-LOW)
    //--------------------------------------------------------------------------
    assign led_qpll0_lock                 = ~gth_qpll0_lock;
    assign led_tx_ready                   = ~tx_ready;
    assign led_rx_locked                  = ~rx_locked;   // 1 = RX engancha la trama
    assign led_fifo_overflow_or_underflow = 1'b1;

    //--------------------------------------------------------------------------
    // 8) GS12190 U3 (TX driver, J2)
    //--------------------------------------------------------------------------
    assign gs12190_u3_sleep_n   = 1'b0;   // despierto
    assign gs12190_u3_direction = 1'b1;   // cable driver (TX)
    assign gs12190_u3_sclk      = 1'b0;
    assign gs12190_u3_sdin      = 1'b0;
    assign gs12190_u3_cs_n      = 1'b1;   // GSPI deseleccionado

    //--------------------------------------------------------------------------
    // 9) GS12190 U8 (RX equalizer, J3)
    //--------------------------------------------------------------------------
    assign gs12190_u8_sleep_n   = 1'b0;   // despierto
    assign gs12190_u8_direction = 1'b0;   // cable equalizer (RX)
    assign gs12190_u8_sclk      = 1'b0;
    assign gs12190_u8_sdin      = 1'b0;
    assign gs12190_u8_cs_n      = 1'b1;   // GSPI deseleccionado

endmodule