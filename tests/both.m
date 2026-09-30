// both — les deux corrections, activables separement, pour un test factoriel 2x2.
//   FIX_FLAGS=1 : re-packe le bloc de drapeaux du descripteur de pipeline (sinon copie brute,
//                 comme la couche livree)
//   FIX_CATT=1  : traduit la piece jointe couleur (sinon laissee brute, comme la couche livree)
// La table de copie du descripteur de pipeline est celle de la couche livree, extraite de son
// desassemblage (43 copies rendu, 20 calcul).
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
#define CATT_SIZE    0x40

extern char __NSDictionary0__struct;
typedef void *(*imp_t)(id, SEL);
static imp_t real_render, real_compute, real_catt;
static int fix_flags, fix_catt;

static pthread_key_t kr, kc, ka;
static pthread_once_t onr = PTHREAD_ONCE_INIT, onc = PTHREAD_ONCE_INIT, ona = PTHREAD_ONCE_INIT;
static void mkr(void){pthread_key_create(&kr,free);} static void mkc(void){pthread_key_create(&kc,free);}
static void mka(void){pthread_key_create(&ka,free);}
static void *tls(pthread_key_t *k, pthread_once_t *o, void (*i)(void), size_t n){
    pthread_once(o,i); void *b=pthread_getspecific(*k);
    if(!b){b=calloc(1,n);pthread_setspecific(*k,b);} return b; }

#define RD8(o)   (*(uint8_t  *)(s + (o)))
#define RD16(o)  (*(uint16_t *)(s + (o)))
#define RD32(o)  (*(uint32_t *)(s + (o)))
#define RD64(o)  (*(uint64_t *)(s + (o)))
#define WR8(o,v)  (*(uint8_t  *)(d + (o)) = (uint8_t)(v))
#define WR16(o,v) (*(uint16_t *)(d + (o)) = (uint16_t)(v))
#define WR32(o,v) (*(uint32_t *)(d + (o)) = (uint32_t)(v))
#define WR64(o,v) (*(uint64_t *)(d + (o)) = (uint64_t)(v))

static uint64_t repack_flags(uint64_t t) {
    uint64_t m = 0;
    m |= (uint64_t)(((t >> 0) & 3ULL) != 0) << 0;
    m |= (uint64_t)(((t >> 2) & 3ULL) != 0) << 1;
    m |= ((t >> 4)  & 1ULL)    << 2;
    m |= ((t >> 5)  & 3ULL)    << 3;
    m |= ((t >> 8)  & 1ULL)    << 6;
    m |= ((t >> 9)  & 1ULL)    << 7;
    m |= ((t >> 10) & 1ULL)    << 8;
    m |= ((t >> 12) & 1ULL)    << 10;
    m |= ((t >> 13) & 1ULL)    << 11;
    m |= ((t >> 14) & 1ULL)    << 12;
    m |= ((t >> 15) & 1ULL)    << 13;
    m |= ((t >> 16) & 1ULL)    << 14;
    m |= ((t >> 17) & 0xFFULL) << 15;
    m |= ((t >> 25) & 7ULL)    << 23;
    m |= ((t >> 28) & 1ULL)    << 26;
    m |= ((t >> 32) & 0xFULL)  << 27;
    m |= ((t >> 36) & 1ULL)    << 31;
    m |= ((t >> 37) & 1ULL)    << 32;
    m |= ((t >> 39) & 1ULL)    << 34;
    m |= ((t >> 40) & 1ULL)    << 35;
    return m;
}
static uint64_t catt_translate(uint64_t t) {
    return  (t & 1)
         | (((t >> 2)  & 0x3FFFFFFULL) << 1)
         | (((t >> 32) & 0xFULL)       << 27)
         | (((t >> 40) & 0x3FFULL)     << 34);
}

static void *fake_render(id self, SEL sel) {
    uint8_t *s = (uint8_t *)real_render(self, sel);
    if ((uintptr_t)__builtin_return_address(0) >= DSC_BASE) return s;
    uint8_t *d = (uint8_t *)tls(&kr, &onr, mkr, RENDER_SIZE);
    uint64_t raw = (uint64_t)RD32(0x0e0) | ((uint64_t)RD32(0x0e4) << 32);
    uint64_t flags_out = fix_flags ? repack_flags(raw) : raw;
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
static void *fake_catt(id self, SEL sel) {
    uint8_t *s = (uint8_t *)real_catt(self, sel);
    if (!fix_catt || !s || (uintptr_t)__builtin_return_address(0) >= DSC_BASE) return s;
    uint8_t *d = (uint8_t *)tls(&ka, &ona, mka, CATT_SIZE);
    memcpy(d, s, CATT_SIZE);
    *(uint64_t *)d = catt_translate(*(uint64_t *)s);
    return d;
}

static IMP impof(const char *c){Class k=objc_getClass(c);if(!k)return NULL;
    Method m=class_getInstanceMethod(k,sel_registerName("_descriptorPrivate"));return m?method_getImplementation(m):NULL;}
static void put(const char *c, IMP r){Class k=objc_getClass(c);if(!k)return;
    Method m=class_getInstanceMethod(k,sel_registerName("_descriptorPrivate"));if(m)method_setImplementation(m,r);}

static id my_create(void) {
    const char *a = getenv("FIX_FLAGS"), *b = getenv("FIX_CATT");
    fix_flags = a && *a == '1'; fix_catt = b && *b == '1';
    IMP gr = impof("MTLRenderPipelineDescriptorInternal");
    IMP gc = impof("MTLComputePipelineDescriptorInternal");
    IMP ga = impof("MTLRenderPipelineColorAttachmentDescriptorInternal");
    id dev = MTLCreateSystemDefaultDevice();
    real_render = (imp_t)gr; real_compute = (imp_t)gc; real_catt = (imp_t)ga;
    if (gr) put("MTLRenderPipelineDescriptorInternal",  (IMP)fake_render);
    if (gc) put("MTLComputePipelineDescriptorInternal", (IMP)fake_compute);
    if (ga) put("MTLRenderPipelineColorAttachmentDescriptorInternal", (IMP)fake_catt);
    fprintf(stderr, "[both] drapeaux %s | piece jointe couleur %s\n",
            fix_flags ? "RE-PACKES" : "bruts (comme la couche livree)",
            fix_catt  ? "TRADUITE"  : "brute (comme la couche livree)");
    return dev;
}
__attribute__((used)) static struct { const void *r; const void *o; }
interp[] __attribute__((section("__DATA,__interpose"))) =
    { { (const void *)my_create, (const void *)MTLCreateSystemDefaultDevice } };
