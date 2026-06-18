#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 bookmarkPageCurl(float2 position, SwiftUI::Layer layer, float2 size, float progress, float direction) {
    float p = clamp(progress, 0.0, 1.0);
    float safeWidth = max(size.x, 1.0);
    float safeHeight = max(size.y, 1.0);
    float forward = direction >= 0.0 ? 1.0 : -1.0;

    float normalizedX = position.x / safeWidth;
    float pageX = forward > 0.0 ? normalizedX : 1.0 - normalizedX;
    float pageY = position.y / safeHeight;
    float vertical = pageY - 0.5;

    // The fold starts near the outside edge and moves inward as the drag commits.
    float foldFront = mix(0.96, 0.16, p);
    float distanceFromFold = pageX - foldFront;
    float curledArea = smoothstep(-0.02, 0.36, distanceFromFold);
    float foldBand = exp(-pow(distanceFromFold * 13.0, 2.0));
    float outerEdge = smoothstep(0.78, 1.0, pageX);
    float curlArc = sin(clamp(distanceFromFold / 0.42, 0.0, 1.0) * M_PI_F) * curledArea * p;

    float2 samplePosition = position;
    samplePosition.x -= forward * (curlArc * 54.0 + curledArea * p * 46.0);
    samplePosition.y += vertical * curlArc * 22.0;

    half4 color = layer.sample(samplePosition);

    float creaseLight = foldBand * p;
    float foldShadow = smoothstep(0.02, 0.36, distanceFromFold) * p;
    float innerShadow = exp(-pow((pageX - max(0.06, foldFront - 0.10)) * 18.0, 2.0)) * p;
    float edgeFade = outerEdge * p;

    color.rgb += half3(creaseLight * 0.30);
    color.rgb *= half(max(0.50, 1.0 - foldShadow * 0.22 - innerShadow * 0.16));
    color.a *= half(1.0 - edgeFade * 0.12);

    return color;
}
