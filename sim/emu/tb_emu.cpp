// End-to-end bench of the MiSTer top (HeavyUnit.sv): plays the HPS. It
//   * resets, waits for the PLL stand-in and the SDRAM,
//   * streams the ROM image through the ioctl port (MRA index 0), a byte per STRIDE
//     clocks and held off by ioctl_wait, then the two DIP bytes (index 254),
//     or, with FAST=1, models Main_MiSTer's address="0x32000000" path: the image copied
//     into the DDR3, then a download of no bytes that the core replays into its loader,
//   * checks the graphics words the loader put into the SDRAM chip,
//   * runs frames from the machine's reset release, capturing the picture as the scaler
//     gets it (VGA_*, 256 x 224) and checking the raster (frame period, rows, geometry),
//     optionally replaying the oracle's coin / start / fire stimulus (HV_PLAY),
//   * writes f<F>.rgb for the frames asked for, in the numbering of the MAME oracle,
//     which tools/video_cmp.py compares with frames/f<F>.raw.
//
//   tb_emu <image> <frames> <out-dir>
// <image> is the MRA's flat image (0x2C1000 bytes; tools/hvyunit_roms.py build).
//
// Environment:
//   DUMP=a:b[:step]   frames to write as f<F>.rgb (default: none)
//   PLAY=1            the oracle's HV_PLAY stimulus: coin at COIN (420) for 8 frames, start at START (480) for 8,
//                     then right held from START+30 and fire every 8 frames
//   SCALE, AR, HW, HH (build 2: the Scale option, see run_emu.sh)
//   FAST=1            load through the DDR3 (build 2)
//   STRIDE=n          clocks per downloaded byte (default 2)
#include "Vtb_emu_top.h"
#include "Vtb_emu_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vtb_emu_top *dut;
static unsigned long long cycles = 0;
#define HPSV(n) dut->rootp->tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__##n
static inline void tick() { dut->CLK_50M = 0; dut->eval(); dut->CLK_50M = 1; dut->eval(); cycles++; }

static const int VIS_W = 256, VIS_H = 224;
static const long IMG_LEN = 0x2C1000;
// the raster: "TV" 390 x 264 (OSD Video timing 0), or "MAME" 404 x 256 (RASTER=1, status[11]); RASTER_AT=<vsync count>
// switches from the first to the second while the bench runs
static unsigned long long H_TOTAL = 390, V_TOTAL = 264;
static unsigned long long LINE_CLK = 16ull * H_TOTAL, FRAME_CLK = LINE_CLK * V_TOTAL;
static const unsigned long long TV_FRAME_CLK = 16ull * 390 * 264, MAME_FRAME_CLK = 16ull * 404 * 256;
static long raster_at = -1;
static void set_status(int bit, int v);
static const unsigned long long VBL_LINE = 240, VS_LINE = 245;

// the framework's scandoubler (Scandoubler Fx, forced_scandoubler): every line twice, HQ2x also twice as wide
static int sd_mul = 1; static bool sd_hq = false;
static std::vector<unsigned> frame_now(VIS_W * VIS_H), frame_last(VIS_W * VIS_H);
static int de_count = 0;
static bool prev_vs = false;
static long vs_count = 0;                 // VGA_VS pulses since the machine's reset release
static bool released = false;             // the bench has dropped ioctl_download
static unsigned long long last_vs_cycle = 0, release_cycle = 0;
static std::vector<unsigned long long> periods;
static long long audio_nonzero = 0;
static unsigned errors = 0;
static std::string outdir;
static long dump_a = 1, dump_b = 0, dump_s = 1;
static int complete_frames = 0, short_frames = 0;
static long last_complete = -1;

// the geometry of the picture as the monitor gets it
static bool g_prev_hs = false, g_prev_de = false;
static unsigned long long g_hs_clk = 0, g_de_clk = 0, g_vs_clk = 0;
static int g_rows = 0, g_lines = 0; static long g_first = -1;
static long g_smin = 1 << 30, g_smax = -1, g_wmin = 1 << 30, g_wmax = -1;
static int geo_rows = 0, geo_lines = 0; static long geo_first = -1;
static long geo_smin = 0, geo_smax = 0, geo_wmin = 0, geo_wmax = 0;

