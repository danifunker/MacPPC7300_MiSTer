/*
 * ppcdis_dingus - disassemble a range of a big-endian binary as PowerPC with
 * dingusppc's disassembler (cpu/ppc/ppcdisasm.cpp, compiled unmodified).
 *
 *   ppcdis_dingus FILE OFFSET LENGTH BASEADDR [-r]
 *
 * One line per word: "AAAAAAAA WWWWWWWW text<TAB>out-regs<TAB>in-regs", the
 * register lists comma-separated as dingusppc reports them (used to track
 * which registers an instruction overwrites). -r turns the simplified
 * mnemonics off. Numbers on the command line are in C notation (0x...).
 */

#include <cpu/ppc/ppcdisasm.h>

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

// ppcdisasm.cpp asks the debugger for register contents (mtsrin/mfsrin);
// a static disassembly has none
uint64_t get_reg(std::string) { return 0; }

int main(int argc, char **argv) {
    if (argc < 5) {
        std::fprintf(stderr, "usage: ppcdis_dingus FILE OFFSET LENGTH BASEADDR [-r]\n");
        return 2;
    }
    const char *path = argv[1];
    unsigned long off = std::strtoul(argv[2], nullptr, 0);
    unsigned long len = std::strtoul(argv[3], nullptr, 0);
    uint32_t base     = uint32_t(std::strtoul(argv[4], nullptr, 0));
    bool simplified   = !(argc > 5 && std::string(argv[5]) == "-r");

    FILE *f = std::fopen(path, "rb");
    if (!f) { std::perror(path); return 1; }
    std::fseek(f, long(off), SEEK_SET);
    std::vector<unsigned char> buf(len);
    size_t got = std::fread(buf.data(), 1, len, f);
    std::fclose(f);

    for (size_t i = 0; i + 4 <= got; i += 4) {
        uint32_t w = uint32_t(buf[i]) << 24 | uint32_t(buf[i + 1]) << 16 | uint32_t(buf[i + 2]) << 8 | buf[i + 3];
        PPCDisasmContext ctx;
        ctx.instr_addr = base + uint32_t(i);
        ctx.instr_code = w;
        ctx.simplified = simplified;
        std::string s;
        if ((w >> 26) == 4) {
            // primary opcode 4 (AltiVec) is illegal on the 601/603/604;
            // dingusppc prints a message on stdout for it instead
            char b[32];
            std::snprintf(b, sizeof(b), "dc.l    0x%08X", w);
            s = b;
        } else {
            try {
                s = disassemble_single(&ctx);
            } catch (...) {
                s = "<exception>";
            }
        }
        std::string out, in;
        for (auto &r : ctx.regs_out) { if (!out.empty()) out += ','; out += r; }
        for (auto &r : ctx.regs_in)  { if (!in.empty())  in  += ','; in  += r; }
        std::printf("%08X %08X %s\t%s\t%s\n", base + uint32_t(i), w, s.c_str(), out.c_str(), in.c_str());
    }
    return 0;
}
