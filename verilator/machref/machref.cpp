/*
 * machref.cpp - a whole dingusppc machine (the Power Macintosh 7600 by
 * default), headless, running a ROM from the reset vector and logging every
 * access the CPU makes to a device. It is the reference for the device side
 * of PPCMac_machine: which registers the ROM touches, in what order, and what
 * dingusppc's devices answer.
 *
 *   machref --rom FILE [--machine pm7600] [--ram MB] [--cpu 604] [--pvr HEX]
 *           [--max N] [--log FILE] [--sample N] [--trace-from N --trace-count M]
 *
 * Log lines (numbers in hex except the instruction count):
 *   A icount pc R|W size address value device   a device access
 *   S icount pc msr                             a sample of where the CPU is
 *   T icount pc opcode msr                      a traced instruction
 *   E icount pc msr                             the end of the run
 * icount is the number of instructions completed before the one making the
 * access (dingusppc's instruction counter, which also stands for its time).
 *
 * dingusppc is compiled unmodified; this file only uses its public
 * interfaces. GPL-3.0-or-later, as dingusppc.
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

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

extern uint64_t g_icycles;    // cpu/ppc/ppcexec.cpp: instructions executed

namespace {

FILE    *g_log = nullptr;
uint64_t g_max = 2000000000ull;
uint64_t g_sample = 0;
uint64_t g_next_sample = 0;
uint64_t g_accesses = 0;
MemCtrlBase *g_mem = nullptr;

struct Proxy;
std::map<MMIODevice *, std::unique_ptr<Proxy>> g_proxies;   // original device -> its proxy
std::map<MMIODevice *, MMIODevice *> g_is_proxy;            // proxy -> original

void rescan();

/* Stands in for a device in the memory map: logs, then passes the access on
   unchanged. */
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
        std::fprintf(g_log, "A %llu %08X R %d %08X %0*X %s\n", (unsigned long long)g_icycles,
                     ppc_state.pc, size, rgn_start + offset, size * 2, v, name.c_str());
        return v;
    }

    void write(uint32_t rgn_start, uint32_t offset, uint32_t value, int size) override {
        g_accesses++;
        std::fprintf(g_log, "A %llu %08X W %d %08X %0*X %s\n", (unsigned long long)g_icycles,
                     ppc_state.pc, size, rgn_start + offset, size * 2, value, name.c_str());
        dev->write(rgn_start, offset, value, size);
        // a PCI configuration write may have moved or added a device's region
        if (is_pci_host)
            rescan();
    }
};

/* Puts a proxy in front of every device region in the map that does not
   have one yet. Regions come and go as the ROM programs the PCI base
   address registers, so this runs again after every configuration write. */
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
                std::fprintf(g_log, "# device %s at %08X-%08X\n", orig->get_name().c_str(), e->start, e->end);
            }
            e->devobj = it->second.get();
        }
        a = (uint64_t(e->end) | 0xFFFull) + 1;
    }
}

TimerInfo g_watch;

void watch(uint64_t, uint64_t) {
    if (g_sample && g_icycles >= g_next_sample) {
        std::fprintf(g_log, "S %llu %08X %08X\n", (unsigned long long)g_icycles, ppc_state.pc, ppc_state.msr);
        g_next_sample = g_icycles + g_sample;
    }
    if (g_icycles >= g_max)
        power_off(po_shutting_down);
}

void usage() {
    std::printf("usage: machref --rom FILE [--machine pm7600] [--ram MB] [--cpu 604] [--pvr HEX]\n"
                "               [--max N] [--log FILE] [--sample N] [--trace-from N --trace-count M]\n"
                "               [--set NAME=VALUE ...]\n");
}

} // namespace

