// stages — les etages sommets et fragments s'executent-ils reellement ?
// Chaque shader incremente un compteur en memoire : on lit ensuite qui a tourne.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static const char *SRC =
"#include <metal_stdlib>\n#include <metal_atomic>\n using namespace metal;\n"
"vertex float4 v_probe(uint vid [[vertex_id]], device atomic_uint *c [[buffer(1)]]) {\n"
"  atomic_fetch_add_explicit(&c[0], 1u, memory_order_relaxed);\n"
"  float2 p[3] = { float2(-3,-1), float2(1,3), float2(1,-1) };\n"
"  return float4(p[vid], 0, 1); }\n"
"fragment float4 f_probe(device atomic_uint *c [[buffer(1)]]) {\n"
"  atomic_fetch_add_explicit(&c[1], 1u, memory_order_relaxed);\n"
"  return float4(0,1,0,1); }\n";

int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q = [dev newCommandQueue];
    printf("peripherique : %s\n\n", dev.name.UTF8String);
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(SRC) options:nil error:&e];
    if (!lib) { printf("compilation impossible : %s\n", e.description.UTF8String); return 2; }

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:64 height:64 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeManaged;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];

    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction   = [lib newFunctionWithName:@"v_probe"];
    pd.fragmentFunction = [lib newFunctionWithName:@"f_probe"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) { printf("creation du pipeline impossible : %s\n", e.description.UTF8String); return 3; }
    printf("pipeline cree OK\n");

    id<MTLBuffer> cnt = [dev newBufferWithLength:16 options:MTLResourceStorageModeManaged];
    memset(cnt.contents, 0, 16); [cnt didModifyRange:NSMakeRange(0,16)];

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = tex;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0,0,1,1);

    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:ps];
    [re setVertexBuffer:cnt offset:0 atIndex:1];
    [re setFragmentBuffer:cnt offset:0 atIndex:1];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl synchronizeResource:cnt]; [bl synchronizeResource:tex]; [bl endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    if (cb.error) printf("erreur GPU : %s\n", cb.error.localizedDescription.UTF8String);

    uint32_t *c = cnt.contents;
    uint8_t p[4]; [tex getBytes:p bytesPerRow:64*4 fromRegion:MTLRegionMake2D(32,32,1,1) mipmapLevel:0];
    printf("\n  invocations du shader de sommets   : %u   %s\n", c[0], c[0] ? "-> l'etage sommets TOURNE" : "-> etage sommets MUET");
    printf("  invocations du shader de fragments : %u   %s\n", c[1], c[1] ? "-> l'etage fragments TOURNE" : "-> etage fragments MUET");
    printf("  pixel resultant                    : R=%d V=%d B=%d\n", p[0], p[1], p[2]);
    printf("\ndiagnostic : ");
    if (!c[0])            printf("rien n'est rasterise, l'etage sommets ne demarre pas\n");
    else if (!c[1])       printf("les sommets tournent mais aucun fragment n'est produit (clipping ou assemblage des primitives)\n");
    else if (p[1] < 200)  printf("les deux etages tournent, l'ecriture dans la cible de rendu est perdue (blend / masque / store)\n");
    else                  printf("tout fonctionne\n");
    return 0;
} }
