// catt2 — verification elargie de la correspondance de la piece jointe couleur.
// La premiere identification ne portait que sur 7 configurations ; celle-ci en couvre une
// vingtaine (formats, masques, melanges separes couleur/alpha) afin de valider la traduction
// sur toute l'etendue des champs et pas seulement sur les quelques bits deja vus.
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
    if (!ps) fprintf(stderr, "  (refuse : %s)\n", e.localizedDescription.UTF8String);
}
#define FMT(n, f) cfg(n, ^(MTLRenderPipelineColorAttachmentDescriptor *a){ a.pixelFormat = f; })

int main(void) { @autoreleasepool {
    dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("aucun peripherique Metal\n"); return 1; }
    NSError *e = nil; lib = [dev newLibraryWithSource:@(SRC) options:nil error:&e];
    if (!lib) { printf("compilation impossible : %s\n", e.description.UTF8String); return 2; }
    fprintf(stderr, "peripherique : %s\n", dev.name.UTF8String);

    cfg("reference RGBA8Unorm", ^(MTLRenderPipelineColorAttachmentDescriptor *a){ });
    FMT("format BGRA8Unorm",       MTLPixelFormatBGRA8Unorm);
    FMT("format RGBA8Unorm_sRGB",  MTLPixelFormatRGBA8Unorm_sRGB);
    FMT("format BGRA8Unorm_sRGB",  MTLPixelFormatBGRA8Unorm_sRGB);
    FMT("format RGBA16Float",      MTLPixelFormatRGBA16Float);
    FMT("format RGBA32Float",      MTLPixelFormatRGBA32Float);
    FMT("format R8Unorm",          MTLPixelFormatR8Unorm);
    FMT("format RG8Unorm",         MTLPixelFormatRG8Unorm);
    FMT("format R16Float",         MTLPixelFormatR16Float);
    FMT("format RGB10A2Unorm",     MTLPixelFormatRGB10A2Unorm);
    FMT("format BGR10A2Unorm",     MTLPixelFormatBGR10A2Unorm);
    FMT("format RG11B10Float",     MTLPixelFormatRG11B10Float);
    FMT("format RGBA16Snorm",      MTLPixelFormatRGBA16Snorm);

    for (int m = 0; m <= 15; m++) {
        char nom[64]; snprintf(nom, sizeof nom, "masque d'ecriture 0x%x", m);
        cfg(nom, ^(MTLRenderPipelineColorAttachmentDescriptor *a){ a.writeMask = (MTLColorWriteMask)m; });
    }

    cfg("melange add, srcAlpha/oneMinusSrcAlpha", ^(MTLRenderPipelineColorAttachmentDescriptor *a){
        a.blendingEnabled = YES; a.rgbBlendOperation = MTLBlendOperationAdd;
        a.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        a.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha; });
    cfg("melange subtract, one/zero", ^(MTLRenderPipelineColorAttachmentDescriptor *a){
        a.blendingEnabled = YES; a.rgbBlendOperation = MTLBlendOperationSubtract;
        a.sourceRGBBlendFactor = MTLBlendFactorOne;
        a.destinationRGBBlendFactor = MTLBlendFactorZero; });
    cfg("melange reverseSubtract, dst/src", ^(MTLRenderPipelineColorAttachmentDescriptor *a){
        a.blendingEnabled = YES; a.rgbBlendOperation = MTLBlendOperationReverseSubtract;
        a.sourceRGBBlendFactor = MTLBlendFactorDestinationColor;
        a.destinationRGBBlendFactor = MTLBlendFactorSourceColor; });
    cfg("melange min", ^(MTLRenderPipelineColorAttachmentDescriptor *a){
        a.blendingEnabled = YES; a.rgbBlendOperation = MTLBlendOperationMin; });
    cfg("melange max", ^(MTLRenderPipelineColorAttachmentDescriptor *a){
        a.blendingEnabled = YES; a.rgbBlendOperation = MTLBlendOperationMax; });
    cfg("alpha separe : add / srcAlpha,zero", ^(MTLRenderPipelineColorAttachmentDescriptor *a){
        a.blendingEnabled = YES;
        a.alphaBlendOperation = MTLBlendOperationAdd;
        a.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        a.destinationAlphaBlendFactor = MTLBlendFactorZero; });
    cfg("alpha separe : subtract / one,one", ^(MTLRenderPipelineColorAttachmentDescriptor *a){
        a.blendingEnabled = YES;
        a.alphaBlendOperation = MTLBlendOperationSubtract;
        a.sourceAlphaBlendFactor = MTLBlendFactorOne;
        a.destinationAlphaBlendFactor = MTLBlendFactorOne; });
    cfg("melange + masque rouge + BGRA", ^(MTLRenderPipelineColorAttachmentDescriptor *a){
        a.pixelFormat = MTLPixelFormatBGRA8Unorm;
        a.writeMask = MTLColorWriteMaskRed;
        a.blendingEnabled = YES;
        a.rgbBlendOperation = MTLBlendOperationAdd;
        a.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        a.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha; });
    return 0;
} }
