// sweep.dylib — transcription EXACTE de la table de la couche livree par OCLP
// (extraite du desassemblage de impostor.dylib, 43 copies pour le rendu, 20 pour le calcul),
// avec une seule variable : la valeur ecrite dans le bloc de drapeaux a +0xd0.
//
// FLAGS=<hexa>   valeur imposee au bloc de drapeaux
// FLAGS non defini -> comportement d'origine (copie brute de +0xe0/+0xe4)
//
// On injecte dans metaltest, qui n'est pas un binaire plateforme : Library Validation
// ne s'applique pas et rien dans le systeme n'est modifie.

#include <Metal/Metal.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DSC_BASE     0x700000000000ULL
#define RENDER_SIZE  0x190
#define COMPUTE_SIZE 0xa8

extern char __NSDictionary0__struct;
typedef void *(*orig_imp_t)(id, SEL);
static orig_imp_t real_render, real_compute;
static int   flags_forced;
static uint64_t flags_value;

static pthread_key_t kr, kc;
static pthread_once_t onr = PTHREAD_ONCE_INIT, onc = PTHREAD_ONCE_INIT;
static void mkr(void){pthread_key_create(&kr,free);} static void mkc(void){pthread_key_create(&kc,free);}
static void *tls(pthread_key_t *k, pthread_once_t *o, void (*i)(void), size_t n){
    pthread_once(o,i); void *b=pthread_getspecific(*k);
    if(!b){b=calloc(1,n);pthread_setspecific(*k,b);} return b;
}

#define RD8(o)   (*(uint8_t  *)(s + (o)))
#define RD16(o)  (*(uint16_t *)(s + (o)))
#define RD32(o)  (*(uint32_t *)(s + (o)))
#define RD64(o)  (*(uint64_t *)(s + (o)))
#define WR8(o,v)  (*(uint8_t  *)(d + (o)) = (uint8_t)(v))
#define WR16(o,v) (*(uint16_t *)(d + (o)) = (uint16_t)(v))
#define WR32(o,v) (*(uint32_t *)(d + (o)) = (uint32_t)(v))
#define WR64(o,v) (*(uint64_t *)(d + (o)) = (uint64_t)(v))

static void *fake_render(id self, SEL sel) {
    uint8_t *s = (uint8_t *)real_render(self, sel);
    if ((uintptr_t)__builtin_return_address(0) >= DSC_BASE) return s;
    uint8_t *d = (uint8_t *)tls(&kr, &onr, mkr, RENDER_SIZE);
    uint64_t flags_out = flags_forced ? flags_value
                                      : ((uint64_t)RD32(0x0e0) | ((uint64_t)RD32(0x0e4) << 32));
    memcpy(d + 8, s + 8, 0x40);
#include "table_render.inc"
    return d;
}

static void *fake_compute(id self, SEL sel) {
    uint8_t *s = (uint8_t *)real_compute(self, sel);
    if ((uintptr_t)__builtin_return_address(0) >= DSC_BASE) return s;
    uint8_t *d = (uint8_t *)tls(&kc, &onc, mkc, COMPUTE_SIZE);
#include "table_compute.inc"
    {   uint8_t v = *(uint8_t *)(d + 0x71);
        v = (uint8_t)((v & ~1u) | (RD8(0x89) & 1u));
        v = (uint8_t)((v & ~2u) | (((RD8(0x89) >> 1) & 1u) << 1));
        *(uint8_t *)(d + 0x71) = v; }
    WR64(0x080, (uint64_t)(uintptr_t)&__NSDictionary0__struct);
    return d;
}

static IMP impof(const char *c){Class k=objc_getClass(c);if(!k)return NULL;
    Method m=class_getInstanceMethod(k,sel_registerName("_descriptorPrivate"));return m?method_getImplementation(m):NULL;}
static void put(const char *c, IMP r){Class k=objc_getClass(c);if(!k)return;
    Method m=class_getInstanceMethod(k,sel_registerName("_descriptorPrivate"));if(m)method_setImplementation(m,r);}

static id my_create(void) {
    const char *f = getenv("FLAGS");
    if (f && *f) { flags_forced = 1; flags_value = strtoull(f, NULL, 16); }
    IMP gr = impof("MTLRenderPipelineDescriptorInternal");
    IMP gc = impof("MTLComputePipelineDescriptorInternal");
    id dev = MTLCreateSystemDefaultDevice();
    real_render = (orig_imp_t)gr; real_compute = (orig_imp_t)gc;
    if (gr) put("MTLRenderPipelineDescriptorInternal",  (IMP)fake_render);
    if (gc) put("MTLComputePipelineDescriptorInternal", (IMP)fake_compute);
    return dev;
}
__attribute__((used)) static struct { const void *r; const void *o; }
interposers[] __attribute__((section("__DATA,__interpose"))) =
    { { (const void *)my_create, (const void *)MTLCreateSystemDefaultDevice } };
