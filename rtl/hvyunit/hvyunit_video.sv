// Heavy Unit video: the opaque 32x32 tilemap of 16x16 tiles, the Pandora sprite
// plane, the 512-entry palette, and the raster that carries them out.
//
// Everything here is behaviourally what MAME's hvyunit.cpp screen_update does
// (docs/ARCHITECTURE.md section 6; tools/hv_oracle.py is the pixel-exact model):
//
//   bitmap row    = visible row + 16
//   scrollX_total = ((port0 & 0x40) << 2) + scrollX + 96     (mod 512)
//   scrollY_total = ((port0 & 0x80) << 1) + scrollY          (mod 512)
//   tile (row*32+col):  code = vram + ((cram & 0x0f) << 8),  colour = cram >> 4
//   pixel index   = colour*16 + pen                  (background, 0x000-0x0FF)
//                 = 0x100 + {bank, pen}              (sprite, pen != 0, on top)
//   RGB           = {ext[3:0], lo[7:4], lo[3:0]}     (xRGB444, nibbles replicated)
//
// Memory is reached through two ports: tile words through a random-access
// client (four 16-bit reads per tile row) and sprite tiles through a burst
// client (64 words).  Words are little-endian: the even byte address is the low
// byte.  Timing assumes clk = 16 x the 6 MHz pixel enable (96 MHz): the per-line
// background fetch needs about 2,000 of a line's 6,240 clocks.
module hvyunit_video #(
    parameter integer H_TOTAL   = 390,
    parameter integer V_TOTAL   = 264,
    parameter integer HS_START  = 293,    // horizontal sync, in pixels
    parameter integer HS_LEN    = 32,
    parameter integer VS_START  = 245,    // vertical sync, in lines
    parameter integer VS_LEN    = 8,
    // the alternative raster (alt = 1, hvyunit_timing's alt_q): its frame length and where its syncs start
    parameter integer V_TOTAL_ALT  = 256,
    parameter integer HS_START_ALT = 307,
    parameter integer VS_START_ALT = 245
) (
    input             clk,
    input             rst,
    input             cen6,               // 6 MHz pixel enable
    input      [ 8:0] hcnt,
    input      [ 8:0] vcnt,
    input             vbl_start,          // one clk pulse (the sprite engine's eof)
    input             alt,                // the raster in force: 0 the main one, 1 the alternative

    input      [ 7:0] scroll_x,
    input      [ 7:0] scroll_y,
    input      [ 7:0] port0,              // bit 6: scrollX bit 8, bit 7: scrollY bit 8

    // background RAM, second read port (one address for both; synchronous read)
    output reg [ 9:0] bg_raddr,
    input      [ 7:0] vram_q,
    input      [ 7:0] cram_q,

    // palette, second read port
    output reg [ 8:0] pal_raddr,
    input      [ 7:0] pal_hi_q,
    input      [ 7:0] pal_lo_q,

    // sprite RAM (live, CPU order) for the Pandora snapshot
    output     [11:0] spr_live_addr,
    input      [ 7:0] spr_live_q,
    output            spr_hold,

    // tile ROM: random-access client, one word per request (level req, 1-clk ack)
    output reg        tile_req,
    output reg [17:0] tile_addr,          // word address in the 512 KB tile region
    input             tile_ack,
    input      [15:0] tile_q,             // valid in the clock of tile_ack

    // sprite ROM: burst client, 64 words per tile
    output            spr_b_req,
    output     [19:0] spr_b_addr,         // word address in the 2 MB sprite region
    input             spr_b_wr,
    input      [ 5:0] spr_b_idx,
    input      [15:0] spr_b_data,
    input             spr_b_done,

    // picture, aligned with cen_pix
    output reg [23:0] rgb,
    output reg        hsync,
    output reg        vsync,
    output reg        hblank,
    output reg        vblank,
    output reg        de,                 // the visible rectangle
    output reg        cen_pix,            // one clk pulse per output pixel

    output            spr_busy,
    output            spr_overrun,
    output     [ 9:0] spr_count
);

    localparam integer VIS_Y0 = 16;       // first visible bitmap row
    localparam integer VIS_H  = 224;
    localparam integer VIS_W  = 256;

    wire visible_now = (vcnt >= VIS_Y0) && (vcnt < VIS_Y0 + VIS_H);

    // ------------------------------------------------------------- plane RAM
    // Two ports of one block RAM: A is the engine's write; B reads a pixel for the
    // scan-out and clears it the clock after the read.  The scan-out clears the
    // plane as it shows it, so no separate clear pass is needed and the plane is
    // empty again for the next vblank's pass.
    //
    // The clear is NOT in the clock of the read: an M10K returns the NEW data to a
    // port that reads the address it writes in the same clock, so a read-and-clear
    // would always read zero in hardware (every sprite invisible) while a simulator
    // of the Verilog source gives the old value.  PLANE_RDW_NEW makes a simulation
    // behave like the block RAM, so that sim/video and sim/emu catch that.
    (* ramstyle = "no_rw_check" *) reg [7:0] plane [0:65535];   // row * 256 + column, rows 0..223 used
    wire        pl_we;
    wire [15:0] pl_addr;
    wire [ 7:0] pl_data;
    reg  [15:0] pl_raddr;
    reg  [ 7:0] pl_q;
    reg         c0, de0;                  // a visible pixel's address is being applied (stage 0 flags, below)
    reg         c1, de1;                  // ... and its read data is back: the pixel is cleared now
    always @(posedge clk) if (pl_we) plane[pl_addr] <= pl_data;          // port A: the engine
    always @(posedge clk) begin                                          // port B: scan-out
        pl_q <= plane[pl_raddr];
        if (c1 && de1) plane[pl_raddr] <= 8'd0;      // pl_raddr holds for the sixteen clocks of the pixel
