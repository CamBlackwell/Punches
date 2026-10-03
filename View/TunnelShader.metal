#include <metal_stdlib>
using namespace metal;

// ============================================================================
// tunnelEffect
//
// Metal port of the fractal-folded raymarched tunnel originally written as a
// Shadertoy fragment shader, "RayMarching starting point," by Martijn
// Steinrucken — aka The Art of Code / BigWings (2020). Released by the
// original author under the MIT License. This is a derivative port adapted
// to run as a SwiftUI `colorEffect` (no camera texture/reflection map, since
// SwiftUI shaders don't have a cubemap channel — replaced with a small
// procedural sky gradient) and to expose speed/tint/intensity as uniforms so
// it can slot into ThemeManager like the water and fog effects.
//
// Credit: Martijn Steinrucken (The Art of Code / BigWings), 2020, MIT License.
//
// ----------------------------------------------------------------------------
// PERFORMANCE NOTES
// Raymarching is inherently expensive: this is a nested loop (march steps x
// fractal folds) evaluated per pixel, per frame. Two things keep it off a
// cliff on a phone GPU:
//   1. `qualitySteps` / `qualityFolds` are uniforms, not compile-time
//      constants — the Swift side can pass a lower budget for a "Low
//      quality" tier instead of shipping a second shader.
//   2. The hot loop runs in `half` precision. Apple GPUs execute half-float
//      math roughly 2x faster than float, and the visual result here — soft
//      background art, usually viewed slightly blurred/upscaled anyway — does
//      not benefit from float precision.
// The other big lever (render resolution) lives on the Swift side, in
// TunnelShaderView, since a shader can't downsample its own output.
// ----------------------------------------------------------------------------
// ============================================================================

static half2 rot2(half2 uv, half a) {
    half s = sin(a), c = cos(a);
    return half2(c * uv.x - s * uv.y, s * uv.x + c * uv.y);
}

static half tunnelDist(half3 p, half time, int foldIterations) {
    half2 uv = p.xz;
    uv.x = abs(uv.x);

    half t = 12.0h + time;
    half2 q = half2(1.0h, 0.0h);

    half th = 0.4h * p.y - 0.6h * t;
    half m = 1.8h;

    for (int i = 0; i < foldIterations; i++) {
        uv -= m * q;
        th += 0.5h * p.y + 0.05h * t;
        uv = rot2(uv, th);
        uv.x = abs(uv.x);
        m *= 0.05h * cos(8.0h * length(uv)) + 0.55h;
    }

    half d = length(uv) - 2.0h * m;
    return 0.5h * d;
}

static half tunnelMarch(half3 ro, half3 rd, half time, int maxSteps, int foldIterations) {
    half dO = 0.0h;
    for (int i = 0; i < maxSteps; i++) {
        half3 p = ro + rd * dO;
        half dS = tunnelDist(p, time, foldIterations);
        dO += dS;
        if (dO > 10.0h || abs(dS) < 0.003h) break;
    }
    return dO;
}

static half3 tunnelNormal(half3 p, half time, int foldIterations) {
    half d = tunnelDist(p, time, foldIterations);
    half2 e = half2(0.002h, 0.0h);
    half3 n = d - half3(
        tunnelDist(p - e.xyy, time, foldIterations),
        tunnelDist(p - e.yxy, time, foldIterations),
        tunnelDist(p - e.yyx, time, foldIterations));
    return normalize(n);
}

static half3 tunnelRayDir(half2 uv, half3 p, half3 l, half z) {
    half3 f = normalize(l - p);
    half3 r = normalize(cross(half3(0.0h, 1.0h, 0.0h), f));
    half3 u = cross(f, r);
    half3 c = f * z;
    half3 i = c + uv.x * r + uv.y * u;
    return normalize(i);
}

// IQ-style cosine palette, used in place of the original's texture lookup.
static half3 tunnelPalette(half t, half3 a, half3 b, half3 c, half3 d) {
    return a + b * cos(6.28318h * (c * t + d));
}

