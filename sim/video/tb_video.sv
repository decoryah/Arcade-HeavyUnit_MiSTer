// Video-only bench: one frame of hvyunit_video from MAME state dumps.
//
//   +cap=<oracle dir>       directory with state/s<F>.bin
//   +frame=<F>              the pixel file f<F>.raw this frame must equal
//   +roms=<dir>             tiles.bin and sprites.bin (hvyunit_roms.py split)
//   +out=<file>             256 x 224 x 3 bytes, R G B
//
// Oracle convention (docs/oracle.md): pixel file F is built from tilemap RAM and
// scroll registers of dump F-1, sprite RAM of dump F-2 and the palette of dump F.
//
// The memory ports are behavioural models of the SDRAM controller's client
// interface: a random-access word client (level req, one-clock ack, data valid
// with the ack) and a 64-word burst client, both with a few clocks of latency.
//
// clk is 16 x the pixel enable, as it is on the MiSTer (96 MHz / 6 MHz).
module tb_video (
    input clk
);

    // ------------------------------------------------------------- raster
    reg [3:0] div = 4'd0;
    always @(posedge clk) div <= div + 4'd1;
    wire cen6 = (div == 4'd0);

    reg rst = 1'b1;
    integer cyc = 0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (cyc == 64) rst <= 1'b0;
    end

    wire [8:0] hcnt, vcnt;
    wire       vbl_start, spr_irq;
    wire raster_alt_q;
    hvyunit_timing #(.H_TOTAL(390), .V_TOTAL(264), .VBL_LINE(240), .SPR_LINE(64),
                     .H_TOTAL_ALT(404), .V_TOTAL_ALT(256)) u_timing (
        .clk(clk), .rst(rst), .cen(cen6), .alt(1'b0), .alt_q(raster_alt_q),
        .hcnt(hcnt), .vcnt(vcnt), .vbl_start(vbl_start), .spr_irq(spr_irq)
    );

    // --------------------------------------------------------- state files
    reg [7:0] st_t [0:7183];       // dump F-1: tilemap RAM + scroll
    reg [7:0] st_s [0:7183];       // dump F-2: sprite RAM
    reg [7:0] st_p [0:7183];       // dump F  : palette

    reg [7:0] spr_ram  [0:4095];
    reg [7:0] vram     [0:1023];
    reg [7:0] cram     [0:1023];
    reg [7:0] pal_hi   [0:511];
    reg [7:0] pal_lo   [0:511];
    reg [7:0] scroll_x = 8'd0, scroll_y = 8'd0, port0 = 8'd0;

    reg [7:0] tiles_b   [0:524287];
    reg [7:0] sprites_b [0:2097151];

    string cap, roms, outfile;
    integer frame, fd, n, i;

    initial begin
        if (!$value$plusargs("cap=%s", cap))   begin $display("tb: +cap= required");   $finish; end
        if (!$value$plusargs("roms=%s", roms)) begin $display("tb: +roms= required");  $finish; end
        if (!$value$plusargs("frame=%d", frame)) begin $display("tb: +frame= required"); $finish; end
        if (!$value$plusargs("out=%s", outfile)) outfile = "frame.rgb";

        fd = $fopen($sformatf("%s/state/s%05d.bin", cap, frame - 1), "rb");
        if (fd == 0) begin $display("tb: cannot open state F-1"); $finish; end
        n = $fread(st_t, fd); $fclose(fd);
        fd = $fopen($sformatf("%s/state/s%05d.bin", cap, frame - 2), "rb");
        if (fd == 0) begin $display("tb: cannot open state F-2"); $finish; end
        n = $fread(st_s, fd); $fclose(fd);
        fd = $fopen($sformatf("%s/state/s%05d.bin", cap, frame), "rb");
        if (fd == 0) begin $display("tb: cannot open state F"); $finish; end
        n = $fread(st_p, fd); $fclose(fd);

        for (i = 0; i < 4096; i = i + 1) spr_ram[i] = st_s[i];
        for (i = 0; i < 1024; i = i + 1) begin vram[i] = st_t[4096 + i]; cram[i] = st_t[5120 + i]; end
        for (i = 0; i < 512;  i = i + 1) begin pal_hi[i] = st_p[6144 + i]; pal_lo[i] = st_p[6656 + i]; end
        scroll_x = st_t[7168]; scroll_y = st_t[7169]; port0 = st_t[7170];

        fd = $fopen({roms, "/tiles.bin"}, "rb");   n = $fread(tiles_b, fd);   $fclose(fd);
        fd = $fopen({roms, "/sprites.bin"}, "rb"); n = $fread(sprites_b, fd); $fclose(fd);
        $display("tb: frame %0d  scroll x=%02x y=%02x p0=%02x", frame, scroll_x, scroll_y, port0);
    end

    // ----------------------------------------------------------- the DUT
    wire [9:0]  bg_raddr;
    reg  [7:0]  vram_q, cram_q;
    wire [8:0]  pal_raddr;
    reg  [7:0]  pal_hi_q, pal_lo_q;
    wire [11:0] spr_live_addr;
    reg  [7:0]  spr_live_q;
    wire        spr_hold;
    wire        tile_req;
    wire [17:0] tile_addr;
    reg         tile_ack = 1'b0;
    reg  [15:0] tile_q   = 16'd0;
    wire        spr_b_req;
    wire [19:0] spr_b_addr;
    reg         spr_b_wr = 1'b0, spr_b_done = 1'b0;
    reg  [5:0]  spr_b_idx = 6'd0;
    reg  [15:0] spr_b_data = 16'd0;

    wire [23:0] rgb;
    wire        hsync, vsync, hblank, vblank, de, cen_pix;
    wire        spr_busy, spr_overrun;
    wire [9:0]  spr_count;

    hvyunit_video #(.H_TOTAL(390), .V_TOTAL(264)) dut (
        .clk(clk), .rst(rst), .cen6(cen6), .hcnt(hcnt), .vcnt(vcnt), .vbl_start(vbl_start), .alt(raster_alt_q),
        .scroll_x(scroll_x), .scroll_y(scroll_y), .port0(port0),
        .bg_raddr(bg_raddr), .vram_q(vram_q), .cram_q(cram_q),
        .pal_raddr(pal_raddr), .pal_hi_q(pal_hi_q), .pal_lo_q(pal_lo_q),
        .spr_live_addr(spr_live_addr), .spr_live_q(spr_live_q), .spr_hold(spr_hold),
        .tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
        .spr_b_req(spr_b_req), .spr_b_addr(spr_b_addr), .spr_b_wr(spr_b_wr), .spr_b_idx(spr_b_idx),
        .spr_b_data(spr_b_data), .spr_b_done(spr_b_done),
        .rgb(rgb), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de), .cen_pix(cen_pix),
        .spr_busy(spr_busy), .spr_overrun(spr_overrun), .spr_count(spr_count)
    );

    // synchronous RAM read ports
    always @(posedge clk) begin
        vram_q     <= vram[bg_raddr];
        cram_q     <= cram[bg_raddr];
        pal_hi_q   <= pal_hi[pal_raddr];
        pal_lo_q   <= pal_lo[pal_raddr];
        spr_live_q <= spr_ram[spr_live_addr];
    end

    // ---- tile ROM: random-access word client, 6 clocks of latency
    reg [3:0] t_wait = 4'd0;
    reg       t_busy = 1'b0;
    always @(posedge clk) begin
        tile_ack <= 1'b0;
        if (tile_req && !t_busy) begin
            t_busy <= 1'b1;
            t_wait <= 4'd6;
        end else if (t_busy) begin
            if (t_wait != 4'd0) t_wait <= t_wait - 4'd1;
            else begin
                tile_ack <= 1'b1;
                tile_q   <= {tiles_b[{tile_addr, 1'b1}], tiles_b[{tile_addr, 1'b0}]};
                t_busy   <= 1'b0;
            end
        end
    end

    // ---- sprite ROM: 64-word burst, 10 clocks to the first word then one every 2
    integer b_state = 0;
    integer b_n = 0, b_lat = 0;
    reg [19:0] b_base;
    always @(posedge clk) begin
        spr_b_wr   <= 1'b0;
        spr_b_done <= 1'b0;
        case (b_state)
            0: if (spr_b_req) begin b_base <= spr_b_addr; b_lat <= 10; b_state <= 1; end
            1: begin
                if (b_lat != 0) b_lat <= b_lat - 1;
                else begin b_n <= 0; b_state <= 2; end
            end
            2: begin
                // one word every other clock
                if (b_lat == 0) begin
                    spr_b_wr   <= 1'b1;
                    spr_b_idx  <= b_n[5:0];
                    spr_b_data <= {sprites_b[{b_base + b_n[19:0], 1'b1}], sprites_b[{b_base + b_n[19:0], 1'b0}]};
                    b_n        <= b_n + 1;
                    b_lat      <= 1;
                    if (b_n == 63) b_state <= 3;
                end else b_lat <= b_lat - 1;
            end
            3: begin
                spr_b_done <= 1'b1;
                b_state    <= 4;
            end
            4: if (!spr_b_req) b_state <= 0;
            default: b_state <= 0;
        endcase
    end

    // ------------------------------------------------------------- capture
    reg [7:0] img [0:57343 * 3 + 2];          // 256 x 224 x 3
    integer px = 0, vbl_n = 0;
    reg     de_d = 1'b0;
    integer frames_done = 0;
    integer ofd, k;

    always @(posedge clk) begin
        if (!rst && vbl_start) begin
            vbl_n = vbl_n + 1;
            // vblank 1 starts the sprite pass; the visible area after it is the frame we want;
            // vblank 2 ends the capture
            if (vbl_n == 2) begin
                ofd = $fopen(outfile, "wb");
                for (k = 0; k < 224 * 256 * 3; k = k + 1) $fwrite(ofd, "%c", img[k]);
                $fclose(ofd);
                $display("tb: wrote %s  (%0d pixels captured, sprite entries drawn %0d, overrun=%b)",
                         outfile, px, spr_count, spr_overrun);
                $finish;
            end
        end
        if (cen_pix && de && vbl_n == 1) begin
            img[px * 3 + 0] = rgb[23:16];
            img[px * 3 + 1] = rgb[15:8];
            img[px * 3 + 2] = rgb[7:0];
            px = px + 1;
        end
    end

endmodule
