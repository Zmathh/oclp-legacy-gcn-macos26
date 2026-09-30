// clip — ou la geometrie se perd-elle ? On fait varier le cadrage, le clipping et la primitive.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static const char *SRC =
"#include <metal_stdlib>\n#include <metal_atomic>\n using namespace metal;\n"
"struct Out { float4 pos [[position]]; float psz [[point_size]]; };\n"
"vertex Out v_buf(uint vid [[vertex_id]], device const float2 *p [[buffer(0)]],\n"
"                 device atomic_uint *c [[buffer(1)]]) {\n"
"  atomic_fetch_add_explicit(&c[0], 1u, memory_order_relaxed);\n"
"  Out o; o.pos = float4(p[vid], 0.0, 1.0); o.psz = 24.0; return o; }\n"
"fragment float4 f_probe(device atomic_uint *c [[buffer(1)]]) {\n"
"  atomic_fetch_add_explicit(&c[1], 1u, memory_order_relaxed);\n"
"  return float4(0,1,0,1); }\n";

static id<MTLDevice> dev; static id<MTLCommandQueue> q;
static id<MTLRenderPipelineState> ps; static id<MTLTexture> tex;

static void run(const char *nom, const float *v, int n, MTLPrimitiveType prim,
                int viewport, int scissor, int clamp) {
    id<MTLBuffer> vb  = [dev newBufferWithBytes:v length:n*8 options:MTLResourceStorageModeManaged];
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
    if (viewport) [re setViewport:(MTLViewport){0,0,64,64,0,1}];
    if (scissor)  [re setScissorRect:(MTLScissorRect){0,0,64,64}];
    if (clamp)    [re setDepthClipMode:MTLDepthClipModeClamp];
    [re setCullMode:MTLCullModeNone];
    [re setVertexBuffer:vb offset:0 atIndex:0];
    [re setVertexBuffer:cnt offset:0 atIndex:1];
    [re setFragmentBuffer:cnt offset:0 atIndex:1];
    [re drawPrimitives:prim vertexStart:0 vertexCount:n];
    [re endEncoding];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl synchronizeResource:cnt]; [bl synchronizeResource:tex]; [bl endEncoding];
    [cb commit]; [cb waitUntilCompleted];

    uint32_t *c = cnt.contents;
    uint8_t p[4]; [tex getBytes:p bytesPerRow:64*4 fromRegion:MTLRegionMake2D(32,32,1,1) mipmapLevel:0];
    printf("  %-40s sommets=%-3u fragments=%-6u pixel V=%-3d %s%s\n",
           nom, c[0], c[1], p[1], c[1] ? "" : "<- rien de rasterise",
           cb.error ? " ERREUR GPU" : "");
}

int main(void) { @autoreleasepool {
    dev = MTLCreateSystemDefaultDevice(); q = [dev newCommandQueue];
    printf("peripherique : %s\n\n", dev.name.UTF8String);
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(SRC) options:nil error:&e];
    if (!lib) { printf("compilation impossible : %s\n", e.description.UTF8String); return 2; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:64 height:64 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeManaged;
    tex = [dev newTextureWithDescriptor:td];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"v_buf"];
    pd.fragmentFunction = [lib newFunctionWithName:@"f_probe"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) { printf("pipeline impossible : %s\n", e.description.UTF8String); return 3; }

    float deborde[6] = { -3,-1,  1,3,  1,-1 };            // exige un decoupage
    float dedans[6]  = { -0.9f,-0.9f,  0,0.9f,  0.9f,-0.9f }; // entierement dans le volume de vue
    float bord[6]    = { -1,-1,  0,1,  1,-1 };             // pile sur les bords
    float inverse[6] = { 1,-1,  0,0.9f,  -0.9f,-0.9f };    // enroulement inverse
    float point[2]   = { 0, 0 };

    printf("A. geometrie\n");
    run("triangle debordant (exige clipping)", deborde, 3, MTLPrimitiveTypeTriangle, 0,0,0);
    run("triangle entierement dedans",         dedans,  3, MTLPrimitiveTypeTriangle, 0,0,0);
    run("triangle pile sur les bords",         bord,    3, MTLPrimitiveTypeTriangle, 0,0,0);
    run("triangle enroulement inverse",        inverse, 3, MTLPrimitiveTypeTriangle, 0,0,0);
    run("point central",                       point,   1, MTLPrimitiveTypePoint,    0,0,0);
    printf("\nB. cadrage impose explicitement\n");
    run("dedans + viewport",                   dedans,  3, MTLPrimitiveTypeTriangle, 1,0,0);
    run("dedans + scissor",                    dedans,  3, MTLPrimitiveTypeTriangle, 0,1,0);
    run("dedans + viewport + scissor",         dedans,  3, MTLPrimitiveTypeTriangle, 1,1,0);
    run("debordant + viewport + scissor",      deborde, 3, MTLPrimitiveTypeTriangle, 1,1,0);
    run("debordant + clipping en clamp",       deborde, 3, MTLPrimitiveTypeTriangle, 1,1,1);
    return 0;
} }
