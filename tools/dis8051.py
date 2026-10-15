#!/usr/bin/env python3
"""Minimal MCS-51 disassembler (standard 8051 instruction set).

    dis8051.py FILE [START [END]]       (hex or decimal addresses)

Written to read the Heavy Unit "Mermaid" firmware (build/hvyunit/mermaid.bin).
SFR and bit names cover the standard 8051 only.
"""
import sys

SFR = {0x80: "P0", 0x81: "SP", 0x82: "DPL", 0x83: "DPH", 0x87: "PCON", 0x88: "TCON",
       0x89: "TMOD", 0x8A: "TL0", 0x8B: "TL1", 0x8C: "TH0", 0x8D: "TH1", 0x90: "P1",
       0x98: "SCON", 0x99: "SBUF", 0xA0: "P2", 0xA8: "IE", 0xB0: "P3", 0xB8: "IP",
       0xD0: "PSW", 0xE0: "ACC", 0xF0: "B"}
BITS = {0x88: "TCON", 0x98: "SCON", 0xA8: "IE", 0xB8: "IP", 0xD0: "PSW", 0xE0: "ACC",
        0xF0: "B", 0x80: "P0", 0x90: "P1", 0xA0: "P2", 0xB0: "P3"}
TCON_BITS = ["IT0", "IE0", "IT1", "IE1", "TR0", "TF0", "TR1", "TF1"]
IE_BITS = ["EX0", "ET0", "EX1", "ET1", "ES", "ET2", "-", "EA"]
PSW_BITS = ["P", "-", "OV", "RS0", "RS1", "F0", "AC", "CY"]


def direct(a):
    return SFR.get(a, "%02Xh" % a) if a >= 0x80 else "%02Xh" % a


def bit(a):
    if a < 0x80:
        return "%02Xh.%d" % (0x20 + (a >> 3), a & 7)
    base, n = a & 0xF8, a & 7
    if base == 0x88:
        return TCON_BITS[n]
    if base == 0xA8:
        return IE_BITS[n]
    if base == 0xD0:
        return PSW_BITS[n]
    return "%s.%d" % (BITS.get(base, "%02Xh" % base), n)


