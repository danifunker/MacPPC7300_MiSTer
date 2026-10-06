/*
 * dingus_ref.cpp - glue between the C API in dingus_ref.h and the dingusppc
 * PowerPC interpreter (compiled unmodified from the dingusppc tree).
 *
 * dingusppc is GPL-3.0-or-later; anything linked with this library is a
 * combined work under the same terms.
 */

#include "dingus_ref.h"

#include <cpu/ppc/ppcemu.h>
#include <cpu/ppc/ppcmmu.h>
#include <devices/common/mmiodevice.h>
#include <devices/memctrl/memctrlbase.h>
#include <loguru.hpp>

#include <cfenv>
#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

/* dingusppc globals that its headers do not declare (cpu/ppc/ppcexec.cpp). */
extern bool     g_realtime;   // false: virtual time = g_icycles << icnt_factor
extern uint64_t g_icycles;    // only advanced by dingusppc's own run loops

namespace {

/* Thrown by the loguru fatal handler, i.e. whenever dingusppc hits ABORT_F(). */
struct RefAbort {};

struct StoreRec {
    uint32_t addr;
    uint32_t size;
    uint64_t value;
};

/* stmw: 32 words; stswx: 31 words + 2; dcbz: 4 doublewords. */
constexpr unsigned MAX_STORES = 64;
constexpr uint32_t PAGE       = 4096;
/* Slack after the RAM so that no host access made through a soft-TLB entry of
   the last page can run off the allocation. */
constexpr size_t   RAM_GUARD  = 64;

StoreRec     g_stores[MAX_STORES];
unsigned     g_nstores = 0;

uint8_t     *g_ram      = nullptr;
MemCtrlBase *g_mem      = nullptr;
bool         g_ready    = false;
bool         g_log_init = false;
char         g_err[512] = "";

/* A device range whose accesses are answered by the caller (ref_add_mmio). */
class BenchMmio : public MMIODevice {
public:
    BenchMmio(ref_mmio_read_fn rd, ref_mmio_write_fn wr, void *ctx) : rd(rd), wr(wr), ctx(ctx) {
        this->name = "bench";
    }
    uint32_t read(uint32_t rgn_start, uint32_t offset, int size) override {
        return rd ? rd(ctx, rgn_start + offset, unsigned(size)) : 0;
    }
    void write(uint32_t rgn_start, uint32_t offset, uint32_t value, int size) override {
        if (wr)
            wr(ctx, rgn_start + offset, unsigned(size), value);
    }

private:
    ref_mmio_read_fn  rd;
    ref_mmio_write_fn wr;
    void             *ctx;
};

std::vector<std::unique_ptr<BenchMmio>> g_mmio;

void log_store(uint32_t addr, uint32_t size, uint64_t value) {
    if (g_nstores < MAX_STORES)
        g_stores[g_nstores] = StoreRec{addr, size, value};
    g_nstores++;
}

void fatal_handler(const loguru::Message &m) {
    snprintf(g_err, sizeof(g_err), "dingusppc abort at %s:%u: %s%s",
             m.filename ? m.filename : "?", m.line,
             m.prefix ? m.prefix : "", m.message ? m.message : "");
    /* strip dingusppc's trailing newline, if any */
    size_t n = strlen(g_err);
    while (n && (g_err[n - 1] == '\n' || g_err[n - 1] == '\r'))
        g_err[--n] = 0;
    throw RefAbort();
}

void setup_logging() {
    if (g_log_init)
        return;
    g_log_init = true;

    /* dingusppc messages go to stderr through loguru. Default: errors and
       aborts only. DINGUSREF_LOG=<n> overrides (-9 silent, -1 +warnings,
       0 +info, 9 everything). */
    loguru::g_preamble_date   = false;
    loguru::g_preamble_time   = false;
    loguru::g_preamble_uptime = false;
    loguru::g_preamble_thread = false;
    loguru::g_stderr_verbosity = loguru::Verbosity_ERROR;
    if (const char *e = getenv("DINGUSREF_LOG"))
        loguru::g_stderr_verbosity = atoi(e);
    loguru::set_fatal_handler(fatal_handler);
}

/* SPR numbers that dingusppc stores under another index. */
unsigned canon_spr(unsigned n) {
    switch (n) {
    case SPR::TBL_U:  return SPR::TBL_S;
    case SPR::TBU_U:  return SPR::TBU_S;
    }
    if (is_601) {
        switch (n) {
        case SPR::RTCU_U: return SPR::RTCU_S;
        case SPR::RTCL_U: return SPR::RTCL_S;
        case SPR::DEC_U:  return SPR::DEC_S;
        }
    }
    return n;
}

/* Select the opcode table (with/without FPU) from the new MSR value regardless
   of what was selected before, then switch the soft-TLB set. */
void apply_msr(uint32_t new_msr) {
    ppc_msr_did_change(new_msr ^ MSR::FP, new_msr, false);
    mmu_change_mode();
    exec_flags = 0;
}

/* Instructions that would make dingusppc trap on the host. The only one known:
   the 601's POWER "div" (power_div, cpu/ppc/poweropcodes.cpp) divides the
   64-bit rA:MQ by rB with a host division, and INT64_MIN / -1 raises SIGFPE
   on x86. */
bool would_trap_host(uint32_t opcode) {
    if (!(is_601 || include_601))
        return false;
    if ((opcode >> 26) != 31 || ((opcode >> 1) & 0x1FF) != 331)
        return false;
    return ppc_state.gpr[(opcode >> 16) & 0x1F] == 0x80000000u &&
           ppc_state.spr[SPR::MQ] == 0 &&
           ppc_state.gpr[(opcode >> 11) & 0x1F] == 0xFFFFFFFFu;
}

inline int vector_taken() {
    /* 0x00000n00 or 0xFFF00n00 depending on MSR[IP] */
    return int(ppc_next_instruction_address & 0x000FFFFFu);
}

/* One instruction. Mirrors ppc_exec_single() in cpu/ppc/ppcexec.cpp, minus the
   virtual-time/timer processing, plus containment of aborts. */
__attribute__((noinline)) int step_one() {
    exec_flags = 0;

    try {
        if (setjmp(exc_env)) {
            /* ppc_exception_handler() longjmp'ed back: SRR0/SRR1/MSR are set
               and ppc_next_instruction_address holds the vector. */
            int vec = vector_taken();
            ppc_state.pc = ppc_next_instruction_address;
            exec_flags = 0;
            return vec;
        }

        uint8_t *pc_real = mmu_translate_imem(ppc_state.pc);
        uint32_t opcode  = ppc_read_instruction(pc_real);
        if (would_trap_host(opcode)) {
            snprintf(g_err, sizeof(g_err),
                     "not executed, dingusppc would die with SIGFPE: 601 div of "
                     "rA:MQ = 0x8000000000000000 by rB = -1 (instruction 0x%08X at 0x%08X)",
                     opcode, ppc_state.pc);
            return REF_STEP_FAULT;
        }
        ppc_main_opcode(ppc_opcode_grabber, opcode);
    } catch (const RefAbort &) {
        exec_flags = 0;
        return REF_STEP_FAULT;
    } catch (...) {
        snprintf(g_err, sizeof(g_err), "dingusppc threw an unexpected C++ exception");
        exec_flags = 0;
        return REF_STEP_FAULT;
    }

    int rc = 0;
    if (exec_flags) {
        /* Exceptions that do not longjmp (external, decrementer) also land
           here; neither can be pending in this library. */
        if (exec_flags & EXEF_EXCEPTION)
            rc = vector_taken();
        ppc_state.pc = ppc_next_instruction_address;
        exec_flags = 0;
    } else {
        ppc_state.pc += 4;
    }
    return rc;
}

} // namespace

