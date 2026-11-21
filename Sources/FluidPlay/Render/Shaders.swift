/// Shaders compiled at runtime — so the project doesn't need a separate Metal Toolchain in Xcode.
enum ShaderSource {
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct VSOut {
        float4 position [[position]];
        float2 uv;
    };

    // A single triangle covering the whole viewport.
    vertex VSOut vs_fullscreen(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VSOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    struct ConvertUniforms {
        float fullRange;
        float pad;
        float2 uvScale;   // image area / buffer size
        float2 uvMax;     // last safe coordinate (without sampling the canvas background)
        float2 pad2;
    };

    // NV12 (BT.709) -> gamma-encoded RGB.
    fragment float4 fs_convert(VSOut in [[stage_in]],
                               texture2d<float> lumaTex [[texture(0)]],
                               texture2d<float> chromaTex [[texture(1)]],
                               constant ConvertUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = min(in.uv * u.uvScale, u.uvMax);
        float y = lumaTex.sample(s, uv).r;
        float2 c = chromaTex.sample(s, uv).rg;
        float3 ycc;
        if (u.fullRange > 0.5) {
            ycc = float3(y, c - 0.5);
        } else {
            ycc = float3((y - 16.0 / 255.0) * (255.0 / 219.0), (c - 128.0 / 255.0) * (255.0 / 224.0));
        }
        float3 rgb = float3(ycc.x + 1.5748 * ycc.z,
                            ycc.x - 0.18732 * ycc.y - 0.46812 * ycc.z,
                            ycc.x + 1.8556 * ycc.y);
        return float4(saturate(rgb), 1.0);
    }

    struct PresentUniforms {
        float2 texel;
        float sharpness;
        float pad;
    };

    // Final composite with contrast-adaptive sharpening (no overshoot at edges).
    fragment float4 fs_present(VSOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               constant PresentUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float3 c = tex.sample(s, in.uv).rgb;
        if (u.sharpness <= 0.001) {
            return float4(c, 1.0);
        }
        float3 n = tex.sample(s, in.uv + float2(0.0, -u.texel.y)).rgb;
        float3 w = tex.sample(s, in.uv + float2(-u.texel.x, 0.0)).rgb;
        float3 e = tex.sample(s, in.uv + float2(u.texel.x, 0.0)).rgb;
        float3 d = tex.sample(s, in.uv + float2(0.0, u.texel.y)).rgb;
        float3 mn = min(min(min(n, w), min(c, e)), d);
        float3 mx = max(max(max(n, w), max(c, e)), d);
        float3 amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-4)));
        float peak = -1.0 / mix(8.0, 5.0, saturate(u.sharpness));
        float3 weight = amp * peak;
        float3 result = ((n + w + e + d) * weight + c) / (1.0 + 4.0 * weight);
        return float4(saturate(result), 1.0);
    }
    """
}
