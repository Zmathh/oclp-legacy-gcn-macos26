// catt — identifie les champs de MTLRenderPipelineColorAttachmentDescriptorInternal,
// la seule structure privee que le pilote consulte et que la couche livree ne traduit pas.
// On cree plusieurs pipelines ne differant que par un reglage connu, et on releve la structure
// a chaque fois : l'octet qui bouge est le champ. Rien n'est traduit, rien n'est modifie.
//
// Le releveur est dans catt_hook.m ; ce programme ne fait que produire les configurations.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static id<MTLDevice> dev; static id<MTLLibrary> lib;

static const char *SRC =
"#include <metal_stdlib>\n using namespace metal;\n"
"vertex float4 v(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(0,1),float2(1,-1)};\n"
"  return float4(p[i],0,1); }\n"
"fragment float4 f() { return float4(0,1,0,1); }\n";

static void cfg(const char *nom, void (^regler)(MTLRenderPipelineColorAttachmentDescriptor *)) {
    NSError *e = nil;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction   = [lib newFunctionWithName:@"v"];
    pd.fragmentFunction = [lib newFunctionWithName:@"f"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    regler(pd.colorAttachments[0]);
    fprintf(stderr, "\n########## %s\n", nom);
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) fprintf(stderr, "  (pipeline refuse : %s)\n", e.localizedDescription.UTF8String);
}

int main(void) { @autoreleasepool {
    dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("aucun peripherique Metal\n"); return 1; }
    NSError *e = nil; lib = [dev newLibraryWithSource:@(SRC) options:nil error:&e];
    if (!lib) { printf("compilation impossible : %s\n", e.description.UTF8String); return 2; }
    fprintf(stderr, "peripherique : %s\n", dev.name.UTF8String);

    cfg("reference : RGBA8Unorm, masque complet, sans melange",
        ^(MTLRenderPipelineColorAttachmentDescriptor *a){ });
    cfg("format BGRA8Unorm",
        ^(MTLRenderPipelineColorAttachmentDescriptor *a){ a.pixelFormat = MTLPixelFormatBGRA8Unorm; });
    cfg("format RGBA16Float",
        ^(MTLRenderPipelineColorAttachmentDescriptor *a){ a.pixelFormat = MTLPixelFormatRGBA16Float; });
    cfg("masque d'ecriture = rouge seul",
        ^(MTLRenderPipelineColorAttachmentDescriptor *a){ a.writeMask = MTLColorWriteMaskRed; });
    cfg("masque d'ecriture = aucun",
        ^(MTLRenderPipelineColorAttachmentDescriptor *a){ a.writeMask = MTLColorWriteMaskNone; });
    cfg("melange active (add, srcAlpha / oneMinusSrcAlpha)",
        ^(MTLRenderPipelineColorAttachmentDescriptor *a){
            a.blendingEnabled = YES;
            a.rgbBlendOperation = MTLBlendOperationAdd;
            a.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
            a.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha; });
    cfg("melange active (subtract, one / zero)",
        ^(MTLRenderPipelineColorAttachmentDescriptor *a){
            a.blendingEnabled = YES;
            a.rgbBlendOperation = MTLBlendOperationSubtract;
            a.sourceRGBBlendFactor = MTLBlendFactorOne;
            a.destinationRGBBlendFactor = MTLBlendFactorZero; });
    return 0;
} }
