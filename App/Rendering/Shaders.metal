//
//  Shaders.metal
//  SteelFront
//
//  Forward renderer: sky pass, lit geometry with dynamic point lights,
//  procedural enemies animated in the vertex shader, additive FX, a first
//  person weapon pass and an HDR bloom / tonemap composite.
//
//  Uniform byte offsets used here are mirrored by UniformWriter on the Swift
//  side. Keep them in sync.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Uniform layouts

struct FrameUniforms {
    float4x4 viewProj;      //   0
    float4x4 invViewProj;   //  64
    float4   cameraPos;     // 128  xyz eye, w tan(fov/2)
    float4   sunDir;        // 144  xyz direction TO the sun, w intensity
    float4   sunColor;      // 160
    float4   skyColor;      // 176  xyz sky ambient, w ground bounce strength
    float4   fogParams;     // 192  xyz fog colour, w density
    float4   lightPos0;     // 208  xyz position, w radius
    float4   lightPos1;     // 224
    float4   lightPos2;     // 240
    float4   lightPos3;     // 256
    float4   lightCol0;     // 272  rgb colour * intensity, a unused
    float4   lightCol1;     // 288
    float4   lightCol2;     // 304
    float4   lightCol3;     // 320
    float4   params;        // 336  x time, y exposure, z damage flash, w hit marker
};                          // total 352

struct DrawUniforms {
    float4x4 model;     //  0
    float4   tint;      // 64  rgb tint, a alpha
    float4   params;    // 80  x atlas tile, y uv scale, z ao strength, w emissive
    float4   anim;      // 96  x walk phase, y move intensity, z hit flash, w death 0..1
    float4   extra;     // 112 x type, y yaw, z scale, w attack blend
};                      // total 128

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
    float3 tint     [[attribute(3)]];
    float  ao       [[attribute(4)]];
    float  limb     [[attribute(5)]];
};

struct LitOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float2 uv;
    float3 tint;
    float  ao;
    float  fog;
    float  emissive;
    float  tile;
};

// MARK: - Helpers

static inline float3 applyFog(float3 colour, float fog, float3 fogColour) {
    return mix(colour, fogColour, clamp(fog, 0.0, 1.0));
}

/// Cheap derivative bump: perturbs the normal using the albedo gradient.
static inline float3 bumpNormal(float3 n, float3 world, float strength) {
    float3 dx = dfdx(world);
    float3 dy = dfdy(world);
    float3 perturbation = cross(n, dy) * dfdx(world.x + world.y) * strength
                        + cross(dx, n) * dfdy(world.x + world.y) * strength;
    return normalize(n + perturbation);
}

static inline float3 lightContribution(float3 N, float3 V, float3 L, float3 radiance,
                                       float roughness) {
    float ndl = saturate(dot(N, L));
    float3 H = normalize(L + V);
    float ndh = saturate(dot(N, H));
    float spec = pow(ndh, mix(96.0, 8.0, roughness)) * (1.0 - roughness) * 0.6;
    return radiance * (ndl + spec);
}

// MARK: - Sky

struct SkyOut {
    float4 position [[position]];
    float2 ndc;
};

vertex SkyOut skyVertex(uint vid [[vertex_id]], constant FrameUniforms& F [[buffer(0)]]) {
    // Full screen triangle.
    float2 p = float2((vid << 1) & 2, vid & 2);
    SkyOut o;
    o.position = float4(p * 2.0 - 1.0, 1.0, 1.0);
    o.ndc = p * 2.0 - 1.0;
    return o;
}

fragment float4 skyFragment(SkyOut in [[stage_in]], constant FrameUniforms& F [[buffer(0)]]) {
    float4 rayClip = float4(in.ndc, 1.0, 1.0);
    float4 rayWorld = F.invViewProj * rayClip;
    float3 dir = normalize(rayWorld.xyz / rayWorld.w - F.cameraPos.xyz);

    float up = saturate(dir.y);
    float3 horizon = float3(0.66, 0.63, 0.56);
    float3 zenith = float3(0.28, 0.42, 0.62);
    float3 colour = mix(horizon, zenith, pow(up, 0.55));

    // Haze band sitting on the horizon.
    float haze = exp(-abs(dir.y) * 9.0);
    colour = mix(colour, float3(0.82, 0.76, 0.64), haze * 0.55);

    // Ground hemisphere (dust).
    colour = mix(colour, float3(0.30, 0.27, 0.22), saturate(-dir.y * 3.0));

    // Sun disc + glow.
    float sunAmount = saturate(dot(dir, normalize(F.sunDir.xyz)));
    colour += F.sunColor.rgb * pow(sunAmount, 900.0) * 6.0;
    colour += F.sunColor.rgb * pow(sunAmount, 12.0) * 0.28;

    // Layered cloud sheet, slowly drifting.
    float t = F.params.x * 0.006;
    float2 cuv = dir.xz / max(abs(dir.y) + 0.12, 0.12) * 0.35 + float2(t, t * 0.6);
    float n = 0.0;
    n += sin(cuv.x * 1.7 + sin(cuv.y * 2.3)) * 0.5;
    n += sin(cuv.y * 3.1 + cos(cuv.x * 1.1 + t * 2.0)) * 0.3;
    n += sin((cuv.x + cuv.y) * 5.3) * 0.16;
    float cloud = smoothstep(0.25, 0.85, n * 0.5 + 0.5) * saturate(dir.y * 4.0);
    float3 cloudColour = mix(float3(0.92, 0.90, 0.86), F.sunColor.rgb, 0.25);
    colour = mix(colour, cloudColour, cloud * 0.55);

    return float4(colour, 1.0);
}

