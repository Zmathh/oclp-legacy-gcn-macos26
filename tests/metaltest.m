// Test Metal minimal : device -> clear (fonction fixe) -> pipeline de rendu + shaders.
// But : distinguer un GPU qui ne dessine rien d'un GPU dont seuls les pipelines/shaders échouent.
// Compilation : clang -fobjc-arc -framework Metal -framework Foundation -o metaltest metaltest.m
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static const char *kShaders =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "vertex float4 v_main(uint vid [[vertex_id]]) {\n"
    "    float2 p[3] = { float2(-3.0, -1.0), float2(1.0, 3.0), float2(1.0, -1.0) };\n"
    "    return float4(p[vid], 0.0, 1.0);\n"
    "}\n"
    "fragment float4 f_main() { return float4(0.0, 1.0, 0.0, 1.0); }\n";

static void readPixel(id<MTLTexture> tex, uint8_t *out) {
    [tex getBytes:out bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(32, 32, 1, 1) mipmapLevel:0];
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("ECHEC: aucun device Metal\n"); return 1; }
        printf("device       : %s\n", dev.name.UTF8String);
        printf("low power    : %d | removable : %d\n", (int)dev.isLowPower, (int)dev.isRemovable);

        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:64 height:64 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        if (!tex || !queue) { printf("ECHEC: texture ou command queue nulle\n"); return 1; }

        // --- Etape 1 : effacement en rouge (chemin fonction fixe, sans shader) ---
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = tex;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc endEncoding];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:tex];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) printf("erreur command buffer (clear) : %s\n", cb.error.description.UTF8String);
        uint8_t px[4] = {0};
        readPixel(tex, px);
        printf("ETAPE 1 clear : R=%d V=%d B=%d A=%d  -> %s\n", px[0], px[1], px[2], px[3],
               (px[0] > 200 && px[1] < 50) ? "OK (rouge)" : "ECHEC");

        // --- Etape 2 : pipeline de rendu + shaders (ce que corrige l'impostor) ---
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(kShaders) options:nil error:&err];
        if (!lib) { printf("ETAPE 2 : compilation shaders ECHEC : %s\n", err.description.UTF8String); return 2; }
        printf("ETAPE 2 : shaders compiles OK\n");

        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v_main"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f_main"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pso) { printf("ETAPE 2 : creation du pipeline ECHEC : %s\n", err.description.UTF8String); return 3; }
        printf("ETAPE 2 : pipeline cree OK\n");

        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 1.0, 1.0); // bleu
        cb = [queue commandBuffer];
        enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pso];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        blit = [cb blitCommandEncoder];
        [blit synchronizeResource:tex];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) printf("erreur command buffer (draw) : %s\n", cb.error.description.UTF8String);
        readPixel(tex, px);
        printf("ETAPE 2 dessin : R=%d V=%d B=%d A=%d  -> %s\n", px[0], px[1], px[2], px[3],
               (px[1] > 200 && px[0] < 50) ? "OK (vert, triangle dessine)"
                                           : (px[2] > 200 ? "ECHEC (reste bleu : rien n'est dessine)"
                                                          : "ECHEC (couleur inattendue)"));
        return 0;
    }
}
