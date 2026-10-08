/*
 * romcov.cpp - execution coverage of a Power Macintosh ROM in a headless
 * dingusppc machine (the 7600 by default). Derived from
 * verilator/machref/machref.cpp (same machine set-up, same device proxies);
 * instead of running dingusppc's loop it steps one instruction at a time and
 * records, for every instruction, the physical word it was fetched from.
 *
 *   romcov --rom FILE --out DIR [--machine pm7600] [--ram MB] [--cpu 604]
 *          [--pvr HEX] [--max N] [--log FILE] [--sample N]
 *          [--dump-at N ...] [--regs-at-pa PA --regs-count N]
 *          [--m68k-reg R]
 *
 * Writes into DIR:
 *   rom_first.bin  u32 little-endian per ROM word: 1 + the instruction count
 *                  at its first execution, 0 if never executed
 *   rom_ea.bin     u32 per ROM word: the effective address it ran at first
 *   ram_first.bin, ram_ea.bin   the same for every RAM word
 *   pages.txt      every (effective page, physical page, MSR) seen with its
 *                  first instruction count: where code runs and from where
 *   ram_N.bin      the whole RAM at instruction N, for each --dump-at N
 *   m68k_pcs.txt   with --m68k-reg R (24 for Apple's emulator): the 68k
 *                  instructions executed, with counts: GPR R minus 2 at the
 *                  first instruction of every opcode-table entry dispatched
 *                  (ROM FFF80000-FFFFFFFF, 8 bytes per 68k opcode); the
 *                  emulator keeps R pointing 2 past the opcode it dispatches
 *   regs.txt       with --regs-at-pa: all GPRs at the first N executions of
 *                  the instruction at that physical address
 *   summary.txt    totals
 * The device log (--log) has machref's format (A/S/E lines); an access made
 * by the 68k emulator carries a last field "68k=ADDR", the 68k instruction
 * behind it (the emulator's r24 - 2).
 *
 * dingusppc is compiled unmodified; GPL-3.0-or-later, as dingusppc.
 */

#include <core/timermanager.h>
#include <cpu/ppc/ppcemu.h>
#include <cpu/ppc/ppcmmu.h>
#include <devices/common/hwcomponent.h>
#include <devices/common/mmiodevice.h>
#include <devices/common/pci/pcihost.h>
#include <devices/memctrl/memctrlbase.h>
#include <machines/machinebase.h>
#include <machines/machinefactory.h>
#include <loguru.hpp>

#include <algorithm>
#include <cinttypes>
#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

extern uint64_t g_icycles;    // cpu/ppc/ppcexec.cpp: instructions executed

namespace {

FILE    *g_log = nullptr;
uint64_t g_accesses = 0;
MemCtrlBase *g_mem = nullptr;

struct Proxy;
std::map<MMIODevice *, std::unique_ptr<Proxy>> g_proxies;
std::map<MMIODevice *, MMIODevice *> g_is_proxy;

void rescan();

/* " 68k=AAAAAAAA" when the access comes from the 68k emulator (code mapped
   at 68060000-680FFFFF): the 68k instruction behind it, from the emulator's
   PC register r24 (2 past the current opcode at dispatch; extension-word
   fetches move it further, so this is the opcode address or a little past) */
const char *m68k_tag() {
    static char buf[24];
    if (ppc_state.pc >= 0x68060000 && ppc_state.pc < 0x68100000) {
        std::snprintf(buf, sizeof(buf), " 68k=%08X", ppc_state.gpr[24] - 2);
        return buf;
    }
    return "";
}

struct Proxy : public MMIODevice {
    MMIODevice *dev;
    bool        is_pci_host;

    explicit Proxy(MMIODevice *d) : dev(d) {
        this->name  = d->get_name();
        is_pci_host = dynamic_cast<PCIHost *>(d) != nullptr;
    }

    uint32_t read(uint32_t rgn_start, uint32_t offset, int size) override {
        uint32_t v = dev->read(rgn_start, offset, size);
        g_accesses++;
        if (g_log)
            std::fprintf(g_log, "A %llu %08X R %d %08X %0*X %s%s\n", (unsigned long long)g_icycles,
                         ppc_state.pc, size, rgn_start + offset, size * 2, v, name.c_str(), m68k_tag());
        return v;
    }