// MARK: - Lit geometry (level, props, pickups)

vertex LitOut litVertex(VertexIn in [[stage_in]],
                        constant FrameUniforms& F [[buffer(0)]],
                        constant DrawUniforms& D [[buffer(1)]]) {
    float4 world = D.model * float4(in.position, 1.0);
    float3 normal = normalize((D.model * float4(in.normal, 0.0)).xyz);

    LitOut o;
    o.position = F.viewProj * world;
    o.world = world.xyz;
    o.normal = normal;
    o.uv = in.uv * D.params.y;
    o.tint = in.tint * D.tint.rgb;
    o.ao = mix(1.0, in.ao, D.params.z);
    float distance = length(F.cameraPos.xyz - world.xyz);
    o.fog = 1.0 - exp(-pow(max(distance, 0.0) * F.fogParams.w, 1.55));
    o.emissive = D.params.w;
    o.tile = D.params.x;
    o.position.z -= 0.00001 * o.position.w;
    return o;
}

fragment float4 litFragment(LitOut in [[stage_in]],
                            constant FrameUniforms& F [[buffer(0)]],
                            constant DrawUniforms& D [[buffer(1)]],
                            texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler linearSampler(filter::linear, address::repeat, mip_filter::linear);

    float tile = floor(in.tile + 0.5);
    float2 tileUV = float2(fmod(tile, 4.0), floor(tile / 4.0)) * 0.25;
    float2 uv = tileUV + fract(in.uv) * 0.25;

    float4 sample = atlas.sample(linearSampler, uv);
    float roughness = clamp(sample.a, 0.05, 1.0);

    float3 albedo = sample.rgb * in.tint;
    float3 N = normalize(in.normal);
    N = bumpNormal(N, in.world, mix(0.02, 0.5, roughness));
    float3 V = normalize(F.cameraPos.xyz - in.world);

    // Hemisphere ambient.
    float skyMix = saturate(N.y * 0.5 + 0.5);
    float3 ambient = mix(F.skyColor.rgb * F.skyColor.w, F.skyColor.rgb, skyMix) * 0.42;

    float3 colour = albedo * ambient * in.ao;

    // Directional sun.
    float3 sunDir = normalize(F.sunDir.xyz);
    float shadow = saturate(0.55 + 0.45 * saturate(in.world.y * 0.06 + 0.5));
    colour += albedo * lightContribution(N, V, sunDir, F.sunColor.rgb * F.sunDir.w * shadow,
                                         roughness);

    // Four dynamic point lights (muzzle flashes, explosions, fires).
    float4 positions[4] = { F.lightPos0, F.lightPos1, F.lightPos2, F.lightPos3 };
    float4 colours[4]   = { F.lightCol0, F.lightCol1, F.lightCol2, F.lightCol3 };
    for (int i = 0; i < 4; ++i) {
        float radius = positions[i].w;
        if (radius <= 0.001) { continue; }
        float3 delta = positions[i].xyz - in.world;
        float dist = length(delta);
        if (dist > radius) { continue; }
        float attenuation = pow(saturate(1.0 - dist / radius), 2.0);
        colour += albedo * lightContribution(N, V, delta / max(dist, 0.001),
                                             colours[i].rgb * attenuation, roughness);
    }

    // Emissive surfaces ignore lighting.
    colour = mix(colour, albedo * 2.4, in.emissive);

    colour = applyFog(colour, in.fog, F.fogParams.rgb);
    return float4(colour * D.tint.a, D.tint.a);
}

// MARK: - Animated enemies

