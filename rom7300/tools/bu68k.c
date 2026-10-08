/*
 * bu68k - the GNU binutils 68k disassembler (as carried in QEMU's
 * disas/m68k.c, compiled unmodified against small shims) behind a command
 * line, as a cross-check of MAME's.
 *
 *   bu68k FILE OFFSET LENGTH BASEADDR      linear listing, 68040
 *   bu68k -s FILE BASEADDR                 server: one hex address per line
 *
 * Prints "AAAAAAAA LEN<TAB>text" per instruction.
 */

#include "qemu/osdep.h"
#include "disas/dis-asm.h"

static unsigned char *g_data;
static size_t g_size;
static uint32_t g_base;
static char g_out[1024];
static size_t g_pos;

static int read_mem(bfd_vma memaddr, bfd_byte *myaddr, int length, struct disassemble_info *info) {
    (void)info;
    uint32_t a = (uint32_t)memaddr - g_base;
    if ((size_t)a + (size_t)length > g_size) return EIO;
    memcpy(myaddr, g_data + a, (size_t)length);
    return 0;
}

static void mem_err(int status, bfd_vma addr, struct disassemble_info *info) {
    (void)status; (void)addr; (void)info;
}

static int outf(FILE *f, const char *fmt, ...) {
    (void)f;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(g_out + g_pos, sizeof(g_out) - g_pos, fmt, ap);
    va_end(ap);
    if (n > 0) {
        g_pos += (size_t)n;
        if (g_pos >= sizeof(g_out)) g_pos = sizeof(g_out) - 1;
    }
    return n;
}

static void print_addr(bfd_vma addr, struct disassemble_info *info) {
    info->fprintf_func(info->stream, "$%X", (unsigned)addr);
}

static void setup(struct disassemble_info *info) {
    memset(info, 0, sizeof(*info));
    info->fprintf_func = outf;
    info->stream = stdout;
    info->read_memory_func = read_mem;
    info->memory_error_func = mem_err;
    info->print_address_func = print_addr;
    info->mach = bfd_mach_m68040;
    info->endian = BFD_ENDIAN_BIG;
}

static int one(struct disassemble_info *info, uint32_t pc) {
    g_pos = 0;
    g_out[0] = 0;
    int n = print_insn_m68k(pc, info);
    if (n <= 0) {
        snprintf(g_out, sizeof(g_out), "<error>");
        n = 2;
    }
    printf("%08X %d\t%s\n", pc, n, g_out);
    return n;
}

static int load(const char *path, unsigned long off, unsigned long len) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return 0; }
    if (len == 0) {
        fseek(f, 0, SEEK_END);
        len = (unsigned long)ftell(f) - off;
    }
    fseek(f, (long)off, SEEK_SET);
    g_data = malloc(len + 16);
    memset(g_data, 0, len + 16);
    g_size = fread(g_data, 1, len, f);
    fclose(f);
    return 1;
}

int main(int argc, char **argv) {
    struct disassemble_info info;
    setup(&info);
    if (argc == 4 && strcmp(argv[1], "-s") == 0) {
        if (!load(argv[2], 0, 0)) return 1;
        g_base = (uint32_t)strtoul(argv[3], NULL, 0);
        char line[64];
        while (fgets(line, sizeof(line), stdin)) {
            if (line[0] == '\n' || line[0] == 0) continue;
            one(&info, (uint32_t)strtoul(line, NULL, 16));
            fflush(stdout);
        }
        return 0;
    }
    if (argc < 5) {
        fprintf(stderr, "usage: bu68k FILE OFFSET LENGTH BASEADDR | bu68k -s FILE BASEADDR\n");
        return 2;
    }
    if (!load(argv[1], strtoul(argv[2], NULL, 0), strtoul(argv[3], NULL, 0))) return 1;
    g_base = (uint32_t)strtoul(argv[4], NULL, 0);
    for (uint32_t pc = g_base; pc < g_base + g_size;) pc += (uint32_t)one(&info, pc);
    return 0;
}