// the oracle's stimulus (sim/oracle/hvyunit_capture.lua play_inputs), applied at vblank start F
static bool play = false;
static long play_coin = 420, play_start = 480;
static unsigned long long next_vbl_cycle = 0;   // when the next vblank start falls
static long vbl_index = 0;                       // (unused: the vblanks are counted as the line counter reaches them)
static long vbl_seen = 0;                        // the dump index of the next vblank start (first is 0)
static unsigned prev_hu_vcnt = 0;
static void apply_inputs(long F) {
    unsigned j = 0;
    if (F >= play_coin && F < play_coin + 8) j |= 1u << 8;            // coin 1
    if (F >= play_start && F < play_start + 8) j |= 1u << 6;          // start 1P
    if (F >= play_start + 30) j |= 1u << 0;                           // right, held
    // fire: set at F%8==0, cleared at F%8==4, from the frame after START+30
    if (F > play_start + 30 && (F % 8) < 4) j |= 1u << 4;
    HPSV(r_joy0) = j;
}

static void write_rgb(long F) {
    char name[512]; snprintf(name, sizeof name, "%s/f%05ld.rgb", outdir.c_str(), F);
    FILE *f = fopen(name, "wb"); if (!f) return;
    for (int i = 0; i < VIS_W * VIS_H; i++) {
        unsigned v = frame_last[i];
        fputc((v >> 16) & 255, f); fputc((v >> 8) & 255, f); fputc(v & 255, f);
    }
    fclose(f);
}

