derive_pll_clocks
derive_clock_uncertainty

# ==============================================================================
# SDRAM. The chip is clocked by the PLL's second 96 MHz output, shifted about
# half a period (rtl/pll); like JTFRAME's MiSTer builds the pin's clock is
# modelled as the machine clock inverted, and the read data -- launched by the
# chip's edge, captured by sdram_ctrl's input register three edges after the
# READ command -- gets a two-cycle path. The register assignments in sys/sys.tcl
# put the SDRAM pins' registers in the IO cells.
# ==============================================================================
set sdram_clk_src [get_pins -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sdram_clk_src] == 0 } {
    set sdram_clk_src [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
create_generated_clock -name SDRAM_CLK -source $sdram_clk_src -divide_by 1 -phase 180 [get_ports {SDRAM_CLK}]

set sys_clk [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sys_clk] == 0 } {
    set sys_clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -setup -end 2
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -hold  -end 2

# the controller's round-robin pointer settles long before it is used (S_IDLE -> S_ARB)
set_multicycle_path -setup 3 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]
set_multicycle_path -hold  2 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]

# ==============================================================================
# The machine steps on clock enables: cen6 is one clk in sixteen (the three
# Z80s, the 8751's oscillator, the dot clock), cen3 one in thirty-two (the
# YM2203). Registers that only change on an enable launch a path the analyser
# takes to have one clock; where the capturing register is on the same enable
# the path really has the whole interval. Eight clocks are declared, half of
# what is there, and only for paths whose launching *and* capturing registers
# are enabled by the same cen. Everything that is sampled at the full clock
# rate (the wrapper registers, the video, the memories' ports) stays single-cycle.
# ==============================================================================

# jt8051: every register of the core, and the 8751's internal RAM and program
# ROM read, advance on cen only (hvyunit_mcu.sv). Same rule as jt8051's own
# timing.sdc, which declares two clocks because jtframe's cores run it at a
# higher ratio; here the ratio is 16.
set MCU      [get_keepers {*|jt8051:u_mcu|*}]
set MCU_IRAM [get_keepers {*|hvyunit_mcu:u_mcu|altsyncram:iram_rtl_0|*}]
set MCU_ROMA [get_registers {*|hvyunit_mcu:u_mcu|rom_addr[*]}]
set_multicycle_path -setup 8 -from $MCU      -to $MCU
set_multicycle_path -hold  7 -from $MCU      -to $MCU
set_multicycle_path -setup 8 -from $MCU      -to $MCU_IRAM
set_multicycle_path -hold  7 -from $MCU      -to $MCU_IRAM
set_multicycle_path -setup 8 -from $MCU_IRAM -to $MCU
set_multicycle_path -hold  7 -from $MCU_IRAM -to $MCU
# the program counter's decode into the ROM address register: that register follows every clk, but the
# ROM is read on cen only, a whole interval after the counter changed
set_multicycle_path -setup 8 -from $MCU      -to $MCU_ROMA
set_multicycle_path -hold  7 -from $MCU      -to $MCU_ROMA

# The three Z80s (T80s): every register of the core, its register file included, advances on cen6 only (CEN is
# the one enable of T80's clocked processes). What the board hands back (data, wait, interrupts) is sampled
# only at those steps, and the T80's outputs into the board's decode stay single-cycle
set Z80 [get_keepers {*|T80s:*|*}]
set_multicycle_path -setup 8 -from $Z80 -to $Z80
set_multicycle_path -hold  7 -from $Z80 -to $Z80

# ==============================================================================
# The framework's HQ2x (sys/hq2x.sv, with its Blend) updates every register of its
# datapath on one clock enable, ce_in: the scandoubler's ce_x4i, which fires four
# times per input pixel, evenly spaced -- four clocks apart for this core's
# 16-clock pixels (sys/scandoubler.v). The framework does not constrain it, and
# its paths have more than the one clock the analyser assumes; three are declared.
# (Only the registers that sit behind ce_in are listed: the output side runs on
# ce_out, and the RAMs' own registers are not touched.)
# ==============================================================================
set HQ [get_registers -nowarn {*|Blend:*|*}]
foreach n {cyc nextpatt pattern Prev0 Prev1 Prev2 Curr0 Curr1 Curr2 Next0 Next1 Next2 A B D F G H
           curbuf prevbuf offs wrdata wrdata_finished waddr wrout_addr wrpix wrin_addr2
           old_reset_line old_reset_frame} {
    set HQ [add_to_collection $HQ [get_registers -nowarn [format {*|Hq2x:*|%s} $n]]]
    set HQ [add_to_collection $HQ [get_registers -nowarn [format {*|Hq2x:*|%s[*]} $n]]]
}
set_multicycle_path -setup 3 -from $HQ -to $HQ
set_multicycle_path -hold  2 -from $HQ -to $HQ

# The Z80s' program ROMs (block RAM in hvyunit_mem, read every clk): an address comes out of a T80 at a cen6 step and
# its byte is sampled by the T80 two or more steps later; the memory itself is read at the full clock rate. Both
# directions of that loop have the whole interval
set ROMS [get_keepers {*|hvyunit_mem:u_mem|altsyncram:rom_*|*}]
set_multicycle_path -setup 8 -from $Z80  -to $ROMS
set_multicycle_path -hold  7 -from $Z80  -to $ROMS
set_multicycle_path -setup 8 -from $ROMS -to $Z80
set_multicycle_path -hold  7 -from $ROMS -to $Z80

# The 8751's reset is taken on cen (hvyunit_mcu.sv rst_c): it changes once in sixteen clocks at most
set MCU_RST [get_registers {*|hvyunit_mcu:u_mcu|rst_c}]
set_multicycle_path -setup 8 -from $MCU_RST -to $MCU
set_multicycle_path -hold  7 -from $MCU_RST -to $MCU

# The YM2203 (jt03 / jt12): its pipeline advances on the divided enable derived from cen3 (one clk in thirty-two),
# slot by slot; the registers behind it are the slot pipeline and the shift-tap RAMs that carry the operators'
# state. Same rule as above, for paths from and to the core's own registers
set YM [get_keepers {*|jt03:u_ym|*}]
set_multicycle_path -setup 8 -from $YM -to $YM
set_multicycle_path -hold  7 -from $YM -to $YM

# the 8751's port input registers (hvyunit_mcu.sv): taken on cen like the rest of the core
set MCU_PR [get_registers {*|hvyunit_mcu:u_mcu|p?_r[*]}]
set_multicycle_path -setup 8 -from $MCU_PR -to $MCU
set_multicycle_path -hold  7 -from $MCU_PR -to $MCU

# The board's RAMs (the main and sub work RAM, the shared RAM, sound RAM) are read at the full clock rate from an
# address that a T80 holds for at least two cen6 steps; what the T80 does with the byte, it does at a step
set RAMS [get_keepers {*|hvyunit_ram:*|altsyncram:*|*}]
set RAMS [add_to_collection $RAMS [get_keepers {*|hvyunit_dpram:*|altsyncram:*|*}]]
set_multicycle_path -setup 8 -from $RAMS -to $Z80
set_multicycle_path -hold  7 -from $RAMS -to $Z80
