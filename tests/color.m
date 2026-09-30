// color — la configuration de cible couleur est-elle ce qui tue les primitives ?
//  A. rendu profondeur seule, sans aucune cible couleur
//  B. meme rendu avec differents formats de pixel
//  C. variantes d'appel de dessin
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static const char *SRC =
"#include <metal_stdlib>\n#include <metal_atomic>\n using namespace metal;\n"
"vertex float4 v(uint vid [[vertex_id]], device atomic_uint *c [[buffer(1)]]) {\n"
"  atomic_fetch_add_explicit(&c[0], 1u, memory_order_relaxed);\n"
"  float2 p[4] = { float2(-0.9,-0.9), float2(0,0.9), float2(0.9,-0.9), float2(0.9,0.9) };\n"
"  return float4(p[vid % 4], 0.5, 1); }\n"
"fragment void f_void(device atomic_uint *c [[buffer(1)]]) {\n"
"  atomic_fetch_add_explicit(&c[1], 1u, memory_order_relaxed); }\n"
"fragment float4 f_col(device atomic_uint *c [[buffer(1)]]) {\n"
"  atomic_fetch_add_explicit(&c[1], 1u, memory_order_relaxed); return float4(0,1,0,1); }\n";

static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLLibrary> lib;

// pf == Invalid -> aucune cible couleur ; depth == 0 -> aucune cible profondeur
static void essai(const char *nom, MTLPixelFormat pf, int depth, int indexe, MTLPrimitiveType prim) {
    NSError *e = nil;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"v"];
    pd.fragmentFunction = [lib newFunctionWithName:(pf == MTLPixelFormatInvalid) ? @"f_void" : @"f_col"];
    if (pf != MTLPixelFormatInvalid) pd.colorAttachments[0].pixelFormat = pf;
    if (depth) pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) { printf("  %-38s pipeline refuse : %s\n", nom, e.localizedDescription.UTF8String); return; }

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    if (depth) {
        MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                      width:64 height:64 mipmapped:NO];
        dd.usage = MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModePrivate;
        rp.depthAttachment.texture = [dev newTextureWithDescriptor:dd];
        rp.depthAttachment.loadAction = MTLLoadActionClear;
        rp.depthAttachment.storeAction = MTLStoreActionDontCare;
        rp.depthAttachment.clearDepth = 1.0;
    }
    if (pf != MTLPixelFormatInvalid) {
        MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf
                                                                                      width:64 height:64 mipmapped:NO];
        cd.usage = MTLTextureUsageRenderTarget; cd.storageMode = MTLStorageModePrivate;
        rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:cd];
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionDontCare;
    }
    id<MTLBuffer> cnt = [dev newBufferWithLength:16 options:MTLResourceStorageModeManaged];
    memset(cnt.contents, 0, 16); [cnt didModifyRange:NSMakeRange(0,16)];

    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:ps]; [re setCullMode:MTLCullModeNone];
    [re setVertexBuffer:cnt offset:0 atIndex:1]; [re setFragmentBuffer:cnt offset:0 atIndex:1];
    if (indexe) {
        uint16_t idx[3] = {0,1,2};
        id<MTLBuffer> ib = [dev newBufferWithBytes:idx length:sizeof idx options:MTLResourceStorageModeManaged];
        [re drawIndexedPrimitives:prim indexCount:3 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0];
    } else {
        [re drawPrimitives:prim vertexStart:0 vertexCount:(prim == MTLPrimitiveTypeTriangleStrip ? 4 : 3)];
    }
    [re endEncoding];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl synchronizeResource:cnt]; [bl endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    uint32_t *c = cnt.contents;
    printf("  %-38s sommets=%-3u fragments=%-6u %s%s\n", nom, c[0], c[1],
           c[1] ? "-> RASTERISE" : "", cb.error ? " ERREUR GPU" : "");
}

int main(void){@autoreleasepool{
    dev = MTLCreateSystemDefaultDevice(); q = [dev newCommandQueue];
    if (!dev) { printf("aucun peripherique Metal\n"); return 1; }
    printf("peripherique : %s\n\n", dev.name.UTF8String);
    NSError *e=nil; lib = [dev newLibraryWithSource:@(SRC) options:nil error:&e];
    if(!lib){printf("compilation impossible : %s\n", e.description.UTF8String); return 2;}

    printf("A. sans aucune cible couleur\n");
    essai("profondeur seule, fragment void", MTLPixelFormatInvalid, 1, 0, MTLPrimitiveTypeTriangle);

    printf("\nB. avec cible couleur, formats varies (+ profondeur)\n");
    essai("RGBA8Unorm",      MTLPixelFormatRGBA8Unorm,     1, 0, MTLPrimitiveTypeTriangle);
    essai("BGRA8Unorm",      MTLPixelFormatBGRA8Unorm,     1, 0, MTLPrimitiveTypeTriangle);
    essai("RGBA8Unorm_sRGB", MTLPixelFormatRGBA8Unorm_sRGB,1, 0, MTLPrimitiveTypeTriangle);
    essai("R8Unorm",         MTLPixelFormatR8Unorm,        1, 0, MTLPrimitiveTypeTriangle);
    essai("RG8Unorm",        MTLPixelFormatRG8Unorm,       1, 0, MTLPrimitiveTypeTriangle);
    essai("RGBA16Float",     MTLPixelFormatRGBA16Float,    1, 0, MTLPrimitiveTypeTriangle);
    essai("RGBA32Float",     MTLPixelFormatRGBA32Float,    1, 0, MTLPrimitiveTypeTriangle);

    printf("\nC. couleur seule, sans profondeur\n");
    essai("RGBA8Unorm sans profondeur", MTLPixelFormatRGBA8Unorm, 0, 0, MTLPrimitiveTypeTriangle);

    printf("\nD. variantes d'appel de dessin (RGBA8Unorm + profondeur)\n");
    essai("dessin indexe",   MTLPixelFormatRGBA8Unorm, 1, 1, MTLPrimitiveTypeTriangle);
    essai("bande de triangles", MTLPixelFormatRGBA8Unorm, 1, 0, MTLPrimitiveTypeTriangleStrip);
    essai("lignes",          MTLPixelFormatRGBA8Unorm, 1, 0, MTLPrimitiveTypeLine);
    return 0;}}