/* ---- store logging hooks ------------------------------------------------
   The Makefile compiles dingusppc's opcode files with
       -Dmmu_write_vmem=ref_hook_write_vmem -Dmmu_dcbz=ref_hook_dcbz
   so every store an instruction makes comes through here. The real functions
   may leave through longjmp (DSI, alignment); the store is then not logged. */

template <class T>
void ref_hook_write_vmem(uint32_t opcode, uint32_t guest_va, T value) {
    mmu_write_vmem<T>(opcode, guest_va, value);
    log_store(guest_va, sizeof(T), value);
}

template void ref_hook_write_vmem<uint8_t>(uint32_t opcode, uint32_t guest_va, uint8_t value);
template void ref_hook_write_vmem<uint16_t>(uint32_t opcode, uint32_t guest_va, uint16_t value);
template void ref_hook_write_vmem<uint32_t>(uint32_t opcode, uint32_t guest_va, uint32_t value);
template void ref_hook_write_vmem<uint64_t>(uint32_t opcode, uint32_t guest_va, uint64_t value);

void ref_hook_dcbz(uint32_t opcode, uint32_t guest_va) {
    mmu_dcbz(opcode, guest_va);
    for (uint32_t offs = 0; offs < 32; offs += 8)
        log_store(guest_va + offs, 8, 0);
}

/* ---- C API ---------------------------------------------------------------- */

