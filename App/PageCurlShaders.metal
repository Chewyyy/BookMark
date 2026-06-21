#include <metal_stdlib>
using namespace metal;

struct PageCurlVertexIn {
    float2 position;
    float2 texCoord;
    float shade;
};

struct PageCurlVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float shade;
};

struct PageCurlUniforms {
    float opacity;
};

vertex PageCurlVertexOut bookmarkPageCurlVertex(const device PageCurlVertexIn *vertices [[buffer(0)]],
                                                uint vertexID [[vertex_id]]) {
    PageCurlVertexIn input = vertices[vertexID];
    PageCurlVertexOut output;
    output.position = float4(input.position, 0.0, 1.0);
    output.texCoord = input.texCoord;
    output.shade = input.shade;
    return output;
}

fragment half4 bookmarkPageCurlFragment(PageCurlVertexOut input [[stage_in]],
                                        texture2d<half> pageTexture [[texture(0)]],
                                        sampler pageSampler [[sampler(0)]],
                                        constant PageCurlUniforms &uniforms [[buffer(0)]]) {
    half4 color = pageTexture.sample(pageSampler, input.texCoord);
    color.rgb *= half(input.shade);
    color.a *= half(uniforms.opacity);
    return color;
}
