#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] half4 waterEffect(
    float2 position,
    half4 color,
    float time,
    float2 size,
    half4 waterColor,
    float intensity
) {
    float2 uv = position / size;

    // --- Caustic light rays from above ---
    // Rays converge from the top, fanning downward
    float rays = 0.0;
    float2 source = float2(0.9, -0.12);

    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        // Each ray has a slightly different angle and drift speed
        float offset = sin(time * (0.3 + fi * 0.07) + fi * 1.3) * 0.28;
        float2 rayDir = normalize(float2(offset + fi * 0.14 - 0.4, 1.0));

        // Signed distance to ray line from source
        float2 toPixel = uv - source;
        float along = dot(toPixel, rayDir);
        float perp = length(toPixel - along * rayDir);

        // Ray only exists going downward from source
        float rayMask = step(0.0, along);

        // Soft beam: narrow bright core, wide soft halo
        float beam = exp(-perp * perp * 180.0) * 0.25
                   + exp(-perp * perp * 40.0)  * 0.15;

        // Fade with depth (rays dim as they travel down)
        float depthFade = exp(-along * 1.2);

        rays += beam * depthFade * rayMask;
    }

    // --- Gentle surface caustics (wavy light patches on the floor) ---
    float cx = sin(uv.x * 8.0 + time * 0.9) * sin(uv.y * 6.0 + time * 0.6);
    float cy = sin(uv.x * 5.0 - time * 0.7) * sin(uv.y * 9.0 + time * 0.5);
    float caustics = max(0.0, cx + cy) * 0.18 * intensity;

    // More intense caustics near the bottom (floor effect)
    caustics *= 0.3 + uv.y * 0.9;

    // --- Depth fog: scene gets darker and more blue with depth ---
    float depth = uv.y;
    float fogAmount = depth * 0.55;

    // --- Water surface ripple distorts the ray edges slightly ---
    float surfaceRipple = sin(uv.x * 14.0 + time * 1.3) * 0.012
                        + sin(uv.x * 9.0  - time * 0.9) * 0.008;

    // Attenuate rays near top to simulate surface entry scatter
    float surfaceScatter = smoothstep(0.0, 0.18, uv.y + surfaceRipple) * 0.6 + 0.4;

    // --- Compose ---
    float rayContrib = rays * intensity * surfaceScatter * 0.7;

    // Deep water base: shift toward darker, cooler blue with depth
    half3 shallowColor = half3(waterColor.rgb) * half(1.1);
    half3 deepColor    = half3(waterColor.r * 0.3, waterColor.g * 0.55, waterColor.b * 0.85);
    half3 baseColor    = mix(shallowColor, deepColor, half(fogAmount));

    // Add light rays as a warm-white tint over base
    half3 rayLight  = half3(0.92, 0.97, 0.5) * half(rayContrib);
    half3 causLight = half3(0.8,  0.95, 1.0) * half(caustics);

    half3 finalColor = baseColor + rayLight + causLight;

    // Slight vignette at edges for underwater lens feel
    float vignette = 1.0 - smoothstep(0.3, 1.0, length(uv - float2(0.5, 0.5)) * 1.2);
    finalColor *= half(0.75 + vignette * 0.25);

    return half4(finalColor, 1.0);
}