vertex LitOut enemyVertex(VertexIn in [[stage_in]],
                          constant FrameUniforms& F [[buffer(0)]],
                          constant DrawUniforms& D [[buffer(1)]]) {
    float3 p = in.position * D.extra.z;
    float phase = D.anim.x;
    float move = D.anim.y;
    float attack = D.extra.w;

    // --- Procedural walk / attack pose -------------------------------------
    float legSwing = sin(phase) * 0.75 * move;
    float kneeBend = max(0.0, -cos(phase)) * 0.85 * move;
    float armSwing = -legSwing * 0.7;
    float bob = abs(sin(phase)) * 0.06 * move;

    float limb = floor(in.limb + 0.5);
    float angle = 0.0;
    float3 pivot = float3(0.0);

    // Hips / shoulders in mesh space (mesh faces +Z), scaled with the model so
    // larger enemies animate around their own joints.
    float s = D.extra.z;
    float3 hipL = float3(-0.17, 0.92, 0.0) * s;
    float3 hipR = float3(0.17, 0.92, 0.0) * s;
    float3 kneeL = float3(-0.17, 0.50, 0.0) * s;
    float3 kneeR = float3(0.17, 0.50, 0.0) * s;
    float3 shoulderL = float3(-0.26, 1.44, 0.0) * s;
    float3 shoulderR = float3(0.26, 1.44, 0.0) * s;

    if (limb == 6.0) {            // left thigh
        angle = legSwing; pivot = hipL;
    } else if (limb == 7.0) {     // left shin
        angle = legSwing - kneeBend; pivot = hipL;
    } else if (limb == 8.0) {     // right thigh
        angle = -legSwing; pivot = hipR;
    } else if (limb == 9.0) {     // right shin
        angle = -legSwing - kneeBend; pivot = hipR;
    } else if (limb == 2.0) {     // left upper arm
        angle = mix(armSwing, -1.35, attack); pivot = shoulderL;
    } else if (limb == 3.0) {     // left forearm
        angle = mix(armSwing * 1.3, -0.55, attack); pivot = shoulderL;
    } else if (limb == 4.0) {     // right upper arm
        angle = mix(-armSwing, -1.45, attack); pivot = shoulderR;
    } else if (limb == 5.0) {     // right forearm
        angle = mix(-armSwing * 1.3, -0.35, attack); pivot = shoulderR;
    } else if (limb == 10.0) {    // weapon
        angle = mix(0.0, -1.4, attack); pivot = float3(0.05, 1.35, 0.15) * s;
    }

    if (angle != 0.0) {
        float c = cos(angle), s = sin(angle);
        float3 relative = p - pivot;
        p = pivot + float3(relative.x,
                           relative.y * c - relative.z * s,
                           relative.y * s + relative.z * c);
    }

    // Shins bend only around the knee, applied after the thigh rotation.
    if (limb == 7.0 || limb == 9.0) {
        float kneeAngle = -kneeBend;
        float3 knee = (limb == 7.0) ? kneeL : kneeR;
        float c = cos(kneeAngle), s = sin(kneeAngle);
        float3 relative = p - knee;
        p = knee + float3(relative.x,
                          relative.y * c - relative.z * s,
                          relative.y * s + relative.z * c);
    }

    // Recoil / stagger kick.
    p.z += D.anim.z * 0.06 * s;

    // Torso bob.
    if (limb < 1.5 || limb > 9.5) { p.y += bob; }

    // Death: topple backwards and sink.
    float death = D.anim.w;
    if (death > 0.0) {
        float c = cos(-death * 1.5), s = sin(-death * 1.5);
        float3 relative = p - float3(0.0, 0.1, 0.0);
        p = float3(0.0, 0.1, 0.0) + float3(relative.x,
                                           relative.y * c - relative.z * s,
                                           relative.y * s + relative.z * c);
        p.y -= death * 0.35;
    }

    float4 world = D.model * float4(p, 1.0);
    float3 normal = normalize((D.model * float4(in.normal, 0.0)).xyz);

    LitOut o;
    o.position = F.viewProj * world;
    o.world = world.xyz;
    o.normal = normal;
    o.uv = in.uv * D.params.y;
    o.tint = in.tint * D.tint.rgb;
    o.ao = in.ao;
    float distance = length(F.cameraPos.xyz - world.xyz);
    o.fog = 1.0 - exp(-pow(max(distance, 0.0) * F.fogParams.w, 1.55));
    o.emissive = D.params.w;
    o.tile = D.params.x;
    return o;
}

// MARK: - First person weapon

