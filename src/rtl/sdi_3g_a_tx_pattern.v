//==============================================================================
// sdi_3g_a_tx_pattern.v   --   TEST TX-to-RX (loopback fisico J2 -> J3)
//
//   TX: generador patron (CON TRS + geometria vertical) -> core SDI TX
//       -> GTH X0Y13 -> U3 -> J2
//   RX: J3 -> U8 -> GTH X0Y14 -> core SDI RX -> decodifica -> ILA
//
//   NIVEL 2 de inyeccion de TRS: ademas de los EAV/SAV, se genera la GEOMETRIA
//   VERTICAL 1080p60 (SMPTE 274M): video activo en lineas 42..1121 (V=0), resto
//   blanking vertical (V=1). El EAV ANTICIPA el V de la linea siguiente; el SAV
//   lleva el V de la linea actual (observado en la senal real de la BlackMagic).
//
//   PATRON: localparam PATTERN_MODE  ->  0 = gris | 1 = rojo  (ambos validados
//   en hardware; el MD-LX los muestra). El croma usa 4:2:2 alternando Cb/Cr.
//==============================================================================

module sdi_3g_a_tx_pattern (
    input  wire        clk_freerun_100m,
    input  wire        refclk_148_5,
    input  wire        sys_rst_n,

    input  wire        gs12190_u3_lock,
    input  wire        gs12190_u3_los,
    input  wire        gs12190_u8_lock,
    input  wire        gs12190_u8_los,

    input  wire        gth_rx_p, gth_rx_n,   // J3 (RX)
    output wire        gth_tx_p, gth_tx_n,   // J2 (TX)

    output wire        tx_ready,
    output wire        gth_qpll0_lock,
    output wire [1:0]  gth_powergood,

    output wire        tx_selfcheck_locked_o,  // 1 = el RX engancha la trama del loopback

    output wire        tx_usrclk_o
);

    //--------------------------------------------------------------------------
    // 1) Senales del Wizard
    //--------------------------------------------------------------------------
    wire [39:0] gtwiz_userdata_tx;
    wire [39:0] gtwiz_userdata_rx;
    wire        tx_clk_int, rx_clk_int;
    wire        tx_active, rx_active;
    wire        gt_tx_done, gt_rx_done;

    // TX: lane [0] del par
    wire [1:0] gth_txp_bus, gth_txn_bus;
    assign gth_tx_p = gth_txp_bus[0];
    assign gth_tx_n = gth_txn_bus[0];

    // RX: pines fisicos reales (J3) -> lane [0]
    wire [1:0] gth_rxp_bus = {gth_rx_p, 1'b0};
    wire [1:0] gth_rxn_bus = {gth_rx_n, 1'b0};

    // Mapeo validado: TX -> [19:0]  |  RX -> [39:20]
    wire [19:0] sdi_tx_data;
    assign gtwiz_userdata_tx[19:0]  = sdi_tx_data;
    assign gtwiz_userdata_tx[39:20] = 20'b0;

    wire [19:0] sdi_rx_datain;
    assign sdi_rx_datain = gtwiz_userdata_rx[39:20];

    wire sdi_tx_rst = ~(gt_tx_done & tx_active);
    wire sdi_rx_rst = ~(gt_rx_done & rx_active);

    assign tx_usrclk_o = tx_clk_int;
    assign tx_ready    = gt_tx_done & tx_active;

    wire tx_selfcheck_locked;
    assign tx_selfcheck_locked_o = tx_selfcheck_locked;

    //--------------------------------------------------------------------------
    //  PATRON A EMITIR:  0 = gris | 1 = rojo
    //  (ambos validados en hardware: el MD-LX los muestra en pantalla)
    //--------------------------------------------------------------------------
    localparam PATTERN_MODE = 1;            // 0 = gris, 1 = rojo

    // Niveles de blanking (validos para cualquier patron)
    localparam [9:0] BLANK_Y   = 10'h040;   // luma en blanking
    localparam [9:0] BLANK_C   = 10'h200;   // croma en blanking

    // --- Gris (color plano, Cb=Cr=neutro) ---
    localparam [9:0] GRAY_Y    = 10'h2D0;
    localparam [9:0] GRAY_CB   = 10'h200;
    localparam [9:0] GRAY_CR   = 10'h200;

    // --- Rojo (10-bit, aprox; Cb bajo, Cr alto) ---
    localparam [9:0] RED_Y     = 10'h110;
    localparam [9:0] RED_CB    = 10'h066;
    localparam [9:0] RED_CR    = 10'h340;

    // Componentes del patron activo seleccionado por PATTERN_MODE
    localparam [9:0] ACT_Y  = (PATTERN_MODE == 0) ? GRAY_Y  : RED_Y;
    localparam [9:0] ACT_CB = (PATTERN_MODE == 0) ? GRAY_CB : RED_CB;
    localparam [9:0] ACT_CR = (PATTERN_MODE == 0) ? GRAY_CR : RED_CR;

    // Palabras del TRS
    localparam [9:0] TRS_3FF   = 10'h3FF;
    localparam [9:0] TRS_000   = 10'h000;
    // XYZ segun estado de linea (F=0 progresivo):
    localparam [9:0] XYZ_SAV_A = 10'h200;   // SAV activa          (V=0,H=0)
    localparam [9:0] XYZ_EAV_A = 10'h274;   // EAV activa          (V=0,H=1)
    localparam [9:0] XYZ_SAV_V = 10'h2AC;   // SAV blanking vert.  (V=1,H=0)
    localparam [9:0] XYZ_EAV_V = 10'h2D8;   // EAV blanking vert.  (V=1,H=1)

    // Geometria vertical 1080p (SMPTE 274M): video activo en lineas 42..1121,
    // resto (1..41 y 1122..1125) es blanking vertical (V=1).
    localparam [10:0] ACT_FIRST = 11'd42;
    localparam [10:0] ACT_LAST  = 11'd1121;

    //--------------------------------------------------------------------------
    // 2) Generador de raster 1080p60 3G-A: 1125 lineas x 2200 muestras
    //--------------------------------------------------------------------------
    //   Estructura horizontal por linea (px = 0..2199):
    //     px 0..3       : EAV  = 3FF 000 000 XYZ_eav  (anticipa linea siguiente)
    //     px 4..275     : blanking horizontal (272 muestras) -> LN/CRC/VPID
    //     px 276..279   : SAV  = 3FF 000 000 XYZ_sav  (linea actual)
    //     px 280..2199  : video activo / blanking de la linea (1920 muestras)
    //--------------------------------------------------------------------------
    reg  [11:0] px   = 12'd0;     // 0..2199
    reg  [10:0] line = 11'd1;     // 1..1125

    always @(posedge tx_clk_int) begin
        if (sdi_tx_rst) begin
            px   <= 12'd0;
            line <= 11'd1;
        end else begin
            if (px == 12'd2199) begin
                px   <= 12'd0;
                line <= (line == 11'd1125) ? 11'd1 : (line + 1'b1);
            end else begin
                px <= px + 1'b1;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 3) Construccion del stream con TRS y geometria vertical (Nivel 2)
    //--------------------------------------------------------------------------
    //   - El SAV lleva el V de la LINEA ACTUAL.
    //   - El EAV ANTICIPA: lleva el V de la LINEA SIGUIENTE.
    //   - En lineas de blanking vertical el "video" es nivel de blanking.
    //--------------------------------------------------------------------------

    //--------------------------------------------------------------------------
    //  GEOMETRIA VERTICAL: decidir si cada linea es video activo o blanking
    //  vertical, y elegir el XYZ y el contenido en consecuencia.
    //
    //  En 1080p60 (SMPTE 274M) el frame tiene 1125 lineas:
    //    - lineas 42..1121  -> VIDEO ACTIVO     (V=0)  : aqui va la imagen
    //    - lineas 1..41 y 1122..1125 -> BLANKING VERTICAL (V=1) : sin imagen
    //  El bit V del XYZ del TRS marca esa diferencia (V=0 activa, V=1 blanking).
    //--------------------------------------------------------------------------

    // ¿La linea ACTUAL es video activo? -> 1 si esta en el rango 42..1121.
    //   Se usa para el SAV (que pertenece a la linea actual) y para el contenido
    //   de video de la linea.
    wire line_active_now  = (line >= ACT_FIRST) && (line <= ACT_LAST);

    // Numero de la linea SIGUIENTE (con wrap: despues de la 1125 viene la 1).
    //   Lo necesitamos porque el EAV ANTICIPA: el EAV que cierra una linea ya
    //   lleva el bit V de la linea que viene a continuacion (comportamiento
    //   observado en la senal real de la BlackMagic: el EAV de la linea 1121,
    //   ultima activa, ya marca V=1 porque la 1122 es blanking vertical).
    wire [10:0] line_next = (line == 11'd1125) ? 11'd1 : (line + 1'b1);

    // ¿La linea SIGUIENTE es video activo? -> se usa para el EAV (anticipado).
    wire line_active_next = (line_next >= ACT_FIRST) && (line_next <= ACT_LAST);

    // XYZ a insertar en cada TRS:
    //   - SAV: usa el estado de la linea ACTUAL  (no anticipa).
    //          activa -> 0x200 ; blanking vertical -> 0x2AC.
    //   - EAV: usa el estado de la linea SIGUIENTE (anticipa).
    //          activa -> 0x274 ; blanking vertical -> 0x2D8.
    wire [9:0] xyz_sav = line_active_now  ? XYZ_SAV_A : XYZ_SAV_V;
    wire [9:0] xyz_eav = line_active_next ? XYZ_EAV_A : XYZ_EAV_V;

    // Contenido de video de la zona activa de la linea:
    //   - Y: el luma del patron si la linea es activa, blanking si no.
    //   - C: croma 4:2:2 -> alterna Cb (px par) y Cr (px impar). px[0] da la
    //        paridad de la muestra. En blanking vertical va nivel de blanking.
    //   (con el gris Cb=Cr=0x200, asi que la alternancia no se nota; con el
    //    rojo Cb!=Cr y px[0] reparte cada croma en su muestra.)
    wire [9:0] vid_y = line_active_now ? ACT_Y : BLANK_Y;
    wire [9:0] vid_c = line_active_now ? (px[0] ? ACT_CR : ACT_CB) : BLANK_C;

    reg [9:0] vy, vc;   // video Y / C a entregar al core

    always @(*) begin
        // --- EAV: px 0..3  (XYZ anticipa la linea siguiente) ---
        if      (px == 12'd0) begin vy = TRS_3FF; vc = TRS_3FF; end
        else if (px == 12'd1) begin vy = TRS_000; vc = TRS_000; end
        else if (px == 12'd2) begin vy = TRS_000; vc = TRS_000; end
        else if (px == 12'd3) begin vy = xyz_eav; vc = xyz_eav; end

        // --- blanking horizontal: px 4..275 ---
        else if (px <= 12'd275) begin vy = BLANK_Y; vc = BLANK_C; end

        // --- SAV: px 276..279  (XYZ de la linea actual) ---
        else if (px == 12'd276) begin vy = TRS_3FF; vc = TRS_3FF; end
        else if (px == 12'd277) begin vy = TRS_000; vc = TRS_000; end
        else if (px == 12'd278) begin vy = TRS_000; vc = TRS_000; end
        else if (px == 12'd279) begin vy = xyz_sav; vc = xyz_sav; end

        // --- video activo / blanking de la linea: px 280..2199 ---
        else begin vy = vid_y; vc = vid_c; end
    end

    wire [9:0] tx_video_y = vy;
    wire [9:0] tx_video_c = vc;

    // SALIDAS del core (data streams con VPID/CRC/LN insertados, sin scramblear).
    wire [9:0] tx_ds1a_out;
    wire [9:0] tx_ds2a_out;

    // Salidas del RX decodificador (dominio rx_clk_int) - para ILA
    wire [9:0]  rx_ds1a_out;
    wire [9:0]  rx_ds2a_out;
    wire [10:0] rx_a_line;
    wire        rx_crc_err_a;
    wire [31:0] rx_a_vpid;
    wire        rx_a_vpid_valid;
    wire        rx_eav;
    wire        rx_sav;
    wire        rx_trs;

    //--------------------------------------------------------------------------
    // 5) GTH Wizard (TX + RX activos, pines reales)
    //--------------------------------------------------------------------------
    gtwizard_ultrascale_0 u_gtwiz (
        .gtwiz_userclk_tx_reset_in         (1'b0),
        .gtwiz_userclk_tx_srcclk_out       (),
        .gtwiz_userclk_tx_usrclk_out       (),
        .gtwiz_userclk_tx_usrclk2_out      (tx_clk_int),
        .gtwiz_userclk_tx_active_out       (tx_active),
        .gtwiz_userclk_rx_reset_in         (1'b0),
        .gtwiz_userclk_rx_srcclk_out       (),
        .gtwiz_userclk_rx_usrclk_out       (),
        .gtwiz_userclk_rx_usrclk2_out      (rx_clk_int),
        .gtwiz_userclk_rx_active_out       (rx_active),
        .gtwiz_reset_clk_freerun_in        (clk_freerun_100m),
        .gtwiz_reset_all_in                (~sys_rst_n),
        .gtwiz_reset_tx_pll_and_datapath_in(1'b0),
        .gtwiz_reset_tx_datapath_in        (1'b0),
        .gtwiz_reset_rx_pll_and_datapath_in(1'b0),
        .gtwiz_reset_rx_datapath_in        (1'b0),
        .gtwiz_reset_rx_cdr_stable_out     (),
        .gtwiz_reset_tx_done_out           (gt_tx_done),
        .gtwiz_reset_rx_done_out           (gt_rx_done),
        .gtwiz_userdata_tx_in              (gtwiz_userdata_tx),
        .gtwiz_userdata_rx_out             (gtwiz_userdata_rx),
        .gtrefclk00_in                     (refclk_148_5),
        .qpll0lock_out                     (gth_qpll0_lock),
        .qpll0outclk_out                   (),
        .qpll0outrefclk_out                (),
        .gthrxn_in                         (gth_rxn_bus),
        .gthrxp_in                         (gth_rxp_bus),
        .gthtxn_out                        (gth_txn_bus),
        .gthtxp_out                        (gth_txp_bus),
        .txpolarity_in                     (2'b00),
        .txdiffctrl_in                     (10'b11000_11000),
        .txpostcursor_in                   (10'b00000_00000),
        .txprecursor_in                    (10'b00000_00000),
        .rxpolarity_in                     (2'b00),
        .rxlpmen_in                        (2'b11),
        .rxcdrhold_in                      (2'b00),
        .loopback_in                       (6'b000_000),
        .txprbssel_in                      (8'h00),
        .txprbsforceerr_in                 (2'b00),
        .rxprbssel_in                      (8'h00),
        .rxprbscntreset_in                 (2'b00),
        .rxprbserr_out                     (),
        .eyescanreset_in                   (2'b00),
        .eyescantrigger_in                 (2'b00),
        .eyescandataerror_out              (),
        .gtpowergood_out                   (gth_powergood),
        .rxbufstatus_out                   (),
        .txbufstatus_out                   (),
        .rxpmaresetdone_out                (),
        .txpmaresetdone_out                (),
        .rxresetdone_out                   (),
        .txresetdone_out                   (),
        .rxsyncdone_out                    ()
    );

    //--------------------------------------------------------------------------
    // 6) SDI core v3.0 -- generacion TX
    //--------------------------------------------------------------------------
    v_smpte_sdi_v3_0_14 #(
        .INCLUDE_RX_EDH_PROCESSOR ("FALSE"),
        .C_FAMILY                 ("virtex7")
    ) u_sdi (
        // RX no usado en este core (se usa el de la seccion 6b)
        .rx_rst                (1'b1),
        .rx_usrclk             (tx_clk_int),
        .rx_data_in            (10'b0),
        .rx_sd_data_in         (10'b0),
        .rx_sd_data_strobe     (1'b0),
        .rx_frame_en           (1'b0),
        .rx_mode_en            (3'b000),
        .rx_mode_detect_en     (1'b0),
        .rx_forced_mode        (2'b10),
        .rx_bit_rate           (1'b0),
        .rx_mode               (),
        .rx_mode_hd            (),
        .rx_mode_sd            (),
        .rx_mode_3g            (),
        .rx_mode_locked        (),
        .rx_t_locked           (),
        .rx_t_family           (),
        .rx_t_rate             (),
        .rx_t_scan             (),
        .rx_level_b_3g         (),
        .rx_ce_sd              (),
        .rx_nsp                (),
        .rx_line_a             (),
        .rx_a_vpid             (),
        .rx_a_vpid_valid       (),
        .rx_b_vpid             (),
        .rx_b_vpid_valid       (),
        .rx_crc_err_a          (),
        .rx_ds1a               (),
        .rx_ds2a               (),
        .rx_eav                (),
        .rx_sav                (),
        .rx_trs                (),
        .rx_line_b             (),
        .rx_dout_rdy_3g        (),
        .rx_crc_err_b          (),
        .rx_ds1b               (),
        .rx_ds2b               (),
        .rx_edh_errcnt_en      (16'b0),
        .rx_edh_clr_errcnt     (1'b0),
        .rx_edh_ap             (),
        .rx_edh_ff             (),
        .rx_edh_anc            (),
        .rx_edh_ap_flags       (),
        .rx_edh_ff_flags       (),
        .rx_edh_anc_flags      (),
        .rx_edh_packet_flags   (),
        .rx_edh_errcnt         (),

        // === TX: generacion ===
        .tx_rst                (sdi_tx_rst),
        .tx_usrclk             (tx_clk_int),
        .tx_ce                 (3'b111),
        .tx_din_rdy            (1'b1),
        .tx_mode               (2'b10),       // 3G
        .tx_level_b_3g         (1'b0),        // Level A
        .tx_insert_crc         (1'b1),
        .tx_insert_ln          (1'b1),
        .tx_insert_edh         (1'b0),
        .tx_insert_vpid        (1'b1),
        .tx_overwrite_vpid     (1'b1),
        .tx_video_a_y_in       (tx_video_y),
        .tx_video_a_c_in       (tx_video_c),
        .tx_video_b_y_in       (10'b0),
        .tx_video_b_c_in       (10'b0),
        .tx_line_a             (line),
        .tx_line_b             (11'b0),
        .tx_vpid_byte1         (8'h89),
        .tx_vpid_byte2         (8'hCB),
        .tx_vpid_byte3         (8'h80),
        .tx_vpid_byte4a        (8'h01),
        .tx_vpid_byte4b        (8'h00),
        .tx_vpid_line_f1       (11'd10),
        .tx_vpid_line_f2       (11'b0),
        .tx_vpid_line_f2_en    (1'b0),
        .tx_ds1a_out           (tx_ds1a_out),
        .tx_ds2a_out           (tx_ds2a_out),
        .tx_ds1b_out           (),
        .tx_ds2b_out           (),
        .tx_use_dsin           (1'b0),
        .tx_ds1a_in            (10'b0),
        .tx_ds2a_in            (10'b0),
        .tx_ds1b_in            (10'b0),
        .tx_ds2b_in            (10'b0),
        .tx_sd_bitrep_bypass   (1'b1),
        .tx_txdata             (sdi_tx_data),
        .tx_ce_align_err       ()
    );

    //--------------------------------------------------------------------------
    // 6b) Core SDI RX -- decodifica lo que vuelve por J3 (dominio rx_clk_int)
    //--------------------------------------------------------------------------
    v_smpte_sdi_v3_0_14 #(
        .INCLUDE_RX_EDH_PROCESSOR ("FALSE"),
        .C_FAMILY                 ("virtex7")
    ) u_sdi_rx (
        .rx_rst                (sdi_rx_rst),
        .rx_usrclk             (rx_clk_int),
        .rx_data_in            (sdi_rx_datain),   // lo que vuelve por J3 (loopback)
        .rx_sd_data_in         (10'b0),
        .rx_sd_data_strobe     (1'b0),
        .rx_frame_en           (1'b1),
        .rx_mode_en            (3'b100),
        .rx_mode_detect_en     (1'b0),
        .rx_forced_mode        (2'b10),
        .rx_bit_rate           (1'b0),
        .rx_mode               (),
        .rx_mode_hd            (),
        .rx_mode_sd            (),
        .rx_mode_3g            (),
        .rx_mode_locked        (tx_selfcheck_locked),
        .rx_t_locked           (),
        .rx_t_family           (),
        .rx_t_rate             (),
        .rx_t_scan             (),
        .rx_level_b_3g         (),
        .rx_ce_sd              (),
        .rx_nsp                (),
        .rx_line_a             (rx_a_line),
        .rx_a_vpid             (rx_a_vpid),
        .rx_a_vpid_valid       (rx_a_vpid_valid),
        .rx_b_vpid             (),
        .rx_b_vpid_valid       (),
        .rx_crc_err_a          (rx_crc_err_a),
        .rx_ds1a               (rx_ds1a_out),
        .rx_ds2a               (rx_ds2a_out),
        .rx_eav                (rx_eav),
        .rx_sav                (rx_sav),
        .rx_trs                (rx_trs),
        .rx_line_b             (),
        .rx_dout_rdy_3g        (),
        .rx_crc_err_b          (),
        .rx_ds1b               (),
        .rx_ds2b               (),
        .rx_edh_errcnt_en      (16'b0),
        .rx_edh_clr_errcnt     (1'b0),
        .rx_edh_ap             (),
        .rx_edh_ff             (),
        .rx_edh_anc            (),
        .rx_edh_ap_flags       (),
        .rx_edh_ff_flags       (),
        .rx_edh_anc_flags      (),
        .rx_edh_packet_flags   (),
        .rx_edh_errcnt         (),
        // TX del core: no usado
        .tx_rst                (1'b1),
        .tx_usrclk             (rx_clk_int),
        .tx_ce                 (3'b000),
        .tx_din_rdy            (1'b0),
        .tx_mode               (2'b10),
        .tx_level_b_3g         (1'b0),
        .tx_insert_crc         (1'b0),
        .tx_insert_ln          (1'b0),
        .tx_insert_edh         (1'b0),
        .tx_insert_vpid        (1'b0),
        .tx_overwrite_vpid     (1'b0),
        .tx_video_a_y_in       (10'b0),
        .tx_video_a_c_in       (10'b0),
        .tx_video_b_y_in       (10'b0),
        .tx_video_b_c_in       (10'b0),
        .tx_line_a             (11'b0),
        .tx_line_b             (11'b0),
        .tx_vpid_byte1         (8'h00),
        .tx_vpid_byte2         (8'h00),
        .tx_vpid_byte3         (8'h00),
        .tx_vpid_byte4a        (8'h00),
        .tx_vpid_byte4b        (8'h00),
        .tx_vpid_line_f1       (11'b0),
        .tx_vpid_line_f2       (11'b0),
        .tx_vpid_line_f2_en    (1'b0),
        .tx_ds1a_out           (),
        .tx_ds2a_out           (),
        .tx_ds1b_out           (),
        .tx_ds2b_out           (),
        .tx_use_dsin           (1'b0),
        .tx_ds1a_in            (10'b0),
        .tx_ds2a_in            (10'b0),
        .tx_ds1b_in            (10'b0),
        .tx_ds2b_in            (10'b0),
        .tx_sd_bitrep_bypass   (1'b1),
        .tx_txdata             (),
        .tx_ce_align_err       ()
    );

    //--------------------------------------------------------------------------
    // 7) ILA  (clk = rx_clk_int)  -- 24 probes
    //--------------------------------------------------------------------------
    // NIVEL 2: comprobar la geometria vertical:
    //   - probe13 (rx_a_line): el line number que decodifica el RX.
    //   - probe11/12 (rx_ds1a/2a): en el EAV/SAV veras el XYZ. Triggea en una
    //     linea activa (p.ej. 100) -> EAV=0x274/SAV=0x200; en blanking vertical
    //     (p.ej. 10) -> EAV=0x2D8/SAV=0x2AC; en la 1121 -> EAV=0x2D8 (anticipa).
    //   - probe8 (rx_a_vpid_valid) y probe17 (rx_a_vpid): VPID.
    ila_0 GILA (
        .clk(rx_clk_int),
        .probe0 (gth_qpll0_lock),     // 1
        .probe1 (tx_ready),           // 1
        .probe2 (gt_tx_done),         // 1
        .probe3 (tx_active),          // 1
        .probe4 (tx_selfcheck_locked),// 1   RX engancha?
        .probe5 (gt_rx_done),         // 1
        .probe6 (rx_active),          // 1
        .probe7 (rx_crc_err_a),       // 1   errores CRC?
        .probe8 (rx_a_vpid_valid),    // 1   VPID validado?
        .probe9 (gs12190_u8_lock),    // 1
        .probe10(gs12190_u8_los),     // 1
        .probe11(rx_ds1a_out),        // 10  Y recuperado por el RX
        .probe12(rx_ds2a_out),        // 10  C recuperado por el RX
        .probe13(rx_a_line),          // 11  line number decodificado por el RX
        .probe14(rx_eav),             // 1   EAV detectado por el RX
        .probe15(rx_sav),             // 1   SAV detectado por el RX
        .probe16(rx_trs),             // 1   TRS detectado por el RX
        .probe17(rx_a_vpid),          // 32  VPID recuperado
        .probe18(sdi_rx_datain),      // 20  palabra cruda RX del GT
        .probe19(tx_video_y),         // 10  ENTRADA Y al core (con TRS+geom)
        .probe20(tx_video_c),         // 10  ENTRADA C al core (con TRS+geom)
        .probe21(tx_ds1a_out),        // 10  SALIDA DS1 del core
        .probe22(tx_ds2a_out),        // 10  SALIDA DS2 del core
        .probe23(line)                // 11  numero de linea (TX)
    );

endmodule