def dis(d, pc):
    op = d[pc]
    b1 = d[pc + 1] if pc + 1 < len(d) else 0
    b2 = d[pc + 2] if pc + 2 < len(d) else 0
    rn = op & 7
    ri = op & 1

    def rel(n):   # n = instruction length
        t = (pc + n + (b1 if n == 2 else b2) - (256 if (b1 if n == 2 else b2) & 0x80 else 0)) & 0xFFFF
        return "%04Xh" % t

    hi = op & 0xF0
    lo = op & 0x0F
    if lo == 1:
        a11 = ((op >> 5) << 8) | b1
        tgt = ((pc + 2) & 0xF800) | a11
        return ("AJMP" if (op & 0x10) == 0 else "ACALL") + " %04Xh" % tgt, 2
    simple = {
        0x00: ("NOP", 1), 0x03: ("RR A", 1), 0x04: ("INC A", 1), 0x13: ("RRC A", 1), 0x14: ("DEC A", 1),
        0x22: ("RET", 1), 0x23: ("RL A", 1), 0x32: ("RETI", 1), 0x33: ("RLC A", 1), 0x73: ("JMP @A+DPTR", 1),
        0x83: ("MOVC A,@A+PC", 1), 0x84: ("DIV AB", 1), 0x93: ("MOVC A,@A+DPTR", 1), 0xA3: ("INC DPTR", 1),
        0xA4: ("MUL AB", 1), 0xB3: ("CPL C", 1), 0xC3: ("CLR C", 1), 0xC4: ("SWAP A", 1), 0xD3: ("SETB C", 1),
        0xD4: ("DA A", 1), 0xE0: ("MOVX A,@DPTR", 1), 0xE4: ("CLR A", 1), 0xF0: ("MOVX @DPTR,A", 1),
        0xF4: ("CPL A", 1), 0xA5: ("(reserved)", 1)}
    if op in simple:
        return simple[op]
    if op == 0x02: return "LJMP %04Xh" % ((b1 << 8) | b2), 3
    if op == 0x12: return "LCALL %04Xh" % ((b1 << 8) | b2), 3
    if op == 0x05: return "INC %s" % direct(b1), 2
    if op == 0x15: return "DEC %s" % direct(b1), 2
    if op in (0x06, 0x07): return "INC @R%d" % ri, 1
    if op in (0x16, 0x17): return "DEC @R%d" % ri, 1
    if 0x08 <= op <= 0x0F: return "INC R%d" % rn, 1
    if 0x18 <= op <= 0x1F: return "DEC R%d" % rn, 1
    if op == 0x10: return "JBC %s,%s" % (bit(b1), rel(3)), 3
    if op == 0x20: return "JB %s,%s" % (bit(b1), rel(3)), 3
    if op == 0x30: return "JNB %s,%s" % (bit(b1), rel(3)), 3
    if op == 0x40: return "JC %s" % rel(2), 2
    if op == 0x50: return "JNC %s" % rel(2), 2
    if op == 0x60: return "JZ %s" % rel(2), 2
    if op == 0x70: return "JNZ %s" % rel(2), 2
    if op == 0x80: return "SJMP %s" % rel(2), 2
    alu = {0x20: "ADD", 0x30: "ADDC", 0x40: "ORL", 0x50: "ANL", 0x60: "XRL", 0x90: "SUBB"}
    if hi in alu and op not in (0x20, 0x30, 0x40, 0x50, 0x60):
        n = alu[hi]
        if lo == 0x4: return "%s A,#%02Xh" % (n, b1), 2
        if lo == 0x5: return "%s A,%s" % (n, direct(b1)), 2
        if lo in (6, 7): return "%s A,@R%d" % (n, ri), 1
        if lo >= 8: return "%s A,R%d" % (n, rn), 1
    if hi in (0x40, 0x50, 0x60):
        n = alu[hi]
        if lo == 2: return "%s %s,A" % (n, direct(b1)), 2
        if lo == 3: return "%s %s,#%02Xh" % (n, direct(b1), b2), 3
    if op == 0x72: return "ORL C,%s" % bit(b1), 2
    if op == 0x82: return "ANL C,%s" % bit(b1), 2
    if op == 0xA0: return "ORL C,/%s" % bit(b1), 2
    if op == 0xB0: return "ANL C,/%s" % bit(b1), 2
    if op == 0x92: return "MOV %s,C" % bit(b1), 2
    if op == 0xA2: return "MOV C,%s" % bit(b1), 2
    if op == 0xB2: return "CPL %s" % bit(b1), 2
    if op == 0xC2: return "CLR %s" % bit(b1), 2
    if op == 0xD2: return "SETB %s" % bit(b1), 2
    if op == 0x74: return "MOV A,#%02Xh" % b1, 2
    if op == 0x75: return "MOV %s,#%02Xh" % (direct(b1), b2), 3
    if op in (0x76, 0x77): return "MOV @R%d,#%02Xh" % (ri, b1), 2
    if 0x78 <= op <= 0x7F: return "MOV R%d,#%02Xh" % (rn, b1), 2
    if op == 0x85: return "MOV %s,%s" % (direct(b2), direct(b1)), 3
    if op in (0x86, 0x87): return "MOV %s,@R%d" % (direct(b1), ri), 2
    if 0x88 <= op <= 0x8F: return "MOV %s,R%d" % (direct(b1), rn), 2
    if op == 0x90: return "MOV DPTR,#%04Xh" % ((b1 << 8) | b2), 3
    if op in (0xA6, 0xA7): return "MOV @R%d,%s" % (ri, direct(b1)), 2
    if 0xA8 <= op <= 0xAF: return "MOV R%d,%s" % (rn, direct(b1)), 2
    if op == 0xB4: return "CJNE A,#%02Xh,%s" % (b1, rel(3)), 3
    if op == 0xB5: return "CJNE A,%s,%s" % (direct(b1), rel(3)), 3
    if op in (0xB6, 0xB7): return "CJNE @R%d,#%02Xh,%s" % (ri, b1, rel(3)), 3
    if 0xB8 <= op <= 0xBF: return "CJNE R%d,#%02Xh,%s" % (rn, b1, rel(3)), 3
    if op == 0xC0: return "PUSH %s" % direct(b1), 2
    if op == 0xD0: return "POP %s" % direct(b1), 2
    if op == 0xC5: return "XCH A,%s" % direct(b1), 2
    if op in (0xC6, 0xC7): return "XCH A,@R%d" % ri, 1
    if 0xC8 <= op <= 0xCF: return "XCH A,R%d" % rn, 1
    if op in (0xD6, 0xD7): return "XCHD A,@R%d" % ri, 1
    if op == 0xD5: return "DJNZ %s,%s" % (direct(b1), rel(3)), 3
    if 0xD8 <= op <= 0xDF: return "DJNZ R%d,%s" % (rn, rel(2)), 2
    if op in (0xE2, 0xE3): return "MOVX A,@R%d" % ri, 1
    if op == 0xE5: return "MOV A,%s" % direct(b1), 2
    if op in (0xE6, 0xE7): return "MOV A,@R%d" % ri, 1
    if 0xE8 <= op <= 0xEF: return "MOV A,R%d" % rn, 1
    if op in (0xF2, 0xF3): return "MOVX @R%d,A" % ri, 1
    if op == 0xF5: return "MOV %s,A" % direct(b1), 2
    if op in (0xF6, 0xF7): return "MOV @R%d,A" % ri, 1
    if 0xF8 <= op <= 0xFF: return "MOV R%d,A" % rn, 1
    return "DB %02Xh" % op, 1


def main():
    d = open(sys.argv[1], "rb").read()
    start = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0
    end = int(sys.argv[3], 0) if len(sys.argv) > 3 else min(len(d), start + 0x80)
    pc = start
    while pc < end:
        text, n = dis(d, pc)
        print("%04X  %-9s %s" % (pc, " ".join("%02X" % b for b in d[pc:pc + n]), text))
        pc += n


if __name__ == "__main__":
    main()
