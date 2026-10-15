// Fast load: replays the ROM image from the DDR3 into the loader.
//
// With address="0x32000000" on the MRA's index-0 <rom>, Main_MiSTer copies the
// whole assembled image into the DDR3 in one go (about a second instead of
// 23-25) and then ends a download that carries no bytes, only a start address:
// the image's length.  (An older Main_MiSTer ignores the attribute and streams
// the bytes as before; nothing here touches that path.)  When that empty
// download ends `go` pulses with `len`, and this block reads the image back a
// 256-byte block at a time (a 32-beat Avalon burst into a small buffer) and
// writes it, byte by byte, into the same loader port the HPS streams through
// (hvyunit_mem's dl_*), honouring its dl_wait.  `done` pulses when the loader
// has written the last word, which is when the core may leave reset.
//
// The Avalon-MM master is plain: rd is held, with its address and burst count,
// until a clock where busy is low; the read beats then arrive on dready.
`default_nettype none

module hvyunit_fastload (
    input  logic        clk,
    input  logic        reset,
    input  logic        go,             // one clock: the empty download ended
    input  logic [24:0] len,            // image length in bytes
    output logic        done,           // one clock: every byte is written

    // the loader's byte port (hvyunit_mem dl_*)
    input  logic        dl_wait,
    input  logic        dl_idle,        // the loader's write FIFO is empty and its writer idle
    output logic        dl_we,
    output logic [24:0] dl_addr,
    output logic  [7:0] dl_data,

    // DDR3 (the framework's DDRAM_*, one 64-bit beat a word)
    input  logic        ddr_busy,
    output logic        ddr_rd,
    output logic [24:0] ddr_addr,       // 64-bit word address within the 0x30000000 window
    output logic  [7:0] ddr_burst,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dready
);
    // byte 0x32000000 of the DDR3: 0x2000000 bytes into the window = 0x400000 beats
    localparam [24:0] FL_BASE = 25'h400000;

    typedef enum logic [2:0] { F_IDLE, F_REQ, F_BEATS, F_PUSH, F_FIN } fst_t;
    fst_t        st;

    (* ramstyle = "MLAB" *) logic [63:0] fbuf [32];
    logic        pend;
    logic [24:0] off;               // byte offset of the block in the image
    logic [24:0] end_b;             // image length
    logic  [5:0] nb;                // beats of the block stored
    logic  [7:0] bi;                // byte within the block
    logic  [8:0] owed;              // read beats still to come
    logic  [2:0] settle;

    wire  [24:0] bpos = off + {17'd0, bi};

    always_ff @(posedge clk) begin
        done  <= 1'b0;
        dl_we <= 1'b0;
        if (reset) owed <= '0;
        else owed <= owed + ((ddr_rd && !ddr_busy) ? 9'(ddr_burst) : 9'd0) - (ddr_dready ? 9'd1 : 9'd0);
        if (ddr_rd && !ddr_busy) ddr_rd <= 1'b0;       // taken (cleared first: a state may present the next one below)
        if (go) pend <= 1'b1;
        if (reset) begin
            st <= F_IDLE; ddr_rd <= 1'b0; pend <= 1'b0;
        end else case (st)
            F_IDLE: if (pend && owed == 9'd0) begin     // after any burst of an aborted load has come back
                pend  <= 1'b0;
                off   <= '0;
                end_b <= len;
                st    <= F_REQ;
            end
            F_REQ: begin
                if (off >= end_b) begin settle <= '0; st <= F_FIN; end
                else if (!ddr_rd) begin
                    ddr_rd    <= 1'b1;
                    ddr_addr  <= FL_BASE + {3'd0, off[24:3]};
                    ddr_burst <= 8'd32;
                    nb        <= '0;
                    st        <= F_BEATS;
                end
            end
            F_BEATS: if (ddr_dready) begin
                fbuf[nb[4:0]] <= ddr_dout;
                nb <= nb + 6'd1;
                if (nb == 6'd31) begin bi <= '0; st <= F_PUSH; end
            end
            // one byte a clock, held off by the loader's FIFO (it stops the HPS the same way)
            F_PUSH: if (!dl_wait) begin
                dl_we   <= (bpos < end_b);
                dl_addr <= bpos;
                dl_data <= fbuf[bi[7:3]][{bi[2:0], 3'b000} +: 8];
                if (bi == 8'd255) begin off <= off + 25'd256; st <= F_REQ; end
                else bi <= bi + 8'd1;
            end
            // done when the loader has written every word: a few quiet clocks, so that the last
            // byte's push is seen before the idle flag is believed
            F_FIN: begin
                if (dl_idle && !dl_we) settle <= settle + 3'd1; else settle <= '0;
                if (settle == 3'd5) begin done <= 1'b1; st <= F_IDLE; end
            end
            default: st <= F_IDLE;
        endcase
    end
endmodule
