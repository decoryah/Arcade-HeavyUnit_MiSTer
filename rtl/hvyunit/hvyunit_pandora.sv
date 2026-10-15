// Kaneko Pandora sprite generator, behaviourally equivalent to MAME's
// kan_pand.cpp as hvyunit.cpp uses it (docs/ARCHITECTURE.md section 6.1, and the
// pixel-exact model in tools/hv_oracle.py).
//
//   * 512 entries x 8 bytes in a 4 KB RAM, accessed by the main Z80 with the
//     address lines swapped:  CPU offset o  ->  entry {o[11], o[7:0]},
//     byte o[10:8].  The engine addresses the RAM in CPU order, so it never has
//     to undo the swap.
//   * At vblank start (MAME's eof) the whole table is SNAPSHOTTED, then every
//     entry is drawn, in order, into a plane; later entries overwrite earlier
//     ones; pen 0 is transparent.  The plane is read out (and cleared) by the
//     scan-out during the following visible area, so sprites lag the RAM by
//     one frame exactly as MAME's double buffer does.
//   * Entry (bytes 0-2 unused):
//        3  [7:4] palette bank   [2] relative position   [1] Y bit 8   [0] X bit 8
//        4  X low   5  Y low   6  code low   7  [7] flip X  [6] flip Y  [5:0] code high
//     with relative entries ADDING dx/dy to the running x/y.  14-bit code.
//   * 16x16 4bpp tiles, 128 bytes each: four 8x8 blocks TL,TR,BL,BR of 32 bytes,
//     4 bytes a row, high nibble = left pixel.  Fetched whole, as one 64-word
//     burst (little-endian words), then drawn at one pixel a clock.
//
// The plane is 256 x 224: the visible rows of MAME's bitmap (16..239).  The
// draw pass is paced to finish inside the vertical blank; `overrun` reports a
// pass that was still running when the visible area began.
module hvyunit_pandora #(
    parameter integer ROW0 = 16,          // first visible row of the 256-row bitmap
    parameter integer ROWS = 224
) (
    input             clk,
    input             rst,

    input             start,              // one clk pulse at vblank start
    input             visible,            // 1 during the visible area (for `overrun`)

    // live sprite RAM, CPU order, synchronous read (data one clk after address)
    output reg [11:0] live_addr,
    input      [ 7:0] live_q,
    output            hold,               // snapshot running: stall the CPU's accesses

    // plane write port
    output reg        pl_we,
    output reg [15:0] pl_addr,            // row * 256 + column
    output reg [ 7:0] pl_data,            // {bank, pen}

    // tile ROM, burst client: always 64 words
    output reg        b_req,
    output reg [19:0] b_addr,             // word address of the tile's first word
    input             b_wr,
    input      [ 5:0] b_idx,
    input      [15:0] b_data,
    input             b_done,

    output            busy,
    output reg        overrun,
    output reg [ 9:0] n_drawn             // entries that needed a tile fetch, last pass
);

    // ----------------------------------------------------------- snapshot RAM
    reg  [7:0]  shadow [0:4095];
    reg  [11:0] sh_waddr;
    reg  [ 7:0] sh_wdata;
    reg         sh_we;
    reg  [11:0] sh_raddr;
    reg  [ 7:0] sh_q;
    always @(posedge clk) begin
        if (sh_we) shadow[sh_waddr] <= sh_wdata;
        sh_q <= shadow[sh_raddr];
    end

    // -------------------------------------------------------------- tile buffer
    reg  [15:0] tbuf [0:63];
    reg  [ 5:0] tb_raddr;
    reg  [15:0] tb_q;
    always @(posedge clk) begin
        if (b_wr) tbuf[b_idx] <= b_data;
        tb_q <= tbuf[tb_raddr];
    end

    // --------------------------------------------------------------- state
    localparam [2:0] S_IDLE = 0, S_COPY = 1, S_RD = 2, S_CALC = 3, S_FETCH = 4,
                     S_WAITB = 5, S_DRAW = 6, S_NEXT = 7;
    reg  [2:0]  state;
    reg  [12:0] cnt;                      // snapshot counter
    reg  [8:0]  ent;                      // entry 0..511
    reg  [2:0]  rd_phase;
    reg  [7:0]  e3, e4, e5, e6, e7;
    reg  signed [15:0] ax, ay;            // running position (MAME ints; only [8:0] matter)
    reg  signed [9:0]  sx, sy;
    reg         fx, fy;
    reg  [3:0]  bank;
    reg  [13:0] code;
    reg  [8:0]  dpix;                     // draw pixel counter (0..255, then drain)
    reg         vis_d;

    assign hold = (state == S_COPY);
    assign busy = (state != S_IDLE);

    // --- draw pipeline.  Cycle t: dpix selects the pixel and its tile-buffer address
    // is registered (stage A).  t+1: the RAM output is registered.  t+2: the data and
    // the pixel's attributes (stage B) are both valid and the plane write is issued.
    wire [3:0] py   = dpix[7:4];
    wire [3:0] px   = dpix[3:0];
    wire [3:0] srow = fy ? ~py : py;
    wire [3:0] spx  = fx ? ~px : px;
    // byte offset inside the 128-byte tile: block*32 + row*4 + col/2
    wire [6:0] boff = {srow[3], spx[3], 5'd0} + {2'd0, srow[2:0], 2'd0} + {5'd0, spx[2:1]};

    reg                pA_valid, pB_valid;
    reg                pA_hi,    pB_hi;
    reg                pA_lane,  pB_lane;
    reg        [3:0]   pA_bank,  pB_bank;
    reg signed [10:0]  pA_x,     pB_x;
    reg signed [10:0]  pA_y,     pB_y;

    wire [7:0] tb_byte = pB_lane ? tb_q[15:8] : tb_q[7:0];
    wire [3:0] nib     = pB_hi ? tb_byte[3:0] : tb_byte[7:4];

    // --- the entry being decoded (e3..e7 registered)
    wire        rel = e3[2];
    wire [8:0]  dxr = {e3[0], e4};
    wire [8:0]  dyr = {e3[1], e5};
    wire signed [15:0] nx = rel ? ax + $signed({7'd0, dxr}) : $signed({7'd0, dxr});
    wire signed [15:0] ny = rel ? ay + $signed({7'd0, dyr}) : $signed({7'd0, dyr});
    wire signed [9:0]  nsx = {nx[8], nx[8:0]};      // sext9(x & 0x1ff)
    wire signed [9:0]  nsy = {ny[8], ny[8:0]};
    // A 16x16 tile at (sx, sy) touches the plane iff it overlaps columns 0..255 and
    // rows ROW0 .. ROW0+ROWS-1.  (MAME clips; skipping the fetch just saves time.)
    wire signed [10:0] nsy11 = {nsy[9], nsy};
    wire off_row = (nsy11 + 11'sd15 < $signed(ROW0[10:0])) ||
                   (nsy11 >= $signed(ROW0[10:0]) + $signed(ROWS[10:0]));
    wire off_col = (nsx > 10'sd255) || (nsx < -10'sd15);
    wire skip    = off_row || off_col;

    always @(posedge clk) begin
        sh_we <= 1'b0;
        pl_we <= 1'b0;
        vis_d <= visible;

        // stage A -> stage B, and the plane write from stage B
        pA_valid <= 1'b0;
        pB_valid <= pA_valid;
        pB_hi    <= pA_hi;
        pB_lane  <= pA_lane;
        pB_bank  <= pA_bank;
        pB_x     <= pA_x;
        pB_y     <= pA_y;
        if (pB_valid && nib != 4'd0 &&
            pB_x >= 11'sd0 && pB_x < 11'sd256 && pB_y >= 11'sd0 && pB_y < ROWS[10:0]) begin
            pl_we   <= 1'b1;
            pl_addr <= {pB_y[7:0], pB_x[7:0]};
            pl_data <= {pB_bank, nib};
        end

        if (rst) begin
            state    <= S_IDLE;
            b_req    <= 1'b0;
            overrun  <= 1'b0;
            n_drawn  <= 10'd0;
            pB_valid <= 1'b0;
            pl_we    <= 1'b0;
        end else begin
            case (state)
            S_IDLE: begin
                if (start) begin
                    state     <= S_COPY;
                    cnt       <= 13'd0;
                    live_addr <= 12'd0;
                    n_drawn   <= 10'd0;
                end
            end

            // copy the live table into the shadow: the address goes out, the byte
            // is back one clock later and is written the clock after
            S_COPY: begin
                live_addr <= live_addr + 12'd1;
                cnt       <= cnt + 13'd1;
                if (cnt >= 13'd1) begin
                    sh_we    <= 1'b1;
                    sh_waddr <= cnt[11:0] - 12'd1;
                    sh_wdata <= live_q;
                end
                if (cnt == 13'd4096) begin
                    state    <= S_RD;
                    ent      <= 9'd0;
                    ax       <= 16'sd0;
                    ay       <= 16'sd0;
                    rd_phase <= 3'd0;
                end
            end

            // bytes 3..7 of the entry, CPU address {ent[8], byte, ent[7:0]}; the
            // shadow RAM has an address register and a data register, so each
            // byte arrives two phases after its address
            S_RD: begin
                case (rd_phase)
                    3'd0: sh_raddr <= {ent[8], 3'd3, ent[7:0]};
                    3'd1: sh_raddr <= {ent[8], 3'd4, ent[7:0]};
                    3'd2: begin sh_raddr <= {ent[8], 3'd5, ent[7:0]}; e3 <= sh_q; end
                    3'd3: begin sh_raddr <= {ent[8], 3'd6, ent[7:0]}; e4 <= sh_q; end
                    3'd4: begin sh_raddr <= {ent[8], 3'd7, ent[7:0]}; e5 <= sh_q; end
                    3'd5: e6 <= sh_q;
                    3'd6: e7 <= sh_q;
                    default: ;
                endcase
                rd_phase <= rd_phase + 3'd1;
                if (rd_phase == 3'd6) state <= S_CALC;
            end

            S_CALC: begin
                ax    <= nx;
                ay    <= ny;
                sx    <= nsx;
                sy    <= nsy;
                fx    <= e7[7];
                fy    <= e7[6];
                bank  <= e3[7:4];
                code  <= {e7[5:0], e6};
                state <= skip ? S_NEXT : S_FETCH;
            end

            S_FETCH: begin
                b_req   <= 1'b1;
                b_addr  <= {code, 6'd0};              // word address: code * 64
                n_drawn <= n_drawn + 10'd1;
                state   <= S_WAITB;
            end

            S_WAITB: begin
                if (b_done) begin
                    b_req <= 1'b0;
                    state <= S_DRAW;
                    dpix  <= 9'd0;
                end
            end

            S_DRAW: begin
                if (dpix < 9'd256) begin
                    tb_raddr <= boff[6:1];
                    pA_lane  <= boff[0];
                    pA_hi    <= spx[0];
                    pA_bank  <= bank;
                    pA_x     <= {sx[9], sx} + $signed({7'd0, px});
                    pA_y     <= {sy[9], sy} + $signed({7'd0, py}) - $signed(ROW0[10:0]);
                    pA_valid <= 1'b1;
                end
                dpix <= dpix + 9'd1;
                if (dpix == 9'd259) state <= S_NEXT;     // pipeline drained
            end

            S_NEXT: begin
                if (ent == 9'd511) state <= S_IDLE;
                else begin
                    ent      <= ent + 9'd1;
                    rd_phase <= 3'd0;
                    state    <= S_RD;
                end
            end
            default: state <= S_IDLE;
            endcase

            // the pass is meant to finish inside the vertical blank
            if (visible && !vis_d) overrun <= (state != S_IDLE);
        end
    end

endmodule