    void write(uint32_t rgn_start, uint32_t offset, uint32_t value, int size) override {
        g_accesses++;
        if (g_log)
            std::fprintf(g_log, "A %llu %08X W %d %08X %0*X %s%s\n", (unsigned long long)g_icycles,
                         ppc_state.pc, size, rgn_start + offset, size * 2, value, name.c_str(), m68k_tag());
        dev->write(rgn_start, offset, value, size);
        if (is_pci_host)
            rescan();
    }
};

void rescan() {
    uint64_t a = 0x80000000ull;
    while (a < 0x100000000ull) {
        AddressMapEntry *e = g_mem->find_range(uint32_t(a));
        if (!e) {
            a += 0x1000;
            continue;
        }
        if ((e->type & RT_MMIO) && e->devobj && !g_is_proxy.count(e->devobj)) {
            MMIODevice *orig = e->devobj;
            auto it = g_proxies.find(orig);
            if (it == g_proxies.end()) {
                auto p = std::make_unique<Proxy>(orig);
                g_is_proxy[p.get()] = orig;
                it = g_proxies.emplace(orig, std::move(p)).first;
                if (g_log)
                    std::fprintf(g_log, "# device %s at %08X-%08X\n", orig->get_name().c_str(), e->start, e->end);
            }
            e->devobj = it->second.get();
        }
        a = (uint64_t(e->end) | 0xFFFull) + 1;
    }
}

/* ---- coverage ------------------------------------------------------------ */

constexpr uint32_t ROM_PA   = 0xFFC00000;
constexpr uint32_t ROM_SIZE = 0x00400000;

const uint8_t *g_rom_host = nullptr;
uint8_t       *g_ram_host = nullptr;   // RAM is one host block from physical 0
uint32_t       g_ram_size = 0;

std::vector<uint32_t> g_rom_first, g_rom_ea, g_ram_first, g_ram_ea;
std::unordered_map<uint64_t, uint64_t> g_pages;   // (ea page, pa page, msr bits) -> first icount
uint64_t g_last_page_key = ~0ull;
uint64_t g_unknown_fetch = 0;
uint64_t g_fetch_faults  = 0;

int      g_m68k_reg = -1;
std::unordered_map<uint32_t, uint64_t> g_m68k_pcs;

uint32_t g_regs_pa = 0xFFFFFFFF;
uint64_t g_regs_left = 0;
FILE    *g_regs = nullptr;

inline void record(uint32_t ea, const uint8_t *host) {
    uint32_t pa;
    uint32_t stamp = uint32_t(std::min<uint64_t>(g_icycles + 1, 0xFFFFFFFFull));
    if (g_rom_host && host >= g_rom_host && host < g_rom_host + ROM_SIZE) {
        uint32_t off = uint32_t(host - g_rom_host);
        pa = ROM_PA + off;
        uint32_t w = off >> 2;
        if (!g_rom_first[w]) { g_rom_first[w] = stamp; g_rom_ea[w] = ea; }
        // the first instruction of an opcode-table entry: the emulator's
        // 68k PC register points 2 past the opcode being dispatched
        if (g_m68k_reg >= 0 && off >= 0x380000 && !(off & 4))
            g_m68k_pcs[ppc_state.gpr[g_m68k_reg] - 2]++;
    } else if (g_ram_host && host >= g_ram_host && host < g_ram_host + g_ram_size) {
        uint32_t off = uint32_t(host - g_ram_host);
        pa = off;
        uint32_t w = off >> 2;
        if (!g_ram_first[w]) { g_ram_first[w] = stamp; g_ram_ea[w] = ea; }
    } else {
        g_unknown_fetch++;
        return;
    }
    uint64_t key = (uint64_t(ea >> 12) << 40) | (uint64_t(pa >> 12) << 20) | (ppc_state.msr & 0xFFFF);
    if (key != g_last_page_key) {
        g_last_page_key = key;
        g_pages.emplace(key, g_icycles);
    }
    if (pa == g_regs_pa && g_regs_left) {
        g_regs_left--;
        std::fprintf(g_regs, "icount %llu pc %08X msr %08X lr %08X ctr %08X cr %08X\n",
                     (unsigned long long)g_icycles, ppc_state.pc, ppc_state.msr,
                     ppc_state.spr[SPR::LR], ppc_state.spr[SPR::CTR], ppc_state.cr);
        for (int r = 0; r < 32; r++)
            std::fprintf(g_regs, "  r%-2d %08X%s", r, ppc_state.gpr[r], (r % 8 == 7) ? "\n" : "");
    }
}

/* Fetches the next instruction's host address the way ppc_exec_single will,
   recording it; if the fetch faults, the exception has been taken (as
   ppc_exec_single would have) and nothing executes this step. */
bool fetch_and_record() {
    if (setjmp(exc_env)) {
        ppc_state.pc = ppc_next_instruction_address;
        exec_flags = 0;
        g_fetch_faults++;
        return false;
    }
    uint32_t ea = ppc_state.pc;
    const uint8_t *host = mmu_translate_imem(ea);
    record(ea, host);
    return true;
}

bool write_file(const std::string &path, const void *data, size_t size) {
    FILE *f = std::fopen(path.c_str(), "wb");
    if (!f) { std::perror(path.c_str()); return false; }
    std::fwrite(data, 1, size, f);
    std::fclose(f);
    return true;
}

void usage() {
    std::printf("usage: romcov --rom FILE --out DIR [--machine pm7600] [--ram MB] [--cpu 604] [--pvr HEX]\n"
                "              [--max N] [--log FILE] [--sample N] [--dump-at N ...]\n"
                "              [--regs-at-pa PA --regs-count N] [--m68k-reg R] [--set NAME=VALUE ...]\n");
}

} // namespace