extern "C" {

int ref_init(uint32_t ram_size, uint32_t pvr) {
    g_ready   = false;
    g_nstores = 0;
    g_err[0]  = 0;

    /* The soft TLB works on whole 4K pages, so the RAM must too. */
    if (ram_size == 0 || ram_size > 0xFFFFF000u)
        return -1;
    uint32_t size = (ram_size + (PAGE - 1)) & ~(PAGE - 1);

    setup_logging();

    delete g_mem;
    g_mem = nullptr;
    g_mmio.clear();
    free(g_ram);
    g_ram = static_cast<uint8_t *>(calloc(size_t(size) + RAM_GUARD, 1));
    if (!g_ram)
        return -1;

    try {
        g_mem = new MemCtrlBase();
        if (!g_mem->add_ram_region(0, size, g_ram))
            return -1;

        /* The time-base frequency is irrelevant (virtual time never advances
           here) but must be nonzero. */
        ppc_cpu_init(g_mem, pvr, false, 25000000ULL);
    } catch (...) {
        return -1;
    }

    /* Determinism: virtual time is instruction-counted, and nothing here ever
       counts. No timer is ever processed, no interrupt line ever asserted. */
    g_realtime             = false;
    g_icycles              = 0;
    int_pin                = false;
    dec_exception_pending  = false;
    thrm_exception_pending = false;
    power_on               = true;

    /* ppc_cpu_init() leaves SPR DEC = 0xFFFFFFFF but its shadow at 0, so a
       guest mfdec would read 0. Make them agree. (601: DEC resets to 0.) */
    dec_wr_value     = ppc_state.spr[SPR::DEC_S];
    dec_wr_timestamp = get_virt_time_ns();
    tbr_wr_value     = 0;
    tbr_wr_timestamp = get_virt_time_ns();
    rtc_lo           = 0;
    rtc_hi           = 0;
    rtc_timestamp    = get_virt_time_ns();

    /* ppc_cpu_init() does not reselect the opcode table when re-initialising
       after MSR[FP] was 1; and it leaves TLB invalidations queued. */
    apply_msr(ppc_state.msr);
    do_ctx_sync();

    g_ready = true;
    return 0;
}

uint8_t *ref_ram(void) {
    return g_ram;
}

void ref_set_state(const ref_state_t *s) {
    if (!g_ready || !s)
        return;

    ppc_state.pc = s->pc & ~3u;
    for (int i = 0; i < 32; i++) {
        ppc_state.gpr[i]         = s->gpr[i];
        ppc_state.fpr[i].int64_r = s->fpr[i];
    }
    ppc_state.cr            = s->cr;
    ppc_state.spr[SPR::XER] = s->xer;
    ppc_state.spr[SPR::LR]  = s->lr;
    ppc_state.spr[SPR::CTR] = s->ctr;
    ppc_state.fpscr         = s->fpscr;
    apply_msr(s->msr);
}

void ref_get_state(ref_state_t *s) {
    if (!s)
        return;
    /* Also clears the padding inside the struct, so that two states obtained
       from here can be compared with memcmp(). */
    memset(s, 0, sizeof(*s));
    if (!g_ready)
        return;

    s->pc = ppc_state.pc;
    for (int i = 0; i < 32; i++) {
        s->gpr[i] = ppc_state.gpr[i];
        s->fpr[i] = ppc_state.fpr[i].int64_r;
    }
    s->cr    = ppc_state.cr;
    s->xer   = ppc_state.spr[SPR::XER];
    s->lr    = ppc_state.spr[SPR::LR];
    s->ctr   = ppc_state.spr[SPR::CTR];
    s->msr   = ppc_state.msr;
    s->fpscr = ppc_state.fpscr;
}

uint32_t ref_get_spr(unsigned n) {
    if (!g_ready || n >= 1024)
        return 0;
    n = canon_spr(n);

    switch (n) {
    /* Time never advances, so these are what a guest mfspr/mftb returns. */
    case SPR::DEC_S:
        return dec_wr_value;
    case SPR::TBL_S:
        return uint32_t(tbr_wr_value);
    case SPR::TBU_S:
        return uint32_t(tbr_wr_value >> 32);
    case SPR::RTCL_S:
        if (is_601)
            return rtc_lo & 0x3FFFFF80u;
        break;
    case SPR::RTCU_S:
        if (is_601)
            return rtc_hi;
        break;
    }
    return ppc_state.spr[n];
}

void ref_set_spr(unsigned n, uint32_t v) {
    if (!g_ready || n >= 1024)
        return;
    n = canon_spr(n);

    switch (n) {
    case SPR::DEC_S:
        if (is_601)
            v &= ~0x7Fu;
        dec_wr_value          = v;
        dec_wr_timestamp      = get_virt_time_ns();
        dec_exception_pending = false;
        ppc_state.spr[n]      = v;
        break;
    case SPR::TBL_S:
        tbr_wr_value     = (tbr_wr_value & 0xFFFFFFFF00000000ULL) | v;
        tbr_wr_timestamp = get_virt_time_ns();
        ppc_state.spr[SPR::TBL_S] = v;
        ppc_state.spr[SPR::TBU_S] = uint32_t(tbr_wr_value >> 32);
        break;
    case SPR::TBU_S:
        tbr_wr_value     = (tbr_wr_value & 0x00000000FFFFFFFFULL) | (uint64_t(v) << 32);
        tbr_wr_timestamp = get_virt_time_ns();
        ppc_state.spr[SPR::TBU_S] = v;
        ppc_state.spr[SPR::TBL_S] = uint32_t(tbr_wr_value);
        break;
    case SPR::RTCL_S:
        if (is_601) {
            v &= 0x3FFFFF80u;
            rtc_lo        = v;
            rtc_timestamp = get_virt_time_ns();
        }
        ppc_state.spr[n] = v;
        break;
    case SPR::RTCU_S:
        if (is_601) {
            rtc_hi        = v;
            rtc_timestamp = get_virt_time_ns();
        }
        ppc_state.spr[n] = v;
        break;
    case SPR::SDR1:
        ppc_state.spr[n] = v;
        mmu_pat_ctx_changed();
        do_ctx_sync();
        break;
    case 528: case 529: case 530: case 531:
    case 532: case 533: case 534: case 535:
        ppc_state.spr[n] = v;
        ibat_update(n);
        do_ctx_sync();
        break;
    case 536: case 537: case 538: case 539:
    case 540: case 541: case 542: case 543:
        ppc_state.spr[n] = v;
        dbat_update(n);
        do_ctx_sync();
        break;
    default:
        ppc_state.spr[n] = v;
        break;
    }
}

uint32_t ref_get_sr(unsigned n) {
    if (!g_ready || n >= 16)
        return 0;
    return ppc_state.sr[n];
}

void ref_set_sr(unsigned n, uint32_t v) {
    if (!g_ready || n >= 16)
        return;
    ppc_state.sr[n] = v;
    mmu_pat_ctx_changed();
    do_ctx_sync();
}

int ref_step(void) {
    g_nstores = 0;
    if (!g_ready) {
        snprintf(g_err, sizeof(g_err), "ref_step() called without a successful ref_init()");
        return REF_STEP_FAULT;
    }
    g_err[0] = 0;

    /* dingusppc computes with host floating point and reads/clears the host
       exception flags. Give it a clean environment with the rounding mode the
       guest asked for, and hand the caller's environment back afterwards. */
    fenv_t host_env;
    feholdexcept(&host_env);
    set_host_rounding_mode(ppc_state.fpscr & FPSCR::RN_MASK);

    int rc = step_one();

    fesetenv(&host_env);
    return rc;
}

unsigned ref_last_store_count(void) {
    return g_nstores < MAX_STORES ? g_nstores : MAX_STORES;
}

void ref_last_store(unsigned i, uint32_t *addr, unsigned *size, uint64_t *value) {
    StoreRec r = {0, 0, 0};
    if (i < ref_last_store_count())
        r = g_stores[i];
    if (addr)
        *addr = r.addr;
    if (size)
        *size = r.size;
    if (value)
        *value = r.value;
}

const char *ref_last_error(void) {
    return g_err;
}

int ref_add_rom(uint32_t base, const uint8_t *data, uint32_t size) {
    if (!g_ready || !data || !size)
        return -1;
    try {
        if (!g_mem->add_rom_region(base, size))
            return -1;
        if (!g_mem->set_data(base, data, size))
            return -1;
    } catch (...) {
        return -1;
    }
    /* the soft TLBs may hold "unmapped" for these addresses */
    do_ctx_sync();
    return 0;
}

int ref_add_mmio(uint32_t base, uint32_t size, ref_mmio_read_fn rd, ref_mmio_write_fn wr, void *ctx) {
    if (!g_ready || !size)
        return -1;
    auto dev = std::make_unique<BenchMmio>(rd, wr, ctx);
    try {
        if (!g_mem->add_mmio_region(base, size, dev.get()))
            return -1;
    } catch (...) {
        return -1;
    }
    g_mmio.push_back(std::move(dev));
    do_ctx_sync();
    return 0;
}

int ref_interrupt(unsigned vector) {
    if (!g_ready)
        return 0;
    Except_Type t;
    if (vector == 0x500)
        t = Except_Type::EXC_EXT_INT;
    else if (vector == 0x900)
        t = Except_Type::EXC_DECR;
    else
        return 0;
    /* dingusppc takes these after an instruction; here the instruction at pc
       has not executed, so it is where execution resumes (SRR0) */
    exec_flags = EXEF_BRANCH;
    ppc_next_instruction_address = ppc_state.pc;
    ppc_exception_handler(t, 0);     /* returns for these two: no longjmp */
    ppc_state.pc = ppc_next_instruction_address;
    exec_flags = 0;
    return int(vector);
}

} // extern "C"
