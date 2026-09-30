// gotscan2 — parcourt la table de liaison du pilote Bronze une fois charge, et pour chaque
// case verifie si elle a bien ete liee. Nomme le symbole de chaque case defaillante et dit si
// ce symbole existe par ailleurs sur le systeme.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define POISON 0x000000000bad4007ULL

static const struct mach_header_64 *hdr;
static uint64_t text_vm;
static const uint8_t *lk_mem; static uint64_t lk_fileoff;

static void *rt(uint64_t vm) { return (void *)((uintptr_t)hdr + (vm - text_vm)); }
static const uint8_t *file(uint64_t off) { return lk_mem + (off - lk_fileoff); }

static uint64_t uleb(const uint8_t **p) {
    uint64_t r = 0; int s = 0; uint8_t b;
    do { b = *(*p)++; r |= (uint64_t)(b & 0x7f) << s; s += 7; } while (b & 0x80);
    return r;
}
static int64_t sleb(const uint8_t **p) {
    int64_t r = 0; int s = 0; uint8_t b;
    do { b = *(*p)++; r |= (int64_t)(b & 0x7f) << s; s += 7; } while (b & 0x80);
    if (s < 64 && (b & 0x40)) r |= -(1LL << s);
    return r;
}

static uint64_t segvm[64]; static int nseg;
static unsigned total, casses;

static void verifier(uint64_t addr, const char *sym) {
    if (!addr || !sym) return;
    total++;
    uint64_t *slot = (uint64_t *)rt(addr);
    if (*slot != POISON) return;
    casses++;
    void *ailleurs = dlsym(RTLD_DEFAULT, sym + (sym[0] == '_' ? 1 : 0));
    printf("  NON LIEE  %-46s  symbole %s\n", sym,
           ailleurs ? "present sur le systeme" : "INTROUVABLE");
}

static void parcourir(const uint8_t *p, const uint8_t *end) {
    const char *sym = NULL; uint64_t addr = 0;
    while (p < end) {
        uint8_t b = *p++, op = b & 0xF0, im = b & 0x0F;
        switch (op) {
        case 0x00: return;                                   // DONE
        case 0x10: break;                                    // SET_DYLIB_ORDINAL_IMM
        case 0x20: uleb(&p); break;                          // SET_DYLIB_ORDINAL_ULEB
        case 0x30: break;                                    // SET_DYLIB_SPECIAL_IMM
        case 0x40: sym = (const char *)p; p += strlen((const char *)p) + 1; break;
        case 0x50: break;                                    // SET_TYPE_IMM
        case 0x60: sleb(&p); break;                          // SET_ADDEND_SLEB
        case 0x70: addr = segvm[im] + uleb(&p); break;       // SET_SEGMENT_AND_OFFSET
        case 0x80: addr += uleb(&p); break;                  // ADD_ADDR_ULEB
        case 0x90: verifier(addr, sym); addr += 8; break;    // DO_BIND
        case 0xA0: verifier(addr, sym); addr += 8 + uleb(&p); break;
        case 0xB0: verifier(addr, sym); addr += 8 + im * 8; break;
        case 0xC0: {                                         // DO_BIND_ULEB_TIMES_SKIPPING
            uint64_t cnt = uleb(&p), skip = uleb(&p);
            for (uint64_t i = 0; i < cnt; i++) { verifier(addr, sym); addr += 8 + skip; }
            break; }
        default: return;
        }
    }
}

int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    printf("peripherique : %s\n", dev ? dev.name.UTF8String : "aucun");
    const char *path = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (strstr(n, "AMDMTLBronzeDriver")) {
            hdr = (const struct mach_header_64 *)_dyld_get_image_header(i); path = n; break;
        }
    }
    if (!hdr) { printf("pilote Bronze non charge\n"); return 1; }
    printf("pilote : %s\n\n", path);

    uint64_t bind_off = 0, bind_size = 0, lazy_off = 0, lazy_size = 0, weak_off = 0, weak_size = 0;
    const uint8_t *p = (const uint8_t *)hdr + sizeof(*hdr);
    for (uint32_t c = 0; c < hdr->ncmds; c++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)p;
            if (!strcmp(sg->segname, "__TEXT")) text_vm = sg->vmaddr;
            if (!strcmp(sg->segname, "__LINKEDIT")) { lk_fileoff = sg->fileoff; lk_mem = NULL; }
            if (nseg < 64) segvm[nseg++] = sg->vmaddr;
        } else if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) {
            const struct dyld_info_command *di = (const struct dyld_info_command *)p;
            bind_off = di->bind_off; bind_size = di->bind_size;
            lazy_off = di->lazy_bind_off; lazy_size = di->lazy_bind_size;
            weak_off = di->weak_bind_off; weak_size = di->weak_bind_size;
        }
        p += lc->cmdsize;
    }
    // adresse memoire du __LINKEDIT
    p = (const uint8_t *)hdr + sizeof(*hdr);
    for (uint32_t c = 0; c < hdr->ncmds; c++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)p;
            if (!strcmp(sg->segname, "__LINKEDIT")) lk_mem = (const uint8_t *)rt(sg->vmaddr);
        }
        p += lc->cmdsize;
    }
    if (!lk_mem || !bind_size) { printf("table de liaison introuvable\n"); return 1; }
    printf("table de liaison : %llu octets (paresseuse %llu, faible %llu)\n\n",
           (unsigned long long)bind_size, (unsigned long long)lazy_size,
           (unsigned long long)weak_size);

    printf("cases non liees :\n");
    parcourir(file(bind_off), file(bind_off + bind_size));
    if (weak_size) parcourir(file(weak_off), file(weak_off + weak_size));
    if (!casses) printf("  (aucune)\n");
    printf("\n%u case(s) non liee(s) sur %u verifiee(s)\n", casses, total);
    return 0;
} }
