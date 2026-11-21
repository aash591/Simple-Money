#version 460 core

// Liquid glass for a rounded rectangle, used as a backdrop image filter.
//
// The refraction, dispersion and rim highlight are ported from Kyant's
// AndroidLiquidGlass (com.kyant.backdrop, Apache-2.0), which targets Jetpack
// Compose and so cannot sample what Flutter draws.

#include <flutter/runtime_effect.glsl>

precision highp float;

// Set by the engine: the size of the backdrop texture, in physical pixels.
uniform vec2 u_size;
// The glass shape in the same space: left, top, width, height.
uniform vec4 u_rect;
uniform float u_radius;
// How far in from the edge the bend reaches, and how hard it bends.
uniform float u_refraction_height;
uniform float u_refraction_amount;
// 0 for a plain lens, 1 to split the bend into colour fringes.
uniform float u_dispersion;
uniform float u_saturation;
// Surface colour laid over the glass, straight alpha.
uniform vec4 u_tint;
uniform float u_highlight;
uniform float u_pixel_ratio;
// Independent lens zoom: values below 1 shrink the bar beneath the handle,
// especially its height. The outer bar uses (1, 1) for unchanged sampling.
uniform vec2 u_magnification;
// A slight softening of what is seen through the glass, in physical pixels;
// 0 for none. Done here rather than by a blur filter underneath, so the bar
// costs the GPU one pass over the screen instead of two.
uniform float u_blur;

uniform sampler2D u_backdrop;

out vec4 frag_color;

float sdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
  vec2 cornerCoord = abs(coord) - (halfSize - vec2(radius));
  float outside = length(max(cornerCoord, 0.0)) - radius;
  float inside = min(max(cornerCoord.x, cornerCoord.y), 0.0);
  return outside + inside;
}

vec2 gradSdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
  vec2 cornerCoord = abs(coord) - (halfSize - vec2(radius));
  vec2 grad;
  if (cornerCoord.x >= 0.0 || cornerCoord.y >= 0.0) {
    grad = sign(coord) * max(cornerCoord, 0.0);
  } else {
    float gradX = step(cornerCoord.y, cornerCoord.x);
    grad = sign(coord) * vec2(gradX, 1.0 - gradX);
  }
  float len = length(grad);
  return len > 0.0 ? grad / len : vec2(0.0);
}

float circleMap(float x) {
  return 1.0 - sqrt(max(1.0 - x * x, 0.0));
}

vec4 backdrop(vec2 coord) {
  vec2 center = u_rect.xy + u_rect.zw * 0.5;
  coord = center + (coord - center) / max(u_magnification, vec2(0.01));
  // No y flip for OpenGL ES, whatever the ImageFilter.shader docs say: as a
  // backdrop filter the texture already arrives the right way up there.
  if (u_blur <= 0.0) {
    return texture(u_backdrop, coord / u_size);
  }
  // A Gaussian blur of sigma [u_blur], sampled on a golden-angle spiral that
  // is turned a little differently for every pixel. A fixed grid of taps
  // (the old 5x5) stamped each letter behind the bar as a few offset copies,
  // which read as pixelated; turning the pattern per pixel spreads those
  // copies into a fine, even grain the eye sees as smooth frost.
  vec2 uv = coord / u_size;
  // Interleaved gradient noise: a cheap per-pixel angle with no visible
  // pattern of its own.
  float spin = 6.2831853 *
      fract(52.9829189 * fract(dot(FlutterFragCoord().xy,
                                   vec2(0.06711056, 0.00583715))));
  // 16 taps, fewer than the grid's 25: the per-pixel turn hides the gaps a
  // sparse fixed pattern would show. The disc reaches 2.5 sigma; past that a
  // Gaussian adds next to nothing.
  vec2 reach = vec2(u_blur * 2.5) / u_size;
  // Each tap is the last one turned by the golden angle, so the loop needs
  // no sin or cos: just one turn of the starting direction.
  vec2 dir = vec2(cos(spin), sin(spin));
  const mat2 golden = mat2(-0.7373688, 0.6754903, -0.6754903, -0.7373688);
  vec4 sum = vec4(0.0);
  float total = 0.0;
  for (int i = 0; i < 16; i++) {
    float t = (float(i) + 0.5) / 16.0;
    // exp(-d^2 / 2) with d = sqrt(t) * 2.5 sigmas.
    float weight = exp(-3.125 * t);
    sum += texture(u_backdrop, uv + dir * sqrt(t) * reach) * weight;
    total += weight;
    dir = golden * dir;
  }
  return sum / total;
}

void main() {
  vec2 coord = FlutterFragCoord().xy;
  vec2 halfSize = u_rect.zw * 0.5;
  vec2 centered = coord - u_rect.xy - halfSize;

  float sd = sdRoundedRect(centered, halfSize, u_radius);
  float gradRadius = min(u_radius * 1.5, min(halfSize.x, halfSize.y));
  vec2 grad = gradSdRoundedRect(centered, halfSize, gradRadius);

  vec4 color;
  if (u_refraction_height <= 0.0 || -sd >= u_refraction_height) {
    color = backdrop(coord);
  } else {
    float depth = -min(sd, 0.0);
    float bend =
        circleMap(1.0 - depth / u_refraction_height) * -u_refraction_amount;
    vec2 refracted = coord + bend * grad;
    if (u_dispersion <= 0.0) {
      color = backdrop(refracted);
    } else {
      float intensity =
          u_dispersion * (centered.x * centered.y) / (halfSize.x * halfSize.y);
      vec2 spread = bend * grad * intensity;
      color = vec4(0.0);

      vec4 red = backdrop(refracted + spread);
      color.r += red.r / 3.5;
      color.a += red.a / 7.0;

      vec4 orange = backdrop(refracted + spread * (2.0 / 3.0));
      color.r += orange.r / 3.5;
      color.g += orange.g / 7.0;
      color.a += orange.a / 7.0;

      vec4 yellow = backdrop(refracted + spread * (1.0 / 3.0));
      color.r += yellow.r / 3.5;
      color.g += yellow.g / 3.5;
      color.a += yellow.a / 7.0;

      vec4 green = backdrop(refracted);
      color.g += green.g / 3.5;
      color.a += green.a / 7.0;

      vec4 cyan = backdrop(refracted - spread * (1.0 / 3.0));
      color.g += cyan.g / 3.5;
      color.b += cyan.b / 3.0;
      color.a += cyan.a / 7.0;

      vec4 blue = backdrop(refracted - spread * (2.0 / 3.0));
      color.b += blue.b / 3.0;
      color.a += blue.a / 7.0;

      vec4 purple = backdrop(refracted - spread);
      color.r += purple.r / 7.0;
      color.b += purple.b / 3.0;
      color.a += purple.a / 7.0;
    }
  }

  float luma = dot(color.rgb, vec3(0.213, 0.715, 0.072));
  color.rgb = max(mix(vec3(luma), color.rgb, u_saturation), 0.0);
  color.rgb = mix(color.rgb, u_tint.rgb * color.a, u_tint.a);

  // A thin rim that catches the light from the top left and, mirrored, the
  // bottom right.
  float rim = 1.0 - smoothstep(0.0, 1.5 * u_pixel_ratio, -sd);
  float facing = abs(dot(grad, vec2(0.7071, 0.7071)));
  color.rgb += vec3(u_highlight * rim * facing) * color.a;

  frag_color = color;
}
