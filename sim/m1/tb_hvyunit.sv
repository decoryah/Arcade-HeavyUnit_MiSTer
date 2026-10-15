// M1 testbench: the whole board running the real ROMs.
//
//   +rom_dir=<dir with main.bin sub.bin sound.bin mermaid.bin>   (hvyunit_roms.py split)
//   +frames=<n>        stop after n vblanks            (default 20)
//   +trace=<file>      Z80 I/O trace in MAME taps.log format
//   +dump_dir=<dir>    per-frame state dumps s<F>.bin in the oracle's layout
//   +dsw1=<hex> +dsw2=<hex>
//
// Trace line:  <r|w> <main|sub|snd> F vpos port data pc     (pc is always 0000)
// plus "F n" at each vblank, exactly as sim/oracle/hvyunit_capture.lua writes
// them, so tools/trace_cmp.py can diff the two.  `r snd 02` (YM status polling)
// is omitted, as it is in the MAME capture by default.
//
// No delays or timing controls anywhere: the clock comes from sim_main.cpp
// (Verilator's --timing needs C++20 coroutines, which this WSL's g++ 9 lacks),
// and reset / firmware download are a counter-driven sequence.

module tb_hvyunit (
    input clk
);

    reg rst = 1'b1;

    // clk = 2 x cen6 = 4 x cen3 (a 12 MHz-equivalent clock); jt8051 needs one
    // idle clk between cen6 pulses, which this gives.
    reg [1:0] div = 2'd0;
    always @(posedge clk) div <= div + 2'd1;
    wire cen6 = ~div[0];
    wire cen3 = (div == 2'd0);

    // ------------------------------------------------------------ ROM images
    reg [7:0] main_rom [0:131071];
    reg [7:0] sub_rom  [0:65535];
    reg [7:0] snd_rom  [0:65535];
    reg [7:0] mcu_rom  [0:4095];

    wire [16:0] main_a;
    wire [15:0] sub_a, snd_a;
    wire [ 7:0] main_d = main_rom[main_a];
    wire [ 7:0] sub_d  = sub_rom[sub_a];
    wire [ 7:0] snd_d  = snd_rom[snd_a];

    // firmware download
    reg  [11:0] prog_a = 12'd0;
    reg  [ 7:0] prog_d = 8'd0;
    reg         prog_we = 1'b0;

    reg [7:0] dsw1 = 8'hfe;     // MAME defaults (listxml)
    reg [7:0] dsw2 = 8'hf7;

    wire [1:0] coin_counter, coin_lockout;
    wire signed [15:0] snd;
    wire [8:0] hcnt, vcnt;
    wire       vbl_start;

    // CPU-only bench: the video block is left out (its timing wants a 96 MHz
    // clock; it has its own bench in sim/video)
    hvyunit_core #(.YM_CLK_PER_CEN(4), .VIDEO(0)) dut (
        .clk(clk), .rst(rst), .cen6(cen6), .cen3(cen3), .raster_alt(1'b0),
        .tile_ack(1'b0), .tile_q(16'd0),
        .spr_b_wr(1'b0), .spr_b_idx(6'd0), .spr_b_data(16'd0), .spr_b_done(1'b0),
        .main_rom_addr(main_a), .main_rom_data(main_d),
        .sub_rom_addr(sub_a),   .sub_rom_data(sub_d),
        .snd_rom_addr(snd_a),   .snd_rom_data(snd_d),
        .mcu_prog_addr(prog_a), .mcu_prog_data(prog_d), .mcu_prog_we(prog_we),
        .in0(8'hff), .in1(8'hff), .in2(8'hff), .dsw1(dsw1), .dsw2(dsw2),
        .coin_counter(coin_counter), .coin_lockout(coin_lockout),
        .snd(snd), .hcnt(hcnt), .vcnt(vcnt), .vbl_start(vbl_start)
    );

    // ------------------------------------------------------------- loading
    string rom_dir, trace_file, dump_dir;
    integer frames_to_run;
    integer fd, n, i;

    initial begin
        if (!$value$plusargs("rom_dir=%s", rom_dir)) begin
            $display("tb: +rom_dir=<dir> is required"); $finish;
        end
        if (!$value$plusargs("frames=%d", frames_to_run)) frames_to_run = 20;
        if ($value$plusargs("dsw1=%h", i)) dsw1 = i[7:0];
        if ($value$plusargs("dsw2=%h", i)) dsw2 = i[7:0];

        fd = $fopen({rom_dir, "/main.bin"}, "rb");
        if (fd == 0) begin $display("tb: cannot open main.bin"); $finish; end
        n = $fread(main_rom, fd); $fclose(fd);
        fd = $fopen({rom_dir, "/sub.bin"}, "rb");
        n = $fread(sub_rom, fd);  $fclose(fd);
        fd = $fopen({rom_dir, "/sound.bin"}, "rb");
        n = $fread(snd_rom, fd);  $fclose(fd);
        fd = $fopen({rom_dir, "/mermaid.bin"}, "rb");
        n = $fread(mcu_rom, fd);  $fclose(fd);
        $display("tb: ROMs loaded from %s", rom_dir);
    end

    // Reset, then download the 8751 firmware the way the MiSTer ioctl would,
    // then hold reset a while longer (jt8051 and jt03 want a long one).
    localparam integer DL_START = 8;
    localparam integer DL_END   = DL_START + 4096;
    localparam integer RST_END  = DL_END + 400;
    integer cyc = 0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        prog_we <= 1'b0;
        if (cyc >= DL_START && cyc < DL_END) begin
            prog_a  <= cyc - DL_START;
            prog_d  <= mcu_rom[cyc - DL_START];
            prog_we <= 1'b1;
        end
        if (cyc == RST_END) rst <= 1'b0;
    end

    // -------------------------------------------------------------- tracing
    integer tfd = 0;
    integer frame = 0;
    initial begin
        if ($value$plusargs("trace=%s", trace_file)) tfd = $fopen(trace_file, "w");
    end

    // previous-clk copies: the end of a bus cycle is when RD_n/WR_n rises, and
    // the address/data must be the ones that were on the bus during it.
    // idle (all high) until a real cycle has been seen: an all-zero start value
    // would read as an active bus cycle and log a phantom access at time 0
    reg [2:0] m_ctl_d = 3'b111, s_ctl_d = 3'b111, z_ctl_d = 3'b111;   // {iorq_n, rd_n, wr_n}
    reg [7:0] m_p_d, s_p_d, z_p_d;           // port (a[7:0])
    reg [7:0] m_wd_d, s_wd_d, z_wd_d;        // write data
    reg [7:0] m_rd_d, s_rd_d, z_rd_d;        // read data on the bus

    task automatic tlog(input string kind, input string cpu, input [7:0] port, input [7:0] data);
        begin
            if (tfd != 0)
                $fdisplay(tfd, "%s %s %0d %0d %02x %02x 0000", kind, cpu, frame, vcnt, port, data);
        end
    endtask

    always @(posedge clk) begin
        // I/O cycles only; the CPUs are held in reset (and their pins are
        // undefined) until rst drops, so nothing is logged before that.
        if (!rst) begin
            if (!m_ctl_d[2] && !m_ctl_d[0] && dut.m_wr_n)  tlog("w", "main", m_p_d, m_wd_d);
            if (!m_ctl_d[2] && !m_ctl_d[1] && dut.m_rd_n)  tlog("r", "main", m_p_d, m_rd_d);
            if (!s_ctl_d[2] && !s_ctl_d[0] && dut.s_wr_n)  tlog("w", "sub",  s_p_d, s_wd_d);
            if (!s_ctl_d[2] && !s_ctl_d[1] && dut.s_rd_n) begin
                tlog("r", "sub",  s_p_d, s_rd_d);
                // same 'q' line the MAME capture writes with HV_MCUPC=1
                if (tfd != 0 && mcu_trace)
                    $fdisplay(tfd, "q %0d %0d %02x %02x %04x", frame, vcnt, s_p_d, s_rd_d, mcu_pc);
            end
            if (!z_ctl_d[2] && !z_ctl_d[0] && dut.z_wr_n)  tlog("w", "snd",  z_p_d, z_wd_d);
            if (!z_ctl_d[2] && !z_ctl_d[1] && dut.z_rd_n && z_p_d != 8'h02) tlog("r", "snd", z_p_d, z_rd_d);
        end

        m_ctl_d <= rst ? 3'b111 : {dut.m_iorq_n, dut.m_rd_n, dut.m_wr_n};
        s_ctl_d <= rst ? 3'b111 : {dut.s_iorq_n, dut.s_rd_n, dut.s_wr_n};
        z_ctl_d <= rst ? 3'b111 : {dut.z_iorq_n, dut.z_rd_n, dut.z_wr_n};
        m_p_d <= dut.ma[7:0]; s_p_d <= dut.sa[7:0]; z_p_d <= dut.za[7:0];
        m_wd_d <= dut.m_do;   s_wd_d <= dut.s_do;   z_wd_d <= dut.z_do;
        m_rd_d <= dut.m_di;   s_rd_d <= dut.s_di;   z_rd_d <= dut.z_di;
    end

    // ------------------------------------------------- 8751 internal tracing
    // 'm' lines are ignored by trace_cmp.py; they exist to see what the
    // Mermaid firmware is doing (the MAME capture cannot see inside the MCU).
    wire [3:0]  mcu_we  = dut.u_mermaid.port_we;
    wire [15:0] mcu_pc  = dut.u_mermaid.u_mcu.u_mcu.pc;
    always @(posedge clk) begin
        if (!rst && tfd != 0 && mcu_trace) begin
            if (mcu_we[0]) $fdisplay(tfd, "m %0d %0d %0d P0 %02x pc=%04x", frame, vcnt, hcnt, dut.u_mermaid.p0_o, mcu_pc);
            if (mcu_we[1]) $fdisplay(tfd, "m %0d %0d %0d P1 %02x pc=%04x", frame, vcnt, hcnt, dut.u_mermaid.p1_o, mcu_pc);
            if (mcu_we[2]) $fdisplay(tfd, "m %0d %0d %0d P2 %02x pc=%04x", frame, vcnt, hcnt, dut.u_mermaid.p2_o, mcu_pc);
            if (mcu_we[3]) $fdisplay(tfd, "m %0d %0d %0d P3 %02x pc=%04x", frame, vcnt, hcnt, dut.u_mermaid.p3_o, mcu_pc);
            if (dut.sub_wr) $fdisplay(tfd, "m %0d %0d %0d SUBLATCH_WR %02x", frame, vcnt, hcnt, dut.sub_wdata);
            if (dut.mer_rd) $fdisplay(tfd, "m %0d %0d %0d MERLATCH_RD %02x pend_before=%b", frame, vcnt, hcnt, dut.mer_latch, dut.mer_pend);
        end
    end
    reg mcu_trace = 1'b0;
    initial mcu_trace = $test$plusargs("mcu_trace");

    // +mcu_itrace=<frame>: instruction-level trace (pc, A, SP, PSW, DPTR) of the
    // 8751 for one frame, one line per PC change.  Written to the same file as
    // 'i' lines.
    integer itrace_frame;
    reg     itrace_on = 1'b0;
    initial itrace_on = $value$plusargs("mcu_itrace=%d", itrace_frame);
    reg [15:0] last_pc;
    wire [7:0]  mcu_a   = dut.u_mermaid.u_mcu.u_mcu.a;
    wire [7:0]  mcu_sp  = dut.u_mermaid.u_mcu.u_mcu.sp;
    wire [7:0]  mcu_psw = dut.u_mermaid.u_mcu.u_mcu.psw;
    wire [15:0] mcu_dptr= dut.u_mermaid.u_mcu.u_mcu.dptr;
    always @(posedge clk) begin
        last_pc <= mcu_pc;
        if (!rst && tfd != 0 && itrace_on && frame == itrace_frame && mcu_pc != last_pc)
            $fdisplay(tfd, "i %0d %0d pc=%04x a=%02x sp=%02x psw=%02x dptr=%04x p1pin=%02x",
                      frame, vcnt, mcu_pc, mcu_a, mcu_sp, mcu_psw, mcu_dptr, dut.u_mermaid.p1_shadow);
    end

    // where is the MCU while it is quiet?  sampled once per raster line
    reg [8:0] vcnt_d;
    always @(posedge clk) begin
        vcnt_d <= vcnt;
        if (!rst && tfd != 0 && mcu_trace && vcnt != vcnt_d)
            $fdisplay(tfd, "p %0d %0d pc=%04x", frame, vcnt, mcu_pc);
    end

    // ---------------------------------------------------------- state dumps
    integer dfd;
    reg do_dump = 1'b0;
    initial do_dump = $value$plusargs("dump_dir=%s", dump_dir);

    task automatic dump_state(input integer f);
        integer k;
        string  nm;
        begin
            nm = $sformatf("%s/s%05d.bin", dump_dir, f);
            dfd = $fopen(nm, "wb");
            for (k = 0; k < 4096; k = k + 1) $fwrite(dfd, "%c", dut.u_spr.mem[k]);
            for (k = 0; k < 1024; k = k + 1) $fwrite(dfd, "%c", dut.u_vram.mem[k]);
            for (k = 0; k < 1024; k = k + 1) $fwrite(dfd, "%c", dut.u_cram.mem[k]);
            for (k = 0; k <  512; k = k + 1) $fwrite(dfd, "%c", dut.u_pale.mem[k]);
            for (k = 0; k <  512; k = k + 1) $fwrite(dfd, "%c", dut.u_pall.mem[k]);
            $fwrite(dfd, "%c%c%c", dut.scroll_x, dut.scroll_y, dut.sub_p0);
            for (k = 0; k < 13; k = k + 1) $fwrite(dfd, "%c", 8'h00);
            $fclose(dfd);
            // the 8751's internal RAM, same instant (MAME side: HV_MCU=1)
            nm  = $sformatf("%s/mcu_m%05d.bin", dump_dir, f);
            dfd = $fopen(nm, "wb");
            for (k = 0; k < 128; k = k + 1) $fwrite(dfd, "%c", dut.u_mermaid.u_mcu.iram[k]);
            $fclose(dfd);
        end
    endtask

    // ---------------------------------------------------------- frame loop
    always @(posedge clk) begin
        if (vbl_start && !rst) begin
            if (tfd != 0) $fdisplay(tfd, "F %0d", frame);
            if (do_dump) dump_state(frame);
            frame = frame + 1;
            if (frame % 10 == 0)
                $display("tb: frame %0d  sub_run=%b  coin=%b lock=%b", frame, dut.sub_run, coin_counter, coin_lockout);
            if (frame >= frames_to_run) begin
                if (tfd != 0) $fclose(tfd);
                $display("tb: done after %0d frames", frame);
                $finish;
            end
        end
    end

endmodule
