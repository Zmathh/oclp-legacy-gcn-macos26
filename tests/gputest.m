// gputest — isole l'etage defaillant : calcul, rasterisation, recopie.
// Aucune injection, aucun correctif : on interroge le pilote tel qu'il est installe.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static id<MTLDevice> dev; static id<MTLCommandQueue> q;
static int total, ok;
static void verdict(const char *nom, int bon, const char *detail) {
    total++; ok += bon ? 1 : 0;
    printf("  %-42s %s%s%s\n", nom, bon ? "OK" : "ECHEC", detail[0] ? "  " : "", detail);
}
static id<MTLTexture> newtex(void) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:64 height:64 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    td.storageMode = MTLStorageModeManaged;
    return [dev newTextureWithDescriptor:td];
}
static void px(id<MTLTexture> t, uint8_t *o) {
    [t getBytes:o bytesPerRow:64*4 fromRegion:MTLRegionMake2D(32,32,1,1) mipmapLevel:0];
}
static void sync_tex(id<MTLCommandBuffer> cb, id<MTLResource> r) {
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder]; [b synchronizeResource:r]; [b endEncoding];
}

static const char *SRC =
"#include <metal_stdlib>\n using namespace metal;\n"
"vertex float4 v_id(uint vid [[vertex_id]]) {\n"
"  float2 p[3] = { float2(-3,-1), float2(1,3), float2(1,-1) };\n"
"  return float4(p[vid], 0, 1); }\n"
"struct VIn { float2 pos [[attribute(0)]]; };\n"
"vertex float4 v_buf(VIn i [[stage_in]]) { return float4(i.pos, 0, 1); }\n"
"fragment float4 f_vert() { return float4(0,1,0,1); }\n"
"kernel void k_buf(device uint *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i] = i + 100; }\n"
"kernel void k_tex(texture2d<float, access::write> t [[texture(0)]], uint2 g [[thread_position_in_grid]]) {\n"
"  t.write(float4(0,1,0,1), g); }\n";