int main(int argc, char **argv) {
    std::string rom_path, machine = "pm7600", log_path, cpu = "604", out_dir;
    unsigned ram_mb = 32;
    uint32_t pvr = 0x00040303;
    uint64_t max = 100000000ull, sample = 0;
    std::vector<uint64_t> dumps;
    std::map<std::string, std::string> settings;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) { usage(); std::exit(2); }
            return argv[++i];
        };
        if (a == "--rom") rom_path = next();
        else if (a == "--out") out_dir = next();
        else if (a == "--machine") machine = next();
        else if (a == "--ram") ram_mb = unsigned(std::atoi(next().c_str()));
        else if (a == "--cpu") cpu = next();
        else if (a == "--pvr") pvr = uint32_t(std::strtoul(next().c_str(), nullptr, 16));
        else if (a == "--max") max = std::strtoull(next().c_str(), nullptr, 0);
        else if (a == "--log") log_path = next();
        else if (a == "--sample") sample = std::strtoull(next().c_str(), nullptr, 0);
        else if (a == "--dump-at") dumps.push_back(std::strtoull(next().c_str(), nullptr, 0));
        else if (a == "--regs-at-pa") g_regs_pa = uint32_t(std::strtoul(next().c_str(), nullptr, 16));
        else if (a == "--regs-count") g_regs_left = std::strtoull(next().c_str(), nullptr, 0);
        else if (a == "--m68k-reg") g_m68k_reg = std::atoi(next().c_str());
        else if (a == "--set") {
            std::string kv = next();
            size_t eq = kv.find('=');
            if (eq == std::string::npos) { usage(); return 2; }
            settings[kv.substr(0, eq)] = kv.substr(eq + 1);
        }
        else { usage(); return a == "--help" ? 0 : 2; }
    }
    if (rom_path.empty() || out_dir.empty()) { usage(); return 2; }
    std::sort(dumps.begin(), dumps.end());

    {
        static const unsigned sizes[] = {128, 64, 32, 16, 8, 4};
        unsigned left = ram_mb, bank = 0;
        while (left && bank <= 12) {
            unsigned s = 0;
            for (unsigned c : sizes) if (c <= left) { s = c; break; }
            if (!s) { std::fprintf(stderr, "cannot make %u MB from DIMMs of 4 MB or more\n", ram_mb); return 2; }
            settings.emplace("rambank" + std::to_string(bank) + "_size", std::to_string(s));
            left -= s;
            bank++;
        }
        for (; bank <= 12; bank++) settings.emplace("rambank" + std::to_string(bank) + "_size", "0");
        settings.emplace("cpu", cpu);
    }

    loguru::g_preamble_date   = false;
    loguru::g_preamble_time   = false;
    loguru::g_preamble_thread = false;
    loguru::g_preamble_uptime = false;
    loguru::g_stderr_verbosity = loguru::Verbosity_WARNING;
    if (const char *e = getenv("ROMCOV_LOG")) loguru::g_stderr_verbosity = std::atoi(e);
    loguru::init(argc, argv);

    if (!log_path.empty()) {
        g_log = std::fopen(log_path.c_str(), "w");
        if (!g_log) { std::fprintf(stderr, "cannot write %s\n", log_path.c_str()); return 2; }
        static char logbuf[1 << 20];
        std::setvbuf(g_log, logbuf, _IOFBF, sizeof(logbuf));
    }
    if (g_regs_left) {
        g_regs = std::fopen((out_dir + "/regs.txt").c_str(), "w");
        if (!g_regs) { std::perror("regs.txt"); return 2; }
    }

    auto rom = std::unique_ptr<char[]>(new char[4 * 1024 * 1024]);
    std::memset(rom.get(), 0, 4 * 1024 * 1024);
    size_t rom_size = MachineFactory::read_boot_rom(rom_path, rom.get());
    if (!rom_size) return 1;

    is_deterministic = true;
    MachineFactory::get_setting_value = [&](const std::string &name) -> std::optional<std::string> {
        auto it = settings.find(name);
        if (it == settings.end()) return std::nullopt;
        return it->second;
    };
    if (MachineFactory::register_machine_settings(machine) < 0) return 1;
    if (MachineFactory::create_machine_for_id(machine, rom.get(), rom_size) < 0) return 1;

    ppc_state.spr[SPR::PVR] = pvr;
    g_mem = dynamic_cast<MemCtrlBase *>(gMachineObj->get_comp_by_type(HWCompType::MEM_CTRL));
    if (!g_mem) { std::fprintf(stderr, "no memory controller\n"); return 1; }

    // the ROM's and the RAM's host blocks; the RAM must be one block from 0
    g_rom_host = g_mem->get_region_hostmem_ptr(ROM_PA);
    g_ram_host = g_mem->get_region_hostmem_ptr(0);
    g_ram_size = ram_mb << 20;
    for (uint32_t a = 0; a < g_ram_size; a += 0x100000) {
        if (g_mem->get_region_hostmem_ptr(a) != g_ram_host + a) {
            std::fprintf(stderr, "RAM is not one host block at %08X; coverage covers %u MB\n", a, a >> 20);
            g_ram_size = a;
            break;
        }
    }
    if (!g_rom_host || !g_ram_host) { std::fprintf(stderr, "no ROM or RAM host memory\n"); return 1; }
    g_rom_first.assign(ROM_SIZE / 4, 0);
    g_rom_ea.assign(ROM_SIZE / 4, 0);
    g_ram_first.assign(g_ram_size / 4, 0);
    g_ram_ea.assign(g_ram_size / 4, 0);

    if (g_log)
        std::fprintf(g_log, "# machine %s, ROM %s, %u MB, PVR %08X, start pc %08X msr %08X\n", machine.c_str(),
                     rom_path.c_str(), ram_mb, pvr, ppc_state.pc, ppc_state.msr);
    rescan();

    power_on = true;
    size_t next_dump = 0;
    uint64_t next_sample = sample;
    uint64_t steps = 0;
    while (power_on && g_icycles < max) {
        while (next_dump < dumps.size() && g_icycles >= dumps[next_dump]) {
            char name[64];
            std::snprintf(name, sizeof(name), "/ram_%llu.bin", (unsigned long long)dumps[next_dump]);
            write_file(out_dir + name, g_ram_host, g_ram_size);
            next_dump++;
        }
        if (sample && g_icycles >= next_sample) {
            if (g_log)
                std::fprintf(g_log, "S %llu %08X %08X\n", (unsigned long long)g_icycles, ppc_state.pc, ppc_state.msr);
            next_sample = g_icycles + sample;
        }
        steps++;
        if (fetch_and_record())
            ppc_exec_single();
    }

    if (g_log) {
        std::fprintf(g_log, "E %llu %08X %08X\n", (unsigned long long)g_icycles, ppc_state.pc, ppc_state.msr);
        std::fclose(g_log);
    }
    if (g_regs) std::fclose(g_regs);

    write_file(out_dir + "/rom_first.bin", g_rom_first.data(), g_rom_first.size() * 4);
    write_file(out_dir + "/rom_ea.bin", g_rom_ea.data(), g_rom_ea.size() * 4);
    write_file(out_dir + "/ram_first.bin", g_ram_first.data(), g_ram_first.size() * 4);
    write_file(out_dir + "/ram_ea.bin", g_ram_ea.data(), g_ram_ea.size() * 4);
    {
        char name[64];
        std::snprintf(name, sizeof(name), "/ram_%llu.bin", (unsigned long long)g_icycles);
        write_file(out_dir + name, g_ram_host, g_ram_size);
    }
    {
        std::vector<std::pair<uint64_t, uint64_t>> v(g_pages.begin(), g_pages.end());
        std::sort(v.begin(), v.end(), [](auto &a, auto &b) { return a.second < b.second; });
        FILE *f = std::fopen((out_dir + "/pages.txt").c_str(), "w");
        if (f) {
            std::fprintf(f, "# first_icount ea_page pa_page msr_low16\n");
            for (auto &p : v)
                std::fprintf(f, "%llu %08X %08X %04X\n", (unsigned long long)p.second,
                             uint32_t(p.first >> 40) << 12, uint32_t((p.first >> 20) & 0xFFFFF) << 12,
                             uint32_t(p.first & 0xFFFF));
            std::fclose(f);
        }
    }
    if (g_m68k_reg >= 0) {
        std::vector<std::pair<uint32_t, uint64_t>> v(g_m68k_pcs.begin(), g_m68k_pcs.end());
        std::sort(v.begin(), v.end());
        FILE *f = std::fopen((out_dir + "/m68k_pcs.txt").c_str(), "w");
        if (f) {
            std::fprintf(f, "# 68k opcode address (r%d - 2 at opcode-table dispatch) and count\n", g_m68k_reg);
            for (auto &p : v) std::fprintf(f, "%08X %llu\n", p.first, (unsigned long long)p.second);
            std::fclose(f);
        }
    }
    {
        FILE *f = std::fopen((out_dir + "/summary.txt").c_str(), "w");
        if (f) {
            size_t rom_words = 0, ram_words = 0;
            for (auto x : g_rom_first) rom_words += x != 0;
            for (auto x : g_ram_first) ram_words += x != 0;
            std::fprintf(f, "machine %s rom %s ram %u MB pvr %08X\n", machine.c_str(), rom_path.c_str(), ram_mb, pvr);
            std::fprintf(f, "instructions %llu steps %llu fetch_faults %llu unknown_fetch %llu device_accesses %llu\n",
                         (unsigned long long)g_icycles, (unsigned long long)steps,
                         (unsigned long long)g_fetch_faults, (unsigned long long)g_unknown_fetch,
                         (unsigned long long)g_accesses);
            std::fprintf(f, "rom_words_executed %zu ram_words_executed %zu\n", rom_words, ram_words);
            std::fprintf(f, "end pc %08X msr %08X (%s)\n", ppc_state.pc, ppc_state.msr,
                         power_on ? "instruction limit" : "the machine stopped itself");
            std::fclose(f);
        }
    }
    std::printf("%llu instructions, stopped at pc %08X msr %08X\n", (unsigned long long)g_icycles,
                ppc_state.pc, ppc_state.msr);
    TimerManager::get_instance()->cancel_all_timers();
    _exit(0);
}
