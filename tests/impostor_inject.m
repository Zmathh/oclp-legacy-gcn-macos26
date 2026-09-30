// impostor_inject.c — runtime validation of the macOS 26 impostor fix, WITHOUT touching AMFI.
//
// Library Validation only rejects an ad-hoc signed impostor.dylib when the process mapping it is
// an Apple platform binary (WindowServer). A locally built test program is not a platform binary,
// so the same code can be injected into it with DYLD_INSERT_LIBRARIES and exercised for real.
//
// The Bronze driver bundle is loaded lazily by MTLCreateSystemDefaultDevice(), and the signed
// impostor.dylib shipped inside it installs its own swizzle at that moment. To be sure of the
// ordering, this library interposes MTLCreateSystemDefaultDevice: it captures the genuine Metal
// IMP *before* the driver loads, lets the driver load and swizzle, then reinstalls its own hook
// on top — always chaining to the genuine IMP, never to the shipped shim.
//
// Mode is chosen at run time so one binary can demonstrate cause and effect:
//   IMPOSTOR_MODE=verbatim  copy +0xe0 unchanged   -> reproduces the macOS 26 bug
//   IMPOSTOR_MODE=repack    apply repack_flags()   -> the proposed fix
//
// Build (native x86_64):
//   clang -O2 -dynamiclib -framework Foundation -framework Metal -o impostor_inject.dylib impostor_inject.c

#include <Metal/Metal.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <malloc/malloc.h>
#include <dlfcn.h>

#define DSC_BASE     0x700000000000ULL
#define RENDER_SIZE  0x190
#define COMPUTE_SIZE 0xa8

extern char __NSDictionary0__struct;

typedef void *(*orig_imp_t)(id, SEL);
static orig_imp_t real_render, real_compute;

static int repack_mode = 1;          // 1 = fix, 0 = reproduce the bug
static int chain_mode  = 0;
static int observe_mode = 0;          // 1 = do not take over, just forward + count (harmless control)
static unsigned long render_calls, compute_calls;
static uint64_t first_raw, first_out;
static int first_seen;

static pthread_key_t key_render, key_compute;
static pthread_once_t once_render = PTHREAD_ONCE_INIT, once_compute = PTHREAD_ONCE_INIT;
static void make_render(void) { pthread_key_create(&key_render, free); }
static void make_compute(void) { pthread_key_create(&key_compute, free); }

static void *thread_storage(pthread_key_t *key, pthread_once_t *once, void (*init)(void), size_t size) {
    pthread_once(once, init);
    void *buf = pthread_getspecific(*key);
    if (!buf) { buf = calloc(1, size); pthread_setspecific(*key, buf); }
    return buf;
}

#define RD8(o)   (*(uint8_t  *)(s + (o)))
#define RD16(o)  (*(uint16_t *)(s + (o)))
#define RD32(o)  (*(uint32_t *)(s + (o)))
#define RD64(o)  (*(uint64_t *)(s + (o)))
#define WR8(o,v)  (*(uint8_t  *)(d + (o)) = (uint8_t)(v))
#define WR16(o,v) (*(uint16_t *)(d + (o)) = (uint16_t)(v))
#define WR32(o,v) (*(uint32_t *)(d + (o)) = (uint32_t)(v))
#define WR64(o,v) (*(uint64_t *)(d + (o)) = (uint64_t)(v))

// The 64-bit flag block: macOS 26 bit positions -> Monterey bit positions.
static uint64_t repack_flags(uint64_t t) {
    uint64_t m = 0;
    m |= (uint64_t)(((t >> 0) & 3ULL) != 0) << 0;   // isAlphaToCoverageEnabled  (2 bits -> 1)
    m |= (uint64_t)(((t >> 2) & 3ULL) != 0) << 1;   // isAlphaToOneEnabled       (2 bits -> 1)
    m |= ((t >> 4)  & 1ULL)    << 2;                // isRasterizationEnabled
    m |= ((t >> 5)  & 3ULL)    << 3;                // inputPrimitiveTopology
    m |= ((t >> 8)  & 1ULL)    << 6;                // isDepthStencilWriteDisabled
    m |= ((t >> 9)  & 1ULL)    << 7;                // openGLModeEnabled
    m |= ((t >> 10) & 1ULL)    << 8;                // sampleCoverageInvert
    m |= ((t >> 12) & 1ULL)    << 10;               // vertexAmplificationMode
    m |= ((t >> 13) & 1ULL)    << 11;               // isTwoSideEnabled
    m |= ((t >> 14) & 1ULL)    << 12;               // isPointSizeOutputVS
    m |= ((t >> 15) & 1ULL)    << 13;               // isPointCoordLowerLeft
    m |= ((t >> 16) & 1ULL)    << 14;               // isPointSmoothEnabled
    m |= ((t >> 17) & 0xFFULL) << 15;               // clipDistanceEnableMask (8 bits)
    m |= ((t >> 25) & 7ULL)    << 23;               // alphaTestFunction
    m |= ((t >> 28) & 1ULL)    << 26;               // isAlphaTestEnabled
    m |= ((t >> 32) & 0xFULL)  << 27;               // logicOperation
    m |= ((t >> 36) & 1ULL)    << 31;               // isLogicOperationEnabled
    m |= ((t >> 37) & 1ULL)    << 32;               // forceResourceIndex
    m |= ((t >> 39) & 1ULL)    << 34;               // objectThreadgroupSizeIsMultipleOf...
    m |= ((t >> 40) & 1ULL)    << 35;               // meshThreadgroupSizeIsMultipleOf...
    return m;
}