int main(int argc, char **argv) {
    std::string rom_path, machine = "pm7600", log_path = "machref.log", cpu = "604";
    unsigned ram_mb = 16;
    uint32_t pvr = 0x00040303;            // the 604 measured on the 7600 and 7300: revision 3.3
    uint64_t trace_from = 0, trace_count = 0;
    std::map<std::string, std::string> settings;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) { usage(); std::exit(2); }
            return argv[++i];
        };
        if (a == "--rom") rom_path = next();
        else if (a == "--machine") machine = next();
        else if (a == "--ram") ram_mb = unsigned(std::atoi(next().c_str()));
        else if (a == "--cpu") cpu = next();
        else if (a == "--pvr") pvr = uint32_t(std::strtoul(next().c_str(), nullptr, 16));
        else if (a == "--max") g_max = std::strtoull(next().c_str(), nullptr, 0);
        else if (a == "--log") log_path = next();
        else if (a == "--sample") g_sample = std::strtoull(next().c_str(), nullptr, 0);
        else if (a == "--trace-from") trace_from = std::strtoull(next().c_str(), nullptr, 0);
        else if (a == "--trace-count") trace_count = std::strtoull(next().c_str(), nullptr, 0);
        else if (a == "--set") {
            std::string kv = next();
            size_t eq = kv.find('=');
            if (eq == std::string::npos) { usage(); return 2; }
            settings[kv.substr(0, eq)] = kv.substr(eq + 1);
        }
        else { usage(); return a == "--help" ? 0 : 2; }
    }
    if (rom_path.empty()) { usage(); return 2; }

    // RAM as DIMMs of the sizes dingusppc accepts (the TNT maps them flat
    // from 0 whatever the bank registers say)
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
    if (const char *e = getenv("MACHREF_LOG")) loguru::g_stderr_verbosity = std::atoi(e);
    loguru::init(argc, argv);

    g_log = std::fopen(log_path.c_str(), "w");
    if (!g_log) { std::fprintf(stderr, "cannot write %s\n", log_path.c_str()); return 2; }
    static char logbuf[1 << 20];
    std::setvbuf(g_log, logbuf, _IOFBF, sizeof(logbuf));

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
    std::fprintf(g_log, "# machine %s, ROM %s, %u MB, PVR %08X, start pc %08X msr %08X\n", machine.c_str(),
                 rom_path.c_str(), ram_mb, pvr, ppc_state.pc, ppc_state.msr);
    rescan();

    TimerManager::get_instance()->add_cyclic_timer(g_watch, USECS_TO_NSECS(10), watch);

    // run to the start of the traced window (or to the end), then step
    // through the window one instruction at a time, then run on
    uint64_t stop = trace_count ? trace_from : g_max;
    uint64_t saved_max = g_max;
    g_max = stop;
    power_on = true;
    if (g_icycles < stop) ppc_exec();
    if (trace_count && power_off_reason == po_shutting_down) {
        g_max = saved_max;
        power_on = true;
        for (uint64_t n = 0; n < trace_count && power_on; n++) {
            // the opcode is read only with translation off: a translated
            // fetch here could take an exception outside dingusppc's loop
            uint32_t pc = ppc_state.pc, opcode = 0xFFFFFFFF;
            if (!(ppc_state.msr & MSR::IR)) {
                const uint8_t *p = g_mem->get_region_hostmem_ptr(pc);
                if (p) opcode = uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
            }
            std::fprintf(g_log, "T %llu %08X %08X %08X\n", (unsigned long long)g_icycles, pc, opcode, ppc_state.msr);
            ppc_exec_single();
        }
        if (power_on && g_icycles < g_max) ppc_exec();
    }

    std::fprintf(g_log, "E %llu %08X %08X\n", (unsigned long long)g_icycles, ppc_state.pc, ppc_state.msr);
    std::fclose(g_log);
    std::printf("%llu instructions, %llu device accesses, stopped at pc %08X msr %08X (%s)\n",
                (unsigned long long)g_icycles, (unsigned long long)g_accesses, ppc_state.pc, ppc_state.msr,
                power_off_reason == po_shutting_down ? "instruction limit" : "the machine stopped itself");
    TimerManager::get_instance()->cancel_all_timers();
    _exit(0);   // the machine's destructors save NVRAM and the like; nothing to keep
}
