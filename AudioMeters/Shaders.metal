#include <metal_stdlib>
using namespace metal;

// MARK: - Vertex Structure

struct Vertex {
    float2 position;
    float4 color;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
};

// MARK: - Uniforms

struct ViewportUniforms {
    float2 viewportSize;
};

// MARK: - Spectrum Curve Shaders

vertex VertexOut spectrumVertexShader(const device Vertex *vertices [[buffer(0)]],
                                     constant ViewportUniforms &uniforms [[buffer(1)]],
                                     uint vertexID [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.color = vertices[vertexID].color;
    out.pointSize = 1.0;
    return out;
}

fragment float4 spectrumFragmentShader(VertexOut in [[stage_in]]) {
    return in.color;
}

// MARK: - Grid Line Shaders

vertex VertexOut gridVertexShader(const device Vertex *vertices [[buffer(0)]],
                                  uint vertexID [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.color = vertices[vertexID].color;
    out.pointSize = 1.0;
    return out;
}

fragment float4 gridFragmentShader(VertexOut in [[stage_in]]) {
    return in.color;
}

// MARK: - Anti-Aliased Line Shader with Width

vertex VertexOut lineVertexShader(const device Vertex *vertices [[buffer(0)]],
                                  constant float &lineWidth [[buffer(1)]],
                                  uint vertexID [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.color = vertices[vertexID].color;
    out.pointSize = lineWidth;
    return out;
}

fragment float4 lineFragmentShader(VertexOut in [[stage_in]],
                                  float2 pointCoord [[point_coord]]) {
    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center);
    float alpha = smoothstep(0.5, 0.2, dist);
    float4 color = in.color;
    color.a *= alpha;
    return color;
}

// MARK: - Glow Effect Shader

struct GlowParams {
    float intensity;
    float radius;
};

fragment float4 glowFragmentShader(VertexOut in [[stage_in]],
                                  constant GlowParams &params [[buffer(0)]]) {
    float4 color = in.color;
    float bloom = params.intensity;
    color.rgb += bloom * 0.15;
    return color;
}

// MARK: - Gradient Fill Shader (for area under curve)

vertex VertexOut fillVertexShader(const device Vertex *vertices [[buffer(0)]],
                                  uint vertexID [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.color = vertices[vertexID].color;
    out.pointSize = 1.0;
    return out;
}

fragment float4 fillFragmentShader(VertexOut in [[stage_in]]) {
    return in.color;
}

// MARK: - Dashed Line Shader (for peak holds)

struct DashParams {
    float dashLength;
    float gapLength;
};

fragment float4 dashedLineFragmentShader(VertexOut in [[stage_in]],
                                        constant DashParams &params [[buffer(0)]]) {
    float totalLength = params.dashLength + params.gapLength;
    float position = fmod(in.position.x, totalLength);

    if (position > params.dashLength) {
        discard_fragment();
    }

    return in.color;
}

// MARK: - Gain Reduction Meter Shader

struct GainReductionParams {
    float threshold;
    float maxReduction;
};

fragment float4 gainReductionFragmentShader(VertexOut in [[stage_in]],
                                           constant GainReductionParams &params [[buffer(0)]]) {
    float4 color = in.color;
    float reductionNormalized = saturate(color.a / params.maxReduction);

    if (reductionNormalized < 0.3) {
        color.rgb = float3(0.2, 0.9, 0.2);
    } else if (reductionNormalized < 0.6) {
        color.rgb = float3(0.9, 0.9, 0.2);
    } else {
        color.rgb = float3(0.9, 0.2, 0.2);
    }

    color.a = 0.6;
    return color;
}

// MARK: - Compute Shaders

kernel void peakDecayKernel(device float *peaks [[buffer(0)]],
                           device const float *current [[buffer(1)]],
                           constant float &decayRate [[buffer(2)]],
                           uint id [[thread_position_in_grid]]) {
    float currentValue = current[id];
    float peakValue = peaks[id];

    if (currentValue > peakValue) {
        peaks[id] = currentValue;
    } else {
        peaks[id] = max(0.0, peakValue - decayRate);
    }
}

kernel void temporalSmoothKernel(device float *smoothed [[buffer(0)]],
                                device const float *input [[buffer(1)]],
                                constant float &attackCoeff [[buffer(2)]],
                                constant float &releaseCoeff [[buffer(3)]],
                                uint id [[thread_position_in_grid]]) {
    float inputValue = input[id];
    float smoothedValue = smoothed[id];

    if (inputValue > smoothedValue) {
        smoothed[id] = inputValue;
    } else {
        smoothed[id] = smoothedValue * releaseCoeff + inputValue * (1.0 - releaseCoeff);
    }
}

kernel void fftMagnitudeKernel(device const float *real [[buffer(0)]],
                              device const float *imag [[buffer(1)]],
                              device float *magnitudes [[buffer(2)]],
                              uint id [[thread_position_in_grid]]) {
    float r = real[id];
    float i = imag[id];
    magnitudes[id] = sqrt(r * r + i * i);
}

kernel void midSideEncodeKernel(device const float *left [[buffer(0)]],
                               device const float *right [[buffer(1)]],
                               device float *mid [[buffer(2)]],
                               device float *side [[buffer(3)]],
                               uint id [[thread_position_in_grid]]) {
    float l = left[id];
    float r = right[id];
    mid[id]  = (l + r) * 0.5;
    side[id] = (l - r) * 0.5;
}

kernel void midSideDecodeKernel(device const float *mid [[buffer(0)]],
                               device const float *side [[buffer(1)]],
                               device float *left [[buffer(2)]],
                               device float *right [[buffer(3)]],
                               uint id [[thread_position_in_grid]]) {
    float m = mid[id];
    float s = side[id];
    left[id]  = m + s;
    right[id] = m - s;
}

kernel void envelopeFollowerKernel(device float *envelope [[buffer(0)]],
                                  device const float *input [[buffer(1)]],
                                  constant float &attackCoeff [[buffer(2)]],
                                  constant float &releaseCoeff [[buffer(3)]],
                                  uint id [[thread_position_in_grid]]) {
    float inputValue = abs(input[id]);
    float envelopeValue = envelope[id];

    if (inputValue > envelopeValue) {
        envelope[id] = attackCoeff * envelopeValue + (1.0 - attackCoeff) * inputValue;
    } else {
        envelope[id] = releaseCoeff * envelopeValue + (1.0 - releaseCoeff) * inputValue;
    }
}

struct GainComputerParams {
    float threshold;
    float ratio;
    float knee;
};

kernel void gainReductionKernel(device const float *inputDB [[buffer(0)]],
                               device float *gainReduction [[buffer(1)]],
                               constant GainComputerParams &params [[buffer(2)]],
                               uint id [[thread_position_in_grid]]) {
    float input = inputDB[id];
    float threshold = params.threshold;
    float ratio = params.ratio;
    float knee = params.knee;
    float reduction = 0.0;

    if (input < (threshold - knee / 2.0)) {
        reduction = 0.0;
    } else if (input > (threshold + knee / 2.0)) {
        float excess = input - threshold;
        reduction = excess * (1.0 - 1.0 / ratio);
    } else {
        float excess = input - threshold + knee / 2.0;
        float scale = excess / knee;
        float scaledExcess = scale * scale * knee / 2.0;
        reduction = scaledExcess * (1.0 - 1.0 / ratio);
    }

    gainReduction[id] = reduction;
}

// MARK: - Q3 Spectrum Shaders

/// Pixel-space vertex shader for the Q3 spectrum view.
///
/// Accepts vertex positions in pixel space (0…width, 0…height) and converts
/// them to Metal NDC. The Y axis is flipped so that pixel-space Y=0 maps to
/// the top of the screen, matching UIKit/SwiftUI coordinate conventions.
///
/// Buffer 0: array of `Vertex` structs (float2 position + float4 color)
/// Buffer 1: viewport size as `float2` (drawable width and height in pixels)
vertex VertexOut q3VertexShader(
    const device Vertex *vertices [[buffer(0)]],
    constant float2 &viewportSize [[buffer(1)]],
    uint vertexID [[vertex_id]])
{
    VertexOut out;
    float2 pixelPos = vertices[vertexID].position;

    // Map pixel space → NDC, flipping Y so (0,0) is top-left.
    float2 ndc = float2(
        (pixelPos.x / viewportSize.x) * 2.0 - 1.0,
        1.0 - (pixelPos.y / viewportSize.y) * 2.0
    );

    out.position  = float4(ndc, 0.0, 1.0);
    out.color     = vertices[vertexID].color;
    out.pointSize = 1.0;
    return out;
}

/// Fragment shader for the Q3 spectrum curve line.
///
/// Adds a subtle luminance-proportional emission, making the line read as
/// self-illuminated against the dark background — consistent with the
/// MiniMeters visual language. The effect is deliberately understated so
/// it does not bleed into adjacent bands.
fragment float4 q3GlowFragmentShader(VertexOut in [[stage_in]])
{
    float4 color = in.color;

    // Perceptual luminance of the input colour (BT.709 coefficients)
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));

    // Screen-blend white toward bright colours; dim colours are unaffected.
    // Coefficient 0.14 keeps the effect subtle — visible but not distracting.
    color.rgb = mix(color.rgb, float3(1.0), luminance * 0.14);

    return color;
}


// MARK: - Goniometer Shaders

/// Per-vertex data for goniometer scatter dots.
/// Carries an `age` value in [0, 1] (0 = oldest, 1 = newest) that the vertex
/// shader uses to compute point size and alpha, producing an exponential
/// phosphor-decay effect without any per-frame texture blending.
struct GonioVertex {
    float2 position;  // pixel space (0…width, 0…height)
    float4 color;
    float  age;       // 0 = oldest, 1 = newest
};

/// Pixel-space vertex shader for goniometer scatter dots.
///
/// - Point size scales from 0.9 px (oldest) to 3.0 px (newest).
/// - Alpha is `pow(age, 1.6)` — exponential decay that lets the newest
///   signal read clearly while older dots dissolve naturally.
/// - Y is flipped to match UIKit/SwiftUI coordinate conventions.
///
/// Buffer 0: `GonioVertex` array
/// Buffer 1: viewport size as `float2`
vertex VertexOut gonioPointVertexShader(
    const device GonioVertex *vertices [[buffer(0)]],
    constant float2            &vp     [[buffer(1)]],
    uint vertexID [[vertex_id]])
{
    GonioVertex v = vertices[vertexID];

    // Pixel space → NDC with Y-flip
    float2 ndc = float2(
        (v.position.x / vp.x) * 2.0 - 1.0,
        1.0 - (v.position.y / vp.y) * 2.0
    );

    VertexOut out;
    out.position  = float4(ndc, 0.0, 1.0);
    out.color     = v.color;
    out.color.a   = pow(v.age, 1.6);          // exponential phosphor decay
    out.pointSize = 0.9 + v.age * 2.1;         // size grows with recency
    return out;
}

/// Fragment shader for goniometer scatter dots.
///
/// Renders each point sprite as a smooth anti-aliased disc using the
/// built-in `point_coord` attribute. The smooth-step edge removes the
/// hard square boundary of a raw point primitive.
fragment float4 gonioPointFragmentShader(
    VertexOut in             [[stage_in]],
    float2    pointCoord     [[point_coord]])
{
    // Map pointCoord from [0,1]² to signed [-1,1]² and compute distance
    float dist  = length(pointCoord - 0.5) * 2.0;
    float alpha = smoothstep(1.0, 0.35, dist);  // soft circular edge

    float4 color = in.color;
    color.a *= alpha;
    return color;
}

/// Pixel-space vertex shader for goniometer guide geometry (circles, axes)
/// and trail lines. Identical mapping to `q3VertexShader`; duplicated here
/// so goniometer and spectrum pipelines are independently configurable.
vertex VertexOut gonioLineVertexShader(
    const device Vertex *vertices [[buffer(0)]],
    constant float2     &vp       [[buffer(1)]],
    uint vertexID [[vertex_id]])
{
    float2 pixelPos = vertices[vertexID].position;
    float2 ndc = float2(
        (pixelPos.x / vp.x) * 2.0 - 1.0,
        1.0 - (pixelPos.y / vp.y) * 2.0
    );

    VertexOut out;
    out.position  = float4(ndc, 0.0, 1.0);
    out.color     = vertices[vertexID].color;
    out.pointSize = 1.0;
    return out;
}

/// Passthrough fragment shader for guide lines and trails.
/// Color (including alpha) is set entirely by the vertex data, allowing
/// per-vertex alpha fading on trail line strips.
fragment float4 gonioLineFragmentShader(VertexOut in [[stage_in]])
{
    return in.color;
}

// MARK: - Enhanced Goniometer Glow Shaders
//
// Two new shader functions used by GoniometerMetalRenderer's glow pipeline.
// The renderer calls drawPrimitives(.point) three times per frame (scatter)
// and twice (trail), each time with different GonioGlowUniforms values,
// producing layered bloom: wide soft glow → medium halo → crisp core.

/// Per-draw uniforms that control point size and alpha for a single glow layer.
/// Swift mirror: `GonioGlowUniforms` (8 bytes — two floats, buffer slot 2).
struct GonioGlowUniforms {
    float pointSizeScale;   // multiplier applied to the age-derived base size
    float alphaScale;       // overall alpha multiplier for this layer
};

/// Pixel-space vertex shader for goniometer glow point sprites.
///
/// Identical NDC mapping to `gonioPointVertexShader` but accepts a
/// `GonioGlowUniforms` uniform (buffer 2) so the caller can vary point
/// size and alpha per layer without rebuilding the vertex buffer.
///
/// - Point size: `(1.2 + age * 2.8) * pointSizeScale`
///   → outer glow pass uses scale ≈ 6, core pass uses scale ≈ 1.
/// - Alpha: `pow(age, 1.5) * alphaScale`
///   → gives phosphor-decay falloff on old samples regardless of layer.
///
/// Buffer 0: GonioVertex array (position float2, color float4, age float)
/// Buffer 1: viewport size float2
/// Buffer 2: GonioGlowUniforms
vertex VertexOut gonioGlowPointVertexShader(
    const device GonioVertex       *vertices [[buffer(0)]],
    constant float2                &vp       [[buffer(1)]],
    constant GonioGlowUniforms     &uni      [[buffer(2)]],
    uint vertexID [[vertex_id]])
{
    GonioVertex v = vertices[vertexID];

    // Pixel space → NDC, Y-flipped to match UIKit/SwiftUI coordinate origin
    float2 ndc = float2(
        (v.position.x / vp.x) * 2.0 - 1.0,
        1.0 - (v.position.y / vp.y) * 2.0
    );

    VertexOut out;
    out.position  = float4(ndc, 0.0, 1.0);
    out.color     = v.color;
    out.color.a   = pow(v.age, 1.5) * uni.alphaScale;
    out.pointSize = (1.2 + v.age * 2.8) * uni.pointSizeScale;
    return out;
}

/// Fragment shader for goniometer glow point sprites.
///
/// Uses a Gaussian radial falloff instead of the hard smoothstep used by
/// `gonioPointFragmentShader`.  The Gaussian `exp(−d² · 2.8)` produces a
/// natural "bloom" appearance: bright core that dissolves softly outward,
/// which layers convincingly across the three scatter/trail passes.
///
/// When the same vertex buffer is rendered with a large pointSizeScale the
/// shader's wide, low-alpha halo provides the ambient bloom.  A subsequent
/// pass with scale ≈ 1 gives the bright dot in the centre.
fragment float4 gonioGlowFragmentShader(
    VertexOut in         [[stage_in]],
    float2    pointCoord [[point_coord]])
{
    float dist  = length(pointCoord - 0.5) * 2.0;         // [0, ~1.41]
    float alpha = exp(-dist * dist * 2.8);                 // Gaussian bloom

    // Slightly brighten the core to give the hotspot a white-hot centre
    float core  = exp(-dist * dist * 18.0);
    float3 rgb  = in.color.rgb + core * 0.35 * (1.0 - in.color.rgb);

    return float4(rgb, in.color.a * alpha);
}