`ifdef PLANE_RDW_NEW
        if (c1 && de1) pl_q <= 8'd0;     // what the M10K does on a read of the address it writes
`endif
    end

    // --------------------------------------------------------------- Pandora
    hvyunit_pandora #(.ROW0(VIS_Y0), .ROWS(VIS_H)) u_pandora (
        .clk(clk), .rst(rst),
        .start(vbl_start), .visible(visible_now),
        .live_addr(spr_live_addr), .live_q(spr_live_q), .hold(spr_hold),
        .pl_we(pl_we), .pl_addr(pl_addr), .pl_data(pl_data),
        .b_req(spr_b_req), .b_addr(spr_b_addr),
        .b_wr(spr_b_wr), .b_idx(spr_b_idx), .b_data(spr_b_data), .b_done(spr_b_done),
        .busy(spr_busy), .overrun(spr_overrun), .n_drawn(spr_count)
    );

    // ----------------------------------------------------- line buffers (BG)
    // two lines of 272 bytes {colour, pen}: the fetch fills one while the
    // scan-out reads the other.  Index = {buffer, tile column, pixel in tile}.
    reg  [7:0] lbuf [0:1023];
    reg        lb_we;
    reg  [9:0] lb_waddr;
    reg  [7:0] lb_wdata;
    reg  [9:0] lb_raddr;
    reg  [7:0] lb_q;
    always @(posedge clk) begin
        if (lb_we) lbuf[lb_waddr] <= lb_wdata;
        lb_q <= lbuf[lb_raddr];
    end

    // ------------------------------------------------------ per-line BG fetch
    // Started at the first column of each line, for the NEXT line, which goes
    // into buffer {its bitmap row [0]} and is read out when that line is shown.
    wire        line_start = cen6 && (hcnt == 9'd0);
    localparam [8:0] VT0 = V_TOTAL, VT1 = V_TOTAL_ALT;
    wire [8:0]  next_row_y = (vcnt >= (alt ? VT1 : VT0) - 9'd1) ? 9'd0 : vcnt + 9'd1;
    wire        next_vis   = (next_row_y >= VIS_Y0) && (next_row_y < VIS_Y0 + VIS_H);

    wire [8:0]  sxt_now = {port0[6], 8'd0} + {1'b0, scroll_x} + 9'd96;
    wire [8:0]  syt_now = {port0[7], 8'd0} + {1'b0, scroll_y};
    wire [8:0]  ty_now  = next_row_y + syt_now;

    localparam [2:0] F_IDLE = 0, F_ATTR = 1, F_ATTR2 = 2, F_ATTR3 = 3, F_REQ = 4, F_WAIT = 5, F_WR = 6, F_NEXT = 7;
    reg  [2:0]  fstate;
    reg  [8:0]  sxt;                      // scrollX_total of the line being prepared
    reg  [8:0]  ty;                       // tilemap row, in pixels
    reg  [4:0]  col0;
    reg  [4:0]  tcol;                     // tile column 0..16 of this line
    reg  [11:0] tcode;
    reg  [3:0]  tcolr;
    reg  [1:0]  widx;                     // word of the tile row, 0..3
    reg  [15:0] wq;
    reg  [1:0]  wrp;                      // pixel within the word, 0..3
    reg         fbuf;

    // word address: code*64 + py[3]*32 + py[2:0]*2 + (widx[1] ? 16 : 0) + widx[0]
    wire [17:0] tword = {tcode, 6'd0} + {12'd0, ty[3], 5'd0} + {14'd0, ty[2:0], 1'b0}
                        + {13'd0, widx[1], 4'd0} + {17'd0, widx[0]};

    reg  [3:0] wpen;
    always @* case (wrp)
        2'd0: wpen = wq[7:4];
        2'd1: wpen = wq[3:0];
        2'd2: wpen = wq[15:12];
        default: wpen = wq[11:8];
    endcase

    always @(posedge clk) begin
        lb_we <= 1'b0;
        if (rst) begin
            fstate   <= F_IDLE;
            tile_req <= 1'b0;
        end else begin
            case (fstate)
            F_IDLE: if (line_start && next_vis) begin
                sxt    <= sxt_now;
                ty     <= ty_now;
                col0   <= sxt_now[8:4];
                tcol   <= 5'd0;
                fbuf   <= next_row_y[0];
                fstate <= F_ATTR;
            end

            // tile (row, col): the two attribute RAMs share the address
            F_ATTR: begin
                bg_raddr <= {ty[8:4], col0 + tcol};
                fstate   <= F_ATTR2;
            end
            F_ATTR2: fstate <= F_ATTR3;                      // RAM latency
            F_ATTR3: begin
                tcode  <= {cram_q[3:0], vram_q};
                tcolr  <= cram_q[7:4];
                widx   <= 2'd0;
                fstate <= F_REQ;
            end

            F_REQ: begin
                tile_req  <= 1'b1;
                tile_addr <= tword;
                fstate    <= F_WAIT;
            end
            F_WAIT: if (tile_ack) begin
                tile_req <= 1'b0;
                wq       <= tile_q;
                wrp      <= 2'd0;
                fstate   <= F_WR;
            end

            // four pixels per word: low byte = pixels 0,1 (high nibble first), high byte = 2,3
            F_WR: begin
                lb_we    <= 1'b1;
                lb_waddr <= {fbuf, tcol, widx, wrp};
                lb_wdata <= {tcolr, wpen};
                wrp      <= wrp + 2'd1;
                if (wrp == 2'd3) fstate <= F_NEXT;
            end

            F_NEXT: begin
                if (widx == 2'd3) begin
                    if (tcol == 5'd16) fstate <= F_IDLE;
                    else begin tcol <= tcol + 5'd1; fstate <= F_ATTR; end
                end else begin
                    widx   <= widx + 2'd1;
                    fstate <= F_REQ;
                end
            end
            default: fstate <= F_IDLE;
            endcase
        end
    end

    // the scroll value the line being SHOWN was fetched with
    reg [8:0] sxt_disp;
    always @(posedge clk) if (line_start) sxt_disp <= sxt;

    // ------------------------------------------------------------- scan-out
    // Each RAM has an address register and a data register, so a pixel takes:
    //   t    cen6: the addresses are chosen                       (stage 0 flags c0)
    //   t+1  the line buffer and plane see their addresses
    //   t+2  both data are back: choose the index, address the palette, clear the plane  (c1)
    //   t+3  the palette sees its address                         (c2)
    //   t+4  palette words back: build the RGB, register the output (c3)
    wire [7:0] x8 = hcnt[7:0];
    wire [8:0] lb_idx = {1'b0, x8} + {5'd0, sxt_disp[3:0]};

    wire [8:0] hs_s = alt ? HS_START_ALT : HS_START;      // where the syncs start in the raster in force
    wire [8:0] vs_s = alt ? VS_START_ALT : VS_START;
    reg        c2, c3;                    // (c0, de0, c1 and de1 are declared with the plane RAM)
    reg        de2, de3;
    reg        hs0, hs1, hs2, hs3;
    reg        vs0, vs1, vs2, vs3;
    reg        hb0, hb1, hb2, hb3;
    reg        vb0, vb1, vb2, vb3;

    always @(posedge clk) begin
        c0 <= 1'b0;
        if (rst) begin
            c1 <= 1'b0; c2 <= 1'b0; c3 <= 1'b0; cen_pix <= 1'b0;
        end else begin
            // stage 0
            if (cen6) begin
                c0       <= 1'b1;
                lb_raddr <= {vcnt[0], lb_idx};
                pl_raddr <= {vcnt[7:0] - 8'd16, x8};
                de0      <= visible_now && (hcnt < VIS_W);
                hs0      <= (hcnt >= hs_s) && (hcnt < hs_s + HS_LEN);
                vs0      <= (vcnt >= vs_s) && (vcnt < vs_s + VS_LEN);
                hb0      <= (hcnt >= VIS_W);
                vb0      <= ~visible_now;
            end

            // flags ride along one stage per clock
            c1 <= c0; de1 <= de0; hs1 <= hs0; vs1 <= vs0; hb1 <= hb0; vb1 <= vb0;
            c2 <= c1; de2 <= de1; hs2 <= hs1; vs2 <= vs1; hb2 <= hb1; vb2 <= vb1;
            c3 <= c2; de3 <= de2; hs3 <= hs2; vs3 <= vs2; hb3 <= hb2; vb3 <= vb2;

            // t+2: line buffer and plane data are valid in this cycle; the plane pixel is
            // cleared at the end of it (the read was at the end of t+1)
            pal_raddr <= (pl_q != 8'd0) ? {1'b1, pl_q} : {1'b0, lb_q};

            // t+4: palette words valid; output register
            cen_pix <= c3;
            if (c3) begin
                de     <= de3;
                hsync  <= hs3;
                vsync  <= vs3;
                hblank <= hb3;
                vblank <= vb3;
                rgb    <= de3 ? {{2{pal_hi_q[3:0]}}, {2{pal_lo_q[7:4]}}, {2{pal_lo_q[3:0]}}} : 24'd0;
            end
        end
    end

endmodule
