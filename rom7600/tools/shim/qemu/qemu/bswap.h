/* Stand-in for QEMU's qemu/bswap.h: the loads disas/dis-asm.h uses. */
#ifndef ROM7600_QEMU_BSWAP_H
#define ROM7600_QEMU_BSWAP_H
#include <stdint.h>
static inline uint64_t ldq_le_p(const void *p) {
    const uint8_t *b = (const uint8_t *)p; uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | b[i];
    return v;
}
static inline int ldl_le_p(const void *p) {
    const uint8_t *b = (const uint8_t *)p;
    return (int)((uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24);
}
static inline int lduw_le_p(const void *p) {
    const uint8_t *b = (const uint8_t *)p;
    return b[0] | b[1] << 8;
}
static inline int ldl_be_p(const void *p) {
    const uint8_t *b = (const uint8_t *)p;
    return (int)((uint32_t)b[3] | (uint32_t)b[2] << 8 | (uint32_t)b[1] << 16 | (uint32_t)b[0] << 24);
}
static inline int lduw_be_p(const void *p) {
    const uint8_t *b = (const uint8_t *)p;
    return b[1] | b[0] << 8;
}
#endif
