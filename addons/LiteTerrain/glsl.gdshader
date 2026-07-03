shader_type spatial;
render_mode diffuse_lambert;

group_uniforms Quality;
// Низкое качество для слабого железа (fill-bound): выключает попиксельный шум и тайл-текстуру.
uniform bool low_quality = false;

group_uniforms Texture;
uniform sampler2D tile_texture : source_color, filter_nearest;
// Размер тайла в мировых юнитах. Тайлинг считается из мировых XZ (см. vertex()), поэтому
// подстраивается под любой размер карты и одинаков в игре и в редакторе.
uniform float tile_world_size  : hint_range(0.1, 100.0) = 1.0;
uniform float texture_blend    : hint_range(0.0, 1.0)    = 0.1;

// Квантизация v_pixel_uv к сетке, чтобы шум и трава были стабильны по ячейке, а не мерцали
// по фрагментам. Константа, а не uniform — это не настройка вида.
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
// Карта примятия травы (кормит grass.gd через SubViewport). Чёрная по умолчанию = нет
// эффекта, можно не подключать.
uniform sampler2D trample_map : hint_default_black, filter_linear;
uniform vec2  trample_center = vec2(0.0);
uniform float trample_size   = 130.0;
group_uniforms;

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
    vec4 world_pos   = MODEL_MATRIX * vec4(VERTEX, 1.0);
    v_pixel_uv       = floor(world_pos.xz / tile_world_size * PIXELS_PER_TILE) / PIXELS_PER_TILE;
    v_world_height   = world_pos.y;
    v_world_normal_y = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y;

    v_is_grass = 0.0;

    // COLOR.r < 0.5 помечает вершины на границе чанка: там смещение травы пропускаем, чтобы
    // шов (особенно на границе LOD) остался на сшитой базовой поверхности. Меши без vertex
    // colours дают COLOR = белый. lod_grass_enabled = 1.0 только на ближнем (LOD-0) материале,
    // так что трава смещается лишь вблизи, где её видно.
    if (lod_grass_enabled > 0.5 && COLOR.r > 0.5 && v_world_height >= grass_min_height && v_world_height <= grass_max_height) {
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
    // Высотные зоны: песок -> трава -> снег.
    float t_grass = smoothstep(height_grass_start - zone_blend,
                                height_grass_start + zone_blend, v_world_height);
    float t_snow  = smoothstep(height_snow_start  - zone_blend,
                                height_snow_start  + zone_blend, v_world_height);

    vec3 zone_col = mix(color_sand.rgb, color_grass.rgb, t_grass);
    zone_col      = mix(zone_col,       color_snow.rgb,  t_snow);

    // Крутые склоны -> камень.
    float rock_t  = 1.0 - smoothstep(rock_threshold - rock_blend,
                                       rock_threshold + rock_blend, v_world_normal_y);
    vec3 base_col = mix(zone_col, color_rock.rgb, rock_t);

    // Попиксельный шум + тайл-текстура. В low_quality пропускаем (экономия fill).
    if (!low_quality) {
        float noise = (hash2D(v_pixel_uv) - 0.5) * color_variation;
        base_col     = clamp(base_col + noise, 0.0, 1.0);
        if (texture_blend > 0.001) {
            vec4 tile_col = texture(tile_texture, v_pixel_uv);
            base_col = mix(base_col, tile_col.rgb, texture_blend);
        }
    }

    // Вершины травы (v_is_grass=1) чуть ярче подстилки — простая тень под травой.
    float shadow = mix(0.65, 1.0, v_is_grass);

    ALBEDO    = base_col * shadow;
    ROUGHNESS = 0.9;
    SPECULAR  = 0.0;
}
