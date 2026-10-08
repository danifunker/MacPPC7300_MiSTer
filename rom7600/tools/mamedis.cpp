/*
 * mamedis - MAME's 68k (Musashi) and PowerPC disassemblers, unmodified,
 * behind a small command line.
 *
 *   mamedis m68k|ppc FILE OFFSET LENGTH BASEADDR      linear listing
 *   mamedis m68k-server FILE BASEADDR                 one request per line
 *
 * Linear mode prints "AAAAAAAA LEN FLAGS HEXBYTES<TAB>text" per instruction,
 * starting at OFFSET of FILE, which is taken to sit at BASEADDR.
 * Server mode maps the whole FILE at BASEADDR and answers each address read
 * from stdin (hex) with one such line, flushed, for recursive descent.
 * FLAGS: o = step over (call), r = step out (return), c = conditional.
 * The 68k disassembler runs as a 68040 (MAME's type, with the FPU and the
 * 68040's cache and MMU instructions).
 */

#include "emu.h"
#include "cpu/m68000/m68kdasm.h"
#include "cpu/powerpc/ppc_dasm.h"

#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct FileBuffer : public util::disasm_interface::data_buffer {
    std::vector<unsigned char> data;
    uint32_t base = 0;

    unsigned char at(offs_t pc) const {
        uint32_t i = pc - base;
        return i < data.size() ? data[i] : 0;
    }
    u8  r8 (offs_t pc) const override { return at(pc); }
    u16 r16(offs_t pc) const override { return u16(at(pc)) << 8 | at(pc + 1); }
    u32 r32(offs_t pc) const override { return u32(r16(pc)) << 16 | r16(pc + 2); }
    u64 r64(offs_t pc) const override { return u64(r32(pc)) << 32 | r32(pc + 4); }
};

std::string one(util::disasm_interface &d, const FileBuffer &buf, uint32_t pc, unsigned &len) {
    std::ostringstream os;
    offs_t r = d.disassemble(os, pc, buf, buf);
    len = r & util::disasm_interface::LENGTHMASK;
    if (len == 0) len = d.opcode_alignment();
    std::string flags;
    if (r & util::disasm_interface::STEP_OVER) flags += 'o';
    if (r & util::disasm_interface::STEP_OUT)  flags += 'r';
    if (r & util::disasm_interface::STEP_COND) flags += 'c';
    if (flags.empty()) flags = "-";
    char head[64];
    std::snprintf(head, sizeof(head), "%08X %u %s ", pc, len, flags.c_str());
    std::string hex;
    for (unsigned i = 0; i < len; i++) {
        char b[4];
        std::snprintf(b, sizeof(b), "%02X", buf.at(pc + i));
        hex += b;
    }
    return std::string(head) + hex + "\t" + os.str();
}

bool load(const char *path, FileBuffer &buf, unsigned long off, unsigned long len) {
    FILE *f = std::fopen(path, "rb");
    if (!f) { std::perror(path); return false; }
    if (len == 0) {
        std::fseek(f, 0, SEEK_END);
        len = std::ftell(f) - off;
    }
    std::fseek(f, long(off), SEEK_SET);
    buf.data.resize(len);
    buf.data.resize(std::fread(buf.data.data(), 1, len, f));
    std::fclose(f);
    return true;
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 4) {
        std::fprintf(stderr, "usage: mamedis m68k|ppc FILE OFFSET LENGTH BASEADDR\n"
                             "       mamedis m68k-server FILE BASEADDR\n");
        return 2;
    }
    std::string mode = argv[1];
    m68k_disassembler m68k(m68k_disassembler::TYPE_68040);
    powerpc_disassembler ppc(powerpc_disassembler::I_POWERPC);
    FileBuffer buf;

    if (mode == "m68k-server") {
        if (!load(argv[2], buf, 0, 0)) return 1;
        buf.base = uint32_t(std::strtoul(argv[3], nullptr, 0));
        std::string line;
        while (std::getline(std::cin, line)) {
            if (line.empty()) continue;
            uint32_t pc = uint32_t(std::strtoul(line.c_str(), nullptr, 16));
            unsigned len;
            std::string s = one(m68k, buf, pc, len);
            std::fputs(s.c_str(), stdout);
            std::fputc('\n', stdout);
            std::fflush(stdout);
        }
        return 0;
    }

    if (argc < 6) { std::fprintf(stderr, "missing arguments\n"); return 2; }
    unsigned long off = std::strtoul(argv[3], nullptr, 0);
    unsigned long len = std::strtoul(argv[4], nullptr, 0);
    uint32_t base     = uint32_t(std::strtoul(argv[5], nullptr, 0));
    if (!load(argv[2], buf, off, len)) return 1;
    buf.base = base;
    util::disasm_interface &d = (mode == "ppc") ? static_cast<util::disasm_interface &>(ppc)
                                                : static_cast<util::disasm_interface &>(m68k);
    uint32_t end = base + uint32_t(buf.data.size());
    for (uint32_t pc = base; pc < end;) {
        unsigned l;
        std::string s = one(d, buf, pc, l);
        std::puts(s.c_str());
        pc += l;
    }
    return 0;
}
