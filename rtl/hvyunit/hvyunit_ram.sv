// Small synchronous RAMs.  Read data appears one clk after the address, which
// is fine for a Z80 running on a 6 MHz enable from a clk of >= 12 MHz.

module hvyunit_ram #(
    parameter integer AW = 10
) (
    input              clk,
    input              we,
    input      [AW-1:0] addr,
    input      [  7:0] din,
    output reg [  7:0] q
);
    reg [7:0] mem [0:(1<<AW)-1];
    always @(posedge clk) begin
        if (we) mem[addr] <= din;
        q <= mem[addr];
    end
endmodule

// True dual port: the 8 KB shared RAM at E000-FFFF seen by the main and sub CPUs.
module hvyunit_dpram #(
    parameter integer AW = 13
) (
    input              clk,
    input              a_we,
    input      [AW-1:0] a_addr,
    input      [  7:0] a_din,
    output reg [  7:0] a_q,
    input              b_we,
    input      [AW-1:0] b_addr,
    input      [  7:0] b_din,
    output reg [  7:0] b_q
);
    // two CPUs share this RAM; what one reads while the other writes the same
    // byte in the same clock is not defined on the real board either
    (* ramstyle = "no_rw_check" *) reg [7:0] mem [0:(1<<AW)-1];
    always @(posedge clk) begin
        if (a_we) mem[a_addr] <= a_din;
        a_q <= mem[a_addr];
    end
    always @(posedge clk) begin
        if (b_we) mem[b_addr] <= b_din;
        b_q <= mem[b_addr];
    end
endmodule
