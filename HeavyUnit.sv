//============================================================================
//
//  Kaneko / Taito "Heavy Unit" (1988) for MiSTer.
//
//  The machine (rtl/hvyunit) is three Z80s, the Mermaid 8751, a YM2203 and
//  Kaneko's Pandora sprite chip, modelled on MAME's hvyunit.cpp and verified
//  against it frame by frame (docs/oracle.md).  This file is its MiSTer
//  platform layer: clocks, memory (target/mister), video, audio, controls and
//  ROM loading through the framework.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;       // signed samples
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire  [21:0] gamma_bus;

// Aspect ratio and Scale. The framework's video_freak (after arcade_video, below) turns the two into VIDEO_ARX/ARY: with
// Scale Normal they pass through as they are; the integer modes replace them with the exact size in pixels (bit 12 set)
// that the HDMI scaler should give the picture. The menu's order is the user's; video_freak's SCALE input counts
// 0 Normal, 1 V-Integer, 2 Narrower HV-Integer, 3 HV-Integer+ (wider), 4 HV-Integer
reg   [2:0] scale_sel;
always @* case (status[34:32])
	3'd1:    scale_sel = 3'd1;   // V-Integer
	3'd2:    scale_sel = 3'd4;   // HV-Integer
	3'd3:    scale_sel = 3'd2;   // Narrower HV-Integer
	3'd4:    scale_sel = 3'd3;   // HV-Integer+
	default: scale_sel = 3'd0;   // Normal
endcase
// Full Screen is ARX = ARY = 0 ("fill"), which has no proportions for the integer rule to size the width from: it sizes
// the height from the width instead and asks for more rows than the screen has. With an integer Scale the screen's own
// proportions stand in for it, so the picture is a whole-number size in the screen's aspect
wire  [1:0] ar         = status[122:121];
wire        fs_int     = (ar == 2'd1) && (scale_sel != 3'd0) && (HDMI_WIDTH != 12'd0) && (HDMI_HEIGHT != 12'd0);
wire [11:0] arx        = fs_int ? HDMI_WIDTH  : (!ar) ? 12'd4 : (ar - 1'd1);     // Original is the monitor's 4:3
wire [11:0] ary        = fs_int ? HDMI_HEIGHT : (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"A.HEAVYUNIT;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[34:32],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer,HV-Integer+;",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[11],Video timing,TV 58.3 Hz,MAME 58.0 Hz;",
	"P1,CRT Adjust;",
	"P1O[14],CRT Adjust,Off,On;",
	"H1P1O[19:15],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[26:20],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,-64,-63,-62,-61,-60,-59,-58,-57,-56,-55,-54,-53,-52,-51,-50,-49,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[31:27],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"DIP;",
	"-;",
	"O[10],SDRAM read capture,Normal,Late;",
	"R0,Reset;",
	"J1,Fire,Bomb,Start 1P,Start 2P,Coin;",
	"jn,A,B,Start,Select,R;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;           // 96 MHz: the whole machine
wire clk_sdram;         // 96 MHz, shifted: the SDRAM chip's clock pin
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.locked(pll_locked)
);