[[ stitchable ]] half4 tunnelEffect(
    float2 position,
    half4 color,
    float time,
    float2 size,
    half4 tintColor,
    float speed,
    float intensity,
    float qualitySteps,      // e.g. 60 (low) ... 200 (high)
    float qualityFolds,       // e.g. 5 (low) ... 9 (high)
    texture2d<half, access::sample> blueNoise   // 64x64 tiling noise, for the dither below
) {
    half2 uv = half2((position - 0.5 * size) / size.y);
    half t = half(time * speed);
    int maxSteps = max(1, int(qualitySteps));
    int foldIterations = max(1, int(qualityFolds));

    half r = 5.5h;
    half3 ro = half3(r, 0.1h * t, 0.0h);
    half3 rd = tunnelRayDir(uv, ro, half3(0.0h, 0.1h * t, 0.0h), 2.0h);

    half3 col = half3(0.0h);
    half d = tunnelMarch(ro, rd, t, maxSteps, foldIterations);

    if (d < 10.0h) {
        half3 p = ro + rd * d;
        half3 n = tunnelNormal(p, t, foldIterations);
        half3 rf = reflect(rd, n);

        half ambient = 0.3h;
        half difPower = 0.4h;
        half dif = max(dot(n, normalize(half3(1.0h, 2.0h, 3.0h))), 0.0h);
        col = half3(dif * difPower + ambient);

        // Procedural sky substitute for the original's iChannel0 reflection map.
        half3 skyLow = half3(0.04h, 0.05h, 0.09h);
        half3 skyHigh = half3(0.55h, 0.7h, 0.9h);
        half3 sky = mix(skyLow, skyHigh, clamp(rf.y * 0.5h + 0.5h, 0.0h, 1.0h));
        col *= sky;
        col *= 1.0h + rf.y;
        col = clamp(col, 0.0h, 1.0h);

        half3 e = half3(1.0h);
        half3 tint = half3(tintColor.r, tintColor.g, tintColor.b);
        //col *= tunnelPalette(rf.y, e, e, e, 0.35h * tint);
    }

    col = pow(col, half3(0.4545h)); // gamma correction
    col = clamp(col * half(intensity), 0.0h, 1.0h);

    // Tiled blue-noise dither before quantisation. The raymarched gradients are
    // very shallow over long stretches, which is exactly where 8-bit output
    // bands; a sub-LSB noise offset removes it. One linear-filtered tap on a
    // 64x64 tile, so the repeat is not perceptible at this amplitude.
    constexpr sampler blueNoiseSampler(address::repeat, filter::linear);
    half3 dither = half3(blueNoise.sample(blueNoiseSampler, position / 64.0f).rgb - 0.5h);
    col = clamp(col + dither * (1.0h / 255.0h), 0.0h, 1.0h);

    return half4(col, color.a);
}

// ============================================================================
// grainOverlay
//
// A one-tap blue-noise grain pass. Applied as a second `colorEffect` over the
// tunnel so the grain lands at full resolution, *after* the low-res buffer has
// been scaled up — applying it inside the raymarched pass would smear the
// grain along with everything else.
//
// `position` and `color` are supplied by SwiftUI and must stay as the first two
// parameters; only the trailing arguments are passed at the call site.
// ----------------------------------------------------------------------------
[[ stitchable ]] half4 grainOverlay(
    float2 position,
    half4 color,
    texture2d<half, access::sample> blueNoise,
    float strength
) {
    constexpr sampler blueNoiseSampler(address::repeat, filter::linear);
    float2 uv = position / 64.0f;
    half3 grain = half3(blueNoise.sample(blueNoiseSampler, uv).rgb - 0.5h);

    half3 out_ = color.rgb + grain * half(clamp(strength, 0.0f, 1.0f));
    return half4(clamp(out_, 0.0h, 1.0h), color.a);
}