int main(void) { @autoreleasepool {
    dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("aucun peripherique Metal\n"); return 1; }
    q = [dev newCommandQueue];
    printf("peripherique : %s\n", dev.name.UTF8String);
    printf("familles     : Apple? %d  Mac2? %d  Common3? %d\n",
           (int)[dev supportsFamily:MTLGPUFamilyApple1], (int)[dev supportsFamily:MTLGPUFamilyMac2],
           (int)[dev supportsFamily:MTLGPUFamilyCommon3]);

    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(SRC) options:nil error:&e];
    if (!lib) { printf("compilation des shaders IMPOSSIBLE : %s\n", e.description.UTF8String); return 2; }
    printf("\nA. chemin sans shader\n");

    // A1 effacement
    id<MTLTexture> t = newtex();
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(1,0,0,1);
    id<MTLCommandBuffer> cb = [q commandBuffer];
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    sync_tex(cb, t); [cb commit]; [cb waitUntilCompleted];
    uint8_t p[4]; px(t, p);
    verdict("effacement vers rouge", p[0] > 200 && p[1] < 50, cb.error ? cb.error.localizedDescription.UTF8String : "");

    // A2 recopie tampon -> tampon
    uint32_t seed[16]; for (int i=0;i<16;i++) seed[i] = i + 7;
    id<MTLBuffer> b1 = [dev newBufferWithBytes:seed length:sizeof seed options:MTLResourceStorageModeManaged];
    id<MTLBuffer> b2 = [dev newBufferWithLength:sizeof seed options:MTLResourceStorageModeManaged];
    cb = [q commandBuffer];
    { id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
      [bl copyFromBuffer:b1 sourceOffset:0 toBuffer:b2 destinationOffset:0 size:sizeof seed];
      [bl synchronizeResource:b2]; [bl endEncoding]; }
    [cb commit]; [cb waitUntilCompleted];
    verdict("recopie tampon -> tampon", memcmp(b2.contents, seed, sizeof seed) == 0, "");

    printf("\nB. chemin calcul (shaders, sans rasterisation)\n");
    // B1 calcul -> tampon
    id<MTLComputePipelineState> cps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k_buf"] error:&e];
    if (!cps) verdict("pipeline de calcul", 0, e.description.UTF8String);
    else {
        id<MTLBuffer> out = [dev newBufferWithLength:64*4 options:MTLResourceStorageModeManaged];
        cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:cps]; [ce setBuffer:out offset:0 atIndex:0];
        [ce dispatchThreads:MTLSizeMake(64,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];
        [ce endEncoding]; sync_tex(cb, out); [cb commit]; [cb waitUntilCompleted];
        uint32_t *o = out.contents; int bon = (o[0]==100 && o[17]==117 && o[63]==163);
        char d[96]; snprintf(d, sizeof d, "out[0]=%u out[17]=%u out[63]=%u", o[0], o[17], o[63]);
        verdict("calcul ecrit dans un tampon", bon, d);
    }
    // B2 calcul -> texture
    id<MTLComputePipelineState> cpt = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k_tex"] error:&e];
    if (!cpt) verdict("pipeline de calcul (texture)", 0, e.description.UTF8String);
    else {
        id<MTLTexture> t2 = newtex();
        cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:cpt]; [ce setTexture:t2 atIndex:0];
        [ce dispatchThreads:MTLSizeMake(64,64,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
        [ce endEncoding]; sync_tex(cb, t2); [cb commit]; [cb waitUntilCompleted];
        uint8_t c[4]; px(t2, c);
        char d[64]; snprintf(d, sizeof d, "R=%d V=%d B=%d", c[0], c[1], c[2]);
        verdict("calcul ecrit dans une texture", c[1] > 200 && c[0] < 50, d);
    }

    printf("\nC. chemin rasterisation (shaders + dessin)\n");
    id<MTLFunction> fv = [lib newFunctionWithName:@"f_vert"];
    // C1 vertex_id, sans tampon de sommets
    { MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
      pd.vertexFunction = [lib newFunctionWithName:@"v_id"]; pd.fragmentFunction = fv;
      pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
      id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
      if (!ps) verdict("pipeline (vertex_id)", 0, e.description.UTF8String);
      else {
        id<MTLTexture> t3 = newtex();
        rp.colorAttachments[0].texture = t3; rp.colorAttachments[0].clearColor = MTLClearColorMake(0,0,1,1);
        cb = [q commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:ps];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding]; sync_tex(cb, t3); [cb commit]; [cb waitUntilCompleted];
        uint8_t c[4]; px(t3, c); char d[80];
        snprintf(d, sizeof d, "R=%d V=%d B=%d%s", c[0],c[1],c[2], cb.error?" (erreur GPU)":"");
        verdict("triangle via vertex_id", c[1] > 200, d);
      } }
    // C2 avec tampon de sommets explicite
    { float verts[6] = { -3,-1, 1,3, 1,-1 };
      id<MTLBuffer> vb = [dev newBufferWithBytes:verts length:sizeof verts options:MTLResourceStorageModeManaged];
      MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
      vd.attributes[0].format = MTLVertexFormatFloat2; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0;
      vd.layouts[0].stride = 8;
      MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
      pd.vertexFunction = [lib newFunctionWithName:@"v_buf"]; pd.fragmentFunction = fv;
      pd.vertexDescriptor = vd; pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
      id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
      if (!ps) verdict("pipeline (tampon de sommets)", 0, e.description.UTF8String);
      else {
        id<MTLTexture> t4 = newtex();
        rp.colorAttachments[0].texture = t4;
        cb = [q commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:ps]; [re setVertexBuffer:vb offset:0 atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding]; sync_tex(cb, t4); [cb commit]; [cb waitUntilCompleted];
        uint8_t c[4]; px(t4, c); char d[80];
        snprintf(d, sizeof d, "R=%d V=%d B=%d%s", c[0],c[1],c[2], cb.error?" (erreur GPU)":"");
        verdict("triangle via tampon de sommets", c[1] > 200, d);
      } }

    printf("\n%d/%d reussis\n", ok, total);
    return 0;
} }
