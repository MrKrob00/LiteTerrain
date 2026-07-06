shader_type spatial;
// specular_disabled: the terrain is matte (SPECULAR=0) — drop specular from the pipeline.
render_mode diffuse_lambert, specular_disabled;

group_uniforms Quality;
// Low quality for weak (fill-bound) hardware: disables per-pixel noise and the tile texture.
uniform bool low_quality = false;

group_uniforms Texture;
// filter_nearest_mipmap is the key to FPS: without mips, distant/grazing tiles read scattered
// texels → constant texture-cache misses (the main fill hog — confirmed by low_quality, which
// disables this sample, giving +14 FPS). With mips, distant pixels read small levels → cache
// hits, cheap and moiré-free; up close, nearest keeps the crisp pixel look.
uniform sampler2D tile_texture : source_color, filter_nearest_mipmap;
// Tile size in world units. Tiling is computed from world-space XZ (see vertex()), so it
// adapts to any map size and looks the same in game and in the editor.
uniform float tile_world_size  : hint_range(0.1, 100.0) = 1.0;
uniform float texture_blend    : hint_range(0.0, 1.0)    = 0.1;

// Quantize v_pixel_uv to a grid so noise and grass are stable per cell instead of flickering
// per fragment. A constant, not a uniform — this is not a look setting.
const float PIXELS_PER_TILE = 16.0;

group_uniforms Colors;
uniform vec4 color_sand  : source_color = vec4(0.76, 0.66, 0.48, 1.0);
uniform vec4 color_grass : source_color = vec4(0.29, 0.48, 0.23, 1.0);
uniform vec4 color_snow  : source_color = vec4(0.94, 0.96, 1.00, 1.0);
uniform vec4 color_rock  : source_color = vec4(0.44, 0.38, 0.31, 1.0);

group_uniforms Terrain;
uniform float height_grass_start : hint_range(-200.0, 500.0) = 20.0;
uniform float height_snow_start  : hint_range(-200.0, 500.0) = 70.0;
uniform float zone_blend         : hint_range(0.1,   30.0)   =  5.0;
uniform float rock_threshold     : hint_range(0.0, 1.0)      = 0.7;
uniform float rock_blend         : hint_range(0.0, 0.5)      = 0.15;
uniform float color_variation    : hint_range(0.0, 0.3)      = 0.06;

group_uniforms Grass;
uniform float grass_density     : hint_range(0.0, 1.0)    = 0.4;
uniform float grass_height      : hint_range(0.0, 1.0)    = 0.15;
uniform float grass_min_height  : hint_range(-10.0, 10.0) = -2.0;
uniform float grass_max_height  : hint_range(-10.0, 10.0) = 5.0;
uniform float bend_radius       : hint_range(0.1, 10.0)   = 1.5;
uniform float lod_grass_enabled : hint_range(0.0, 1.0)    = 1.0;

group_uniforms Trample;
// Grass trample map (fed by grass.gd through a SubViewport). Black by default = no
// effect; it can be left unconnected.
uniform sampler2D trample_map : hint_default_black, filter_linear;
uniform vec2  trample_center = vec2(0.0);
uniform float trample_size   = 130.0;
group_uniforms;

// FILL OPTIMIZATION: the height/slope zone color (and the transition to rock) is computed in the
// VERTEX shader (v_base_col) and interpolated, instead of being recomputed per pixel. The terrain
// is fill-bound (expensive per-pixel) while there are orders of magnitude fewer vertices. The look
// is the same; zone borders become a linear transition (imperceptible up close where the mesh is
// dense, and tiny at distance anyway). Only what must be per-pixel stays in the fragment: noise
// and the tile texture.
varying vec2  v_pixel_uv;    // quantized (floored to the grid) — for stable noise and grass
varying vec2  v_tile_uv;     // smooth — for sampling the tile texture: only from this can the GPU
                             // pick the mip level correctly (via ddx/ddy derivatives); the
                             // quantized v_pixel_uv has stepped derivatives → broken mips.
varying vec3  v_base_col;
varying float v_is_grass;

float hash2D(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void vertex() {
    vec4 world_pos = MODEL_MATRIX * vec4(VERTEX, 1.0);
    float wy = world_pos.y;
    v_tile_uv  = world_pos.xz / tile_world_size;                                  // smooth (texture + mip)
    v_pixel_uv = floor(v_tile_uv * PIXELS_PER_TILE) / PIXELS_PER_TILE;            // quantized (noise/grass)

    // Height zones (sand→grass→snow) + slope→rock — the whole base color is computed here.
    float t_grass = smoothstep(height_grass_start - zone_blend, height_grass_start + zone_blend, wy);
    float t_snow  = smoothstep(height_snow_start  - zone_blend, height_snow_start  + zone_blend, wy);
    vec3  zone    = mix(color_sand.rgb, color_grass.rgb, t_grass);
    zone          = mix(zone,           color_snow.rgb,  t_snow);
    float ny      = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y;
    float rock_t  = 1.0 - smoothstep(rock_threshold - rock_blend, rock_threshold + rock_blend, ny);
    v_base_col    = mix(zone, color_rock.rgb, rock_t);

    v_is_grass = 0.0;
    // COLOR.r < 0.5 marks vertices on a chunk border: grass displacement is skipped there so the
    // seam (especially at LOD boundaries) stays on the stitched base surface. lod_grass_enabled=1
    // only on the near LOD-0 material — grass is displaced only up close where it is visible.
    if (lod_grass_enabled > 0.5 && COLOR.r > 0.5 && wy >= grass_min_height && wy <= grass_max_height) {
        if (hash2D(v_pixel_uv) < grass_density) {
            vec3 offset = NORMAL * grass_height;
            vec2 t_uv = (world_pos.xz - trample_center) / trample_size + vec2(0.5);
            if (t_uv.x >= 0.0 && t_uv.x <= 1.0 && t_uv.y >= 0.0 && t_uv.y <= 1.0) {
                float press = texture(trample_map, t_uv).r;
                offset.y -= clamp(press, 0.0, 1.0) * grass_height * 2.0;
            }
            VERTEX    += offset;
            v_is_grass = 1.0;
        }
    }
}

void fragment() {
    vec3 base_col = v_base_col;

    // Per-pixel only: color noise + tile texture. Skipped in low_quality (saves fill).
    if (!low_quality) {
        base_col = clamp(base_col + (hash2D(v_pixel_uv) - 0.5) * color_variation, 0.0, 1.0);
        if (texture_blend > 0.001) {
            base_col = mix(base_col, texture(tile_texture, v_tile_uv).rgb, texture_blend);
        }
    }

    // Grass vertices (v_is_grass=1) slightly brighter than the ground below — a cheap shadow under the grass.
    ALBEDO    = base_col * mix(0.65, 1.0, v_is_grass);
    ROUGHNESS = 0.9;
}
