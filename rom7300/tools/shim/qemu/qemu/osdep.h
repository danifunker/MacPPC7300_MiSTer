/* Stand-in for QEMU's qemu/osdep.h: the C library headers and the one GLib
   macro that disas/dis-asm.h and disas/m68k.c use. */
#ifndef ROM7600_QEMU_OSDEP_H
#define ROM7600_QEMU_OSDEP_H
#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <math.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif
#ifndef MAX
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#endif
#ifndef G_GNUC_PRINTF
#define G_GNUC_PRINTF(a, b) __attribute__((format(printf, a, b)))
#endif
#endif