static void dump(const char *tag, const uint8_t *p, size_t n) {
    fprintf(stderr, "[dump] %s (%zu octets)\n", tag, n);
    for (size_t o = 0; o < n; o += 16) {
        fprintf(stderr, "[dump] +0x%03zx ", o);
        for (size_t i = 0; i < 16; i++) fprintf(stderr, "%02x%s", p[o+i], (i==7)?"  ":" ");
        fprintf(stderr, "\n");
    }
}

static void *fake_render(id self, SEL sel) {
    uint8_t *s = (uint8_t *)real_render(self, sel);
    if (observe_mode) {
        int from_metal = ((uintptr_t)__builtin_return_address(0) >= DSC_BASE);
        static int seen_metal, seen_driver;
        int *seen = from_metal ? &seen_metal : &seen_driver;
        render_calls++;
        if (!*seen) {
            *seen = 1;
            fprintf(stderr, "[inject] observe : macOS %s — appel #%lu depuis %s — malloc_size=%zu\n",
                    getenv("OBSERVE_TAG") ? getenv("OBSERVE_TAG") : "?", render_calls,
                    from_metal ? "Metal (interne)" : "pilote Bronze", malloc_size(s));
            dump(from_metal ? "structure BRUTE, appelant Metal interne"
                            : "structure BRUTE, appelant pilote Bronze", s, 0x250);
        }
        return s;
    }
    if (chain_mode) { render_calls++; return s; }                      // control: pass shim result through
    if ((uintptr_t)__builtin_return_address(0) >= DSC_BASE) return s;  // internal Metal call
    uint8_t *d = (uint8_t *)thread_storage(&key_render, &once_render, make_render, RENDER_SIZE);
    render_calls++;

    memcpy(d, s, 0x48);
    WR64(0x48, RD64(0x48)); WR64(0x50, RD64(0x50)); WR64(0x58, RD64(0x58)); WR64(0x60, RD64(0x60));
    WR8 (0x68, RD8 (0x68)); WR64(0x70, RD64(0x70)); WR64(0x78, RD64(0x78)); WR64(0x80, RD64(0x80));
    WR64(0x88, RD64(0x88)); WR64(0x90, RD64(0x90)); WR8 (0x98, RD8 (0x98));
    WR64(0xa0, RD64(0xb0)); WR64(0xa8, RD64(0xb8)); WR64(0xb0, RD64(0xc0)); WR32(0xb8, RD32(0xc8));
    WR64(0xc8, RD64(0xd8));

    uint64_t raw = RD64(0xe0);
    uint64_t out = repack_mode ? repack_flags(raw) : raw;   // <-- the point of the experiment
    WR64(0xd0, out);
    if (!first_seen) { first_seen = 1; first_raw = raw; first_out = out; }
    if (render_calls <= 8)
        fprintf(stderr, "[inject] render #%lu  +0xe0 raw=0x%016llx -> 0x%016llx  rasterEnabled(bit2)=%d\n",
                render_calls, (unsigned long long)raw, (unsigned long long)out, (int)((out >> 2) & 1));

    WR32(0xd8, RD32(0xe8)); WR32(0xdc, RD32(0xec));
    WR64(0xe0, RD64(0xf0)); WR64(0xe8, RD64(0xf8)); WR64(0xf0, RD64(0x100));
    WR64(0xf8, RD64(0x108)); WR64(0x100, RD64(0x110));
    WR64(0x108, RD64(0x198)); WR64(0x110, RD64(0x1a0)); WR64(0x118, RD64(0x1a8));
    WR64(0x120, RD64(0x1b8)); WR64(0x138, RD64(0x1d0));
    WR8 (0x140, RD8 (0x1d8)); WR32(0x144, RD32(0x1dc));
    WR64(0x148, RD64(0x1e0)); WR64(0x150, RD64(0x1e8)); WR64(0x158, RD64(0x1f0));
    WR64(0x160, RD64(0x1f8)); WR64(0x168, RD64(0x210)); WR64(0x170, RD64(0x218));
    WR64(0x178, RD64(0x230)); WR64(0x180, RD64(0x238));
    WR8 (0x188, RD8 (0x240)); WR8 (0x189, RD8 (0x241));
    return d;
}

