// Mermaid MCU glue: the board-level behaviour MAME implements in the
// mermaid_p0..p3 callbacks of hvyunit.cpp.  Every line below corresponds to a
// line of that driver; see docs/ARCHITECTURE.md section 4.
//
//   P0 out  [0] low   -> load P1 from the Mermaid latch, clear its pending flag
//           [1] rise  -> write P1 (the shadow byte) into the SUB latch
//           [3:2]     -> input-port select for P2 reads
//           [6:5]     -> DIP-switch nibble select for P3 reads
//           [4] rise  -> latch coin counters / lockouts from P2
//   P1      bidirectional data bus; "shadow" byte, pin = latch & shadow
//   P2 in   IN1 / IN2 / IN0 / 0xFF by P0[3:2];   P2 out [3:0] coin control
//   P3 in   [7:4] DIP nibble, [3] sublatch pending, [2] !mermaid-latch pending,
//           [1:0] read as 0 (MAME's callback returns zero there)
//   P3 out  [1] = sub CPU run (1) / reset (0)
//   INT0    = Mermaid latch pending (active low pin)
//
// MAME invokes each callback on EVERY port write, including writes of an
// unchanged value; port_we from the patched jt8051 reproduces that exactly.
module hvyunit_mermaid (
    input             rst,
    input             clk,
    input             cen,              // 6 MHz oscillator enable

    // firmware download
    input      [11:0] prog_addr,
    input      [ 7:0] prog_data,
    input             prog_we,

    // latches (owned by the board core)
    input      [ 7:0] mlatch_data,      // sub CPU -> Mermaid
    input             mlatch_pend,
    input             slatch_pend,      // Mermaid -> sub CPU
    output reg        mlatch_rd,        // pulse: Mermaid read its latch
    output reg        slatch_wr,        // pulse: Mermaid wrote the sub latch
    output reg [ 7:0] slatch_data,

    // board inputs, active low as on the PCB
    input      [ 7:0] in0, in1, in2,
    input      [ 7:0] dsw1, dsw2,

    output            sub_run,          // 0 holds the sub CPU in reset
    output reg [ 1:0] coin_counter,
    output reg [ 1:0] coin_lockout
);

    wire [7:0] p0_o, p1_o, p2_o, p3_o;
    wire [3:0] port_we;

    reg  [7:0] p0_prev;                 // last value written to P0 (MAME m_mermaid_p[0])
    reg  [7:0] p1_shadow;               // MAME m_mermaid_p[1]
    reg  [7:0] p2_shadow;               // MAME m_mermaid_p[2]

    // ------------------------------------------------------------ port reads
    reg [7:0] p2_in;
    always @* begin
        case (p0_o[3:2])
            2'd0:    p2_in = in1;
            2'd1:    p2_in = in2;
            2'd2:    p2_in = in0;
            default: p2_in = 8'hff;
        endcase
    end

    reg [3:0] dsw_nib;
    always @* begin
        case (p0_o[6:5])
            2'd0:    dsw_nib = {dsw2[4], dsw2[0], dsw1[4], dsw1[0]};
            2'd1:    dsw_nib = {dsw2[5], dsw2[1], dsw1[5], dsw1[1]};
            2'd2:    dsw_nib = {dsw2[6], dsw2[2], dsw1[6], dsw1[2]};
            default: dsw_nib = {dsw2[7], dsw2[3], dsw1[7], dsw1[3]};
        endcase
    end

    wire [7:0] p3_in = {dsw_nib, slatch_pend, ~mlatch_pend, 2'b00};

    // ------------------------------------------------------------ port writes
    always @(posedge clk) begin
        slatch_wr <= 1'b0;
        mlatch_rd <= 1'b0;
        if (rst) begin
            p0_prev      <= 8'hff;
            p1_shadow    <= 8'hff;
            p2_shadow    <= 8'hff;
            coin_counter <= 2'b00;
            coin_lockout <= 2'b00;
            slatch_data  <= 8'h00;
        end else begin
            if (port_we[0]) begin
                // order matches mermaid_p0_w: the sub-latch write uses the shadow
                // byte as it stood BEFORE this write's latch read
                if (!p0_prev[1] && p0_o[1]) begin
                    slatch_wr   <= 1'b1;
                    slatch_data <= p1_shadow;
                end
                if (!p0_o[0]) begin
                    p1_shadow <= mlatch_data;
                    mlatch_rd <= 1'b1;
                end
                if (!p0_prev[4] && p0_o[4]) begin
                    coin_counter <= p2_shadow[1:0];
                    coin_lockout <= ~p2_shadow[3:2];
                end
                p0_prev <= p0_o;
            end
            if (port_we[1]) p1_shadow <= p1_o;
            if (port_we[2]) p2_shadow <= p2_o;
        end
    end

    assign sub_run = p3_o[1];

    hvyunit_mcu u_mcu (
        .rst       ( rst          ),
        .clk       ( clk          ),
        .cen       ( cen          ),
        .int0n     ( ~mlatch_pend ),
        .int1n     ( 1'b1         ),
        .p0_i      ( 8'hff        ),
        .p1_i      ( p1_shadow    ),
        .p2_i      ( p2_in        ),
        .p3_i      ( p3_in        ),
        .p0_o      ( p0_o         ),
        .p1_o      ( p1_o         ),
        .p2_o      ( p2_o         ),
        .p3_o      ( p3_o         ),
        .port_we   ( port_we      ),
        .prog_addr ( prog_addr    ),
        .prog_data ( prog_data    ),
        .prog_we   ( prog_we      )
    );

endmodule
