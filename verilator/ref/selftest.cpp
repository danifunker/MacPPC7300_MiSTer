/*
 * selftest.cpp - self-test for libdingusref.a.
 *
 * Hand-encoded PowerPC instructions are placed in the reference's RAM and
 * single-stepped. After every step the complete architectural state, the store
 * log and the whole RAM are compared with expected values that were worked out
 * from the PowerPC architecture (32-bit PEM), not taken from dingusppc.
 *
 * Where dingusppc is known to disagree with the architecture the test says so
 * on every run ("DEVIATION: ...") and still passes, provided the disagreement
 * is exactly the documented one. "selftest --strict" turns those into
 * failures. Anything else that differs is reported as the first mismatch and
 * the exit status is nonzero.
 *
 * Part 3 does the same for a few things the PowerPC 604 User's Manual (Nov 94)
 * specifies beyond the architecture. Part 5 does not test the architecture at
 * all; it pins down what this library does in situations only dingusppc or the
 * library define (frozen time base, accesses outside RAM, arbitrary
 * instruction words).
 */

#include "dingus_ref.h"

#include <cinttypes>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>

namespace {

constexpr uint32_t RAM_SIZE = 0x10000;      /* 64 KiB */
constexpr uint32_t PVR_604  = 0x00040303;   /* the 604 in the Power Mac 7600 */
constexpr uint32_t PVR_601  = 0x00010001;
constexpr uint32_t PVR_750  = 0x00080200;

/* MSR bits */
constexpr uint32_t MSR_EE = 0x8000, MSR_PR = 0x4000, MSR_FP = 0x2000, MSR_ME = 0x1000,
                   MSR_IR = 0x0020, MSR_DR = 0x0010, MSR_RI = 0x0002;
/* supervisor, real mode, big-endian, vectors at 0x000n_nnnn */
constexpr uint32_t MSR_BASE = MSR_EE | MSR_ME | MSR_RI;   /* 0x00009002 */

/* SPR numbers */
constexpr unsigned SPR_DSISR = 18, SPR_DAR = 19, SPR_DEC = 22, SPR_SRR0 = 26, SPR_SRR1 = 27,
                   SPR_TBL = 284, SPR_TBU = 285, SPR_PVR = 287;

constexpr uint32_t NOP = 0x60000000;        /* ori r0,r0,0 */
constexpr uint32_t RFI = 0x4C000064;

bool g_strict     = false;
int  g_checks     = 0;
int  g_deviations = 0;

/* ---- expected machine ---------------------------------------------------- */

struct Store {
    uint32_t addr;
    unsigned size;
    uint64_t value;
};

ref_state_t          E;        /* expected architectural state */
std::vector<uint8_t> M;        /* expected RAM contents */
std::vector<Store>   ES;       /* stores expected from the step being executed */
uint32_t             PC;       /* address of the instruction being executed */
uint32_t             WORD;     /* its encoding */
const char          *DESC = "";

[[noreturn]] void fail(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    printf("FAIL at 0x%08X (%08X  %s): ", PC, WORD, DESC);
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    exit(1);
}

void check_eq(const char *what, uint64_t got, uint64_t want) {
    g_checks++;
    if (got != want)
        fail("%s = 0x%" PRIX64 ", expected 0x%" PRIX64, what, got, want);
}

/* A value where dingusppc is known to differ from what `authority` (the
   architecture, or the 604 User's Manual) specifies. Reported once per run
   however often the instruction is executed. */
const char *const ARCH  = "the architecture";
const char *const UM604 = "the 604 User's Manual";

void check_known_deviation(const char *what, uint64_t got, uint64_t want, uint64_t dingus,
                           const char *note, const char *authority = ARCH) {
    static std::set<std::string> reported;
    bool first = reported.insert(std::string(DESC) + "/" + what).second;

    g_checks++;
    if (got == want) {
        if (first)
            printf("NOTE: %s: %s now is what %s says (0x%" PRIX64
                   "); the deviation documented in README.md is gone.\n",
                   DESC, what, authority, want);
        return;
    }
    if (got != dingus)
        fail("%s = 0x%" PRIX64 ", %s says 0x%" PRIX64
             " (known dingusppc value 0x%" PRIX64 ")", what, got, authority, want, dingus);
    if (!first)
        return;
    printf("DEVIATION: %s: %s = 0x%" PRIX64 ", %s says 0x%" PRIX64 ". %s\n",
           DESC, what, got, authority, want, note);
    g_deviations++;
    if (g_strict)
        fail("--strict: known dingusppc deviation counted as failure");
}

void poke8(uint32_t addr, uint8_t v) {
    ref_ram()[addr] = v;
    M[addr]         = v;
}

void poke32(uint32_t addr, uint32_t v) {
    for (int i = 0; i < 4; i++)
        poke8(addr + i, uint8_t(v >> (24 - 8 * i)));
}

/* Announce a store the current instruction must make. Memory is big-endian. */
void expect_store(uint32_t addr, unsigned size, uint64_t value) {
    ES.push_back(Store{addr, size, value});
    for (unsigned i = 0; i < size; i++)
        if (addr + i < RAM_SIZE)
            M[addr + i] = uint8_t(value >> (8 * (size - 1 - i)));
}

void compare_state() {
    ref_state_t g;
    ref_get_state(&g);
    char name[16];

    check_eq("pc", g.pc, E.pc);
    for (int i = 0; i < 32; i++) {
        snprintf(name, sizeof(name), "r%d", i);
        check_eq(name, g.gpr[i], E.gpr[i]);
    }
    for (int i = 0; i < 32; i++) {
        snprintf(name, sizeof(name), "f%d", i);
        check_eq(name, g.fpr[i], E.fpr[i]);
    }
    check_eq("cr", g.cr, E.cr);
    check_eq("xer", g.xer, E.xer);
    check_eq("lr", g.lr, E.lr);
    check_eq("ctr", g.ctr, E.ctr);
    check_eq("msr", g.msr, E.msr);
    check_eq("fpscr", g.fpscr, E.fpscr);
}

void compare_stores() {
    check_eq("store count", ref_last_store_count(), ES.size());
    for (unsigned i = 0; i < ES.size(); i++) {
        uint32_t addr;
        unsigned size;
        uint64_t value;
        char     name[32];
        ref_last_store(i, &addr, &size, &value);
        snprintf(name, sizeof(name), "store[%u].addr", i);
        check_eq(name, addr, ES[i].addr);
        snprintf(name, sizeof(name), "store[%u].size", i);
        check_eq(name, size, ES[i].size);
        snprintf(name, sizeof(name), "store[%u].value", i);
        check_eq(name, value, ES[i].value);
    }
}

void compare_ram() {
    g_checks++;
    const uint8_t *ram = ref_ram();
    if (memcmp(ram, M.data(), RAM_SIZE) == 0)
        return;
    for (uint32_t a = 0; a < RAM_SIZE; a++)
        if (ram[a] != M[a])
            fail("RAM[0x%05X] = 0x%02X, expected 0x%02X", a, ram[a], M[a]);
}

/* Place the instruction at the expected pc; default expectation: pc += 4. */
void begin(uint32_t word, const char *desc) {
    PC   = E.pc;
    WORD = word;
    DESC = desc;
    poke32(PC, word);
    E.pc = PC + 4;
    ES.clear();
}

void step_expect(int want_rc) {
    int rc = ref_step();
    g_checks++;
    if (rc != want_rc)
        fail("ref_step() returned %s0x%X, expected %s0x%X%s%s",
             rc < 0 ? "-" : "", unsigned(rc < 0 ? -rc : rc),
             want_rc < 0 ? "-" : "", unsigned(want_rc < 0 ? -want_rc : want_rc),
             rc == REF_STEP_FAULT ? ": " : "", rc == REF_STEP_FAULT ? ref_last_error() : "");
}

void finish(int want_rc) {
    step_expect(want_rc);
    compare_state();
    compare_stores();
    compare_ram();
}

/* STEP(encoding, "assembly", expected ref_step() result, expected state changes...) */
#define STEP(word, desc, rc, ...)   \
    do {                            \
        begin(word, desc);          \
        { __VA_ARGS__; }            \
        finish(rc);                 \
    } while (0)

/* Fresh CPU, fresh RAM, known state. */
void reset_machine(uint32_t pvr, uint32_t msr) {
    PC   = 0;
    WORD = 0;
    DESC = "ref_init";
    if (ref_init(RAM_SIZE, pvr) != 0)
        fail("ref_init(0x%X, 0x%08X) failed", RAM_SIZE, pvr);
    if (!ref_ram())
        fail("ref_ram() returned NULL");
    M.assign(RAM_SIZE, 0);
    compare_ram();                    /* RAM starts zeroed */
    check_eq("PVR", ref_get_spr(SPR_PVR), pvr);

    memset(&E, 0, sizeof(E));
    E.pc  = 0x1000;
    E.msr = msr;
    E.gpr[0]  = 0xAAAA5555;           /* must never be used as (rA|0) */
    E.gpr[20] = 0xA000005A;
    E.gpr[29] = 0x11112222;
    E.gpr[30] = 0x33334444;
    E.gpr[31] = 0xDEADBEEF;
    for (int i = 0; i < 32; i++)
        E.fpr[i] = 0x4010000000000000ULL + (uint64_t(i) << 40) + i;
    ref_set_state(&E);
    DESC = "ref_set_state";
    compare_state();
}

/* Exception entry as the architecture defines it for MSR_BASE-like states:
   everything but ME (and IP, ILE) is cleared; SRR0/SRR1 are checked by the caller. */
uint32_t msr_after_exception(uint32_t msr) {
    return msr & MSR_ME;
}

/* ---- part 1: the main program -------------------------------------------- */

void main_program(ref_state_t *final_state, std::vector<uint8_t> *final_ram) {
    reset_machine(PVR_604, MSR_BASE);

    /* data that lmw will read back */
    poke32(0x201C, 0xCAFEF00D);
    poke32(0x202C, 0x01020304);
    poke32(0x2030, 0xA5A5A5A5);

    /* --- addi / addis / ori --- */
    STEP(0x38201234, "li r1,0x1234 (addi r1,0,0x1234)", 0, E.gpr[1] = 0x00001234);
    STEP(0x3C408000, "lis r2,0x8000 (addis r2,0,0x8000)", 0, E.gpr[2] = 0x80000000);
    STEP(0x6042FFFF, "ori r2,r2,0xFFFF", 0, E.gpr[2] = 0x8000FFFF);
    STEP(0x3861FFFF, "addi r3,r1,-1", 0, E.gpr[3] = 0x00001233);
    STEP(0x3C837FFF, "addis r4,r3,0x7FFF", 0, E.gpr[4] = 0x7FFF1233);

    /* --- add with Rc and OE ---
       0x7FFF1233 + 0x7FFF1233 = 0xFFFE2466: negative, and a signed overflow. */
    STEP(0x7CA42215, "add. r5,r4,r4", 0,
         E.gpr[5] = 0xFFFE2466; E.cr = 0x80000000 /* CR0 = LT */);
    STEP(0x7CC42615, "addo. r6,r4,r4", 0,
         E.gpr[6] = 0xFFFE2466; E.xer = 0xC0000000 /* SO|OV */;
         E.cr = 0x90000000 /* CR0 = LT|SO */);
    STEP(0x7CE10E14, "addo r7,r1,r1", 0,
         E.gpr[7] = 0x00002468; E.xer = 0x80000000 /* OV cleared, SO sticky */);
    STEP(0x7D094A15, "add. r8,r9,r9", 0,
         E.gpr[8] = 0; E.cr = 0x30000000 /* CR0 = EQ|SO */);

    /* --- mullw / divw ---
       0x8000FFFF * 0x1234: low 32 bits = 0xFFFF * 0x1234 = 0x1233EDCC.
       -2147418113 / 4660 = -460819 (truncated) = 0xFFF8F7ED. */
    STEP(0x7D4209D6, "mullw r10,r2,r1", 0, E.gpr[10] = 0x1233EDCC);
    STEP(0x7D620BD6, "divw r11,r2,r1", 0, E.gpr[11] = 0xFFF8F7ED);

    /* --- stores and loads of each size --- */
    STEP(0x39802000, "li r12,0x2000", 0, E.gpr[12] = 0x00002000);
    STEP(0x904C0000, "stw r2,0(r12)", 0, expect_store(0x2000, 4, 0x8000FFFF));
    STEP(0xB02C0006, "sth r1,6(r12)", 0, expect_store(0x2006, 2, 0x1234));
    STEP(0x982C0009, "stb r1,9(r12)", 0, expect_store(0x2009, 1, 0x34));
    STEP(0x81AC0000, "lwz r13,0(r12)", 0, E.gpr[13] = 0x8000FFFF);
    STEP(0xA1CC0006, "lhz r14,6(r12)", 0, E.gpr[14] = 0x00001234);
    STEP(0x89EC0009, "lbz r15,9(r12)", 0, E.gpr[15] = 0x00000034);
    STEP(0xA1CC0002, "lhz r14,2(r12)", 0, E.gpr[14] = 0x0000FFFF /* zero-extended */);
    STEP(0x89EC0000, "lbz r15,0(r12)", 0, E.gpr[15] = 0x00000080 /* big-endian: MSB first */);

    /* --- update forms --- */
    STEP(0x942CFFF0, "stwu r1,-16(r12)", 0,
         expect_store(0x1FF0, 4, 0x00001234); E.gpr[12] = 0x00001FF0);
    STEP(0x860C0010, "lwzu r16,16(r12)", 0,
         E.gpr[16] = 0x8000FFFF; E.gpr[12] = 0x00002000);

    /* --- stmw / lmw --- */
    STEP(0xBFAC0020, "stmw r29,0x20(r12)", 0,
         expect_store(0x2020, 4, 0x11112222);
         expect_store(0x2024, 4, 0x33334444);
         expect_store(0x2028, 4, 0xDEADBEEF));
    STEP(0xBB4C001C, "lmw r26,0x1C(r12)", 0,
         E.gpr[26] = 0xCAFEF00D; E.gpr[27] = 0x11112222; E.gpr[28] = 0x33334444;
         E.gpr[29] = 0xDEADBEEF; E.gpr[30] = 0x01020304; E.gpr[31] = 0xA5A5A5A5);

    /* --- cmpw, conditional branches, CR logic ---
       r1 = 0x1234 > r3 = 0x1233 and XER[SO] = 1: CR7 = GT|SO. */
    STEP(0x7F811800, "cmpw cr7,r1,r3", 0, E.cr = 0x30000005);
    poke32(E.pc + 4, 0x00000000);   /* the skipped slot: illegal if ever executed */
    STEP(0x419D0008, "bgt cr7,+8 (taken)", 0, E.pc = PC + 8);
    STEP(0x419E0008, "beq cr7,+8 (not taken)", 0, (void)0);
    poke32(E.pc + 4, 0x00000000);
    STEP(0x409E0008, "bne cr7,+8 (taken)", 0, E.pc = PC + 8);
    STEP(0x4C1DF182, "crxor 0,29,30", 0, E.cr = 0xB0000005 /* 1 xor 0 -> CR bit 0 */);
    STEP(0x4FFFF982, "crxor 31,31,31 (crclr 31)", 0, E.cr = 0xB0000004);

    /* --- mfcr / mtcrf --- */
    STEP(0x7E200026, "mfcr r17", 0, E.gpr[17] = 0xB0000004);
    STEP(0x7C481120, "mtcrf 0x81,r2", 0, E.cr = 0x8000000F /* fields 0 and 7 from 0x8000FFFF */);
    STEP(0x7D4FF120, "mtcrf 0xFF,r10", 0, E.cr = 0x1233EDCC);

    /* --- LR / CTR / XER moves --- */
    STEP(0x7C2803A6, "mtlr r1", 0, E.lr = 0x00001234);
    STEP(0x7E4802A6, "mflr r18", 0, E.gpr[18] = 0x00001234);
    STEP(0x7C6903A6, "mtctr r3", 0, E.ctr = 0x00001233);
    STEP(0x7E6902A6, "mfctr r19", 0, E.gpr[19] = 0x00001233);
    STEP(0x7E8103A6, "mtxer r20", 0, E.xer = 0xA000005A /* SO, CA, byte count 0x5A */);
    STEP(0x7EA102A6, "mfxer r21", 0, E.gpr[21] = 0xA000005A);

    /* --- bl + blr --- */
    const uint32_t SUB = 0x1800;
    STEP(0x48000001 | ((SUB - E.pc) & 0x03FFFFFC), "bl 0x1800", 0,
         E.lr = PC + 4; E.pc = SUB);
    STEP(0x3AD60001, "addi r22,r22,1", 0, E.gpr[22] = 1);
    STEP(0x4E800020, "blr", 0, E.pc = E.lr);

    /* --- bdnz loop: three passes --- */
    STEP(0x3B000003, "li r24,3", 0, E.gpr[24] = 3);
    STEP(0x7F0903A6, "mtctr r24", 0, E.ctr = 3);
    for (int pass = 1; pass <= 3; pass++) {
        STEP(0x3AF70005, "addi r23,r23,5", 0, E.gpr[23] = 5 * pass);
        STEP(0x4200FFFC, "bdnz -4", 0,
             E.ctr = 3 - pass; if (E.ctr != 0) E.pc = PC - 4);
    }

    /* --- illegal instruction: program exception, SRR1[12] = illegal --- */
    const uint32_t ill = E.pc;
    poke32(0x700, RFI);
    poke32(0xC00, RFI);
    STEP(0x00000000, "illegal instruction word 0x00000000", 0x700,
         E.pc = 0x700; E.msr = msr_after_exception(MSR_BASE));
    check_eq("SRR0", ref_get_spr(SPR_SRR0), ill);
    check_eq("SRR1", ref_get_spr(SPR_SRR1), MSR_BASE | 0x00080000);

    /* return behind the illegal word: also exercises ref_set_spr and rfi */
    ref_set_spr(SPR_SRR0, ill + 4);
    check_eq("SRR0 after ref_set_spr", ref_get_spr(SPR_SRR0), ill + 4);
    STEP(RFI, "rfi", 0, E.pc = ill + 4; E.msr = MSR_BASE);

    /* --- sc: system call exception, SRR0 = next instruction --- */
    const uint32_t sc = E.pc;
    STEP(0x44000002, "sc", 0xC00, E.pc = 0xC00; E.msr = msr_after_exception(MSR_BASE));
    check_eq("SRR0", ref_get_spr(SPR_SRR0), sc + 4);
    check_known_deviation("SRR1", ref_get_spr(SPR_SRR1), MSR_BASE, MSR_BASE | 0x00020000,
        "dingusppc sets SRR1[14] on sc for every CPU (601/POWER behaviour); "
        "the PowerPC architecture clears SRR1[1-4,10-15].");
    STEP(RFI, "rfi", 0, E.pc = sc + 4; E.msr = MSR_BASE);

    if (final_state)
        ref_get_state(final_state);
    if (final_ram)
        final_ram->assign(ref_ram(), ref_ram() + RAM_SIZE);
}

/* ---- part 2: more exceptions, FPSCR --------------------------------------- */

void more_exceptions() {
    /* privileged instruction in user mode: SRR1[13] */
    reset_machine(PVR_604, MSR_BASE | MSR_PR);
    STEP(0x7C6000A6, "mfmsr r3 (MSR[PR]=1)", 0x700,
         E.pc = 0x700; E.msr = msr_after_exception(MSR_BASE | MSR_PR));
    check_eq("SRR0", ref_get_spr(SPR_SRR0), 0x1000);
    check_eq("SRR1", ref_get_spr(SPR_SRR1), (MSR_BASE | MSR_PR) | 0x00040000);

    /* trap: SRR1[14]. r3 = 0x1233, r1 = 0x1234 */
    reset_machine(PVR_604, MSR_BASE);
    E.gpr[1] = 0x1234;
    E.gpr[3] = 0x1233;
    ref_set_state(&E);
    STEP(0x7C810808, "tw 4,r1,r1 (tweq: equal, traps)", 0x700,
         E.pc = 0x700; E.msr = msr_after_exception(MSR_BASE));
    check_eq("SRR0", ref_get_spr(SPR_SRR0), 0x1000);
    check_eq("SRR1", ref_get_spr(SPR_SRR1), MSR_BASE | 0x00020000);

    E.pc  = 0x1000;
    E.msr = MSR_BASE;
    ref_set_state(&E);
    STEP(0x0E031234, "twi 16,r3,0x1234 (twlti: 0x1233 < 0x1234, traps)", 0x700,
         E.pc = 0x700; E.msr = msr_after_exception(MSR_BASE));
    check_eq("SRR1", ref_get_spr(SPR_SRR1), MSR_BASE | 0x00020000);

    /* tw with an asymmetric condition: TO=16 traps if (rA) < (rB) signed.
       rA = r3 = 0x1233, rB = r1 = 0x1234: must trap. */
    E.pc  = 0x1000;
    E.msr = MSR_BASE;
    ref_set_state(&E);
    begin(0x7E030808, "tw 16,r3,r1 (twlt: 0x1233 < 0x1234, traps)");
    {
        int rc = ref_step();
        check_known_deviation("ref_step() result", uint64_t(rc), 0x700, 0,
            "dingusppc's tw compares (rB) with (rA), i.e. with the operands swapped, "
            "so lt/gt and llt/lgt conditions are reversed (twi is correct).");
        if (rc == 0x700) {
            E.pc  = 0x700;
            E.msr = msr_after_exception(MSR_BASE);
        }
        compare_state();
    }

    /* floating-point unavailable: vector 0x800, SRR0 = the instruction */
    reset_machine(PVR_604, MSR_BASE);
    STEP(0xFC201090, "fmr f1,f2 (MSR[FP]=0)", 0x800,
         E.pc = 0x800; E.msr = msr_after_exception(MSR_BASE));
    check_eq("SRR0", ref_get_spr(SPR_SRR0), 0x1000);
    check_known_deviation("SRR1", ref_get_spr(SPR_SRR1), MSR_BASE, MSR_BASE | 0x00100000,
        "dingusppc sets SRR1[11] (the program exception's FP-enabled bit) on the "
        "FP-unavailable exception; the architecture clears SRR1[1-4,10-15].");

    /* ...and the same instruction with the FPU enabled: raw pattern moves */
    reset_machine(PVR_604, MSR_BASE | MSR_FP);
    STEP(0xFC201090, "fmr f1,f2 (MSR[FP]=1)", 0, E.fpr[1] = E.fpr[2]);
}

/* Two FPSCR effects the architecture defines exactly. (No attempt is made to
   validate dingusppc's floating point in general.) */
void fp_status() {
    ref_state_t g;

    /* fcmpu sets the CR field and FPCC, nothing else. 1.0 < 2.0 */
    reset_machine(PVR_604, MSR_BASE | MSR_FP);
    E.fpr[1] = 0x3FF0000000000000ULL;
    E.fpr[2] = 0x4000000000000000ULL;
    E.fpscr  = 0x00000080;                      /* VE */
    ref_set_state(&E);
    begin(0xFC011000, "fcmpu cr0,f1,f2 (1.0 < 2.0, FPSCR[VE]=1)");
    step_expect(0);
    ref_get_state(&g);
    E.cr = 0x80000000;                          /* CR0 = LT */
    check_known_deviation("fpscr", g.fpscr, 0x00008080 /* FPCC = FL, VE kept */, 0x00008000,
        "dingusppc's fcmpu/fcmpo clear FPSCR[VE] (\"kludge to pass tests\").");
    E.fpscr = g.fpscr;
    compare_state();

    /* 1.0 + 2^-60 is inexact; rounded to nearest the sum is 1.0 again:
       XX and FI (and therefore FX) are set, FR is not, FPRF = +normalized. */
    reset_machine(PVR_604, MSR_BASE | MSR_FP);
    E.fpr[1] = 0x3FF0000000000000ULL;
    E.fpr[2] = 0x3C30000000000000ULL;
    ref_set_state(&E);
    begin(0xFC61102A, "fadd f3,f1,f2 (1.0 + 2^-60)");
    step_expect(0);
    ref_get_state(&g);
    E.fpr[3] = 0x3FF0000000000000ULL;
    check_known_deviation("fpscr", g.fpscr, 0x82024000, 0x00004000,
        "dingusppc's arithmetic never reports inexact results (FPSCR[XX], [FI], [FR]).");
    E.fpscr = g.fpscr;
    compare_state();
}

/* ---- part 3: what the 604 does according to its User's Manual ------------- */

/* Only the ref_step() result is compared; the rest is undefined on a 604 or
   follows from the result. */
void result_604(uint32_t word, const char *desc, int rc_604, int rc_dingus, const char *note) {
    begin(word, desc);
    int rc = ref_step();
    check_known_deviation("ref_step() result", uint32_t(rc), uint32_t(rc_604),
                          uint32_t(rc_dingus), note, UM604);
}

void ppc604_specifics() {
    /* 4.5.6: lmw and stmw whose address is not word-aligned take the alignment
       exception. DSISR[0-26] for "stmw r31,d(r1)": bit 17 = 1, bits 18-21 =
       0b0111, bits 22-26 = 31; bits 27-31 are undefined for stmw. */
    reset_machine(PVR_604, MSR_BASE);
    E.gpr[1] = 0x2001;
    ref_set_state(&E);
    STEP(0xBFE10000, "stmw r31,0(r1) (EA = 0x2001)", 0x600,
         E.pc = 0x600; E.msr = msr_after_exception(MSR_BASE));
    check_eq("SRR0", ref_get_spr(SPR_SRR0), 0x1000);
    check_eq("SRR1", ref_get_spr(SPR_SRR1), MSR_BASE);
    check_eq("DAR", ref_get_spr(SPR_DAR), 0x2001);
    check_eq("DSISR[0-26]", ref_get_spr(SPR_DSISR) & 0xFFFFFFE0, 0x00005FE0);

    reset_machine(PVR_604, MSR_BASE);
    E.gpr[1] = 0x2001;
    ref_set_state(&E);
    result_604(0xBBE10000, "lmw r31,0(r1) (EA = 0x2001)", 0x600, 0,
        "dingusppc checks the alignment of stmw but not of lmw (nor lwarx, stwcx., lfs, "
        "stfs); UM 4.5.6.");

    /* 4.5.7: the SPR field is fully decoded; an undefined SPR is a program exception. */
    reset_machine(PVR_604, MSR_BASE);
    result_604(0x7C8422A6, "mfspr r4,132 (no such SPR)", 0x700, 0,
        "dingusppc treats every SPR number it does not know as plain storage; UM 4.5.7.");

    /* 2.3.1.2: the 604 does not implement the optional tlbia. */
    reset_machine(PVR_604, MSR_BASE);
    result_604(0x7C0002E4, "tlbia", 0x700, 0,
        "dingusppc accepts tlbia (as a no-op) on every non-601 CPU; UM 2.3.1.2.");

    /* 2.3.4.3: invalid forms are executed (with undefined rD/r0 or CR0), not trapped. */
    reset_machine(PVR_604, MSR_BASE);
    result_604(0x84600010, "lwzu r3,16(r0) (invalid form: rA = 0)", 0, 0x700,
        "dingusppc raises an illegal-instruction program exception for update forms with "
        "rA = 0 or rA = rD; UM 2.3.4.3.");
    reset_machine(PVR_604, MSR_BASE);
    E.gpr[4] = 0x2000;
    ref_set_state(&E);
    result_604(0x7C64002F, "lwzx. r3,r4,r0 (invalid form: Rc = 1)", 0, 0x700,
        "dingusppc decodes bit 31 strictly: instructions without a record form are "
        "illegal when it is set; UM 2.3.4.3.");
}

/* ---- part 4: ref_init again, determinism ---------------------------------- */

void determinism() {
    ref_state_t          s1, s2;
    std::vector<uint8_t> m1, m2;

    /* ref_get_state() must zero-fill the struct's padding so that memcmp() is
       valid: start from different garbage. */
    memset(&s1, 0xFF, sizeof(s1));
    memset(&s2, 0x00, sizeof(s2));
    main_program(&s1, &m1);
    main_program(&s2, &m2);

    DESC = "second run of the main program";
    g_checks++;
    if (memcmp(&s1, &s2, sizeof(s1)) != 0)
        fail("final state differs between two identical runs");
    g_checks++;
    if (m1 != m2)
        fail("final RAM differs between two identical runs");
}

/* ---- part 5: library-defined behaviour ------------------------------------ */

void run_nops(int n) {
    for (int i = 0; i < n; i++)
        STEP(NOP, "nop", 0, (void)0);
}

void frozen_time() {
    /* Right after ref_init: DEC = 0xFFFFFFFF, TB = 0. EE is on throughout. */
    reset_machine(PVR_604, MSR_BASE);
    STEP(0x7C7602A6, "mfdec r3", 0, E.gpr[3] = 0xFFFFFFFF);
    STEP(0x7C8C42E6, "mftb r4", 0, E.gpr[4] = 0);
    STEP(0x7CAD42E6, "mftbu r5", 0, E.gpr[5] = 0);

    /* Values set from outside read back unchanged however many instructions run. */
    ref_set_spr(SPR_TBL, 0x89ABCDEF);
    ref_set_spr(SPR_TBU, 0x01234567);
    ref_set_spr(SPR_DEC, 5);
    run_nops(32);
    STEP(0x7C7602A6, "mfdec r3", 0, E.gpr[3] = 5);
    STEP(0x7C8C42E6, "mftb r4", 0, E.gpr[4] = 0x89ABCDEF);
    STEP(0x7CAD42E6, "mftbu r5", 0, E.gpr[5] = 0x01234567);
    check_eq("ref_get_spr(DEC)", ref_get_spr(SPR_DEC), 5);
    check_eq("ref_get_spr(TBL)", ref_get_spr(SPR_TBL), 0x89ABCDEF);
    check_eq("ref_get_spr(268)", ref_get_spr(268), 0x89ABCDEF);
    check_eq("ref_get_spr(TBU)", ref_get_spr(SPR_TBU), 0x01234567);

    /* A decrementer written by the guest never counts and never interrupts,
       not even when written with a value that has "already expired". */
    STEP(0x38C00001, "li r6,1", 0, E.gpr[6] = 1);
    STEP(0x7CD603A6, "mtdec r6", 0, (void)0);
    run_nops(32);
    STEP(0x7C7602A6, "mfdec r3", 0, E.gpr[3] = 1);
    STEP(0x3CC08000, "lis r6,0x8000", 0, E.gpr[6] = 0x80000000);
    STEP(0x7CD603A6, "mtdec r6 (bit 0 goes 0 -> 1)", 0, (void)0);
    run_nops(32);
    STEP(0x7C7602A6, "mfdec r3", 0, E.gpr[3] = 0x80000000);
}

void segment_registers() {
    reset_machine(PVR_604, MSR_BASE);
    E.gpr[1] = 0x2468ACE0;
    ref_set_state(&E);
    ref_set_sr(5, 0x12345678);
    check_eq("ref_get_sr(5)", ref_get_sr(5), 0x12345678);
    STEP(0x7C6504A6, "mfsr r3,5", 0, E.gpr[3] = 0x12345678);
    STEP(0x7C2701A4, "mtsr 7,r1", 0, (void)0);
    check_eq("ref_get_sr(7)", ref_get_sr(7), 0x2468ACE0);
}

void outside_ram() {
    reset_machine(PVR_604, MSR_BASE);
    E.gpr[3] = 0x13579BDF;
    E.gpr[4] = 0x00100000;        /* 1 MiB: far outside the 64 KiB of RAM */
    ref_set_state(&E);

    /* dingusppc: a load from unmapped memory reads all ones, no exception */
    STEP(0x80A40000, "lwz r5,0(r4) (outside RAM)", 0, E.gpr[5] = 0xFFFFFFFF);
    STEP(0x88C40000, "lbz r6,0(r4) (outside RAM)", 0, E.gpr[6] = 0x000000FF);
    /* dingusppc: a store to unmapped memory is dropped, no exception.
       The store log still reports what the instruction tried to write. */
    STEP(0x90640000, "stw r3,0(r4) (outside RAM)", 0,
         expect_store(0x00100000, 4, 0x13579BDF));

    /* An instruction fetch from outside RAM would abort dingusppc. The library
       returns REF_STEP_FAULT instead and leaves the state alone. */
    static const uint32_t wild[] = {0x00100000, 0xFFF00100, 0x00010000, 0xFFFFFFFC};
    for (uint32_t pc : wild) {
        E.pc = pc;
        ref_set_state(&E);
        PC   = pc;
        WORD = 0;
        DESC = "instruction fetch outside RAM";
        ES.clear();
        int rc = ref_step();
        g_checks++;
        if (rc != REF_STEP_FAULT)
            fail("ref_step() returned 0x%X, expected REF_STEP_FAULT", unsigned(rc));
        g_checks++;
        if (ref_last_error()[0] == 0)
            fail("ref_last_error() is empty after REF_STEP_FAULT");
        compare_state();
        compare_stores();
        compare_ram();
    }

    /* ...and the reference is still usable afterwards. */
    E.pc = 0x1000;
    ref_set_state(&E);
    STEP(0x38E00007, "li r7,7", 0, E.gpr[7] = 7);
}

/* The 601's POWER "div" divides rA:MQ by rB with a host 64-bit division that
   traps on the host for 0x8000000000000000 / -1; the library must contain it. */
void host_trap_601() {
    reset_machine(PVR_601, MSR_BASE);
    E.gpr[3] = 0x80000000;
    E.gpr[4] = 0xFFFFFFFF;
    ref_set_state(&E);
    ref_set_spr(0, 0);            /* MQ */
    begin(0x7CA32296, "div r5,r3,r4 (601: rA:MQ = -2^63, rB = -1)");
    int rc = ref_step();
    g_checks++;
    if (rc != REF_STEP_FAULT)
        fail("ref_step() returned 0x%X, expected REF_STEP_FAULT", unsigned(rc));
    E.pc = PC;
    compare_state();
}

/* Arbitrary instruction words with arbitrary register contents: every step must
   come back with 0, a plausible vector, or REF_STEP_FAULT. */
uint32_t g_rng = 0x2545F491;

uint32_t rnd() {
    g_rng ^= g_rng << 13;
    g_rng ^= g_rng >> 17;
    g_rng ^= g_rng << 5;
    return g_rng;
}

void fuzz(uint32_t pvr, const char *name, int count, bool with_mmu) {
    static const uint32_t msrs[] = {
        MSR_BASE, MSR_BASE | MSR_FP, MSR_BASE | MSR_PR, MSR_BASE | MSR_PR | MSR_FP, 0,
        0xFFFFFFFE /* everything but LE */};
    static const uint32_t mmu_msrs[] = {
        MSR_BASE | MSR_DR, MSR_BASE | MSR_FP | MSR_DR, MSR_BASE | MSR_IR | MSR_DR,
        MSR_BASE | MSR_PR | MSR_IR | MSR_DR, MSR_BASE | MSR_IR};
    static const uint32_t prim[] = {31, 31, 31, 19, 59, 63, 63, 46, 47, 16, 18, 17, 3};

    int n_ok = 0, n_exc = 0, n_fault = 0;

    DESC = name;
    if (ref_init(RAM_SIZE, pvr) != 0)
        fail("ref_init failed");

    ref_state_t s;
    for (int i = 0; i < count; i++) {
        uint32_t word = rnd();
        if (i & 1)
            word = (word & 0x03FFFFFF) | (prim[rnd() % (sizeof(prim) / sizeof(prim[0]))] << 26);

        for (int r = 0; r < 32; r++) {
            uint32_t v = rnd();
            switch (rnd() & 3) {
            case 0: v &= 0xFFFF; break;           /* inside RAM */
            case 1: v = 0xFFF0 + (v & 0x1F); break; /* around the end of RAM */
            }
            s.gpr[r] = v;
            s.fpr[r] = (uint64_t(rnd()) << 32) | rnd();
            if ((rnd() & 7) == 0)
                s.fpr[r] |= 0x7FF0000000000000ULL;   /* infinities and NaNs */
        }
        s.pc    = 0x1000;
        s.cr    = rnd();
        s.xer   = rnd() & 0xE000007F;
        s.lr    = rnd();
        s.ctr   = rnd();
        s.fpscr = rnd() & 0x000000FF;
        if (with_mmu) {
            s.msr = mmu_msrs[rnd() % (sizeof(mmu_msrs) / sizeof(mmu_msrs[0]))];
            if ((i & 63) == 0) {
                ref_set_spr(25, rnd() & 0x0000FFFF);          /* SDR1: table in/near RAM */
                ref_set_sr(rnd() & 15, rnd());
                ref_set_sr(0, rnd() & 0x00FFFFFF);
                ref_set_spr(528 + (rnd() & 15), rnd());       /* a BAT register */
            }
        } else {
            s.msr = msrs[rnd() % (sizeof(msrs) / sizeof(msrs[0]))];
        }
        ref_set_state(&s);

        ref_ram()[0x1000] = uint8_t(word >> 24);
        ref_ram()[0x1001] = uint8_t(word >> 16);
        ref_ram()[0x1002] = uint8_t(word >> 8);
        ref_ram()[0x1003] = uint8_t(word);

        PC   = 0x1000;
        WORD = word;
        int rc = ref_step();
        g_checks++;
        switch (rc) {
        case 0:
            n_ok++;
            break;
        case 0x300: case 0x400: case 0x600: case 0x700: case 0x800: case 0xC00:
            n_exc++;
            break;
        case REF_STEP_FAULT:
            n_fault++;
            break;
        default:
            fail("ref_step() returned unexpected code 0x%X", unsigned(rc));
        }
        if (ref_last_store_count() > 64)
            fail("implausible store count %u", ref_last_store_count());
    }
    printf("  fuzz %-14s %7d words: %d completed, %d exceptions, %d REF_STEP_FAULT\n",
           name, count, n_ok, n_exc, n_fault);
}

} // namespace

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "--strict"))
            g_strict = true;

    /* Keep dingusppc's own log output out of the way unless asked for. */
    setenv("DINGUSREF_LOG", "-9", 0);
    setvbuf(stdout, nullptr, _IOLBF, 0);

    printf("dingusref selftest\n");

    printf("part 1: main program (integer, load/store, branches, CR, SPRs, illegal, sc)\n");
    main_program(nullptr, nullptr);

    printf("part 2: privileged / trap / FP-unavailable exceptions, FPSCR\n");
    more_exceptions();
    fp_status();

    printf("part 3: PowerPC 604 User's Manual specifics\n");
    ppc604_specifics();

    printf("part 4: ref_init again, identical second run\n");
    determinism();

    printf("part 5: library-defined behaviour (frozen time, SRs, outside RAM, garbage)\n");
    frozen_time();
    segment_registers();
    outside_ram();
    host_trap_601();
    fuzz(PVR_604, "604", 200000, false);
    fuzz(PVR_601, "601", 200000, false);
    fuzz(PVR_750, "750", 200000, false);
    fuzz(PVR_604, "604 MMU on", 200000, true);
    fuzz(PVR_601, "601 MMU on", 200000, true);

    /* the reference still works after all that */
    main_program(nullptr, nullptr);

    if (g_deviations)
        printf("PASS (%d checks; %d known dingusppc deviation(s) from the architecture or "
               "the 604 manual, listed above)\n", g_checks, g_deviations);
    else
        printf("PASS (%d checks)\n", g_checks);
    return 0;
}