static void video_watch() {
    if (audio_nonzero == 0 && (dut->AUDIO_L != 0 || dut->AUDIO_R != 0)) audio_nonzero = 1;
    bool hs = dut->VGA_HS, de = dut->VGA_DE;
    if (hs && !g_prev_hs) { g_lines++; g_hs_clk = cycles; }
    if (de && !g_prev_de) {
        long s = (long)(cycles - g_hs_clk); g_de_clk = cycles; g_rows++;
        if (g_first < 0) g_first = (long)(cycles - g_vs_clk);
        if (s < g_smin) g_smin = s; if (s > g_smax) g_smax = s;
    }
    if (!de && g_prev_de) { long w = (long)(cycles - g_de_clk); if (w < g_wmin) g_wmin = w; if (w > g_wmax) g_wmax = w; }
    g_prev_hs = hs; g_prev_de = de;

    bool vs = dut->VGA_VS;
    if (vs && !prev_vs) {                       // a frame's vsync: the picture of line-frame vs_count-1... see below
        geo_first = g_first; geo_rows = g_rows; geo_lines = g_lines; geo_smin = g_smin; geo_smax = g_smax; geo_wmin = g_wmin; geo_wmax = g_wmax;
        g_vs_clk = cycles; g_lines = 0; g_first = -1; g_rows = 0; g_smin = 1 << 30; g_smax = -1; g_wmin = 1 << 30; g_wmax = -1;
        if (released) {
            // VS number k (k >= 1) falls at line 245 of line-frame k-1, after that frame's picture (rows 16..239):
            // the pixels collected since the previous pulse are the picture of line-frame k-1 = oracle frame F
            long F = vs_count;               // vs_count counts the pulses before this one
            if (de_count == VIS_W * VIS_H * sd_mul) {
                frame_last = frame_now; complete_frames++; last_complete = F;
                if (F >= dump_a && F <= dump_b && ((F - dump_a) % dump_s) == 0) write_rgb(F);
            } else if (F == 0 && getenv("CRT") && atoi(getenv("CRT")) && getenv("VSHIFT") && atoi(getenv("VSHIFT")) != 0) {
                // CRT Adjust's V-Shift moves the vertical sync by whole lines, so the first period after the reset
                // release, which starts at the line counter's zero, is a different length (here: two pictures)
                printf("  frame 0: %d visible pixels (V-Shift taking effect)\n", de_count);
            } else {
                short_frames++;
                printf("  frame %ld: %d visible pixels (expect %d)\n", F, de_count, VIS_W * VIS_H * sd_mul);
            }
            if (last_vs_cycle) periods.push_back(cycles - last_vs_cycle);
            last_vs_cycle = cycles;
            vs_count++;
            if (raster_at >= 0 && vs_count == raster_at) set_status(11, 1);   // the menu's Video timing, mid-run
            // the vblank start of line-frame vs_count is 19 + 240 lines after this pulse
            next_vbl_cycle = cycles + (V_TOTAL - VS_LINE + VBL_LINE) * LINE_CLK;
            vbl_index = vs_count;
        }
        de_count = 0;
    }
    prev_vs = vs;
    if (dut->CE_PIXEL && dut->VGA_DE) {
        unsigned px = ((unsigned)dut->VGA_R << 16) | ((unsigned)dut->VGA_G << 8) | dut->VGA_B;
        if (sd_mul == 1) { if (de_count < VIS_W * VIS_H) frame_now[de_count] = px; }
        else {   // scandoubled: keep the even rows (and the even columns of HQ2x's double width) as the 256 x 224 picture
            int w2 = VIS_W * (sd_hq ? 2 : 1), row = de_count / w2, col = de_count % w2;
            if (!(row & 1) && !(sd_hq && (col & 1)) && row / 2 < VIS_H) frame_now[(row / 2) * VIS_W + (sd_hq ? col / 2 : col)] = px;
        }
        de_count++;
    }
    if (play && released) {
        // The capture applies the inputs in MAME's frame_done F, which runs at vblank start F. Do the same here, in the
        // clock the machine's line counter reaches the vblank line (the framework's sync_fix moves the vsync pulse that
        // reaches the monitor by up to a line, so that pulse is not a reference for this: a press that lands a few
        // hundred clocks after the vblank interrupt is seen a frame later by the game's input polling)
        const unsigned vc = dut->rootp->tb_emu_top__DOT__u_emu__DOT__hu_vcnt;
        if (vc == (unsigned)VBL_LINE && prev_hu_vcnt != (unsigned)VBL_LINE) apply_inputs(vbl_seen++);
        prev_hu_vcnt = vc;
    }
}
static void run(long n) { while (n--) { tick(); video_watch(); } }

static void set_status(int bit, int v) {
    int w = bit / 32, b = bit % 32;
    unsigned x = HPSV(r_status)[w];
    HPSV(r_status)[w] = v ? (x | (1u << b)) : (x & ~(1u << b));
}

