#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Input: BC3 color texture (YCoCg encoded, hardware-decompressed)
layout(set = 0, binding = 0) uniform sampler2D u_color_tex;

// Input: BC4 alpha texture (HapM only; sampled via R channel)
layout(set = 0, binding = 1) uniform sampler2D u_alpha_tex;

// Output: RGBA8 storage image
layout(set = 0, binding = 2, rgba8) uniform writeonly image2D u_output_img;

// Push constants: 0 = no alpha (HapY), 1 = has alpha (HapM)
layout(push_constant) uniform PushConstants {
    int has_alpha;
} u_constants;

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(u_output_img);

    if (pos.x >= size.x || pos.y >= size.y) {
        return;
    }

    // Sample the BC3 texture at exact texel coordinates (no filtering).
    // texelFetch returns the decompressed BC3 texel value.
    vec4 s = texelFetch(u_color_tex, pos, 0);

    // YCoCg inverse transform
    float scale = 1.0 / (floor(s.b * 255.0 / 8.0 + 0.5) * (8.0 / 255.0) + 1.0);
    float Co = (s.r - 128.0 / 255.0) * scale;
    float Cg = (s.g - 128.0 / 255.0) * scale;
    float Y = s.a;

    float R = Y + Co - Cg;
    float G = Y + Cg;
    float B = Y - Co - Cg;

    // Alpha: from BC4 alpha texture (HapM) or 1.0
    float A = 1.0;
    if (u_constants.has_alpha != 0) {
        vec4 alpha_sample = texelFetch(u_alpha_tex, pos, 0);
        A = alpha_sample.r; // BC4 is single-channel (R)
    }

    imageStore(u_output_img, pos, vec4(R, G, B, A));
}
