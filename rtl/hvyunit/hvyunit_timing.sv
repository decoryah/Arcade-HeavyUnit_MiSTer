// Heavy Unit frame timing: line/column counters on the 6 MHz dot enable and
// the two raster events the board logic needs.
//
// The defaults reproduce MAME's model of this board (hvyunit.cpp): a 256-line
// frame at ~58 Hz, vblank starting at line 240, and the main-CPU "sprite" IRQ
// at line 64.  The real PCB measures 15.59 kHz / 58 Hz, i.e. about 385 x 269;
// which line numbers the interrupts really sit on in that frame is unknown
// (MAME marks the line-64 timing "likely off"), so these are parameters, not
// facts.  See docs/ARCHITECTURE.md, open question 2.
//
// 6 MHz / (404 * 256) = 58.02 Hz.
//
// Two rasters can be built in: the one the H_TOTAL / V_TOTAL parameters give,
// and an alternative one (H_TOTAL_ALT / V_TOTAL_ALT) chosen by the `alt`
// input.  The choice is taken at the start of a frame (alt_q is the raster in
// force), so a change from the menu never cuts a frame.  The vblank and
// sprite-IRQ lines are the same in both.
module hvyunit_timing #(
    parameter integer H_TOTAL = 404,
    parameter integer V_TOTAL = 256,
    parameter integer VBL_LINE = 240,   // first line of vblank
    parameter integer SPR_LINE = 64,    // line of the main CPU's sprite IRQ
    parameter integer H_TOTAL_ALT = 404,
    parameter integer V_TOTAL_ALT = 256
) (
    input             clk,
    input             rst,
    input             cen,              // 6 MHz dot enable
    input             alt,              // 1: the alternative raster, from the next frame
    output reg        alt_q,            // the raster in force
    output reg [ 8:0] hcnt,
    output reg [ 8:0] vcnt,
    output reg        vbl_start,        // one clk pulse: first column of line VBL_LINE
    output reg        spr_irq           // one clk pulse: first column of line SPR_LINE
);

    localparam [8:0] HT0 = H_TOTAL,     VT0 = V_TOTAL;
    localparam [8:0] HT1 = H_TOTAL_ALT, VT1 = V_TOTAL_ALT;

    // >= rather than ==, so that a counter can never run past a shorter total
    wire        h_last = (hcnt >= (alt_q ? HT1 : HT0) - 9'd1);
    wire        v_last = (vcnt >= (alt_q ? VT1 : VT0) - 9'd1);
    wire [8:0]  v_next = v_last ? 9'd0 : vcnt + 9'd1;

    always @(posedge clk) begin
        vbl_start <= 1'b0;
        spr_irq   <= 1'b0;
        if (rst) begin
            hcnt  <= 9'd0;
            vcnt  <= 9'd0;
            alt_q <= alt;
        end else if (cen) begin
            if (h_last) begin
                hcnt <= 9'd0;
                vcnt <= v_next;
                if (v_last) alt_q <= alt;
                if (v_next == VBL_LINE) vbl_start <= 1'b1;
                if (v_next == SPR_LINE) spr_irq   <= 1'b1;
            end else begin
                hcnt <= hcnt + 9'd1;
            end
        end
    end

endmodule
