// Verilator driver: toggle the clock until the testbench calls $finish.
#include "Vtb_hvyunit.h"
#include "verilated.h"

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);     // makes +rom_dir=... etc. visible to $value$plusargs
    Vtb_hvyunit *top = new Vtb_hvyunit;
    top->clk = 0;
    top->eval();
    while (!Verilated::gotFinish()) {
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();
    }
    top->final();
    delete top;
    return 0;
}
