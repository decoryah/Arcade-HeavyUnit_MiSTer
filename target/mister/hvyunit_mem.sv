// Heavy Unit memory subsystem for MiSTer.
//
// The MRA's ROM image (tools/hvyunit_roms.py, 0x2C1000 bytes) arrives from the
// HPS a byte at a time with its image offset:
//
//   0x000000  main Z80 program   128 KB   -> block RAM
//   0x020000  sub  Z80 program    64 KB   -> block RAM
//   0x030000  sound Z80 program   64 KB   -> block RAM
//   0x040000  background tiles   512 KB   -> SDRAM word 0x00000
//   0x0C0000  sprites              2 MB   -> SDRAM word 0x40000
//   0x2C0000  Mermaid 8751 firmware 4 KB  -> the MCU's programming port
//
// so the two graphics regions are one contiguous run in SDRAM, word address
// (offset - 0x40000) / 2.  SDRAM words are little-endian: the even byte of the
// image is the low byte, which is what hvyunit_video / hvyunit_pandora assume.
//
// Graphics bytes are paired into words, queued in a small FIFO and written
// through client 1 of the SDRAM controller; `dl_wait` stalls the HPS while the
// FIFO is more than half full.  Reads: client 0 is the background tile fetch
// (single words); the sprite engine uses the controller's burst port.
`default_nettype none

module hvyunit_mem (
    input  logic        clk,            // 96 MHz
    input  logic        clk_sdram,      // 96 MHz, phase-shifted: drives the chip's clock pin
    input  logic        init,           // reset / re-initialise
    input  logic        rd_late,
    output logic        ready,

    // the ROM image from the HPS
    input  logic        dl_we,          // one clock per byte
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,
    output logic        dl_wait,
    output logic        dl_idle,        // every byte given so far has been written to the SDRAM

    // program ROMs (block RAM): synchronous read
    input  logic [16:0] main_addr, output logic [7:0] main_q,
    input  logic [15:0] sub_addr,  output logic [7:0] sub_q,
    input  logic [15:0] snd_addr,  output logic [7:0] snd_q,

    // Mermaid firmware
    output logic        mcu_we,
    output logic [11:0] mcu_addr,
    output logic  [7:0] mcu_data,

    // background tiles: random-access word client
    input  logic        tile_req,
    input  logic [17:0] tile_addr,
    output logic        tile_ack,
    output logic [15:0] tile_q,

    // sprites: 64-word burst client
    input  logic        spr_b_req,
    input  logic [19:0] spr_b_addr,
    output logic        spr_b_wr,
    output logic  [5:0] spr_b_idx,
    output logic [15:0] spr_b_data,
    output logic        spr_b_done,

    // SDRAM pins
    inout  wire  [15:0] dram_dq,
    output logic [12:0] dram_a,
    output logic  [1:0] dram_ba,
    output logic  [1:0] dram_dqm,
    output logic        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n
);
    localparam [24:0] IMG_SUB = 25'h020000, IMG_SND = 25'h030000, IMG_GFX = 25'h040000,
                      IMG_MCU = 25'h2C0000, IMG_END = 25'h2C1000;

    // ----------------------------------------------------- program ROMs (BRAM)
    (* ramstyle = "M10K" *) logic [7:0] rom_main [0:131071];
    (* ramstyle = "M10K" *) logic [7:0] rom_sub  [0:65535];
    (* ramstyle = "M10K" *) logic [7:0] rom_snd  [0:65535];

    wire in_main = dl_addr < IMG_SUB;
    wire in_sub  = dl_addr >= IMG_SUB && dl_addr < IMG_SND;
    wire in_snd  = dl_addr >= IMG_SND && dl_addr < IMG_GFX;
    wire in_gfx  = dl_addr >= IMG_GFX && dl_addr < IMG_MCU;
    wire in_mcu  = dl_addr >= IMG_MCU && dl_addr < IMG_END;

    always_ff @(posedge clk) begin
        if (dl_we && in_main) rom_main[dl_addr[16:0]] <= dl_data;
        if (dl_we && in_sub)  rom_sub [dl_addr[15:0]] <= dl_data;
        if (dl_we && in_snd)  rom_snd [dl_addr[15:0]] <= dl_data;
        main_q <= rom_main[main_addr];
        sub_q  <= rom_sub [sub_addr];
        snd_q  <= rom_snd [snd_addr];
    end

    // ------------------------------------------------------ MCU programming
    always_ff @(posedge clk) begin
        mcu_we   <= dl_we && in_mcu;
        mcu_addr <= dl_addr[11:0];
        mcu_data <= dl_data;
    end

    // ---------------------------------------------- graphics: bytes -> words
    logic  [7:0] lo_byte;
    logic        wf_push;
    logic [37:0] wf_in;                         // {word address[21:0], data[15:0]}
    wire  [24:0] gfx_off = dl_addr - IMG_GFX;   // offset from the start of the tile region

    always_comb begin
        wf_push = 1'b0;
        wf_in   = '0;
        if (dl_we && in_gfx && dl_addr[0]) begin
            wf_push = 1'b1;
            wf_in   = {gfx_off[22:1], dl_data, lo_byte};
        end
    end
    always_ff @(posedge clk) if (dl_we && in_gfx && !dl_addr[0]) lo_byte <= dl_data;

    (* ramstyle = "no_rw_check" *) logic [37:0] wfifo [0:15];
    logic  [4:0] wf_wp, wf_rp;
    wire         wf_empty = (wf_wp == wf_rp);
    assign       dl_wait  = ((wf_wp - wf_rp) >= 5'd8);

    // SDRAM write client (client 1)
    logic        sd_req, sd_ack;
    logic [24:1] sd_addr;
    logic [15:0] sd_data;
    typedef enum logic [1:0] { W_IDLE, W_REQ } wst_t;
    wst_t wst;
    assign dl_idle = wf_empty && !wf_push && (wst == W_IDLE);

    always_ff @(posedge clk) begin
        if (init) begin
            wf_wp <= '0; wf_rp <= '0; wst <= W_IDLE; sd_req <= 1'b0;
        end else begin
            if (wf_push) begin
                wfifo[wf_wp[3:0]] <= wf_in;
                wf_wp <= wf_wp + 5'd1;
            end
            case (wst)
                W_IDLE: if (!wf_empty) begin
                    sd_addr <= {2'b00, wfifo[wf_rp[3:0]][37:16]};
                    sd_data <= wfifo[wf_rp[3:0]][15:0];
                    sd_req  <= 1'b1;
                    wst     <= W_REQ;
                end
                W_REQ: if (sd_ack) begin
                    sd_req <= 1'b0;
                    wf_rp  <= wf_rp + 5'd1;
                    wst    <= W_IDLE;
                end
                default: wst <= W_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------ SDRAM controller
    logic [24:1] c_addr  [6];
    logic        c_req   [6];
    logic        c_we    [6];
    logic [15:0] c_wdata [6];
    logic  [1:0] c_be    [6];
    logic        c_ack   [6];
    logic [15:0] rdata;

    always_comb begin
        for (int i = 0; i < 6; i++) begin
            c_addr[i] = '0; c_req[i] = 1'b0; c_we[i] = 1'b0; c_wdata[i] = '0; c_be[i] = 2'b11;
        end
        c_addr[0]  = {6'd0, tile_addr};
        c_req[0]   = tile_req;
        c_addr[1]  = sd_addr;
        c_req[1]   = sd_req;
        c_we[1]    = 1'b1;
        c_wdata[1] = sd_data;
    end
    assign tile_ack = c_ack[0];
    assign tile_q   = rdata;
    assign sd_ack   = c_ack[1];

    logic        b_wr_i, b_done_i;
    logic  [9:0] b_idx_i;
    logic [15:0] b_data_i;
    logic        dqml, dqmh, ncs;

    sdram_ctrl #(.NCLI(6)) u_sdram (
        .clk(clk), .clk_pin(clk_sdram), .init(init), .rd_late(rd_late), .burst_slow(1'b0), .ready(ready),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_BA(dram_ba),
        .SDRAM_nCS(ncs), .SDRAM_nWE(dram_we_n), .SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n),
        .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata), .c_be(c_be), .c_ack(c_ack),
        .rdata(rdata),
        .b_addr(24'h040000 + {4'd0, spr_b_addr}), .b_len(10'd64), .b_req(spr_b_req), .b_abort(1'b0),
        .b_wr(b_wr_i), .b_idx(b_idx_i), .b_data(b_data_i), .b_done(b_done_i),
        .b_we(1'b0), .b_wdata(16'd0), .b_be(2'b11), .b_widx()
    );
    assign dram_dqm   = {dqmh, dqml};
    assign spr_b_wr   = b_wr_i;
    assign spr_b_idx  = b_idx_i[5:0];
    assign spr_b_data = b_data_i;
    assign spr_b_done = b_done_i;

    wire unused = ^{ncs, gfx_off[24:23], gfx_off[0]};
endmodule
