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
    // Anti-aliasing for line endpoints
    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center);
    
    // Smooth edge falloff
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
    
    // Additive bloom effect
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
    // Interpolated gradient color from vertices
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
    // Use in.position.x which already has the [[position]] attribute
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
    
    // Color code based on gain reduction amount
    // Green = no reduction, Yellow = moderate, Red = heavy
    float reductionNormalized = saturate(color.a / params.maxReduction);
    
    if (reductionNormalized < 0.3) {
        color.rgb = float3(0.2, 0.9, 0.2); // Green
    } else if (reductionNormalized < 0.6) {
        color.rgb = float3(0.9, 0.9, 0.2); // Yellow
    } else {
        color.rgb = float3(0.9, 0.2, 0.2); // Red
    }
    
    color.a = 0.6; // Semi-transparent overlay
    
    return color;
}

// MARK: - Compute Shaders (GPU Optimizations)

// Peak hold decay compute shader
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

// Temporal smoothing compute shader
kernel void temporalSmoothKernel(device float *smoothed [[buffer(0)]],
                                device const float *input [[buffer(1)]],
                                constant float &attackCoeff [[buffer(2)]],
                                constant float &releaseCoeff [[buffer(3)]],
                                uint id [[thread_position_in_grid]]) {
    float inputValue = input[id];
    float smoothedValue = smoothed[id];
    
    if (inputValue > smoothedValue) {
        // Attack
        smoothed[id] = inputValue;
    } else {
        // Release
        smoothed[id] = smoothedValue * releaseCoeff + inputValue * (1.0 - releaseCoeff);
    }
}

// FFT magnitude calculation (if moving FFT to GPU)
kernel void fftMagnitudeKernel(device const float *real [[buffer(0)]],
                              device const float *imag [[buffer(1)]],
                              device float *magnitudes [[buffer(2)]],
                              uint id [[thread_position_in_grid]]) {
    float r = real[id];
    float i = imag[id];
    magnitudes[id] = sqrt(r * r + i * i);
}

// Mid/Side encoding on GPU (if moving to GPU)
kernel void midSideEncodeKernel(device const float *left [[buffer(0)]],
                               device const float *right [[buffer(1)]],
                               device float *mid [[buffer(2)]],
                               device float *side [[buffer(3)]],
                               uint id [[thread_position_in_grid]]) {
    float l = left[id];
    float r = right[id];
    
    // Mid = (L + R) / 2
    mid[id] = (l + r) * 0.5;
    
    // Side = (L - R) / 2
    side[id] = (l - r) * 0.5;
}

// Mid/Side decoding on GPU
kernel void midSideDecodeKernel(device const float *mid [[buffer(0)]],
                               device const float *side [[buffer(1)]],
                               device float *left [[buffer(2)]],
                               device float *right [[buffer(3)]],
                               uint id [[thread_position_in_grid]]) {
    float m = mid[id];
    float s = side[id];
    
    // Left = M + S
    left[id] = m + s;
    
    // Right = M - S
    right[id] = m - s;
}

// Envelope follower compute shader
kernel void envelopeFollowerKernel(device float *envelope [[buffer(0)]],
                                  device const float *input [[buffer(1)]],
                                  constant float &attackCoeff [[buffer(2)]],
                                  constant float &releaseCoeff [[buffer(3)]],
                                  uint id [[thread_position_in_grid]]) {
    float inputValue = abs(input[id]);
    float envelopeValue = envelope[id];
    
    if (inputValue > envelopeValue) {
        // Attack
        envelope[id] = attackCoeff * envelopeValue + (1.0 - attackCoeff) * inputValue;
    } else {
        // Release
        envelope[id] = releaseCoeff * envelopeValue + (1.0 - releaseCoeff) * inputValue;
    }
}

// Gain reduction computer shader
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
        // Below threshold
        reduction = 0.0;
    } else if (input > (threshold + knee / 2.0)) {
        // Above knee - full compression
        float excess = input - threshold;
        reduction = excess * (1.0 - 1.0 / ratio);
    } else {
        // In knee - soft knee
        float excess = input - threshold + knee / 2.0;
        float scale = excess / knee;
        float scaledExcess = scale * scale * knee / 2.0;
        reduction = scaledExcess * (1.0 - 1.0 / ratio);
    }
    
    gainReduction[id] = reduction;
}
