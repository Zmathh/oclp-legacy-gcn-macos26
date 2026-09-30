// iosurf — reproduit le chemin ou WindowServer plante : creation d'une texture Metal adossee
// a une IOSurface, ce que fait CoreDisplay pour composer l'ecran.
//   -[BronzeMtlDevice newTextureWithDescriptor:iosurface:plane:]
//     -> -[BronzeMtlTexture initIOSurfaceWithDevice:descriptor:iosurface:plane:field:]
//       -> isIOSurfaceSharedMetalTexture(__IOSurface*)   <- EXC_BAD_ACCESS
//
// clang -O2 -fobjc-arc -framework Metal -framework Foundation -framework IOSurface -o iosurf iosurf.m
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>

static id<MTLDevice> dev;

static void essai(const char *nom, MTLPixelFormat pf, uint32_t fourcc, int partagee) {
    NSDictionary *props = @{
        (id)kIOSurfaceWidth           : @64,
        (id)kIOSurfaceHeight          : @64,
        (id)kIOSurfaceBytesPerElement : @4,
        (id)kIOSurfacePixelFormat     : @(fourcc),
    };
    IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!surf) { printf("  %-34s IOSurface non creee\n", nom); return; }
    if (partagee) IOSurfaceSetValue(surf, CFSTR("IOSurfaceMetalSharedTexture"), kCFBooleanTrue);

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:64 height:64 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;

    fflush(stdout);
    id<MTLTexture> t = [dev newTextureWithDescriptor:td iosurface:surf plane:0];
    printf("  %-34s %s\n", nom, t ? "OK" : "nil (refusee, mais pas de plantage)");
    fflush(stdout);
    CFRelease(surf);
}

int main(void) { @autoreleasepool {
    dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("aucun peripherique Metal\n"); return 1; }
    printf("peripherique : %s\n\n", dev.name.UTF8String);

    printf("A. IOSurface ordinaire\n");
    essai("BGRA8Unorm ('BGRA')", MTLPixelFormatBGRA8Unorm, 'BGRA', 0);
    essai("RGBA8Unorm ('RGBA')", MTLPixelFormatRGBA8Unorm, 'RGBA', 0);

    printf("\nB. IOSurface marquee texture Metal partagee\n");
    printf("   (c'est ce que teste isIOSurfaceSharedMetalTexture)\n");
    essai("BGRA8Unorm partagee", MTLPixelFormatBGRA8Unorm, 'BGRA', 1);

    printf("\ntermine sans plantage\n");
    return 0;
} }