// stream bytes of data[0..n) as one download of the given index; stride = clocks per byte
static void download(int index, const unsigned char *data, long n, int stride, long addr0 = 0) {
    HPSV(r_index) = index; HPSV(r_download) = 1; HPSV(r_addr) = addr0;
    run(8);
    for (long i = 0; i < n; i++) {
        long guard = 0;
        while (HPSV(r_wait_seen) && guard++ < 1000000) run(1);
        HPSV(r_addr) = addr0 + i; HPSV(r_dout) = data[i]; HPSV(r_wr) = 1; run(1);
        HPSV(r_wr) = 0; run(stride - 1);
    }
    run(40);
    HPSV(r_download) = 0; HPSV(r_index) = 0;
    run(8);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: %s <image> <frames> <out-dir>\n", argv[0]); return 2; }
    const int frames = atoi(argv[2]); outdir = argv[3];
    const int stride = getenv("STRIDE") ? atoi(getenv("STRIDE")) : 2;
    std::vector<unsigned char> img(IMG_LEN);
    FILE *f = fopen(argv[1], "rb"); if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
    if (fread(img.data(), 1, IMG_LEN, f) != (size_t)IMG_LEN) { fprintf(stderr, "short image\n"); return 1; } fclose(f);
    if (getenv("DUMP")) {
        long a = 0, b = 0, s = 1; int n = sscanf(getenv("DUMP"), "%ld:%ld:%ld", &a, &b, &s);
        if (n >= 2) { dump_a = a; dump_b = b; dump_s = n >= 3 && s > 0 ? s : 1; }
    }
    play = getenv("PLAY") && atoi(getenv("PLAY"));
    if (getenv("RASTER_AT")) raster_at = atol(getenv("RASTER_AT"));
    if ((getenv("RASTER") && atoi(getenv("RASTER"))) || raster_at >= 0) {
        // the checks below are against the raster the run ends in
        H_TOTAL = 404; V_TOTAL = 256; LINE_CLK = 16ull * H_TOTAL; FRAME_CLK = LINE_CLK * V_TOTAL;
    }
    if (getenv("COIN"))  play_coin = atol(getenv("COIN"));
    if (getenv("START")) play_start = atol(getenv("START"));

    dut = new Vtb_emu_top;
    dut->HDMI_WIDTH  = getenv("HW") ? atoi(getenv("HW")) : 1920;
    dut->HDMI_HEIGHT = getenv("HH") ? atoi(getenv("HH")) : 1080;
    dut->RESET = 1; run(40); dut->RESET = 0;
    {   // OSD options (status bits as the CONF_STR defines them)
        auto field = [&](int lo, int w, int v) { for (int i = 0; i < w; i++) set_status(lo + i, (v >> i) & 1); };
        // Scale (status[34:32]: 0 Normal, 1 V-Integer, 2 HV-Integer, 3 Narrower HV-Integer, 4 HV-Integer+), Aspect ratio (status[122:121])
        if (getenv("SCALE")) field(32, 3, atoi(getenv("SCALE")));
        if (getenv("AR"))    field(121, 2, atoi(getenv("AR")));
        // CRT Adjust: status[14] on, [19:15] H-Size, [26:20] H-Position, [31:27] V-Shift, with the values as the OSD
        // menu counts them: H-Size 0..+15 then -16..-1 (signed 5-bit), H-Position 0..+28 then -64..-1, V-Shift -16..+15
        if (getenv("RASTER") && atoi(getenv("RASTER"))) set_status(11, 1);
        if (getenv("CRT") && atoi(getenv("CRT"))) set_status(14, 1);
        if (getenv("HSIZE")) { int v = atoi(getenv("HSIZE")); field(15, 5, v & 31); }
        if (getenv("HPOS"))  { int v = atoi(getenv("HPOS"));  field(20, 7, v >= 0 ? v : 93 + v); }
        if (getenv("VSHIFT")) field(27, 5, atoi(getenv("VSHIFT")) & 31);
        // the framework settings the OSD does not hold: forced_scandoubler (MiSTer.ini); Scandoubler Fx is OSD status[5:3]
        if (getenv("FSD") && atoi(getenv("FSD"))) HPSV(r_fsd) = 1;
        if (getenv("FX")) field(3, 3, atoi(getenv("FX")));
        const bool fsd = getenv("FSD") && atoi(getenv("FSD")); const int fx = getenv("FX") ? atoi(getenv("FX")) : 0;
        if (fsd || fx) {
            sd_hq = (fx == 1); sd_mul = sd_hq ? 4 : 2;
            printf("scandoubler on (Fx %d, forced %d): expect %d rows of %d pixels, %d lines a frame\n", fx, (int)fsd, 2 * VIS_H, VIS_W * (sd_hq ? 2 : 1), 2 * (int)V_TOTAL);
        }
    }
    run(40000);                                  // SDRAM init
    printf("up after %llu clocks; loading %ld bytes\n", cycles, IMG_LEN);
    unsigned long long t0 = cycles;
#ifdef HAS_FAST
    if (getenv("FAST") && atoi(getenv("FAST"))) {
        // what Main_MiSTer does for address= on the MRA's index-0 <rom>: the whole assembled image is copied into the DDR3
        // at that address, between the start and the end of a download that carries no bytes, only a start address
        // (ioctl_addr) that is the image's length; hps_io counts one more at the end. The core then replays it
        auto &dd = dut->rootp->tb_emu_top__DOT__ddr__DOT__mem;
        const size_t FLB = 0x400000;                 // beats in the client's window: byte 0x32000000
        for (size_t i = 0; i < (size_t)IMG_LEN / 8; i++) {
            unsigned long long v = 0;
            for (int b = 7; b >= 0; b--) v = (v << 8) | img[i * 8 + b];
            dd[FLB + i] = v;
        }
        HPSV(r_index) = 0; HPSV(r_addr) = IMG_LEN; HPSV(r_download) = 1; run(64);
        HPSV(r_addr) = IMG_LEN + 1; HPSV(r_download) = 0;
        unsigned long long t1 = cycles; long guard = 0;
        const long GUARD = 400000000;
        while (dut->rootp->tb_emu_top__DOT__u_emu__DOT__fast_dl && guard++ < GUARD) run(1);
        printf("fast load: the image replayed from the DDR3 in %llu clocks (%.3f s at 96 MHz)\n", cycles - t1, (cycles - t1) / 96e6);
        if (guard >= GUARD) { printf("  FAIL: the replay did not finish\n"); errors++; }
        run(8);
    } else
#endif
    {
        download(0, img.data(), IMG_LEN, stride);
        printf("image loaded in %llu clocks\n", cycles - t0);
    }
    {   // the loader's work against the layout of target/mister/hvyunit_mem.sv: SDRAM word = (offset - 0x40000) / 2,
        // little-endian (the even byte of the image is the low byte)
        run(4000);
        auto &sd = dut->rootp->tb_emu_top__DOT__chip__DOT__mem;
        unsigned long long words = 0, bad_w = 0;
        for (long off = 0x40000; off < 0x2C0000; off += 2) {
            unsigned want = ((unsigned)img[off + 1] << 8) | img[off];
            size_t w = (size_t)(off - 0x40000) / 2;
            words++;
            if (sd[w] != want) { if (bad_w < 6) printf("  SDRAM word %06zx: %04x, expected %04x\n", w, (unsigned)sd[w], want); bad_w++; }
        }
        printf("loader check: %llu graphics words of the image compared with the SDRAM chip, %llu wrong\n", words, bad_w);
        if (bad_w) { printf("  FAIL: the streamed image is not where the ports read it\n"); errors++; }
    }
    {   // the DIP switches (MRA index 254): DSW1, DSW2, as the MRA's <switches default="FE,F7">
        unsigned char dsw[2] = { 0xFE, 0xF7 };
        if (getenv("DSW1")) dsw[0] = (unsigned char)strtol(getenv("DSW1"), nullptr, 16);
        if (getenv("DSW2")) dsw[1] = (unsigned char)strtol(getenv("DSW2"), nullptr, 16);
        download(254, dsw, 2, 8);
    }
    // the machine's reset follows ioctl_download going low: from here the raster counts from its first line
    released = true; release_cycle = cycles; de_count = 0;
    next_vbl_cycle = cycles + 3 + VBL_LINE * LINE_CLK;     // the registered reset leaves a couple of clocks
    vbl_index = 0;

    unsigned long long guard = 0;
    while (vs_count < frames + 1 && guard++ < 40000000000ull) tick(), video_watch();
    printf("%ld frames after the reset release (%d complete pictures, %d incomplete)\n", vs_count, complete_frames, short_frames);
    if (short_frames) { printf("  FAIL: pictures that were not 256 x 224\n"); errors++; }

    {   // the raster's period: 16 clocks a pixel, 390 x 264
        printf("frame period %llu clocks (expect %llu = %.4f Hz)\n", periods.empty() ? 0ull : periods.back(), FRAME_CLK, 96e6 / (double)FRAME_CLK);
        int ok = 0, bad = 0;
        for (size_t i = 0; i < periods.size(); i++) {
            // a mid-run switch: the frames before it are the TV raster's, the ones after it MAME's
            const bool tv_ok = raster_at >= 0 && periods[i] == TV_FRAME_CLK && (long)i <= raster_at;
            // the one period that spans the switch: the rest of a TV frame (19 lines after the vsync's line 245), then
            // 245 MAME lines; the framework's sync_fix may place the vsync pulse up to a line later
            const long long trans = 16ll * (19 * 390 + 245 * 404);
            const bool sw_ok = raster_at >= 0 && llabs((long long)periods[i] - trans) <= 16 * 404;
            if (periods[i] == FRAME_CLK || tv_ok || sw_ok) ok++;
            else { bad++; if (bad < 6) printf("  frame %zu: period %llu clocks = %.3f lines\n", i, periods[i], periods[i] / (double)LINE_CLK); }
        }
        printf("frame periods: %d whole, %d other\n", ok, bad);
        if (bad) { printf("  FAIL: a frame of the wrong length\n"); errors++; }
    }
    unsigned nonblack = 0; for (unsigned v : frame_last) if (v) nonblack++;
    printf("last complete picture (frame %ld): %u non-black pixels\n", last_complete, nonblack);
    printf("geometry (last frame): %d rows with picture, %d lines a frame; first row %ld clocks after the vsync pulse (%.3f lines);"
           " rows start %ld..%ld clocks after hsync, %ld..%ld clocks wide\n",
           geo_rows, geo_lines, geo_first, geo_first / (double)LINE_CLK, geo_smin, geo_smax, geo_wmin, geo_wmax);
    const bool crt_on = getenv("CRT") && atoi(getenv("CRT")) && sd_mul == 1;
    if (sd_mul > 1) {
        if (geo_rows != 2 * VIS_H || geo_lines != 2 * (int)V_TOTAL) {
            printf("  FAIL: the scandoubled raster should be %d rows in %d lines\n", 2 * VIS_H, 2 * (int)V_TOTAL); errors++;
        }
    } else if (!crt_on) {
        if (geo_rows != VIS_H) { printf("  FAIL: expected %d rows with picture\n", VIS_H); errors++; }
        if (geo_lines != (int)V_TOTAL) { printf("  FAIL: expected %d lines a frame\n", (int)V_TOTAL); errors++; }
        if (geo_wmin != 16 * VIS_W || geo_wmax != 16 * VIS_W) { printf("  FAIL: expected rows %d clocks wide\n", 16 * VIS_W); errors++; }
    } else {
        // CRT Adjust: whole lines still, every row of the picture present, its width the pixel count times the read
        // period (64 + H-Size quarters of a clock per pixel), its place moved by H-Position pixels
        int hs = getenv("HSIZE") ? atoi(getenv("HSIZE")) : 0, hp = getenv("HPOS") ? atoi(getenv("HPOS")) : 0;
        if (geo_rows != VIS_H) { printf("  FAIL: expected %d rows with picture\n", VIS_H); errors++; }
        if (geo_lines != (int)V_TOTAL) { printf("  FAIL: expected %d lines a frame\n", (int)V_TOTAL); errors++; }
        const long want_w = (long)VIS_W * (64 + hs) / 4;            // clocks: pixels * (64+hs)/4 per pixel
        if (labs(geo_wmin - want_w) > 16 || labs(geo_wmax - want_w) > 16) {
            printf("  FAIL: expected rows about %ld clocks wide (H-Size %d), got %ld..%ld\n", want_w, hs, geo_wmin, geo_wmax); errors++;
        }
        printf("CRT Adjust: H-Size %d H-Position %d V-Shift %d: rows start %ld clocks after hsync, %ld..%ld wide\n",
               hs, hp, getenv("VSHIFT") ? atoi(getenv("VSHIFT")) : 0, geo_smin, geo_wmin, geo_wmax);
    }
    if (nonblack == 0) { printf("  FAIL: the picture is blank\n"); errors++; }
    {   // Scale: the size the core asks the scaler for. Worked out here from the picture as it leaves arcade_video (rows,
        // pixels in a row), the OSD settings and the size of the scaler, by the documented rule of the framework: the picture is
        // scaled up by the largest whole factor that fits the height of the scaler; its width follows the aspect ratio (V-Integer)
        // or is a whole multiple of the pixel row (the HV modes: narrower = the multiple below the aspect width, wider = the
        // one above it, HV-Integer = whichever of the two is nearer, the wider one only if it still fits the width)
        const int menu = getenv("SCALE") ? atoi(getenv("SCALE")) : 0, ar = getenv("AR") ? atoi(getenv("AR")) : 0;
        const int HW = dut->HDMI_WIDTH, HH = dut->HDMI_HEIGHT;
        const int rows = geo_rows, w = VIS_W * (sd_hq ? 2 : 1);
        static const int map[5] = {0, 1, 4, 2, 3};                    // the OSD order -> video_freak SCALE
        const int sel = (menu >= 0 && menu <= 4) ? map[menu] : 0;
        // Full Screen (0 / 0) has no proportions for the integer rule to work from: with an integer mode the core
        // gives it the scaler's own (HeavyUnit.sv fs_int), unless the size of the scaler is unknown (direct video)
        const bool fs_int = ar == 1 && sel != 0 && HW != 0 && HH != 0;
        const int arx_in = fs_int ? HW : (ar == 0 ? 4 : ar - 1), ary_in = fs_int ? HH : (ar == 0 ? 3 : 0);
        int ex = arx_in, ey = ary_in; bool eabs = false, checked = true;
        if (sel && !(!ary_in && arx_in) && HH / rows > 0) {
            int oh = rows * (HH / rows), ht = 0, hi, dn;
            if (!ary_in) {                                            // no proportions at all: the framework own rule, reported not judged
                int m = HW / w ? HW / w : 1; hi = w * m; oh = rows * m; dn = HW; checked = false;
            } else {
                ht = (int)((long)oh * arx_in / ary_in); int m0 = ht / w ? ht / w : 1; hi = w * m0; dn = ht;
                if (hi > HW) { int m1 = HW / w ? HW / w : 1; hi = w * m1; oh = rows * m1; dn = HW; }
            }
            const int wide = hi + w;
            const bool narrow = (((ht - hi) & 0xfff) <= ((wide - ht) & 0xfff)) || wide > HW;
            const int wres = hi == ht ? hi : wide;
            switch (sel) {
                case 2: ex = hi; break;
                case 3: ex = wres > HW ? hi : wres; break;
                case 4: ex = narrow ? hi : wres; break;
                default: ex = dn;
            }
            ey = oh; eabs = true;
        }
        const int gx = dut->VIDEO_ARX & 0xfff, gy = dut->VIDEO_ARY & 0xfff, gax = (dut->VIDEO_ARX >> 12) & 1, gay = (dut->VIDEO_ARY >> 12) & 1;
        printf("scale: Scale %d (SCALE %d) Aspect %d, picture %d rows of %d pixels, scaler %d x %d: core asks for %s%d x %s%d; rule gives %s%d x %s%d%s\n",
               menu, sel, ar, rows, w, HW, HH, gax ? "" : "ratio ", gx, gay ? "" : "ratio ", gy, eabs ? "" : "ratio ", ex, eabs ? "" : "ratio ", ey,
               checked ? "" : " (not checked)");
        if (checked && (gx != ex || gy != ey || gax != (int)eabs || gay != (int)eabs)) { printf("  FAIL: the size asked of the scaler\n"); errors++; }
        if (eabs && (HH - ey) < 0) printf("  note: the height asked for is %d pixels over the scaler\n", ey - HH);
    }
    printf("audio samples non-zero seen: %lld\n", audio_nonzero);
    printf("%s: %u errors, %llu clocks\n", errors ? "FAIL" : "PASS", errors, cycles);
    delete dut; return errors ? 1 : 0;
}