vertex LitOut viewModelVertex(VertexIn in [[stage_in]],
                              constant FrameUniforms& F [[buffer(0)]],
                              constant DrawUniforms& D [[buffer(1)]]) {
    float4 clip = D.model * float4(in.position, 1.0);
    LitOut o;
    o.position = F.viewProj * clip;
    // Keep lighting stable by faking a world position near the camera.
    o.world = F.cameraPos.xyz + (D.model * float4(in.position, 1.0)).xyz * 0.02;
    o.normal = normalize((D.model * float4(in.normal, 0.0)).xyz);
    o.uv = in.uv * D.params.y;
    o.tint = in.tint * D.tint.rgb;
    o.ao = in.ao;
    o.fog = 0.0;
    o.emissive = D.params.w;
    o.tile = D.params.x;
    return o;
}

// MARK: - Additive / alpha FX (particles, tracers, muzzle flash)

struct FXVertexIn {
    float3 position [[attribute(0)]];
    float2 uv       [[attribute(1)]];
    float4 colour   [[attribute(2)]];
};

struct FXOut {
    float4 position [[position]];
    float2 uv;
    float4 colour;
};

vertex FXOut fxVertex(FXVertexIn in [[stage_in]], constant FrameUniforms& F [[buffer(0)]]) {
    FXOut o;
    o.position = F.viewProj * float4(in.position, 1.0);
    o.uv = in.uv;
    o.colour = in.colour;
    return o;
}

fragment float4 fxFragment(FXOut in [[stage_in]], texture2d<float> sprite [[texture(0)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float4 mask = sprite.sample(linearSampler, in.uv);
    float alpha = mask.a * in.colour.a;
    if (alpha < 0.004) { discard_fragment(); }
    return float4(in.colour.rgb * mask.rgb, alpha);
}

// MARK: - Post processing

struct PostOut {
    float4 position [[position]];
    float2 uv;
};

vertex PostOut postVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    PostOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

/// Bright pass: keeps only the highlights for the bloom chain.
fragment float4 brightFragment(PostOut in [[stage_in]], texture2d<float> source [[texture(0)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float3 colour = source.sample(linearSampler, in.uv).rgb;
    float luma = dot(colour, float3(0.2126, 0.7152, 0.0722));
    float contribution = smoothstep(0.85, 1.6, luma);
    return float4(colour * contribution, 1.0);
}

/// Separable gaussian blur. `direction` is (1,0) or (0,1) in texel units.
fragment float4 blurFragment(PostOut in [[stage_in]],
                             texture2d<float> source [[texture(0)]],
                             constant float2& direction [[buffer(0)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float weights[5] = { 0.227, 0.194, 0.121, 0.054, 0.016 };
    float3 result = source.sample(linearSampler, in.uv).rgb * weights[0];
    for (int i = 1; i < 5; ++i) {
        float2 offset = direction * float(i);
        result += source.sample(linearSampler, in.uv + offset).rgb * weights[i];
        result += source.sample(linearSampler, in.uv - offset).rgb * weights[i];
    }
    return float4(result, 1.0);
}

/// Final composite: bloom, ACES tonemap, vignette, grain and damage tint.
fragment float4 compositeFragment(PostOut in [[stage_in]],
                                  texture2d<float> scene [[texture(0)]],
                                  texture2d<float> bloom [[texture(1)]],
                                  constant FrameUniforms& F [[buffer(0)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

    // Slight chromatic aberration towards the frame edges.
    float2 centre = in.uv - 0.5;
    float radial = dot(centre, centre);
    float2 aberration = centre * radial * 0.012;
    float3 colour;
    colour.r = scene.sample(linearSampler, in.uv + aberration).r;
    colour.g = scene.sample(linearSampler, in.uv).g;
    colour.b = scene.sample(linearSampler, in.uv - aberration).b;

    colour += bloom.sample(linearSampler, in.uv).rgb * 0.85;
    colour *= F.params.y;   // exposure

    // Damage tint.
    float damage = F.params.z;
    colour = mix(colour, float3(0.55, 0.05, 0.05), damage * 0.45 * (0.35 + radial));

    // ACES filmic tonemap.
    float3 x = colour;
    float3 a = x * (x * 2.51 + 0.03);
    float3 b = x * (x * 2.43 + 0.59) + 0.14;
    colour = saturate(a / b);

    // Vignette.
    colour *= 1.0 - radial * 0.85;

    // Film grain.
    float grain = fract(sin(dot(in.uv * float2(1234.5, 5678.9) + F.params.x,
                                float2(12.9898, 78.233))) * 43758.5453);
    colour += (grain - 0.5) * 0.022;

    // sRGB-ish gamma.
    colour = pow(max(colour, 0.0), float3(1.0 / 2.2));
    return float4(colour, 1.0);
}
