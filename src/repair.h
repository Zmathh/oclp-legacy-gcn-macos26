// repair.h — reparation des liaisons manquantes du pilote Bronze.
//
// Dans WindowServer, une case de la table des symboles externes du pilote contenait 0xbad4007,
// la valeur que dyld inscrit pour une liaison non resolue, et le premier deréférencement plantait
// (EXC_BAD_ACCESS dans isIOSurfaceSharedMetalTexture). Le symbole concerne,
// _kIOSurfaceCreationProperties, existe pourtant : dans un processus ordinaire de macOS 26 la
// meme case est correctement liee, et aucune des 1473 liaisons du pilote ne manque. La cause de
// cette difference n'est pas identifiee.
//
// Plutot que d'en dependre, on repare : on parcourt la table de liaison, et pour chaque case
// restee empoisonnee on ecrit l'adresse que dlsym rend pour ce symbole. Dans un processus ou
// tout est correctement lie, cette routine ne modifie rien.

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define BIND_POISON 0x000000000bad4007ULL

static const struct mach_header_64 *rp_hdr;
static uint64_t rp_text_vm;
static const uint8_t *rp_lk_mem;
static uint64_t rp_lk_fileoff;
static uint64_t rp_segvm[64];
static int rp_nseg;
static unsigned rp_repairs, rp_failures;

static void *rp_rt(uint64_t vm) { return (void *)((uintptr_t)rp_hdr + (vm - rp_text_vm)); }

static uint64_t rp_uleb(const uint8_t **p) {
    uint64_t r = 0; int s = 0; uint8_t b;
    do { b = *(*p)++; r |= (uint64_t)(b & 0x7f) << s; s += 7; } while (b & 0x80);
    return r;
}
static int64_t rp_sleb(const uint8_t **p) {
    int64_t r = 0; int s = 0; uint8_t b;
    do { b = *(*p)++; r |= (int64_t)(b & 0x7f) << s; s += 7; } while (b & 0x80);
    if (s < 64 && (b & 0x40)) r |= -(1LL << s);
    return r;
}

static void rp_fix(uint64_t addr, const char *sym) {
    if (!addr || !sym) return;
    uint64_t *slot = (uint64_t *)rp_rt(addr);
    if (*slot != BIND_POISON) return;
    void *v = dlsym(RTLD_DEFAULT, sym + (sym[0] == '_' ? 1 : 0));
    if (!v) { rp_failures++; return; }
    long ps = sysconf(_SC_PAGESIZE);
    void *page = (void *)((uintptr_t)slot & ~(uintptr_t)(ps - 1));
    if (mprotect(page, ps, PROT_READ | PROT_WRITE) != 0) { rp_failures++; return; }
    *slot = (uint64_t)(uintptr_t)v;
    mprotect(page, ps, PROT_READ);
    rp_repairs++;
}

static void rp_walk(const uint8_t *p, const uint8_t *end) {
    const char *sym = NULL; uint64_t addr = 0;
    while (p < end) {
        uint8_t b = *p++, op = b & 0xF0, im = b & 0x0F;
        switch (op) {
        case 0x00: return;
        case 0x10: break;
        case 0x20: rp_uleb(&p); break;
        case 0x30: break;
        case 0x40: sym = (const char *)p; p += strlen((const char *)p) + 1; break;
        case 0x50: break;
        case 0x60: rp_sleb(&p); break;
        case 0x70: if (im < 64) addr = rp_segvm[im] + rp_uleb(&p); else return; break;
        case 0x80: addr += rp_uleb(&p); break;
        case 0x90: rp_fix(addr, sym); addr += 8; break;
        case 0xA0: rp_fix(addr, sym); addr += 8 + rp_uleb(&p); break;
        case 0xB0: rp_fix(addr, sym); addr += 8 + im * 8; break;
        case 0xC0: { uint64_t c = rp_uleb(&p), s = rp_uleb(&p);
                     for (uint64_t i = 0; i < c; i++) { rp_fix(addr, sym); addr += 8 + s; }
                     break; }
        default: return;
        }
    }
}

// Rend 1 si le pilote a ete trouve et sa table parcourue.
static int repair_bronze_bindings(void) {
    rp_hdr = NULL; rp_nseg = 0; rp_lk_mem = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && strstr(n, "AMDMTLBronzeDriver")) {
            rp_hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
            break;
        }
    }
    if (!rp_hdr) return 0;

    uint64_t bind_off = 0, bind_size = 0, weak_off = 0, weak_size = 0, lk_vm = 0;
    const uint8_t *p = (const uint8_t *)rp_hdr + sizeof(*rp_hdr);
    for (uint32_t c = 0; c < rp_hdr->ncmds; c++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)p;
            if (!strcmp(sg->segname, "__TEXT")) rp_text_vm = sg->vmaddr;
            if (!strcmp(sg->segname, "__LINKEDIT")) { lk_vm = sg->vmaddr; rp_lk_fileoff = sg->fileoff; }
            if (rp_nseg < 64) rp_segvm[rp_nseg++] = sg->vmaddr;
        } else if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) {
            const struct dyld_info_command *di = (const struct dyld_info_command *)p;
            bind_off = di->bind_off; bind_size = di->bind_size;
            weak_off = di->weak_bind_off; weak_size = di->weak_bind_size;
        }
        p += lc->cmdsize;
    }
    if (!lk_vm || !bind_size) return 0;
    rp_lk_mem = (const uint8_t *)rp_rt(lk_vm);

    const uint8_t *b = rp_lk_mem + (bind_off - rp_lk_fileoff);
    rp_walk(b, b + bind_size);
    if (weak_size) {
        const uint8_t *w = rp_lk_mem + (weak_off - rp_lk_fileoff);
        rp_walk(w, w + weak_size);
    }
    if (rp_repairs || rp_failures)
        fprintf(stderr, "[impostor] liaisons reparees : %u, echecs : %u\n", rp_repairs, rp_failures);
    return 1;
}
