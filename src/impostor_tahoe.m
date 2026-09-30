// impostor.dylib pour macOS 26 (Tahoe) — couche OCLP 2.5.0 + deux corrections.
//
// Base : la table de copie de la couche livree par OCLP 2.5.0, extraite de son desassemblage
// (43 copies pour le descripteur de rendu, 20 pour le calcul), reprise telle quelle.
//
// Correction 1 — bloc de drapeaux du descripteur de pipeline (+0xe0 -> +0xd0).
//   macOS 26 le re-packe ; la couche d'origine le recopie brut, et le pilote lit
//   isRasterizationEnabled = 0 : aucun fragment n'est produit.
// Correction 2 — MTLRenderPipelineColorAttachmentDescriptorInternal, non traduite a l'origine.
//   macOS 26 decale ses champs ; le pilote lit un masque d'ecriture nul : rien n'est ecrit.
//
// Verifie sur iMac15,1 / Radeon R9 M295X / macOS 26.0 (25A354), par injection dans des
// programmes de test : avec les deux corrections, les comptes de fragments et les pixels sont
// identiques a ceux de macOS 15.8 ; avec l'une seule, rien n'est dessine.
//
// Compilation :
//   clang -O2 -x objective-c -dynamiclib -framework Foundation -framework Metal \
//     -install_name /System/Library/Extensions/AMDMTLBronzeDriver.bundle/Contents/MacOS/impostor.dylib \
//     -o impostor.dylib impostor_tahoe.m
// Chargee dans WindowServer, elle doit etre signee avec la chaine du projet (Library Validation).
#include <Metal/Metal.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "repair.h"

static int reparation_faite;
#define DSC_BASE     0x700000000000ULL
#define RENDER_SIZE  0x190
#define COMPUTE_SIZE 0xa8
#define CATT_SIZE    0x40

extern char __NSDictionary0__struct;
typedef void *(*imp_t)(id, SEL);
static imp_t real_render, real_compute, real_catt;
static const int fix_flags = 1, fix_catt = 1;

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
    if (!reparation_faite) reparation_faite = repair_bronze_bindings();
    uint8_t *s = (uint8_t *)real_render(self, sel);
    if ((uintptr_t)__builtin_return_address(0) >= DSC_BASE) return s;
    uint8_t *d = (uint8_t *)tls(&kr, &onr, mkr, RENDER_SIZE);
    uint64_t raw = (uint64_t)RD32(0x0e0) | ((uint64_t)RD32(0x0e4) << 32);
    uint64_t flags_out = fix_flags ? repack_flags(raw) : raw;
    memcpy(d + 8, s + 8, 0x40);
    WR64(0x000, RD64(0x000));
    WR64(0x048, RD64(0x048));
    WR64(0x050, RD64(0x050));
    WR64(0x058, RD64(0x058));
    WR64(0x060, RD64(0x060));
    WR8(0x068, RD8(0x068));
    WR64(0x070, RD64(0x070));
    WR64(0x078, RD64(0x078));
    WR64(0x080, RD64(0x080));
    WR64(0x088, RD64(0x088));
    WR64(0x090, RD64(0x090));
    WR8(0x098, RD8(0x098));
    WR64(0x0a0, RD64(0x0b0));
    WR64(0x0a8, RD64(0x0b8));
    WR64(0x0b0, RD64(0x0c0));
    WR32(0x0b8, RD32(0x0c8));
    WR64(0x0c8, RD64(0x0d8));
    WR32(0x0d0, (uint32_t)flags_out);            // <-- bloc de drapeaux (bas)
    WR32(0x0d4, (uint32_t)(flags_out >> 32));   // <-- bloc de drapeaux (haut)
    WR32(0x0d8, RD32(0x0e8));
    WR32(0x0dc, RD32(0x0ec));
    WR64(0x0e0, RD64(0x0f0));
    WR64(0x0e8, RD64(0x0f8));
    WR64(0x0f0, RD64(0x100));
    WR64(0x0f8, RD64(0x108));
    WR64(0x100, RD64(0x110));
    WR64(0x108, RD64(0x198));
    WR64(0x110, RD64(0x1a0));
    WR64(0x118, RD64(0x1a8));
    WR64(0x120, RD64(0x1b8));
    WR64(0x138, RD64(0x1d0));
    WR8(0x140, RD8(0x1d8));
    WR32(0x144, RD32(0x1dc));
    WR64(0x148, RD64(0x1e0));
    WR64(0x150, RD64(0x1e8));
    WR64(0x158, RD64(0x1f0));
    WR64(0x160, RD64(0x1f8));
    WR64(0x168, RD64(0x210));
    WR64(0x170, RD64(0x218));
    WR64(0x178, RD64(0x230));
    WR64(0x180, RD64(0x238));
    WR8(0x188, RD8(0x240));
    WR8(0x189, RD8(0x241));
    return d;
}
static void *fake_compute(id self, SEL sel) {
    uint8_t *s = (uint8_t *)real_compute(self, sel);
    if ((uintptr_t)__builtin_return_address(0) >= DSC_BASE) return s;
    uint8_t *d = (uint8_t *)tls(&kc, &onc, mkc, COMPUTE_SIZE);
    WR64(0x000, RD64(0x000));
    WR64(0x008, RD64(0x008));
    WR8(0x010, RD8(0x010));
    WR64(0x018, RD64(0x018));
    WR64(0x020, RD64(0x020));
    WR64(0x028, RD64(0x030));
    WR64(0x030, RD64(0x038));
    WR64(0x038, RD64(0x040));
    WR64(0x040, RD64(0x048));
    WR8(0x048, RD8(0x050));
    WR64(0x050, RD64(0x068));
    WR8(0x058, RD8(0x070));
    WR64(0x060, RD64(0x078));
    WR64(0x068, RD64(0x080));
    WR8(0x070, RD8(0x088));
    WR64(0x078, RD64(0x090));
    WR64(0x088, RD64(0x098));
    WR64(0x090, RD64(0x0a0));
    WR8(0x098, RD8(0x0a8));
    WR64(0x0a0, RD64(0x0b0));
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

__attribute__((constructor)) static void impostor_tahoe_init(void) {
    reparation_faite = repair_bronze_bindings();
    IMP gr = impof("MTLRenderPipelineDescriptorInternal");
    IMP gc = impof("MTLComputePipelineDescriptorInternal");
    IMP ga = impof("MTLRenderPipelineColorAttachmentDescriptorInternal");
    real_render = (imp_t)gr; real_compute = (imp_t)gc; real_catt = (imp_t)ga;
    if (gr) put("MTLRenderPipelineDescriptorInternal",  (IMP)fake_render);
    if (gc) put("MTLComputePipelineDescriptorInternal", (IMP)fake_compute);
    if (ga) put("MTLRenderPipelineColorAttachmentDescriptorInternal", (IMP)fake_catt);
}
