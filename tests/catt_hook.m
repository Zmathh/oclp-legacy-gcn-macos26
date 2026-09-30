// catt_hook — releve MTLRenderPipelineColorAttachmentDescriptorInternal a chaque fois que le
// pilote Bronze la consulte. N'ecrit rien, ne traduit rien.
#include <Metal/Metal.h>
#include <objc/runtime.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#define DSC_BASE 0x700000000000ULL
#define TAILLE   0x40

typedef void *(*imp_t)(id, SEL);
static imp_t reel;
static unsigned n;

static void *faux(id self, SEL sel) {
    uint8_t *s = (uint8_t *)reel(self, sel);
    if ((uintptr_t)__builtin_return_address(0) < DSC_BASE && s) {
        fprintf(stderr, "  releve %u :\n", ++n);
        for (int o = 0; o < TAILLE; o += 16) {
            fprintf(stderr, "    +0x%02x ", o);
            for (int i = 0; i < 16; i++) fprintf(stderr, "%02x%s", s[o+i], (i==7)?"  ":" ");
            fprintf(stderr, "\n");
        }
    }
    return s;
}

static id my_create(void) {
    Class c = objc_getClass("MTLRenderPipelineColorAttachmentDescriptorInternal");
    SEL sel = sel_registerName("_descriptorPrivate");
    Method m = c ? class_getInstanceMethod(c, sel) : NULL;
    if (m) reel = (imp_t)method_getImplementation(m);
    id dev = MTLCreateSystemDefaultDevice();
    if (m) method_setImplementation(m, (IMP)faux);
    else fprintf(stderr, "  (classe ou methode introuvable)\n");
    return dev;
}
__attribute__((used)) static struct { const void *r; const void *o; }
interp[] __attribute__((section("__DATA,__interpose"))) =
    { { (const void *)my_create, (const void *)MTLCreateSystemDefaultDevice } };
