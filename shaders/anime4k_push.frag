// Anime4K v1 "Push" bake filter for the reader (full-image offscreen pass).
//
// The host (anime4k_shader.dart) rasterizes the source ui.Image into a fresh
// WxH offscreen target with this shader, then caches the result: every
// fragment coordinate satisfies FlutterFragCoord().xy in [0, W)x[0, H), so
// uv = frag * uTexelSize is exact with no DPR or ancestor-transform
// dependence. Do NOT reuse this shader for on-screen drawRect passes.
//
// Kernel mirrors native/anime4k (unscaled Push, 3x3 Sobel + 4-direction
// clamp-guided push, strength 1/3): luma = BT.601, grad = |gx|+|gy| clamped
// to [0, 1], push = uStrength * grad mixed toward the brightest directional
// average. Alpha is preserved (premultiplied path, opaque pages unaffected).
#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uTexelSize;  // (1/W, 1/H) of the source image
uniform float uStrength;  // push strength, default 0.3333333
uniform sampler2D uTexture;

out vec4 fragColor;

float getLuma(vec4 c) {
  return dot(c.rgb, vec3(0.299, 0.587, 0.114));
}

vec4 tap(vec2 uv) {
  return texture(uTexture, clamp(uv, vec2(0.0), vec2(1.0)));
}

void main() {
  vec2 uv = FlutterFragCoord().xy * uTexelSize;

  vec4 cc = tap(uv);
  vec4 tl = tap(uv + vec2(-uTexelSize.x, -uTexelSize.y));
  vec4 tc = tap(uv + vec2(0.0, -uTexelSize.y));
  vec4 tr = tap(uv + vec2(uTexelSize.x, -uTexelSize.y));
  vec4 ml = tap(uv + vec2(-uTexelSize.x, 0.0));
  vec4 mr = tap(uv + vec2(uTexelSize.x, 0.0));
  vec4 bl = tap(uv + vec2(-uTexelSize.x, uTexelSize.y));
  vec4 bc = tap(uv + vec2(0.0, uTexelSize.y));
  vec4 br = tap(uv + vec2(uTexelSize.x, uTexelSize.y));

  float l_cc = getLuma(cc);
  float l_tl = getLuma(tl), l_tc = getLuma(tc), l_tr = getLuma(tr);
  float l_ml = getLuma(ml), l_mr = getLuma(mr);
  float l_bl = getLuma(bl), l_bc = getLuma(bc), l_br = getLuma(br);

  float gx = -l_tl - 2.0 * l_ml - l_bl + l_tr + 2.0 * l_mr + l_br;
  float gy = -l_tl - 2.0 * l_tc - l_tr + l_bl + 2.0 * l_bc + l_br;
  float grad = clamp(abs(gx) + abs(gy), 0.0, 1.0);

  // 4-direction brightest-average push (aligned with native/anime4k).
  vec4 lightest = cc;
  float maxL = l_cc;
  vec4 avgH = 0.5 * (ml + mr);
  float lH = 0.5 * (l_ml + l_mr);
  if (lH > maxL) {
    maxL = lH;
    lightest = avgH;
  }
  vec4 avgV = 0.5 * (tc + bc);
  float lV = 0.5 * (l_tc + l_bc);
  if (lV > maxL) {
    maxL = lV;
    lightest = avgV;
  }
  vec4 avgD1 = 0.5 * (tl + br);
  float lD1 = 0.5 * (l_tl + l_br);
  if (lD1 > maxL) {
    maxL = lD1;
    lightest = avgD1;
  }
  vec4 avgD2 = 0.5 * (tr + bl);
  float lD2 = 0.5 * (l_tr + l_bl);
  if (lD2 > maxL) {
    maxL = lD2;
    lightest = avgD2;
  }

  float push = uStrength * grad;
  fragColor = vec4(mix(cc.rgb, lightest.rgb, push) * cc.a, cc.a);
}