// 6 MHz: the three Z80s, the 8751's oscillator and the dot clock (a pixel every
// 16 clocks); 3 MHz: the YM2203
reg [4:0] clk_div;
always @(posedge clk_sys) clk_div <= clk_div + 5'd1;
wire cen6 = (clk_div[3:0] == 4'd0);
wire cen3 = (clk_div[4:0] == 5'd0);

///////////////////////////////////////////////////

wire         ioctl_download;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire         ioctl_wait;

wire  [31:0] joystick_0, joystick_1;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, ~status[14], direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.video_rotated(1'b0),
	.direct_video(direct_video),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

///////////////////////   CONTROLS   ///////////////////////

// keyboard: 1 / 2 start, 5 / 6 coin, F2 service (MAME's defaults)
reg key_start1, key_start2, key_coin1, key_coin2, key_service;
always @(posedge clk_sys) begin
	reg old_stb;
	old_stb <= ps2_key[10];
	if (old_stb != ps2_key[10]) begin
		case (ps2_key[7:0])
			8'h16: key_start1  <= ps2_key[9];      // 1
			8'h1E: key_start2  <= ps2_key[9];      // 2
			8'h2E: key_coin1   <= ps2_key[9];      // 5
			8'h36: key_coin2   <= ps2_key[9];      // 6
			8'h06: key_service <= ps2_key[9];      // F2
			default: ;
		endcase
	end
end

// joystick bits: 0 right, 1 left, 2 down, 3 up, 4 fire, 5 bomb, 6 start 1P, 7 start 2P, 8 coin
wire [31:0] j0 = joystick_0, j1 = joystick_1;

// the board's input ports, active low (MAME's IN0 / IN1 / IN2):
//   IN0: bit0 start 1, 1 start 2, 2 coin 1, 3 coin 2, 6 service
//   IN1 / IN2: bit0 up, 1 down, 2 left, 3 right, 4 button 1, 5 button 2
wire [7:0] in0 = ~{1'b0, key_service, 2'b00,
                   j1[8] | key_coin2, j0[8] | key_coin1,
                   j0[7] | j1[6] | key_start2, j0[6] | key_start1};
wire [7:0] in1 = ~{2'b00, j0[5], j0[4], j0[0], j0[1], j0[2], j0[3]};
wire [7:0] in2 = ~{2'b00, j1[5], j1[4], j1[0], j1[1], j1[2], j1[3]};

// DIP switches: MRA index 254, byte 0 = DSW1, byte 1 = DSW2
reg [7:0] sw [8];
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index[7:0] == 8'd254) && !ioctl_addr[26:3]) sw[ioctl_addr[2:0]] <= ioctl_dout;

///////////////////////   MEMORIES   ///////////////////////

wire rom_dl = ioctl_download && (ioctl_index[7:0] == 8'd0);
wire dl_we  = rom_dl && ioctl_wr;

reg  rom_dl_d;
always @(posedge clk_sys) rom_dl_d <= rom_dl;
wire dl_start = rom_dl && !rom_dl_d;
wire dl_done  = !rom_dl && rom_dl_d;

// Fast load: with address= on the MRA's index-0 <rom>, Main_MiSTer copies the whole assembled image into the DDR3 in one
// go and then ends a download that has no data bytes, only a start address: the image's length (ioctl_addr, which
// is 0 at the start of an ordinary download). The machine stays in reset from that start until hvyunit_fastload has
// read the image back and pushed it through the loader (fl_done). An older Main_MiSTer ignores the attribute and
// streams the bytes as before; nothing here touches that path
reg         fast_dl /*verilator public_flat_rd*/ = 1'b0;
reg  [24:0] fast_len;
wire        fl_go   = fast_dl && dl_done;
wire        fl_done;
always @(posedge clk_sys) begin
	if (dl_start) begin fast_dl <= (ioctl_addr != 27'd0); fast_len <= ioctl_addr[24:0]; end
	else if (fl_done) fast_dl <= 1'b0;
end

wire        mem_init = ~pll_locked | RESET;
wire        mem_ready;

wire [16:0] main_addr; wire [7:0] main_q;
wire [15:0] sub_addr;  wire [7:0] sub_q;
wire [15:0] snd_addr;  wire [7:0] snd_q;
wire        mcu_we;    wire [11:0] mcu_addr; wire [7:0] mcu_data;
wire        tile_req, tile_ack;  wire [17:0] tile_addr;  wire [15:0] tile_q;
wire        spr_b_req, spr_b_wr, spr_b_done;
wire [19:0] spr_b_addr; wire [5:0] spr_b_idx; wire [15:0] spr_b_data;

wire        dram_cke;
wire  [1:0] dram_dqm;

// the loader's byte port: the HPS's stream, or the fast load's replay of the image
wire        fl_we;
wire [24:0] fl_addr;
wire  [7:0] fl_data;
wire        dl_idle;

hvyunit_mem u_mem
(
	.clk(clk_sys), .clk_sdram(clk_sdram), .init(mem_init), .rd_late(status[10]), .ready(mem_ready),
	.dl_we(dl_we | fl_we), .dl_addr(fl_we ? fl_addr : ioctl_addr[24:0]), .dl_data(fl_we ? fl_data : ioctl_dout),
	.dl_wait(ioctl_wait), .dl_idle(dl_idle),
	.main_addr(main_addr), .main_q(main_q),
	.sub_addr(sub_addr),   .sub_q(sub_q),
	.snd_addr(snd_addr),   .snd_q(snd_q),
	.mcu_we(mcu_we), .mcu_addr(mcu_addr), .mcu_data(mcu_data),
	.tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
	.spr_b_req(spr_b_req), .spr_b_addr(spr_b_addr), .spr_b_wr(spr_b_wr), .spr_b_idx(spr_b_idx),
	.spr_b_data(spr_b_data), .spr_b_done(spr_b_done),
	.dram_dq(SDRAM_DQ), .dram_a(SDRAM_A), .dram_ba(SDRAM_BA), .dram_dqm(dram_dqm),
	.dram_clk(SDRAM_CLK), .dram_cke(dram_cke), .dram_ras_n(SDRAM_nRAS), .dram_cas_n(SDRAM_nCAS), .dram_we_n(SDRAM_nWE)
);
assign SDRAM_CKE  = dram_cke;
assign SDRAM_nCS  = 1'b0;
assign {SDRAM_DQMH, SDRAM_DQML} = dram_dqm;

// DDR3: only the fast load's reads of the image (the machine itself has no use for it). The core's window is the
// 256 MB at byte 0x30000000; the image is at 0x32000000 in it
wire        fl_ddr_rd;
wire [24:0] fl_ddr_addr;
wire  [7:0] fl_ddr_burst;

hvyunit_fastload u_fast
(
	.clk(clk_sys), .reset(~pll_locked),
	.go(fl_go), .len(fast_len), .done(fl_done),
	.dl_wait(ioctl_wait), .dl_idle(dl_idle), .dl_we(fl_we), .dl_addr(fl_addr), .dl_data(fl_data),
	.ddr_busy(DDRAM_BUSY), .ddr_rd(fl_ddr_rd), .ddr_addr(fl_ddr_addr), .ddr_burst(fl_ddr_burst),
	.ddr_dout(DDRAM_DOUT), .ddr_dready(DDRAM_DOUT_READY)
);
assign DDRAM_CLK      = clk_sys;
assign DDRAM_BURSTCNT = fl_ddr_burst;
assign DDRAM_ADDR     = {4'd3, fl_ddr_addr};
assign DDRAM_RD       = fl_ddr_rd;
assign DDRAM_DIN      = 64'd0;
assign DDRAM_BE       = 8'd0;
assign DDRAM_WE       = 1'b0;

///////////////////////   THE MACHINE   ///////////////////////

// the machine's reset is registered: it fans out to three CPUs and the MCU
wire        hu_reset_c = RESET | status[0] | buttons[1] | ioctl_download | fast_dl | ~mem_ready;
reg         hu_reset = 1'b1;
always @(posedge clk_sys) hu_reset <= hu_reset_c;

wire [23:0] hu_rgb;
wire        hu_hs, hu_vs, hu_hb, hu_vb, hu_de, hu_cen_pix;
wire signed [15:0] hu_snd;
wire        hu_spr_overrun;
wire  [8:0] hu_vcnt;
wire        hu_alt;                     // the raster in force (0 TV, 1 MAME)

hvyunit_core #(
	.YM_CLK_PER_CEN(32),
	// Video timing (OSD, status[11]), taken at the start of a frame:
	//   0, "TV": 390 x 264 at 6 MHz = 58.27 Hz / 15.38 kHz (the board measures about 58 Hz / 15.59 kHz). The line and
	//      frame counts sit among those of the other MiSTer arcade cores (264 lines, vsync 8 lines, 251 lines in the
	//      HDMI picture): the RetroTINK 4K sorts a direct-video signal into a class by its timing (240p, 288p, ...)
	//      and only treats a known class properly when the MiSTer menu opens (docs/ARCHITECTURE.md section 14).
	//   1, "MAME": 404 x 256 = 58.01 Hz / 14.85 kHz, MAME's model of the board (a 256-line frame at 58 Hz), so the
	//      vblank and sprite IRQs fall at the same fractions of the frame as in MAME.
	// The picture starts 97 pixels after the hsync pulse in both, and vsync is 8 lines starting at line 245.
	.H_TOTAL(390), .V_TOTAL(264), .VBL_LINE(240), .SPR_LINE(64),
	.HS_START(293), .HS_LEN(32), .VS_START(245), .VS_LEN(8),
	.H_TOTAL_ALT(404), .V_TOTAL_ALT(256), .HS_START_ALT(307), .VS_START_ALT(245),
	.VIDEO(1)
) hu
(
	.clk(clk_sys), .rst(hu_reset), .cen6(cen6), .cen3(cen3),
	.raster_alt(status[11]), .raster_alt_q(hu_alt),
	.main_rom_addr(main_addr), .main_rom_data(main_q),
	.sub_rom_addr(sub_addr),   .sub_rom_data(sub_q),
	.snd_rom_addr(snd_addr),   .snd_rom_data(snd_q),
	.mcu_prog_addr(mcu_addr), .mcu_prog_data(mcu_data), .mcu_prog_we(mcu_we),
	.in0(in0), .in1(in1), .in2(in2), .dsw1(sw[0]), .dsw2(sw[1]),
	.coin_counter(), .coin_lockout(),
	.snd(hu_snd),
	.tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
	.spr_b_req(spr_b_req), .spr_b_addr(spr_b_addr), .spr_b_wr(spr_b_wr), .spr_b_idx(spr_b_idx),
	.spr_b_data(spr_b_data), .spr_b_done(spr_b_done),
	.rgb(hu_rgb), .hsync(hu_hs), .vsync(hu_vs), .hblank(hu_hb), .vblank(hu_vb), .de(hu_de), .cen_pix(hu_cen_pix),
	.spr_busy(), .spr_overrun(hu_spr_overrun), .spr_count(),
	.hcnt(), .vcnt(hu_vcnt), .vbl_start()
);

///////////////////////   AUDIO   ///////////////////////

// the YM2203's mono output on both channels
assign AUDIO_L = hu_snd;
assign AUDIO_R = hu_snd;

///////////////////////   VIDEO   ///////////////////////

// The core emits one pixel per 6 MHz enable on the 96 MHz clock and holds it for the sixteen clocks. hu_hb is the
// horizontal blank alone (it toggles on every line of the frame) and hu_vb the vertical blank, which is what the
// framework's scandoubler wants for its line timing; hu_de is the visible rectangle. hblank_c, the combined blank, is
// what CRT Adjust (hb_in) wants.
wire hblank_c = ~hu_de;

// the finished picture's signals, one clock later, before they meet the CRT Adjust select
reg [23:0] vq_rgb;
reg        vq_hb, vq_hbh, vq_vb, vq_hs, vq_vs, vq_ce;
always @(posedge clk_sys) begin
	vq_rgb <= hu_rgb; vq_hb <= hblank_c; vq_hbh <= hu_hb; vq_vb <= hu_vb; vq_hs <= hu_hs; vq_vs <= hu_vs; vq_ce <= hu_cen_pix;
end

// CRT Adjust: the size, horizontal position and vertical position of the picture on a 15 kHz analog output
// (rmonic79's MiSTer-CRT-Adjust, modules/crt-adjust). The picture goes through a line buffer and is read out
// at a different pixel rate (H-Size) or a different place in the line (H-Position), and the vertical sync is
// delayed by whole lines (V-Shift); the sync pulses themselves keep their rate, so the monitor stays locked.
// Off, the picture takes the path it always had. It does nothing while the scandoubler is in use (31 kHz).
wire crt_sd = (|status[5:3]) | forced_scandoubler;
// the visible rows of the core (rows 16..239 of its 264 lines): the module needs the vertical blank of the *next* line,
// because the hsync pulse (pixel 288) falls after the line's own picture and the buffer line it starts holds the next
localparam [8:0] VIS_Y0 = 9'd16, VIS_H = 9'd224;
wire crt_vb_next = ~(hu_vcnt >= VIS_Y0 - 9'd1 && hu_vcnt < VIS_Y0 + VIS_H - 9'd1);

// the OSD values, as the menu counts them: H-Size 0..+15 then -16..-1 (a signed 5-bit number; a step is 1/64
// of the picture's width, 4 pixels), H-Position 0..+28 then -64..-1, V-Shift signed 5-bit.
// The picture is 256 pixels in a line of 390, i.e. two thirds of the line against a TV's four fifths: that is
// the board's own timing (the arcade monitor's size controls make up for it) and why it looks small on a CRT.
// H-Size stretches the picture about its OWN CENTRE (crt_hcen below): the module counts its read-out from the
// hsync pulse, so growing it would otherwise push the picture to the right and off the end of the line.
// +11 fills about as much as a TV picture (300 of 390 pixel times, 77 %); +15 is the most the line holds
// (316 of 390, with a few pixels of front porch left). H-Position moves it from there (0..+28 right, -64..-1 left).
// The hsync pulse sits 97 pixels before the picture (390 - 293), as it always has, so the centring below is unchanged.
localparam signed [8:0] CRT_HBIAS = -9'sd1;     // cancels the module's own one-pixel delay of the picture
wire signed [5:0] crt_hsz = $signed(status[19:15]);
wire        [6:0] crt_hp = status[26:20];
wire signed [8:0] crt_hpos = (crt_hp <= 7'd28) ? $signed({2'b00, crt_hp}) : $signed({2'b00, crt_hp}) - 9'sd93;
// the content shift that keeps the picture's centre (pixel 225 of the buffer line: 97 + 128) where it is when the
// read period is (64 + H-Size) / 64 of a pixel: -225 * H-Size / (64 + H-Size), rounded
reg signed [8:0] crt_hcen;
always @* case (crt_hsz[4:0])
	5'd0:  crt_hcen =   9'sd0;
	5'd1:  crt_hcen =  -9'sd3;
	5'd2:  crt_hcen =  -9'sd7;
	5'd3:  crt_hcen = -9'sd10;
	5'd4:  crt_hcen = -9'sd13;
	5'd5:  crt_hcen = -9'sd16;
	5'd6:  crt_hcen = -9'sd19;
	5'd7:  crt_hcen = -9'sd22;
	5'd8:  crt_hcen = -9'sd25;
	5'd9:  crt_hcen = -9'sd28;
	5'd10: crt_hcen = -9'sd30;
	5'd11: crt_hcen = -9'sd33;
	5'd12: crt_hcen = -9'sd36;
	5'd13: crt_hcen = -9'sd38;
	5'd14: crt_hcen = -9'sd40;
	5'd15: crt_hcen = -9'sd43;
	5'd16: crt_hcen =  9'sd75;   // -16
	5'd17: crt_hcen =  9'sd69;
	5'd18: crt_hcen =  9'sd63;
	5'd19: crt_hcen =  9'sd57;
	5'd20: crt_hcen =  9'sd52;
	5'd21: crt_hcen =  9'sd47;
	5'd22: crt_hcen =  9'sd42;
	5'd23: crt_hcen =  9'sd37;
	5'd24: crt_hcen =  9'sd32;
	5'd25: crt_hcen =  9'sd28;
	5'd26: crt_hcen =  9'sd23;
	5'd27: crt_hcen =  9'sd19;
	5'd28: crt_hcen =  9'sd15;
	5'd29: crt_hcen =  9'sd11;
	5'd30: crt_hcen =  9'sd7;
	default: crt_hcen = 9'sd4;   // -1
endcase
// the picture is read a line after it is written, so the sync is delayed one line to keep its place; a positive
// V-Shift moves the picture down, which is the sync coming earlier. Negative delays count from the frame length
// the module is built for (264 lines); in the 256-line MAME raster they count from 256, i.e. 8 lines fewer
wire signed [6:0] crt_vs_t = 7'sd1 - $signed({status[31], status[31], status[31:27]});
wire signed [6:0] crt_vs_a = (hu_alt && crt_vs_t[6]) ? crt_vs_t - 7'sd8 : crt_vs_t;
reg               crt_on;
reg signed  [4:0] crt_hsize;
reg signed  [8:0] crt_hoff;
reg signed  [5:0] crt_voff;
always @(posedge clk_sys) if (hu_cen_pix) begin
	crt_on    <= status[14] & ~crt_sd;
	crt_hsize <= crt_hsz[4:0];
	crt_hoff  <= crt_hpos + CRT_HBIAS + crt_hcen;
	crt_voff  <= crt_vs_a[5:0];
end

// the pixel read enable: one every (64 + H-Size) quarters of a clock (sixteen clocks a pixel at 6 MHz), counted
// from the module's own line reference
wire       crt_hs_ref;
reg        crt_hs_ref_d;
wire [7:0] crt_period = 8'd64 + {{3{crt_hsize[4]}}, crt_hsize};
reg  [7:0] crt_acc;
wire       crt_tick = (crt_acc + 8'd4) >= {1'b0, crt_period};
always @(posedge clk_sys) begin
	crt_hs_ref_d <= crt_hs_ref;
	if      (crt_hs_ref & ~crt_hs_ref_d) crt_acc <= 8'd0;
	else if (crt_tick)                   crt_acc <= crt_acc + 8'd4 - {1'b0, crt_period};
	else                                 crt_acc <= crt_acc + 8'd4;
end
wire crt_rd_en = crt_on ? crt_tick : vq_ce;

wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb_unused;
crt_adjust #(.VTOTAL(264), .HTOTAL(404), .HPOS_MODE(1)) u_crt
(
	.clk(clk_sys), .pxl_cen(vq_ce), .pxl2_cen(crt_rd_en), .active(crt_on),
	.hsize(crt_hsize), .hoffset(crt_hoff), .voffset(crt_voff),
	.r_in(vq_rgb[23:16]), .g_in(vq_rgb[15:8]), .b_in(vq_rgb[7:0]),
	.hs_in(vq_hs), .vs_in(vq_vs), .hb_in(vq_hb), .vb_in(crt_vb_next),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb_unused),
	.hs_ref_out(crt_hs_ref)
);

wire vga_de_av;
arcade_video #(.WIDTH(256), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(crt_on ? crt_rd_en : vq_ce),
	.RGB_in(crt_on ? {crt_r, crt_g, crt_b} : vq_rgb),
	.HBlank(crt_on ? (crt_hb | crt_hs) : vq_hbh),  // CRT Adjust: nothing of the picture inside the hsync pulse; off: the horizontal blank alone
	.VBlank(crt_on ? 1'b0 : vq_vb),             // CRT Adjust: the module's blank already includes the vertical one
	.HSync(crt_on ? crt_hs : vq_hs),
	.VSync(crt_on ? crt_vs : vq_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(vga_de_av),
	.VGA_SL(VGA_SL),

	.fx(status[5:3]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

// Scale: integer scaling on the HDMI scaler (framework module; it measures the picture's rows and width from the
// finished stream, scandoubler and CRT Adjust included, and works out the size from HDMI_WIDTH/HEIGHT). Crop is unused.
// With Normal it adds nothing but a few clocks of delay to VGA_DE.
video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de_av),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(scale_sel)
);

///////////////////////   LED   ///////////////////////

reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = hu_reset ? act_cnt[24] : hu_spr_overrun | act_cnt[26];

endmodule
