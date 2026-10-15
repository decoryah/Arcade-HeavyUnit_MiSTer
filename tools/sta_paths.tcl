# Worst setup paths of the last fit, summarised by (from-module, to-module).
#   quartus_sta -t tools/sta_paths.tcl [npaths]
project_open HeavyUnit
create_timing_netlist
read_sdc
update_timing_netlist
set n 300
if { $argc > 0 } { set n [lindex $quartus(args) 0] }
set clk [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
if { [get_collection_size $clk] == 0 } {
    set clk [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
}
set paths [get_timing_paths -setup -npaths $n -to_clock $clk -from_clock $clk]
foreach_in_collection p $paths {
    set s [get_path_info $p -slack]
    set f [get_node_info -name [get_path_info $p -from]]
    set t [get_node_info -name [get_path_info $p -to]]
    puts [format "%8.3f  %s  ->  %s" $s $f $t]
}
delete_timing_netlist
project_close
