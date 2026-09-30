// gotscan — inspecte la table des symboles externes du pilote Bronze une fois charge.
// Le plantage de WindowServer venait d'une case contenant 0xbad4007 ; on regarde combien de
// cases sont dans cet etat, et ce que devrait contenir celle qui a plante.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define POISON 0x000000000bad4007ULL

int main(void) { @autoreleasepool {
    // charger le pilote en creant un peripherique Metal
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    printf("peripherique : %s\n", dev ? dev.name.UTF8String : "aucun");

    const struct mach_header_64 *hdr = NULL; intptr_t slide = 0; const char *path = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (strstr(n, "AMDMTLBronzeDriver")) {
            hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
            slide = _dyld_get_image_vmaddr_slide(i); path = n; break;
        }
    }
    if (!hdr) { printf("pilote Bronze non charge dans ce processus\n"); return 1; }
    printf("pilote  : %s\n", path);
    printf("en-tete : %p   decalage : 0x%lx\n\n", (void *)hdr, (unsigned long)slide);

    // valeur attendue pour kIOSurfaceCreationProperties
    void *h = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    void *attendu = h ? dlsym(h, "kIOSurfaceCreationProperties") : NULL;
    printf("adresse de la variable kIOSurfaceCreationProperties : %p\n", attendu);
    if (attendu) {
        CFStringRef v = *(CFStringRef *)attendu;
        printf("   sa valeur : %s\n", v ? [(__bridge NSString *)v UTF8String] : "(nulle)");
    }

    // parcourir les segments et chercher les cases empoisonnees
    const uint8_t *p = (const uint8_t *)hdr + sizeof(*hdr);
    uint64_t text_vm = 0;
    for (uint32_t c = 0; c < hdr->ncmds; c++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)p;
            if (!strcmp(sg->segname, "__TEXT")) text_vm = sg->vmaddr;
        }
        p += lc->cmdsize;
    }
    printf("\n__TEXT vmaddr du fichier : 0x%llx\n", (unsigned long long)text_vm);

    p = (const uint8_t *)hdr + sizeof(*hdr);
    unsigned total = 0;
    for (uint32_t c = 0; c < hdr->ncmds; c++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)p;
            if (strstr(sg->segname, "__DATA")) {
                const uint64_t *base = (const uint64_t *)((uintptr_t)hdr + (sg->vmaddr - text_vm));
                size_t n = sg->vmsize / 8, trouve = 0;
                for (size_t i = 0; i < n; i++) {
                    if (base[i] == POISON) {
                        if (trouve < 6)
                            printf("  %-14s +0x%05zx  EMPOISONNEE\n", sg->segname, i * 8);
                        trouve++;
                    }
                }
                printf("  %-14s vmaddr 0x%llx taille 0x%llx -> %zu case(s) empoisonnee(s)\n",
                       sg->segname, (unsigned long long)sg->vmaddr,
                       (unsigned long long)sg->vmsize, trouve);
                total += trouve;
                if (!strcmp(sg->segname, "__DATA_CONST"))
                    printf("     contenu de +0xfd8 (la case qui a plante) : 0x%016llx\n",
                           (unsigned long long)base[0xfd8 / 8]);
            }
        }
        p += lc->cmdsize;
    }
    printf("\ntotal : %u case(s) empoisonnee(s)\n", total);
    return 0;
} }
