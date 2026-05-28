//==============================================================================
// sdi_3g_a_top.v
//
// Top-level del FPGA xku15p-ffve1517-2-i en placa ALINX AXKU15 + FMC FH1219.
//
// Topologia de reloj (validada en bring-up):
//   Oscilador 148.5 MHz --> HP (E23/E24) --> IBUFDS --> BUFG --> ODDRE1
//        --> OBUFDS --> HP (E28/E29) --> [condensador AC en SDI board]
//        --> AG12/AG11 (MGT226_CLK0) --> IBUFDS_GTE4 --> gtrefclk00 del QPLL0
//
//   El GT Wizard esta configurado con REFCLK source = "MGTREFCLK0 of Quad
//   X0Y2 (-1)" (mecanismo GTSOUTHREFCLK), porque los canales estan en el
//   Quad X0Y3 (Bank 227) y el refclk re-entra por el Quad X0Y2 (Bank 226).
//
// Aloja los buffers de pad (IBUFDS_GTE4 para refclk MGT, IBUFDS+BUFGCE_DIV
// para el oscilador de sistema, y la cadena de clock-forwarding del puente)
// e instancia el wrapper de logica SDI.
//==============================================================================

module sdi_3g_a_top (
    // === Oscilador de sistema (200 MHz LVDS desde el SOM ACKU15, AR32/AT32) ===
    input  wire        sys_clk_200m_p,
    input  wire        sys_clk_200m_n,

    // === Reset fisico (pulsador KEY1 del AXKU15, activo bajo, A8) ===
    input  wire        sys_rst_n,

    // === Puente de reloj 148.5 MHz: ENTRADA por pines HP (FMC1_LA00_CC, E23/E24) ===
    input  wire        refclk_hp_in_p,     // E23
    input  wire        refclk_hp_in_n,     // E24

    // === Puente de reloj 148.5 MHz: SALIDA por pines HP (FMC1_LA17_CC, E28/E29) ===
    output wire        refclk_hp_out_p,    // E28
    output wire        refclk_hp_out_n,    // E29

    // === Refclk 148.5 MHz re-entrante por pines MGT (FMC1_HPC_GBTCLK0, AG12/AG11) ===
    input  wire        refclk_148_5_p,     // AG12 (MGT226_CLK0, Quad X0Y2)
    input  wire        refclk_148_5_n,     // AG11 (MGT226_CLK0, Quad X0Y2)

    // === Pares MGT serie hacia GS12190 (FH1219) ===
    input  wire        gth_rx_p,           // X0Y14 RX = AE4
    input  wire        gth_rx_n,           // X0Y14 RX = AE3
    output wire        gth_tx_p,           // X0Y13 TX = AF6
    output wire        gth_tx_n,           // X0Y13 TX = AF5

    // === Status LEDs (banco 91 HD a 3.3V, active-LOW) ===
    output wire        led_qpll0_lock,
    output wire        led_tx_ready,
    output wire        led_rx_locked,
    output wire        led_fifo_overflow_or_underflow,

    // === Control del GS12190 U3 (TX driver, BNC J2) ===
    output wire        gs12190_u3_sleep_n,    // Pin H27, GPIO2 del U3
    output wire        gs12190_u3_direction,  // Pin J27, GPIO3 del U3
    output wire        gs12190_u3_sclk,       // GSPI clock)
    output wire        gs12190_u3_sdin,       // GSPI data in)
    output wire        gs12190_u3_cs_n,       // Chip select GSPI
    input  wire        gs12190_u3_sdout,      // GSPI data out (no usado en modo pin)
    input  wire        gs12190_u3_lock,       // Status de lock del chip
    input  wire        gs12190_u3_los         // Status de loss of signal)
    
);

    //--------------------------------------------------------------------------
    // 1) Buffer del oscilador de sistema 200 MHz (LVDS -> single-ended)
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
    // 2) Free-running 100 MHz (200 MHz / 2 mediante BUFGCE_DIV)
    //    Alimenta el reset controller del GT Wizard y la logica de status.
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
    // 3) PUENTE DE RELOJ 148.5 MHz (clock forwarding)
    //    El oscilador llega por pines HP (E23/E24); lo reenviamos por E28/E29
    //    hacia el condensador de la SDI board, que lo redirige a los pines MGT.
    //--------------------------------------------------------------------------

    // 3.1) Receptor diferencial del oscilador por HP
    wire clk_hp_ibuf;
    IBUFDS #(
        .IBUF_LOW_PWR ("FALSE"),
        .IOSTANDARD   ("LVDS")
    ) u_ibufds_hp (
        .I  (refclk_hp_in_p),    // E23
        .IB (refclk_hp_in_n),    // E24
        .O  (clk_hp_ibuf)
    );

    // 3.2) Buffer global (necesario para clockear el ODDRE1)
    wire clk_hp_global;
    BUFG u_bufg_hp (
        .I (clk_hp_ibuf),
        .O (clk_hp_global)
    );

    // 3.3) ODDRE1 para clock forwarding (D1=1, D2=0 reproduce la onda de C)
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

    // 3.4) Transmisor diferencial hacia los pines HP de salida
    OBUFDS #(
        .IOSTANDARD ("LVDS")
    ) u_obufds_hp (
        .I  (clk_fwd),
        .O  (refclk_hp_out_p),   // E28
        .OB (refclk_hp_out_n)    // E29
    );

    //--------------------------------------------------------------------------
    // 4) Receptor del refclk MGT 148.5 MHz re-entrante (AG12/AG11, Quad 226)
    //    Su salida .O alimenta gtrefclk00_in del GT Wizard (-> QPLL0).
    //--------------------------------------------------------------------------
    wire refclk_148_5;
    IBUFDS_GTE4 #(
        .REFCLK_EN_TX_PATH  (1'b0),
        .REFCLK_HROW_CK_SEL (2'b00),
        .REFCLK_ICNTL_RX    (2'b00)
    ) u_ibufds_gte4_refclk (
        .I     (refclk_148_5_p),   // AG12 (MGT226_CLK0)
        .IB    (refclk_148_5_n),   // AG11 (MGT226_CLK0)
        .CEB   (1'b0),
        .O     (refclk_148_5),     // -> gtrefclk00_in del Wizard
        .ODIV2 ()                  // no usado
    );

    //--------------------------------------------------------------------------
    // 5) Sincronizacion del reset al dominio freerun
    //    (async assert / sync de-assert, 4 etapas)
    //--------------------------------------------------------------------------
    reg [3:0] rst_sync = 4'b0000;
    always @(posedge clk_freerun_100m or negedge sys_rst_n) begin
        if (!sys_rst_n) rst_sync <= 4'b0000;
        else            rst_sync <= {rst_sync[2:0], 1'b1};
    end
    wire sys_rst_n_sync = rst_sync[3];

    //--------------------------------------------------------------------------
    // 6) Instancia del wrapper SDI fifo
    //--------------------------------------------------------------------------
    wire        fifo_overflow, fifo_underflow;
    wire        rx_locked, tx_ready, gth_qpll0_lock;
    wire [1:0]  gth_powergood;

    sdi_3g_a_wrapper_fifo u_sdi_wrapper_fifo (
        .clk_freerun_100m (clk_freerun_100m),
        .refclk_148_5     (refclk_148_5),
        .sys_rst_n        (sys_rst_n_sync),
        .gth_rx_p         (gth_rx_p),
        .gth_rx_n         (gth_rx_n),
        .gth_tx_p         (gth_tx_p),
        .gth_tx_n         (gth_tx_n),
        .rx_locked        (rx_locked),
        .tx_ready         (tx_ready),
        .gth_qpll0_lock   (gth_qpll0_lock),
        .gth_powergood    (gth_powergood),
        .fifo_overflow    (fifo_overflow),
        .fifo_underflow   (fifo_underflow),
        .tx_usrclk_o      (/* abierto, solo para debug */),
        .rx_usrclk_o      (/* idem */),
        .gs12190_u3_lock  (gs12190_u3_lock),
        .gs12190_u3_los   (gs12190_u3_los)  
    );

    //--------------------------------------------------------------------------
    // 7) LEDs de status (active-LOW; pulse stretchers para errores de FIFO)
    //--------------------------------------------------------------------------
    reg [24:0] ovfl_stretch  = 25'd0;
    reg [24:0] undfl_stretch = 25'd0;

    always @(posedge clk_freerun_100m) begin
        if (fifo_overflow)       ovfl_stretch  <= 25'h1FFFFFF;
        else if (|ovfl_stretch)  ovfl_stretch  <= ovfl_stretch  - 1'b1;

        if (fifo_underflow)      undfl_stretch <= 25'h1FFFFFF;
        else if (|undfl_stretch) undfl_stretch <= undfl_stretch - 1'b1;
    end

    // active-LOW: el pin a 0 enciende el LED
    assign led_qpll0_lock                 = ~gth_qpll0_lock;
    //assign led_tx_ready                   = ~tx_ready;
    //assign led_rx_locked                  = ~rx_locked;
    //assign led_fifo_overflow_or_underflow = ~((|ovfl_stretch) | (|undfl_stretch));
    

    //--------------------------------------------------------------------------
    // X) Configuración estática del GS12190 U3 (TX driver, J2)
    //--------------------------------------------------------------------------
    // Por defecto el chip arranca en Auto Sleep Mode y se duerme por LOS,
    // apagando el buffer de salida del cable driver. Lo despertamos manualmente
    // y lo ponemos en modo driver vía GPIO (control por pines, sin GSPI).
    //
    //   GPIO2 (pin 33, control SLEEP):  LOW  = despierto / HIGH = dormido
    //   GPIO3 (control DIRECCIÓN):      LOW  = equalizer / HIGH = driver
    //--------------------------------------------------------------------------
    assign gs12190_u3_sleep_n  = 1'b0;   // LOW = NO sleep (despierto)
    assign gs12190_u3_direction = 1'b1;  // HIGH = Cable Driver Mode (TX)   

    // GSPI desactivado (chip deseleccionado, no escuchar comandos)
    assign gs12190_u3_sclk = 1'b0;       // Clock idle
    assign gs12190_u3_sdin = 1'b0;       // Data idle
    assign gs12190_u3_cs_n = 1'b1;       // CS HIGH = chip DESELECCIONADO
    
    // SDOUT, LOCK, LOS son entradas - las puedes ignorar o conectar a LEDs/ILA
    // Si quieres ver el lock status, podrías hacer:
     assign led_fifo_overflow_or_underflow = ~gs12190_u3_lock;  //(active-low si te interesa monitorearlo)
    


endmodule