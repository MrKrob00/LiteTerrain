shader_type spatial;
render_mode diffuse_lambert;

// ── Tile texture (опціональний оверлей) ───────────────────────────────────────
uniform sampler2D tile_texture : source_color, filter_nearest;
uniform float tile_scale       : hint_range(0.1, 1000.0) = 5.0;
uniform float texture_blend    : hint_range(0.0, 1.0)    = 0.0;
uniform float pixels_per_tile  = 16.0;

// ── Кольори зон ───────────────────────────────────────────────────────────────
uniform vec4 color_sand  : source_color = vec4(0.76, 0.66, 0.48, 1.0);
uniform vec4 color_grass : source_color = vec4(0.29, 0.48, 0.23, 1.0);
uniform vec4 color_snow  : source_color = vec4(0.94, 0.96, 1.00, 1.0);
uniform vec4 color_rock  : source_color = vec4(0.44, 0.38, 0.31, 1.0);

// ── Висотні пороги ────────────────────────────────────────────────────────────
uniform float height_grass_start : hint_range(-200.0, 500.0) = 20.0;
uniform float height_snow_start  : hint_range(-200.0, 500.0) = 70.0;
uniform float zone_blend         : hint_range(0.1,   30.0)   =  5.0;

// ── Скеля / схил ──────────────────────────────────────────────────────────────
uniform float rock_threshold : hint_range(0.0, 1.0) = 0.7;
uniform float rock_blend     : hint_range(0.0, 0.5) = 0.15;

// ── Шумова варіація кольору ───────────────────────────────────────────────────
uniform float color_variation : hint_range(0.0, 0.3) = 0.06;

// ── Система трави ─────────────────────────────────────────────────────────────
uniform float grass_density     : hint_range(0.0, 1.0)    = 0.4;
uniform float grass_height      : hint_range(0.0, 1.0)    = 0.15;
uniform float grass_min_height  : hint_range(-10.0, 10.0) = -2.0;
uniform float grass_max_height  : hint_range(-10.0, 10.0) = 5.0;
uniform float bend_radius       : hint_range(0.1, 10.0)   = 1.5;
uniform float lod_grass_enabled : hint_range(0.0, 1.0)    = 1.0;

uniform vec2 bender_positions[64];
uniform int  bender_count = 0;

// ── Varyings ──────────────────────────────────────────────────────────────────
varying vec2  v_pixel_uv;
varying float v_world_height;
varying float v_world_normal_y;
varying float v_is_grass;

float hash2D(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void vertex() {
    v_pixel_uv = floor(UV * tile_scale * pixels_per_tile) / pixels_per_tile;

    vec4 world_pos   = MODEL_MATRIX * vec4(VERTEX, 1.0);
    v_world_height   = world_pos.y;
    v_world_normal_y = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y;

    v_is_grass = 0.0;

    if (v_world_height >= grass_min_height && v_world_height <= grass_max_height) {
        if (hash2D(v_pixel_uv) < grass_density) {
            vec3 offset = NORMAL * grass_height;
            if (bender_count > 0) {
                vec2 world_xz = world_pos.xz;
                float press   = 0.0;
                for (int i = 0; i < bender_count; i++) {
                    float d         = length(bender_positions[i] - world_xz);
                    float influence = max(0.0, 1.0 - d / bend_radius);
                    press          += influence * influence;
                }
                offset.y -= clamp(press, 0.0, 1.0) * grass_height * 2.0;
            }
            VERTEX    += offset;
            v_is_grass = 1.0;
        }
    }
}

void fragment() {
    // 1. Висотні зони
    float t_grass = smoothstep(height_grass_start - zone_blend,
                                height_grass_start + zone_blend, v_world_height);
    float t_snow  = smoothstep(height_snow_start  - zone_blend,
                                height_snow_start  + zone_blend, v_world_height);

    vec3 zone_col = mix(color_sand.rgb, color_grass.rgb, t_grass);
    zone_col      = mix(zone_col,       color_snow.rgb,  t_snow);

    // 2. Схил → камінь
    float rock_t  = 1.0 - smoothstep(rock_threshold - rock_blend,
                                       rock_threshold + rock_blend, v_world_normal_y);
    vec3 base_col = mix(zone_col, color_rock.rgb, rock_t);

    // 3. Шумова варіація
    float noise = (hash2D(v_pixel_uv) - 0.5) * color_variation;
    base_col     = clamp(base_col + noise, 0.0, 1.0);

    // 4. Тайл-текстура (опціонально)
    if (texture_blend > 0.001) {
        vec4 tile_col = texture(tile_texture, v_pixel_uv);
        base_col = mix(base_col, tile_col.rgb, texture_blend);
    }

    // 5. Тінь під травою
    // Однакова формула для всіх LOD: трава-вершини (v_is_grass=1) яскраві,
    // підстилка (v_is_grass=0) темніша. Прибрано 1.0 - lod_grass_enabled —
    // воно робило LOD-1+ на 35% яскравіше за LOD-0 і давало видимий шов.
    float shadow = mix(0.65, 1.0, v_is_grass);

    ALBEDO    = base_col * shadow;
    ROUGHNESS = 0.9;
    SPECULAR  = 0.0;
}