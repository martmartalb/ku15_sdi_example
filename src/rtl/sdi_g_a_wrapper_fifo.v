//==============================================================================
// sdi_3g_a_wrapper_fifo.v
//
// PASSTHROUGH LOOPBACK RX → TX (bring-up test)
//   J3 BNC (RX) → GS12190 → GTH X0Y14 → SDI core RX
//      └→ {rx_ds2a, rx_ds1a} → FIFO async → {tx_video_c_in, tx_video_y_in}
//          → SDI core TX → GTH X0Y13 → GS12190 → J2 BNC (TX)
//==============================================================================

module sdi_3g_a_wrapper_fifo (
    input  wire        clk_freerun_100m,
    input  wire        refclk_148_5,
    input  wire        sys_rst_n,
    
    input  wire        gth_rx_p, gth_rx_n,
    output wire        gth_tx_p, gth_tx_n,
    
    output wire        rx_locked,
    output wire        tx_ready,
    output wire        gth_qpll0_lock,
    output wire [1:0]  gth_powergood,
    output wire        fifo_overflow,
    output wire        fifo_underflow,
    
    output wire        tx_usrclk_o,
    output wire        rx_usrclk_o,
    
    input  wire        gs12190_u3_lock, 
    input  wire        gs12190_u3_los  
);

    //--------------------------------------------------------------------------
    // 1) Señales del Wizard
    //--------------------------------------------------------------------------
    wire [39:0] gtwiz_userdata_tx;
    wire [39:0] gtwiz_userdata_rx;
    wire        tx_clk_int, rx_clk_int;
    wire        tx_active, rx_active;
    wire        gt_tx_done, gt_rx_done;
    
    wire [1:0] gth_rxp_bus = {gth_rx_p, 1'b0};
    wire [1:0] gth_rxn_bus = {gth_rx_n, 1'b0};
    wire [1:0] gth_txp_bus, gth_txn_bus;
    assign gth_tx_p = gth_txp_bus[0];
    assign gth_tx_n = gth_txn_bus[0];
    
    wire [19:0] sdi_tx_data;
    wire [19:0] sdi_rx_data;
    assign gtwiz_userdata_tx[19:0]  = sdi_tx_data;
    assign gtwiz_userdata_tx[39:20] = 20'b0;
    assign sdi_rx_data              = gtwiz_userdata_rx[39:20];
    
    wire sdi_tx_rst = ~(gt_tx_done & tx_active);
    wire sdi_rx_rst = ~(gt_rx_done & rx_active);
    
    assign tx_usrclk_o = tx_clk_int;
    assign rx_usrclk_o = rx_clk_int;
    assign tx_ready    = gt_tx_done & tx_active;
    
    //--------------------------------------------------------------------------
    // 2) Video paths
    //--------------------------------------------------------------------------
    // Salida del SDI core RX (dominio rx_clk_int)
    wire [9:0]  rx_ds1a_rxdom;   // Y stream
    wire [9:0]  rx_ds2a_rxdom;   // C stream
    
    // Entrada al SDI core TX (dominio tx_clk_int, tras FIFO)
    wire [9:0]  tx_video_y_txdom;
    wire [9:0]  tx_video_c_txdom;
    
    // Línea TX generada localmente
    reg  [10:0] tx_line_counter = 11'd1;
    reg  [11:0] tx_pixel_counter = 12'd0;
    
    // Contador de línea libre (no sincronizado con RX, suficiente para bring-up)
    // 1080p60 3G-A Level A: 1125 líneas × 2200 píxeles por línea
    always @(posedge tx_clk_int) begin
        if (sdi_tx_rst) begin
            tx_line_counter  <= 11'd1;
            tx_pixel_counter <= 12'd0;
        end else begin
            if (tx_pixel_counter == 12'd2199) begin
                tx_pixel_counter <= 12'd0;
                if (tx_line_counter == 11'd1125)
                    tx_line_counter <= 11'd1;
                else
                    tx_line_counter <= tx_line_counter + 1'b1;
            end else begin
                tx_pixel_counter <= tx_pixel_counter + 1'b1;
            end
        end
    end
    
    //--------------------------------------------------------------------------
    // 3) FIFO asíncrono RX → TX (20 bits × 16 entradas)
    //--------------------------------------------------------------------------
    // Cruce de dominio entre rx_clk_int (recovered) y tx_clk_int (local).
    // Para bring-up, sin lógica de drop/repeat - overrun/underrun como flags.
    
    wire fifo_wr_en = ~sdi_rx_rst;  // escribir siempre que RX esté listo
    wire fifo_rd_en = ~sdi_tx_rst;  // leer siempre que TX esté listo
    wire fifo_full, fifo_empty;
    wire [19:0] fifo_din  = {rx_ds2a_rxdom, rx_ds1a_rxdom};
    wire [19:0] fifo_dout;
    
    // Si el FIFO está vacío, emite ceros (luminancia y croma neutros)
    assign tx_video_y_txdom = fifo_empty ? 10'h040 : fifo_dout[9:0];
    assign tx_video_c_txdom = fifo_empty ? 10'h200 : fifo_dout[19:10];
    
    assign fifo_overflow  = fifo_wr_en & fifo_full;
    assign fifo_underflow = fifo_rd_en & fifo_empty;
    
    // FIFO XPM async (Vivado primitive) - 16 entradas, FWFT mode
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE   ("distributed"),
        .FIFO_WRITE_DEPTH   (16),
        .WRITE_DATA_WIDTH   (20),
        .READ_DATA_WIDTH    (20),
        .READ_MODE          ("fwft"),
        .USE_ADV_FEATURES   ("0000")
    ) u_video_fifo (
        .wr_clk             (rx_clk_int),
        .wr_en              (fifo_wr_en & ~fifo_full),
        .din                (fifo_din),
        .full               (fifo_full),
        .rd_clk             (tx_clk_int),
        .rd_en              (fifo_rd_en & ~fifo_empty),
        .dout               (fifo_dout),
        .empty              (fifo_empty),
        .rst                (sdi_rx_rst),
        // tieoffs
        .injectsbiterr      (1'b0),
        .injectdbiterr      (1'b0),
        .sleep              (1'b0),
        .almost_empty       (),
        .almost_full        (),
        .data_valid         (),
        .dbiterr            (),
        .overflow           (),
        .prog_empty         (),
        .prog_full          (),
        .rd_data_count      (),
        .rd_rst_busy        (),
        .sbiterr            (),
        .underflow          (),
        .wr_ack             (),
        .wr_data_count      (),
        .wr_rst_busy        ()
    );
    
    //--------------------------------------------------------------------------
    // 4) GTH Wizard
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
    // 5) SDI core v3.0
    //--------------------------------------------------------------------------
    v_smpte_sdi_v3_0_14 #(
        .INCLUDE_RX_EDH_PROCESSOR ("FALSE"),
        .C_FAMILY                 ("virtex7")
    ) u_sdi (
        // === RX (J3 → wrapper) ===
        .rx_rst                (sdi_rx_rst),
        .rx_usrclk             (rx_clk_int),
        .rx_data_in            (sdi_rx_data),
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
        .rx_mode_locked        (rx_locked),
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
        .rx_ds1a               (rx_ds1a_rxdom),   // Y RX → FIFO
        .rx_ds2a               (rx_ds2a_rxdom),   // C RX → FIFO
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
        
        // === TX (wrapper → J2) ===
        .tx_rst                (sdi_tx_rst),
        .tx_usrclk             (tx_clk_int),
        .tx_ce                 (3'b111),
        .tx_din_rdy            (1'b1),
        .tx_mode               (2'b10),
        .tx_level_b_3g         (1'b0),
        .tx_insert_crc         (1'b1),
        .tx_insert_ln          (1'b1),
        .tx_insert_edh         (1'b0),
        .tx_insert_vpid        (1'b1),
        .tx_overwrite_vpid     (1'b1),
        .tx_video_a_y_in       (tx_video_y_txdom),  // ← desde FIFO
        .tx_video_a_c_in       (tx_video_c_txdom),  // ← desde FIFO
        .tx_video_b_y_in       (10'b0),
        .tx_video_b_c_in       (10'b0),
        .tx_line_a             (tx_line_counter),
        .tx_line_b             (11'b0),
        .tx_vpid_byte1         (8'h89),
        .tx_vpid_byte2         (8'h70),
        .tx_vpid_byte3         (8'hC9),
        .tx_vpid_byte4a        (8'h01),
        .tx_vpid_byte4b        (8'h00),
        .tx_vpid_line_f1       (11'd10),
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
        .tx_txdata             (sdi_tx_data),
        .tx_ce_align_err       ()
    );
    
    
    //ILA
    
    ila_0 GILA (
        .clk(clk_freerun_100m),              // Conecta aquí el reloj de muestreo de tu sistema
        .probe0(gth_qpll0_lock),        // 1 bit
        .probe1(gth_powergood),        // 2 bits: input [1:0]
        .probe2(tx_ready),        // 1 bit
        .probe3(rx_locked),        // 1 bit
        .probe4(gt_tx_done),        // 1 bit
        .probe5(gt_rx_done),        // 1 bit
        .probe6(gs12190_u3_lock),        // 1 bit
        .probe7(gs12190_u3_los),        // 1 bit
        .probe8(fifo_empty),        // 1 bit
        .probe9(fifo_full),        // 1 bit
        .probe10(fifo_overflow),      // 1 bit
        .probe11(fifo_underflow),      // 1 bit
        .probe12(gtwiz_userdata_tx),      // 40 bits: input [39:0]
        .probe13(tx_video_y_txdom),      // 10 bits: input [9:0]
        .probe14(tx_video_c_txdom)       // 10 bits: input [9:0]
    );      
 
    
endmodule