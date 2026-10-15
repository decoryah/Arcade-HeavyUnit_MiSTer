#include "Vtb_video.h"
#include "verilated.h"

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_video *top = new Vtb_video;
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
