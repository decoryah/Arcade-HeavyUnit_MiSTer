// 8751 "Mermaid": jt8051 plus the 4 KB program ROM and 128-byte internal RAM
// it needs.  Derived from jtframe's jtframe_8751mcu (GPL-3.0-or-later, Jose
// Tejada); rewritten without the jtframe RAM/sync modules because the board has
// no external data memory and the only wrapper behaviour that matters is the
// clock-gated read of ROM and RAM.
//
// `cen` is the 6 MHz OSCILLATOR enable (pin 18/19 on the PCB): jt8051 counts
// twelve of them per machine cycle, and needs at least one idle clk between
// consecutive cen pulses.
module hvyunit_mcu (
    input             rst,
    input             clk,
    input             cen,

    input             int0n,
    input             int1n,
    input      [ 7:0] p0_i, p1_i, p2_i, p3_i,
    output     [ 7:0] p0_o, p1_o, p2_o, p3_o,
    output     [ 3:0] port_we,        // one-clk strobe per SFR write to P0..P3

    // firmware download (0x0E00 bytes are meaningful)
    input      [11:0] prog_addr,
    input      [ 7:0] prog_data,
    input             prog_we
);

    // ---------------------------------------------------------------- ROM
    reg [7:0] prom [0:4095];
    always @(posedge clk) if (prog_we) prom[prog_addr] <= prog_data;

    wire [15:0] pre_rom;
    reg  [15:0] rom_addr;
    reg  [ 7:0] rom_q;
    always @(posedge clk) rom_addr <= pre_rom;
    // The MCU only works if ROM is read on cen, not every clk.
    always @(posedge clk) if (cen) rom_q <= prom[rom_addr[11:0]];

    // ---------------------------------------------------------------- RAM
    reg  [7:0] iram [0:127];
    wire [6:0] ram_addr;
    wire [7:0] ram_data;
    wire       ram_we;
    reg  [7:0] ram_q;
    reg  [6:0] clr_cnt;
    (* preserve *) reg rstl;       // the RAM clear loop's own copy: not to be merged with the core's reset below

    always @(posedge clk) begin
        rstl <= rst;
        if (rstl) begin
            iram[clr_cnt] <= 8'd0;
            clr_cnt       <= clr_cnt + 7'd1;
        end else if (cen) begin
            if (ram_we) iram[ram_addr] <= ram_data;
            ram_q <= iram[ram_addr];
        end
    end

    // ---------------------------------------------------------------- core
    // The core's reset is taken on cen, like everything it does: it then changes at most once in
    // sixteen clocks, so its fan-out to every register of the core has the whole interval to settle
    // (HeavyUnit.sdc relaxes exactly these paths) and all of them see the release before the first
    // enable that follows it.
    (* preserve *) reg rst_c = 1'b1;
    always @(posedge clk) if (cen) rst_c <= rst;

    // the ports are read on cen as well; the board's inputs (keys, DIP switches, the latch flags) are
    // clk-rate registers behind a mux, so they are taken on cen first
    reg [7:0] p0_r, p1_r, p2_r, p3_r;
    always @(posedge clk) if (cen) begin
        p0_r <= p0_i; p1_r <= p1_i; p2_r <= p2_i; p3_r <= p3_i;
    end

    wire [ 7:0] x_dout_unused;
    wire [15:0] x_addr_unused;
    wire        x_wr_unused, x_acc_unused;

    jt8051 u_mcu (
        .rst      ( rst_c      ),
        .clk      ( clk        ),
        .cen      ( cen        ),
        .int0n    ( int0n      ),
        .int1n    ( int1n      ),
        .p0_i     ( p0_r       ),
        .p1_i     ( p1_r       ),
        .p2_i     ( p2_r       ),
        .p3_i     ( p3_r       ),
        .p0_o     ( p0_o       ),
        .p1_o     ( p1_o       ),
        .p2_o     ( p2_o       ),
        .p3_o     ( p3_o       ),
        .rom_data ( rom_q      ),
        .rom_addr ( pre_rom    ),
        .ram_din  ( ram_q      ),
        .ram_dout ( ram_data   ),
        .ram_addr ( ram_addr   ),
        .ram_we   ( ram_we     ),
        .x_din    ( 8'hff      ),   // no external data memory on this board
        .x_dout   ( x_dout_unused ),
        .x_addr   ( x_addr_unused ),
        .x_wr     ( x_wr_unused   ),
        .x_acc    ( x_acc_unused  ),
        .port_we  ( port_we    )
    );

endmodule
