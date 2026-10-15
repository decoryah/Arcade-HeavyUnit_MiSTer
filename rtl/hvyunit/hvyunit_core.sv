// Heavy Unit (Kaneko/Taito 1988) board core -- milestone M1.
//
// Three Z80s, the Mermaid 8751, the three latches, every RAM and the YM2203,
// wired exactly as MAME's hvyunit.cpp maps them (docs/ARCHITECTURE.md sec. 2-4).
// No video generation yet: the sprite/BG/palette RAMs exist and are written by
// the CPUs, but nothing reads them out until M3.
//
// Clocking.  The core is clocked by `clk` and advances on two enables:
//   cen6  6 MHz  Z80 x3, the 8751 oscillator, the dot clock
//   cen3  3 MHz  YM2203
// The 8751 (jt8051) needs at least one idle clk between cen6 pulses, so clk
// must be >= 12 MHz.  YM_CLK_PER_CEN is clk / cen3 and sizes the YM2203 write
// stretch.
//
// ROM ports are asynchronous-read from the core's point of view (data may take
// one clk).  Hook them to BRAM or an SDRAM cache later; add wait states then.
module hvyunit_core #(
    parameter integer YM_CLK_PER_CEN = 4,
    parameter integer H_TOTAL  = 404,
    parameter integer V_TOTAL  = 256,
    parameter integer VBL_LINE = 240,
    parameter integer SPR_LINE = 64,
    parameter integer HS_START = 288,
    parameter integer HS_LEN   = 32,
    parameter integer VS_START = 248,
    parameter integer VS_LEN   = 3,
    // an alternative raster, chosen with raster_alt (taken at the start of a frame); the same as the main one
    // unless a top level asks for another
    parameter integer H_TOTAL_ALT  = 404,
    parameter integer V_TOTAL_ALT  = 256,
    parameter integer HS_START_ALT = 288,
    parameter integer VS_START_ALT = 248,
    parameter integer VIDEO    = 1          // 0 leaves the video block out (CPU-only benches)
) (
    input             clk,
    input             rst,              // synchronous, active high
    input             cen6,
    input             cen3,
    input             raster_alt,       // 1: the alternative raster (from the next frame)

    // program ROMs
    output     [16:0] main_rom_addr,    // 128 KB
    input      [ 7:0] main_rom_data,
    output     [15:0] sub_rom_addr,     //  64 KB
    input      [ 7:0] sub_rom_data,
    output     [15:0] snd_rom_addr,     //  64 KB
    input      [ 7:0] snd_rom_data,

    // Mermaid firmware download (0x0E00 bytes)
    input      [11:0] mcu_prog_addr,
    input      [ 7:0] mcu_prog_data,
    input             mcu_prog_we,

    // controls, active low as on the board
    input      [ 7:0] in0, in1, in2,
    input      [ 7:0] dsw1, dsw2,

    output     [ 1:0] coin_counter,
    output     [ 1:0] coin_lockout,

    output signed [15:0] snd,

    // tile ROM (512 KB region): random-access word client (level req, 1-clk ack)
    output            tile_req,
    output     [17:0] tile_addr,        // word address
    input             tile_ack,
    input      [15:0] tile_q,           // valid in the clock of tile_ack

    // sprite ROM (2 MB region): burst client, 64 words per request
    output            spr_b_req,
    output     [19:0] spr_b_addr,       // word address of the first word
    input             spr_b_wr,
    input      [ 5:0] spr_b_idx,
    input      [15:0] spr_b_data,
    input             spr_b_done,

    // picture, one pixel per cen_pix
    output     [23:0] rgb,
    output            hsync,
    output            vsync,
    output            hblank,
    output            vblank,
    output            de,
    output            cen_pix,

    output            spr_busy,
    output            spr_overrun,
    output     [ 9:0] spr_count,

    // raster position (6 MHz dot enable)
    output     [ 8:0] hcnt,
    output     [ 8:0] vcnt,
    output            vbl_start,
    output            raster_alt_q      // the raster in force
);

    // =====================================================================
    // Raster
    // =====================================================================
    wire spr_irq;

    hvyunit_timing #(
        .H_TOTAL ( H_TOTAL ), .V_TOTAL ( V_TOTAL ),
        .VBL_LINE( VBL_LINE ), .SPR_LINE( SPR_LINE ),
        .H_TOTAL_ALT( H_TOTAL_ALT ), .V_TOTAL_ALT( V_TOTAL_ALT )
    ) u_timing (
        .clk ( clk ), .rst ( rst ), .cen ( cen6 ),
        .alt ( raster_alt ), .alt_q ( raster_alt_q ),
        .hcnt( hcnt ), .vcnt( vcnt ),
        .vbl_start( vbl_start ), .spr_irq( spr_irq )
    );

    // =====================================================================
    // CPU bus signals
    // =====================================================================
    wire [15:0] ma, sa, za;                 // addresses
    wire [ 7:0] m_do, s_do, z_do;           // CPU data out
    reg  [ 7:0] m_di, s_di, z_di;           // CPU data in
    wire m_m1_n, m_mreq_n, m_iorq_n, m_rd_n, m_wr_n;
    wire s_m1_n, s_mreq_n, s_iorq_n, s_rd_n, s_wr_n;
    wire z_m1_n, z_mreq_n, z_iorq_n, z_rd_n, z_wr_n;
    wire m_int_n, s_int_n, z_int_n, s_nmi_n, z_nmi_n;

    wire m_mem_wr = ~m_mreq_n & ~m_wr_n;
    wire s_mem_wr = ~s_mreq_n & ~s_wr_n;
    wire z_mem_wr = ~z_mreq_n & ~z_wr_n;
    wire m_io_wr  = ~m_iorq_n & ~m_wr_n;
    wire s_io_wr  = ~s_iorq_n & ~s_wr_n;
    wire z_io_wr  = ~z_iorq_n & ~z_wr_n;
    wire s_io_rd  = ~s_iorq_n & ~s_rd_n;
    wire z_io_rd  = ~z_iorq_n & ~z_rd_n;
    wire m_inta   = ~m_m1_n & ~m_iorq_n;    // interrupt acknowledge cycles
    wire s_inta   = ~s_m1_n & ~s_iorq_n;
    wire z_inta   = ~z_m1_n & ~z_iorq_n;

    // MCU outputs
    wire sub_run;
    wire m_rst_n = ~rst;
    wire s_rst_n = ~rst & sub_run;          // the Mermaid can hold the sub CPU in reset
    wire z_rst_n = ~rst;

    // The Pandora snapshots the sprite RAM at vblank start (MAME's eof is
    // instantaneous): the main CPU's accesses to that window wait for it.  The
    // copy is a few thousand clocks, a handful of Z80 instructions.
    wire spr_hold;
    wire m_spr_acc = ma[15:12] == 4'hc;
    wire m_wait_n  = ~(spr_hold & m_spr_acc & ~m_mreq_n);

    T80s u_main (
        .RESET_n(m_rst_n), .CLK(clk), .CEN(cen6), .WAIT_n(m_wait_n), .INT_n(m_int_n),
        .NMI_n(1'b1), .BUSRQ_n(1'b1), .OUT0(1'b0), .DI(m_di),
        .M1_n(m_m1_n), .MREQ_n(m_mreq_n), .IORQ_n(m_iorq_n), .RD_n(m_rd_n), .WR_n(m_wr_n),
        .RFSH_n(), .HALT_n(), .BUSAK_n(), .A(ma), .DOUT(m_do)
    );
    T80s u_sub (
        .RESET_n(s_rst_n), .CLK(clk), .CEN(cen6), .WAIT_n(1'b1), .INT_n(s_int_n),
        .NMI_n(s_nmi_n), .BUSRQ_n(1'b1), .OUT0(1'b0), .DI(s_di),
        .M1_n(s_m1_n), .MREQ_n(s_mreq_n), .IORQ_n(s_iorq_n), .RD_n(s_rd_n), .WR_n(s_wr_n),
        .RFSH_n(), .HALT_n(), .BUSAK_n(), .A(sa), .DOUT(s_do)
    );
    T80s u_snd (
        .RESET_n(z_rst_n), .CLK(clk), .CEN(cen6), .WAIT_n(1'b1), .INT_n(z_int_n),
        .NMI_n(z_nmi_n), .BUSRQ_n(1'b1), .OUT0(1'b0), .DI(z_di),
        .M1_n(z_m1_n), .MREQ_n(z_mreq_n), .IORQ_n(z_iorq_n), .RD_n(z_rd_n), .WR_n(z_wr_n),
        .RFSH_n(), .HALT_n(), .BUSAK_n(), .A(za), .DOUT(z_do)
    );

    // =====================================================================
    // Bank registers
    // =====================================================================
    reg [2:0] main_bank;                    // OUT 00h / 01h, data[2:0]
    reg [1:0] sub_bank;                     // OUT 00h data[1:0]
    reg [7:0] sub_p0;                       // OUT 00h full byte (scroll high bits live here)
    reg [7:0] scroll_x, scroll_y;
    reg [1:0] snd_bank;

    always @(posedge clk) begin
        if (rst) begin
            main_bank <= 3'd0;
            sub_bank  <= 2'd0;
            sub_p0    <= 8'd0;
            scroll_x  <= 8'd0;
            scroll_y  <= 8'd0;
            snd_bank  <= 2'd0;
        end else begin
            if (m_io_wr && ma[7:1] == 7'd0) main_bank <= m_do[2:0];      // ports 00h and 01h
            if (s_io_wr) case (sa[7:0])
                8'h00: begin sub_bank <= s_do[1:0]; sub_p0 <= s_do; end
                8'h06: scroll_y <= s_do;
                8'h08: scroll_x <= s_do;
                default: ;
            endcase
            if (z_io_wr && za[7:0] == 8'h00) snd_bank <= z_do[1:0];
        end
    end

    // =====================================================================
    // Latches
    // =====================================================================
    reg [7:0] snd_latch,  mer_latch;        // sub -> sound, sub -> Mermaid
    reg [7:0] sub_latch;                    // Mermaid -> sub
    reg       snd_pend, mer_pend, sub_pend;

    wire       mer_rd, sub_wr;
    wire [7:0] sub_wdata;

    always @(posedge clk) begin
        if (rst) begin
            snd_pend <= 1'b0; mer_pend <= 1'b0; sub_pend <= 1'b0;
            snd_latch <= 8'd0; mer_latch <= 8'd0; sub_latch <= 8'd0;
        end else begin
            // reads clear the pending flag, writes set it (write wins a tie)
            if (z_io_rd && za[7:0] == 8'h04) snd_pend <= 1'b0;
            if (s_io_wr && sa[7:0] == 8'h02) begin snd_latch <= s_do; snd_pend <= 1'b1; end

            if (mer_rd)                       mer_pend <= 1'b0;
            if (s_io_wr && sa[7:0] == 8'h04) begin mer_latch <= s_do; mer_pend <= 1'b1; end

            if (s_io_rd && sa[7:0] == 8'h04) sub_pend <= 1'b0;
            if (sub_wr)                      begin sub_latch <= sub_wdata; sub_pend <= 1'b1; end
        end
    end

    // =====================================================================
    // Interrupts
    // =====================================================================
    // Main CPU: IM2, vector low byte supplied on the bus. 0xFD at vblank, 0xFF at the
    // line-64 sprite IRQ.  MAME uses HOLD_LINE: asserted until the Z80 acknowledges.
    reg       m_irq;
    reg [7:0] m_vec;
    always @(posedge clk) begin
        if (rst) begin
            m_irq <= 1'b0;
            m_vec <= 8'hff;
        end else begin
            if (m_inta) m_irq <= 1'b0;
            if (vbl_start) begin m_irq <= 1'b1; m_vec <= 8'hfd; end
            if (spr_irq)   begin m_irq <= 1'b1; m_vec <= 8'hff; end
        end
    end
    assign m_int_n = ~m_irq;

    // Sub CPU: level IRQ0 asserted at vblank start, cleared by OUT 0Eh. The data
    // bus reads 0xFF on acknowledge (RST 38h).  NMI is pulsed by main OUT 02h.
    reg s_irq;
    always @(posedge clk) begin
        if (rst)                                 s_irq <= 1'b0;
        else begin
            if (s_io_wr && sa[7:0] == 8'h0e)     s_irq <= 1'b0;
            if (vbl_start)                       s_irq <= 1'b1;
        end
    end
    assign s_int_n = ~s_irq;
    assign s_nmi_n = ~(m_io_wr && ma[7:0] == 8'h02);

    // Sound CPU: NMI while the sound latch holds unread data, IRQ from the YM2203.
    wire ym_irq_n;
    assign z_nmi_n = ~snd_pend;
    assign z_int_n = ym_irq_n;

    // =====================================================================
    // RAM
    // =====================================================================
    wire [7:0] spr_q, mram_q, shr_m_q, shr_s_q;
    wire [7:0] vram_q, cram_q, pale_q, pall_q, sra_q, srb_q, zram_q;

    wire m_spr = ma[15:12] == 4'hc;
    wire m_ram = ma[15:12] == 4'hd;
    wire m_shr = ma[15:13] == 3'b111;

    // The memories the picture is made from have a second, read-only port for
    // the video block: sprite RAM (the Pandora snapshot), video / colour RAM
    // (the tile fetch) and the palette (the scan-out).
    wire [11:0] spr_live_addr;
    wire [ 7:0] spr_live_q;
    wire [ 9:0] bg_raddr;
    wire [ 7:0] vram_vq, cram_vq;
    wire [ 8:0] pal_raddr;
    wire [ 7:0] pal_hi_q, pal_lo_q;

    hvyunit_dpram #(.AW(12)) u_spr (
        .clk(clk),
        .a_we(m_mem_wr & m_spr), .a_addr(ma[11:0]), .a_din(m_do), .a_q(spr_q),
        .b_we(1'b0), .b_addr(spr_live_addr), .b_din(8'd0), .b_q(spr_live_q)
    );
    hvyunit_ram #(.AW(12)) u_mram (.clk(clk), .we(m_mem_wr & m_ram), .addr(ma[11:0]), .din(m_do), .q(mram_q));

    wire s_c0 = sa[15:10] == 6'b110000;     // C000-C3FF video RAM
    wire s_c4 = sa[15:10] == 6'b110001;     // C400-C7FF colour RAM
    wire s_d0 = sa[15: 9] == 7'b1101000;    // D000-D1FF palette (high byte)
    wire s_d8 = sa[15: 9] == 7'b1101100;    // D800-D9FF palette (low byte)
    wire s_d2 = sa[15:11] == 5'b11010 && sa[10:9] != 2'b00;   // D200-D7FF plain RAM
    wire s_da = sa[15:11] == 5'b11011 && sa[10:9] != 2'b00;   // DA00-DFFF plain RAM
    wire s_shr = sa[15:13] == 3'b111;

    hvyunit_dpram #(.AW(10)) u_vram (
        .clk(clk),
        .a_we(s_mem_wr & s_c0), .a_addr(sa[9:0]), .a_din(s_do), .a_q(vram_q),
        .b_we(1'b0), .b_addr(bg_raddr), .b_din(8'd0), .b_q(vram_vq)
    );
    hvyunit_dpram #(.AW(10)) u_cram (
        .clk(clk),
        .a_we(s_mem_wr & s_c4), .a_addr(sa[9:0]), .a_din(s_do), .a_q(cram_q),
        .b_we(1'b0), .b_addr(bg_raddr), .b_din(8'd0), .b_q(cram_vq)
    );
    hvyunit_dpram #(.AW(9)) u_pale (
        .clk(clk),
        .a_we(s_mem_wr & s_d0), .a_addr(sa[8:0]), .a_din(s_do), .a_q(pale_q),
        .b_we(1'b0), .b_addr(pal_raddr), .b_din(8'd0), .b_q(pal_hi_q)
    );
    hvyunit_dpram #(.AW(9)) u_pall (
        .clk(clk),
        .a_we(s_mem_wr & s_d8), .a_addr(sa[8:0]), .a_din(s_do), .a_q(pall_q),
        .b_we(1'b0), .b_addr(pal_raddr), .b_din(8'd0), .b_q(pal_lo_q)
    );
    hvyunit_ram #(.AW(11)) u_sra  (.clk(clk), .we(s_mem_wr & s_d2), .addr(sa[10:0]), .din(s_do), .q(sra_q));
    hvyunit_ram #(.AW(11)) u_srb  (.clk(clk), .we(s_mem_wr & s_da), .addr(sa[10:0]), .din(s_do), .q(srb_q));

    hvyunit_dpram #(.AW(13)) u_shared (
        .clk(clk),
        .a_we(m_mem_wr & m_shr), .a_addr(ma[12:0]), .a_din(m_do), .a_q(shr_m_q),
        .b_we(s_mem_wr & s_shr), .b_addr(sa[12:0]), .b_din(s_do), .b_q(shr_s_q)
    );

    wire z_ramsel = za[15:11] == 5'b11000;  // C000-C7FF
    hvyunit_ram #(.AW(11)) u_zram (.clk(clk), .we(z_mem_wr & z_ramsel), .addr(za[10:0]), .din(z_do), .q(zram_q));

    // =====================================================================
    // Video
    // =====================================================================
    generate if (VIDEO != 0) begin : g_video
        hvyunit_video #(
            .H_TOTAL(H_TOTAL), .V_TOTAL(V_TOTAL),
            .HS_START(HS_START), .HS_LEN(HS_LEN), .VS_START(VS_START), .VS_LEN(VS_LEN),
            .V_TOTAL_ALT(V_TOTAL_ALT), .HS_START_ALT(HS_START_ALT), .VS_START_ALT(VS_START_ALT)
        ) u_video (
            .clk(clk), .rst(rst), .cen6(cen6), .hcnt(hcnt), .vcnt(vcnt), .vbl_start(vbl_start),
            .alt(raster_alt_q),
            .scroll_x(scroll_x), .scroll_y(scroll_y), .port0(sub_p0),
            .bg_raddr(bg_raddr), .vram_q(vram_vq), .cram_q(cram_vq),
            .pal_raddr(pal_raddr), .pal_hi_q(pal_hi_q), .pal_lo_q(pal_lo_q),
            .spr_live_addr(spr_live_addr), .spr_live_q(spr_live_q), .spr_hold(spr_hold),
            .tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
            .spr_b_req(spr_b_req), .spr_b_addr(spr_b_addr), .spr_b_wr(spr_b_wr), .spr_b_idx(spr_b_idx),
            .spr_b_data(spr_b_data), .spr_b_done(spr_b_done),
            .rgb(rgb), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de),
            .cen_pix(cen_pix),
            .spr_busy(spr_busy), .spr_overrun(spr_overrun), .spr_count(spr_count)
        );
    end else begin : g_novideo
        assign bg_raddr = 10'd0;
        assign pal_raddr = 9'd0;
        assign spr_live_addr = 12'd0;
        assign spr_hold = 1'b0;
        assign tile_req = 1'b0;
        assign tile_addr = 18'd0;
        assign spr_b_req = 1'b0;
        assign spr_b_addr = 20'd0;
        assign rgb = 24'd0;
        assign hsync = 1'b0;
        assign vsync = 1'b0;
        assign hblank = 1'b0;
        assign vblank = 1'b0;
        assign de = 1'b0;
        assign cen_pix = 1'b0;
        assign spr_busy = 1'b0;
        assign spr_overrun = 1'b0;
        assign spr_count = 10'd0;
    end endgenerate

    // =====================================================================
    // ROM addressing
    // =====================================================================
    wire m_romhi = ma[15:14] == 2'b10;      // 8000-BFFF banked
    wire s_romhi = sa[15:14] == 2'b10;
    wire z_romhi = za[15:14] == 2'b10;
    assign main_rom_addr = m_romhi ? {main_bank, ma[13:0]} : {2'b00, ma[14:0]};
    assign sub_rom_addr  = s_romhi ? {sub_bank,  sa[13:0]} : {1'b0,  sa[14:0]};
    assign snd_rom_addr  = z_romhi ? {snd_bank,  za[13:0]} : {1'b0,  za[14:0]};

    // =====================================================================
    // YM2203
    // =====================================================================
    // jt03 samples its bus on its own enable, so the write is latched and
    // stretched across at least two cen3 periods (the Sand Scorpion idiom).
    localparam integer HOLD = 2 * YM_CLK_PER_CEN + 4;
    wire ym_sel_wr = z_io_wr && (za[7:0] == 8'h02 || za[7:0] == 8'h03);
    reg        ym_sel_d;
    reg [7:0]  ym_din;
    reg        ym_addr;
    reg [7:0]  ym_hold;
    always @(posedge clk) begin
        ym_sel_d <= ym_sel_wr;
        if (rst) ym_hold <= 8'd0;
        else if (ym_sel_wr && !ym_sel_d) begin
            ym_din  <= z_do;
            ym_addr <= za[0];
            ym_hold <= HOLD[7:0];
        end else if (ym_hold != 8'd0) ym_hold <= ym_hold - 8'd1;
    end
    wire       ym_wr_n = (ym_hold == 8'd0);
    wire       ym_a0   = ym_wr_n ? za[0] : ym_addr;
    wire [7:0] ym_dout;
    wire signed [15:0] ym_snd;

    jt03 u_ym (
        .rst(rst), .clk(clk), .cen(cen3),
        .din(ym_din), .addr(ym_a0), .cs_n(1'b0), .wr_n(ym_wr_n),
        .dout(ym_dout), .irq_n(ym_irq_n),
        .IOA_in(8'hff), .IOB_in(8'hff), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
        .psg_A(), .psg_B(), .psg_C(), .fm_snd(), .psg_snd(), .snd(ym_snd), .snd_sample(),
        .debug_view()
    );
    // MAME routes the chip to a mono speaker at 0.80
    assign snd = (ym_snd >>> 1) + (ym_snd >>> 2) + (ym_snd >>> 5);   // ~0.78

    // =====================================================================
    // Mermaid
    // =====================================================================
    hvyunit_mermaid u_mermaid (
        .rst(rst), .clk(clk), .cen(cen6),
        .prog_addr(mcu_prog_addr), .prog_data(mcu_prog_data), .prog_we(mcu_prog_we),
        .mlatch_data(mer_latch), .mlatch_pend(mer_pend), .slatch_pend(sub_pend),
        .mlatch_rd(mer_rd), .slatch_wr(sub_wr), .slatch_data(sub_wdata),
        .in0(in0), .in1(in1), .in2(in2), .dsw1(dsw1), .dsw2(dsw2),
        .sub_run(sub_run), .coin_counter(coin_counter), .coin_lockout(coin_lockout)
    );

    // =====================================================================
    // CPU read data
    // =====================================================================
    always @* begin
        m_di = 8'h00;
        if (m_inta)                         m_di = m_vec;
        else if (ma[15] == 1'b0 || m_romhi) m_di = main_rom_data;
        else if (m_spr)                     m_di = spr_q;
        else if (m_ram)                     m_di = mram_q;
        else if (m_shr)                     m_di = shr_m_q;
    end

    always @* begin
        s_di = 8'h00;
        if (s_inta) s_di = 8'hff;
        else if (~s_iorq_n) begin
            case (sa[7:0])
                8'h04:   s_di = sub_latch;
                // bit2 = !sub-latch pending, bit3 = Mermaid-latch pending
                8'h0c:   s_di = {4'd0, mer_pend, ~sub_pend, 2'd0};
                default: s_di = 8'h00;
            endcase
        end
        else if (sa[15] == 1'b0 || s_romhi) s_di = sub_rom_data;
        else if (s_c0)                      s_di = vram_q;
        else if (s_c4)                      s_di = cram_q;
        else if (s_d0)                      s_di = pale_q;
        else if (s_d8)                      s_di = pall_q;
        else if (s_d2)                      s_di = sra_q;
        else if (s_da)                      s_di = srb_q;
        else if (s_shr)                     s_di = shr_s_q;
    end

    always @* begin
        z_di = 8'h00;
        if (z_inta) z_di = 8'hff;
        else if (~z_iorq_n) begin
            case (za[7:0])
                8'h02, 8'h03: z_di = ym_dout;
                8'h04:        z_di = snd_latch;
                default:      z_di = 8'h00;
            endcase
        end
        else if (za[15] == 1'b0 || z_romhi) z_di = snd_rom_data;
        else if (z_ramsel)                  z_di = zram_q;
    end

endmodule