static void *fake_compute(id self, SEL sel) {
    uint8_t *s = (uint8_t *)real_compute(self, sel);
    if (chain_mode) { compute_calls++; return s; }
    if ((uintptr_t)__builtin_return_address(0) >= DSC_BASE) return s;
    uint8_t *d = (uint8_t *)thread_storage(&key_compute, &once_compute, make_compute, COMPUTE_SIZE);
    compute_calls++;

    WR64(0x00, RD64(0x00)); WR64(0x08, RD64(0x08)); WR8(0x10, RD8(0x10)); WR16(0x12, RD16(0x12));
    WR64(0x18, RD64(0x18)); WR64(0x20, RD64(0x20)); WR64(0x28, RD64(0x30)); WR64(0x30, RD64(0x38));
    WR64(0x38, RD64(0x40)); WR64(0x40, RD64(0x48)); WR8 (0x48, RD8 (0x50)); WR64(0x50, RD64(0x68));
    WR8 (0x58, RD8 (0x70)); WR64(0x60, RD64(0x78)); WR64(0x68, RD64(0x80)); WR8 (0x70, RD8 (0x88));
    {
        uint8_t v = *(uint8_t *)(d + 0x71);
        v = (uint8_t)((v & ~1u) | (RD8(0x89) & 1u));
        v = (uint8_t)((v & ~2u) | (((RD8(0x89) >> 1) & 1u) << 1));
        *(uint8_t *)(d + 0x71) = v;
    }
    WR64(0x78, RD64(0x90));
    WR64(0x80, (uint64_t)(uintptr_t)&__NSDictionary0__struct);
    WR64(0x88, RD64(0x98)); WR64(0x90, RD64(0xa0)); WR8(0x98, RD8(0xa8)); WR64(0xa0, RD64(0xb0));
    return d;
}

// --- hook management -------------------------------------------------------------------------

static IMP current_imp(const char *cls_name) {
    Class cls = objc_getClass(cls_name);
    if (!cls) return NULL;
    Method m = class_getInstanceMethod(cls, sel_registerName("_descriptorPrivate"));
    return m ? method_getImplementation(m) : NULL;
}

static void install(const char *cls_name, IMP replacement) {
    Class cls = objc_getClass(cls_name);
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel_registerName("_descriptorPrivate"));
    if (m) method_setImplementation(m, replacement);
}

// Interpose device creation so the ordering is deterministic:
//   capture genuine IMPs -> let Metal load the Bronze bundle (its shim swizzles) -> take over.
static id my_MTLCreateSystemDefaultDevice(void) {
    const char *mode = getenv("IMPOSTOR_MODE");
    if (!mode) mode = "repack";
    chain_mode   = (strcmp(mode, "chain") == 0);
    observe_mode = (strcmp(mode, "observe") == 0) || (strcmp(mode, "shimobserve") == 0);
    if (strcmp(mode, "shimobserve") == 0) chain_mode = 1;  // chaine sur la couche d'origine et photographie SA sortie
    // observe : on court-circuite la couche livree pour voir la structure BRUTE, sans rien traduire
    repack_mode = (strcmp(mode, "verbatim") != 0);

    IMP genuine_r = current_imp("MTLRenderPipelineDescriptorInternal");
    IMP genuine_c = current_imp("MTLComputePipelineDescriptorInternal");

    // Charger la couche de reference APRES que Metal ait enregistre ses classes :
    // son constructeur ne trouve rien si on l'injecte au demarrage du processus.
    const char *pre = getenv("IMPOSTOR_PRELOAD");
    if (pre && *pre) {
        void *h = dlopen(pre, RTLD_NOW | RTLD_LOCAL);
        fprintf(stderr, "[inject] dlopen(%s) = %s\n", pre, h ? "ok" : dlerror());
    }

    id dev = MTLCreateSystemDefaultDevice();

    IMP after_r = current_imp("MTLRenderPipelineDescriptorInternal");
    fprintf(stderr, "[inject] mode=%s  shipped shim %s\n",
            chain_mode ? "chain (control, no translation of our own)"
                       : (repack_mode ? "repack (fix)" : "verbatim (reproduce bug)"),
            (after_r != genuine_r) ? "was active, taking over" : "not present");

    // chain mode keeps the shipped shim downstream; the other modes bypass it entirely
    real_render  = (orig_imp_t)(chain_mode ? after_r : genuine_r);
    real_compute = (orig_imp_t)(chain_mode ? current_imp("MTLComputePipelineDescriptorInternal")
                                           : genuine_c);
    if (real_render) install("MTLRenderPipelineDescriptorInternal",  (IMP)fake_render);
    if (real_compute) install("MTLComputePipelineDescriptorInternal", (IMP)fake_compute);
    return dev;
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)my_MTLCreateSystemDefaultDevice, (const void *)MTLCreateSystemDefaultDevice },
};

__attribute__((destructor)) static void report(void) {
    fprintf(stderr, "[inject] render translations=%lu compute translations=%lu\n",
            render_calls, compute_calls);
    if (first_seen)
        fprintf(stderr, "[inject] first descriptor: +0xe0 raw=0x%016llx -> driver sees 0x%016llx "
                        "(bit2 / isRasterizationEnabled = %d)\n",
                (unsigned long long)first_raw, (unsigned long long)first_out,
                (int)((first_out >> 2) & 1));
}
