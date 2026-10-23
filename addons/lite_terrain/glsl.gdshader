
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;
// THE FAST GROUND (ChunkTerrain.fast_ground, on while shadows are off): the same code with this line
// swapped for `render_mode unshaded;` and FAST_GROUND defined. The phone's probe put the engine's own
// lighting at 12 ms of a 47 ms frame even per vertex, and with no shadow to receive it buys nothing:
// the ground lights itself here with the one lambert term the engine computed, per vertex, from
// `ground_amb` / `ground_sun` (day_cycle.gd writes them from the environment and the light, scaled
// to match the lit path on the real driver).

// WHERE EACH SETTING IS TUNED: in the map's inspector. Its `surface_material`
// (addons/lite_terrain/terrain_shader.tres) carries this shader and shows every uniform; the node
// draws with a copy of it, into which its `biomes` write the colours, rock, snow, grass and canyon
// bands (TerrainBiomes.apply_to_material) and the game the grass fade and the trample - so those
// few are tuned in the biomes, everything else on the material.

// A/B SWITCHES FOR THE DEVICE (uncomment one, run, compare FPS; the picture changes - for measuring
// only, never commit one on). Each cuts one block, so the frame time it gives back is that block's cost:
// #define PROBE_NO_DETAIL      // the detail fetch and its ~20 ALU a pixel
// #define PROBE_NO_LIFT        // the grass/snow lift: hashes and the trample fetch in the VERTEX stage
// #define PROBE_NO_TONE        // the slow tone noise (vnoise, 4 hashes a vertex)
// #define PROBE_NO_HAZE        // the haze written to FOG
// #define PROBE_NO_SHADOW      // the fast ground's one shadow fetch and its branches (FAST_GROUND only)
// #define PROBE_FLAT_VERTEX    // the whole vertex colour block: v_* constant, only position + haze
group_uniforms Texture;
// THE GROUND'S DETAIL (art/ground_detail.py): four tileable masks read in the ONE fetch the old
// tile used - R cracked earth, G sand ripples, B grass clumps, A broad patches. Masks, not colour:
// no source_color. Set by TerrainBiomes.apply_to_material. Each biome takes its own channel, after
// TerraTech's ground (the player's screenshots): the desert rippled, the meadow tufted, everything
// a little patchy, so no ground is one flat colour.
uniform sampler2D ground_detail : hint_default_white, filter_nearest_mipmap, repeat_enable;
uniform float detail_world_size : hint_range(1.0, 40.0)  = 9.0;
uniform float ripple_strength   : hint_range(0.0, 1.0)   = 0.55;
uniform float grass_detail      : hint_range(0.0, 1.0)   = 1.0;
uniform float patch_strength    : hint_range(0.0, 0.5)   = 0.10;
// THE PAINTED GROUND (the player's reference: a hand-painted forest floor, first on the meadow, then
// "the other biomes too"). The detail's B channel is brush dabs round a neutral 0.5
// (art/ground_detail.py): below it the ground turns toward its biome's DARK tint, above toward its
// LIGHT one - a shift of HUE, a cool shade against a warm light, not only of shade. The same pair, its
// square root, tints a slow tone noise (~25 m) per vertex, so no tile reads as a tile. One pair a
// biome, blended per vertex in the order the colours are (v_pd / v_pl): the fragment mixes two
// varyings by the one fetch it already makes. The STYLE only, the player's word: no paths or
// clearings were asked for, and none are drawn.
uniform vec3  stroke_dark  : source_color = vec3(0.62, 0.80, 0.84);    // the meadow
uniform vec3  stroke_light : source_color = vec3(1.30, 1.20, 0.74);
uniform vec3  sand_dark    : source_color = vec3(0.93, 0.88, 0.84);    // warm ochre, deeper
uniform vec3  sand_light   : source_color = vec3(1.07, 1.06, 1.08);    // pale, sun-bleached
uniform vec3  salt_dark    : source_color = vec3(0.90, 0.90, 0.97);    // a cool grey-blue film
uniform vec3  salt_light   : source_color = vec3(1.07, 1.05, 1.02);
uniform vec3  canyon_dark  : source_color = vec3(0.84, 0.82, 0.94);    // dusty purple shade
uniform vec3  canyon_light : source_color = vec3(1.12, 1.08, 0.98);    // sunlit orange
uniform vec3  rock_dark    : source_color = vec3(0.76, 0.82, 0.96);    // blue-grey shade
uniform vec3  rock_light   : source_color = vec3(1.18, 1.12, 1.00);    // warm grey
uniform vec3  snow_dark    : source_color = vec3(0.88, 0.93, 1.03);    // blue snow shade
uniform vec3  snow_light   : source_color = vec3(1.03, 1.02, 0.98);    // warm white
// The rock is cut into facets by the same cells the salt flat cracks into (the detail's R channel),
// lighter: a dark seam between plates and a tone a plate. On a cliff they run down the slope - the
// detail lies on the ground's plane - and read as weathered streaks.
uniform float rock_facets  : hint_range(0.0, 1.0)   = 0.55;

group_uniforms Colors;
uniform vec4 color_sand  : source_color = vec4(0.87, 0.74, 0.49, 1.0);  // warm golden sand (desert)
uniform vec4 color_grass : source_color = vec4(0.33, 0.56, 0.23, 1.0);  // lush green (meadow)
uniform vec4 color_snow  : source_color = vec4(0.94, 0.96, 1.00, 1.0);
// SNOW FOLLOWS HEIGHT, not just the mountain mask. The mask says WHERE the mountain region is;
// it says nothing about how high the ground actually got there. Painting by the mask alone put
// white patches on flat ground inside that region — the colour and the landform disagreed, and
// the map read as broken. snow_line is the world height where snow starts, snow_blend the
// softness of that edge.
//
// BOTH ARE METRES AND BOTH ARE COMPUTED, not authored: the biome resource holds them as a share of
// the world's Height and multiplies it out (TerrainBiomes.snow_line_at). Metres set by hand only
// ever match the one map they were set for.
uniform float snow_line  : hint_range(-100.0, 400.0) = 60.0;
uniform float snow_blend : hint_range(1.0, 120.0)    = 25.0;
uniform vec4 color_rock  : source_color = vec4(0.50, 0.50, 0.54, 1.0);  // blue-grey (contrasts with canyon rock)

group_uniforms Terrain;
uniform float rock_threshold     : hint_range(0.0, 1.0)      = 0.7;
uniform float rock_blend         : hint_range(0.0, 0.5)      = 0.15;

group_uniforms Biomes;
uniform float sand_grass        : hint_range(0.0, 0.5)     = 0.1;    // the desert's share of the meadow's grass
// CANYON biome: terracotta regions. Overrides sand and meadow, dry land, no grass.
uniform vec4  color_canyon      : source_color = vec4(0.70, 0.30, 0.15, 1.0);
uniform float canyon_band_h     : hint_range(2.0, 12.0)    = 6.0;    // stratum height (matches the geometry terrace)
// SALT FLATS: a dried lake bed, cracked into tiles (the ground detail's R channel). Its mask rides
// in COLOR.r with the vertex's BORDER CODE (chunk_terrain EDGE_STEP / SALT_SPAN): r = code / 3 +
// SALT_SPAN x salt, code 0 inside the node, 1 on a border running along x, 2 along z.
uniform vec4  color_salt        : source_color = vec4(0.90, 0.84, 0.74, 1.0);
uniform float crack_strength    : hint_range(0.0, 1.0)     = 0.65;
const float SALT_SPAN = 0.3;
const float SNOW_HOLD = 0.14;

group_uniforms Grass;
uniform float grass_density     : hint_range(0.0, 1.0)    = 1.0;   // share of meadow vertices lifted
uniform float grass_height      : hint_range(0.0, 1.0)    = 0.3;
uniform float grass_shade       : hint_range(0.4, 1.2)    = 0.62;
// Where the lift fades out, metres from the camera over the ground: before the first seam the
// border rule below cannot hold (level 1 against level 2). Set by chunk_terrain (_grass_fade).
uniform vec2  grass_fade = vec2(72.0, 96.0);

group_uniforms Trample;
// Grass flatten map (fed by grass.gd through a SubViewport). Black by default = no effect,
// so it can be left unconnected.
uniform sampler2D trample_map : hint_default_black, filter_linear;
uniform vec2  trample_center = vec2(0.0);
uniform float trample_size   = 130.0;
// set by ChunkTerrain.set_grass_trample: with no map there is nothing to fetch in the vertex stage
uniform bool  trample_on     = false;
group_uniforms;


// The zone colour and the slope-driven fade into rock are computed in the VERTEX stage
// (v_base_col) and interpolated: the terrain is fill-bound and there are orders of magnitude
// fewer vertices than pixels. The fragment stage keeps only what has to be per-pixel — the
// detail masks, the shadow fetch and the lighting.
//
// THE HAZE costs one smoothstep a VERTEX: the engine's fog was tried and cost 5-7 fps of 23 on
// the device (CLAUDE.md, Look and light), for the one thing wanted - far ground going into the
// horizon's colour. The per-pixel detail stops long before it
// (DETAIL_FAR), and the far chunks are most of the frame.
// THE HAZE IS THE WORLD'S, NOT THIS MATERIAL'S (project.godot [shader_globals]): `world_haze` is
// its colour - day_cycle.gd moves it with the hour, warm cream by day, orange at dusk, deep blue at
// night - and the sky's horizon IS that colour, so far ground melts into the sky as TerraTech's does
// (the player's screenshot). `haze_range` = begin, end (m), strength. The trees read the same two.
// It is written to FOG, which the renderer mixes in AFTER the lighting, in this same pass: mixed
// into ALBEDO it was lit again, and a far slope in shade came out a dark smudge in bright haze.
global uniform vec4 world_haze;
global uniform vec4 haze_range;
#ifdef FAST_GROUND
global uniform vec4 sun_dir;
global uniform vec4 ground_amb;
global uniform vec4 ground_sun;
varying mediump float v_sun;   // the lambert term; ground_sun.rgb is a uniform, multiplied in the fragment
// THE SUN'S SHADOW CASCADES (sun_shadows.gd): top-down windows of casters projected along the light,
// near to far at 25 cm, 67 cm and 2 m a texel. Each window: uv = world.xz * x + yz, w = its half in
// metres, 0 while that map is not built. ONE FETCH A PIXEL: which window a pixel reads is decided per
// VERTEX (`v_shsel`, the distance into each window is piecewise linear, so interpolating it is exact
// but at the corners) and the fragment only branches on it - `textureLod`, since an implicit
// derivative inside a branch some pixels of a quad skip is undefined. sun_shadow_strength 0 = no
// map (shadows off): nothing is fetched.
uniform sampler2D sun_shadow_map : hint_default_black, filter_linear;
uniform sampler2D sun_shadow_map1 : hint_default_black, filter_linear;
uniform sampler2D sun_shadow_map2 : hint_default_black, filter_linear;
uniform vec4 sun_shadow_uv0 = vec4(0.0);
uniform vec4 sun_shadow_uv1 = vec4(0.0);
uniform vec4 sun_shadow_uv2 = vec4(0.0);
uniform float sun_shadow_strength = 0.0;
// x, y, z: how far past its hand-over line a vertex stands in window 0, 1, 2 (< 0: that window);
// w: the outermost window's fade, 1 inside and 0 past its edge
// mediump: the three are metres used for their SIGN only (fp16 holds +-65504 m, and a sign near the
// line is decided at a few mm either way), w a 0..1 fade
varying mediump vec4 v_shsel;
// A window with another after it hands over SH_BAND m inside its edge (sun_shadows.SH_BAND), the line
// wandering SH_DITHER m by a hash a vertex, so the change of sharpness is no straight seam. The last
// window fades out over the last SH_FADE of its half, as the one window always did.
const float SH_BAND = 8.0;
const float SH_DITHER = 6.0;
const float SH_FADE = 1.0 / 6.0;
#endif
// THE PACKED VARYINGS: x the haze (strength in), y the detail fade (v_det) - one mediump vec2
varying mediump vec2 v_hd;
// THE DETAIL IS DRAWN ONLY OUT TO DETAIL_FAR, faded over DETAIL_FADE before it (it ran to the solid
// haze; 80 m first, doubled at the player's call once the ground was painted), on the ground's own plane everywhere (canyon walls streak; three planes were a pick a
// pixel), and there is no per-pixel colour hash - the player's cuts after the phone's probe put the
// detail block at ~7 ms, tried as switches and kept on.
const float DETAIL_FAR = 160.0;
const float DETAIL_FADE = 40.0;


// MEDIUMP WHERE IT IS A COLOUR (the phone's GPU, Adreno 610, runs half floats at twice the rate and
// stores half the varying memory per vertex in its binning pass): a colour ends 8-bit, and fp16 is
// 11 bits of mantissa, so the picture cannot tell. World positions
// stay highp in v_wpos - the detail uv needs it; v_shsel is mediump (signs only).
// THE BASE COLOUR RIDES IN THE DAB PAIR (v_bd = base x dark, v_bl = base x light): the fragment's
// base * mix(pd, pl, b) is mix(base*pd, base*pl, b), and past DETAIL_FAR both are 1 x base. Three
// floats a vertex fewer; the products are interpolated instead of the factors - measured the same
// picture (map_diff2.png).
// THE DETAIL'S STRENGTHS, every one worked out per vertex with DETAIL_FAR's fade folded in, so the
// fragment only multiplies: the dab tints (dark, light), the ripples a channel (bare sand, snow),
// the cracks as 1 + x + y * R (the salt flat, the rock's facets), the patches.
varying mediump vec3  v_bd;
varying mediump vec3  v_bl;
// xy the ripples' sand and snow weight (tints RIP_SAND / RIP_SNOW are constants: linear, so exact), zw the cracks
varying mediump vec4  v_rc;
varying vec2  v_wpos;
const vec3 RIP_SAND = vec3(0.24, 0.30, 0.40);
const vec3 RIP_SNOW = vec3(0.22, 0.16, 0.06);         // world x, z - the detail fetch and the shadow lookup

float hash2D(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Value noise on the hash lattice: vertex work only (a few per vertex), never per pixel.
float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash2D(i), hash2D(i + vec2(1.0, 0.0)), f.x),
               mix(hash2D(i + vec2(0.0, 1.0)), hash2D(i + vec2(1.0, 1.0)), f.x), f.y);
}

// THE BLADE AT ONE WORLD POINT: whether it grows (the hash against the meadow share) and how far
// the trample map presses it down. A function of the point and nothing else.
float blade_at(vec2 p, float amount) {
    if (hash2D(p) >= grass_density * amount) {
        return 0.0;
    }
    float h = grass_height * amount;
    vec2 t_uv = (p - trample_center) / trample_size + vec2(0.5);
    if (trample_on && t_uv.x >= 0.0 && t_uv.x <= 1.0 && t_uv.y >= 0.0 && t_uv.y <= 1.0) {
        h -= clamp(textureLod(trample_map, t_uv, 0.0).r, 0.0, 1.0) * grass_height * amount * 2.0;
    }
    return h;
}

// THE SNOW CRUST ON THE PEAKS (the player's call: "lift the vertices on the mountains like the grass,
// as snow"): where the snow line has put snow and the face is not rock, EVERY vertex rises, by
// snow_height times its own hash (no gaps, unlike grass blades) - a lumpy crust. The same point
// function and border rule as the grass, so seams between levels meet; not over the grass height,
// which is what the shot marks' and the landing wave's depth lift clear (G.grass_lift).
uniform float snow_height : hint_range(0.0, 1.0) = 0.3;

float drift_at(vec2 p, float amount) {
    return snow_height * amount * (0.45 + 0.55 * hash2D(p + vec2(17.1, 3.7)));
}

#ifdef FAST_GROUND
// How far past its hand-over line `p` stands in the window `u` (< 0: inside it), in metres.
float sh_out(vec2 p, vec4 u, float band) {
    vec2 d = abs(p - (vec2(0.5) - u.yz) * (2.0 * u.w));
    return max(d.x, d.y) - (u.w - band);
}
#endif

void vertex() {
    vec4 world_pos = MODEL_MATRIX * vec4(VERTEX, 1.0);
    float wy = world_pos.y;
    vec3 wn       = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
    v_wpos     = world_pos.xz;
    // Distance is measured ALONG THE GROUND, without height: otherwise a mountain under the camera, a hundred
    // metres down, would drown in the haze on a par with the horizon.
    float ground_d = length(world_pos.xz - CAMERA_POSITION_WORLD.xz);
    float v_haze = smoothstep(haze_range.x, haze_range.y, ground_d) * haze_range.z;   // the strength folded in: linear, so exact
    float v_det = 1.0 - smoothstep(DETAIL_FAR - DETAIL_FADE, DETAIL_FAR, ground_d);
#ifdef FAST_GROUND
    // `ground_sun.a` wraps the lambert term: the lit path's slopes turned from the sun came out lighter
    // than a plain max(n.l, 0) gives (fitted on the real driver, day_cycle.GROUND_WRAP)
    float ndl = dot(wn, normalize(sun_dir.xyz));
    v_sun = clamp((ndl + ground_sun.a) / (1.0 + ground_sun.a), 0.0, 1.0);
    v_shsel = vec4(1.0, 1.0, 1.0, 0.0);
    if (sun_shadow_strength > 0.0 && sun_shadow_uv0.w > 0.0) {
        vec2 sp = world_pos.xz;
        float dith = (hash2D(floor(sp) + vec2(31.7, 9.3)) - 0.5) * SH_DITHER;
        bool has1 = sun_shadow_uv1.w > 0.0;
        bool has2 = sun_shadow_uv2.w > 0.0;
        v_shsel.x = sh_out(sp, sun_shadow_uv0, (has1 || has2) ? SH_BAND - dith : 0.0);
        v_shsel.y = has1 ? sh_out(sp, sun_shadow_uv1, has2 ? SH_BAND - dith : 0.0) : 1.0;
        v_shsel.z = has2 ? sh_out(sp, sun_shadow_uv2, 0.0) : 1.0;
        vec4 last = has2 ? sun_shadow_uv2 : (has1 ? sun_shadow_uv1 : sun_shadow_uv0);
        v_shsel.w = clamp(-sh_out(sp, last, 0.0) / (last.w * SH_FADE), 0.0, 1.0);
    }
#endif


    // The biome masks are baked into the vertex COLOR by the terrain (chunk_terrain._biome_colour).
    float biome_grass = COLOR.b;
    float canyon  = COLOR.g;
    float mountain = COLOR.a;                                          // MOUNTAIN biome (snowy, high)
    // THE STRATA ARE PAINTED: a band by height (a flat tread gets one), each a colour of a short
    // palette round color_canyon - orange-red, deep red, a dusty purple-brown and, rarer, a salmon -
    // and a shade of its own. One terracotta a little lighter or darker read as one red mass.
    // hash2D is NOT used here: on whole numbers it clusters (a quarter of the bands came out over
    // 0.9), and the rare pale band painted whole canyon floors sand-coloured.
    // Only a canyon vertex pays for its band (two sin and the palette): everywhere else canyon_col is
    // weighted by canyon (or cliff_c, canyon times something) = 0, so the result is the same.
    vec3  canyon_col = color_canyon.rgb;
    if (canyon > 0.0) {
        float band_id    = floor(wy / canyon_band_h);
        float bh         = fract(sin(band_id * 91.7 + 7.3) * 43758.5453);   // 0..1 per band, stable
        vec3  cc         = color_canyon.rgb;
        canyon_col = bh < 0.40 ? cc * vec3(1.10, 1.12, 1.00)
                   : bh < 0.72 ? cc * vec3(0.86, 0.80, 0.86)
                   : bh < 0.90 ? cc * vec3(0.74, 0.86, 1.36)
                   :             cc * vec3(1.12, 1.42, 1.55);
        canyon_col      *= 0.90 + 0.18 * fract(sin(band_id * 47.3 + 2.1) * 43758.5453);
    }
    // Colour channels are 8-bit: the code is read with a margin, the salt is what is left over.
    float edge    = floor(COLOR.r * 3.0 + 0.05);
    float salt    = clamp((COLOR.r - edge / 3.0) / SALT_SPAN, 0.0, 1.0);
    vec3  zone    = mix(color_sand.rgb, color_grass.rgb, biome_grass);  // desert ↔ meadow
    zone          = mix(zone,           color_salt.rgb,   salt);        // the salt flat on the desert
    zone          = mix(zone,           canyon_col,       canyon);      // canyon on top
    float snow    = mountain * smoothstep(snow_line - snow_blend, snow_line + snow_blend, wy);
    zone          = mix(zone,           color_snow.rgb,   snow);        // snow only up high
    // snow clings to steeper ground than bare earth (SNOW_HOLD): a far mountain's coarse normals
    // otherwise read a whole flank as rock - a grey smudge over the snow
    float rock_at = rock_threshold - SNOW_HOLD * snow;
    float rock_t  = 1.0 - smoothstep(rock_at - rock_blend, rock_at + rock_blend, wn.y);
    // a canyon cliff is its stratum in shade, so the bands run on up the walls (a flat dark brown
    // hid them where they show best); over the snow line a cliff is the mountain's grey rock, or a
    // canyon under a mountain put brown blots on its snow
    float cliff_c = canyon * (1.0 - snow);
    vec3  rock_col = mix(color_rock.rgb, canyon_col * vec3(0.70, 0.64, 0.74), cliff_c);
    vec3 v_base_col = mix(zone, rock_col, rock_t);

    // the painted pair, assembled in the colours' own order
    vec3 pd = mix(sand_dark,  mix(vec3(1.0), stroke_dark,  grass_detail), biome_grass);
    vec3 pl = mix(sand_light, mix(vec3(1.0), stroke_light, grass_detail), biome_grass);
    pd = mix(pd, salt_dark, salt);      pl = mix(pl, salt_light, salt);
    pd = mix(pd, canyon_dark, canyon);  pl = mix(pl, canyon_light, canyon);
    pd = mix(pd, snow_dark, snow);      pl = mix(pl, snow_light, snow);
    pd = mix(pd, mix(rock_dark, canyon_dark, cliff_c), rock_t);
    pl = mix(pl, mix(rock_light, canyon_light, cliff_c), rock_t);

    // THE MEADOW'S TONE COMES FROM THE BIOME, NOT FROM WHETHER THIS VERTEX WAS LIFTED: only the near
    // level lifts, and only by a hash's roll, so a tone by the lift gave the near meadow two tones
    // in patches and the far one a third (the player: "two colours, and a third in the distance").
    // Every level knows the masks and the slope; the lift below stays geometry, seen only near.
    float grass_amount = mix(sand_grass, 1.0, biome_grass)
            * (1.0 - rock_t) * (1.0 - canyon) * (1.0 - mountain) * (1.0 - salt);
    // the grass's colour share: the meadow's tone at the root (grass_shade) against the 0.78 of
    // every other ground. Per vertex: it was a multiply a pixel.
    float grass_col = clamp(biome_grass * (1.0 - rock_t) * (1.0 - canyon) * (1.0 - salt) * (1.0 - snow), 0.0, 1.0);
    v_base_col *= mix(0.78, grass_shade, grass_col);
    // a slow change of tone (~25 m) between the biome's cool shade and its warm light - the dabs'
    // pair, softened - so the 9 m tile never reads as a tile
#ifdef PROBE_NO_TONE
    float tone = 0.5;
#else
    float tone = vnoise(world_pos.xz * 0.04 + vec2(5.0, 9.0));
#endif
    v_base_col *= sqrt(mix(pd, pl, tone));
    vec3 v_pd = mix(vec3(1.0), pd, v_det);
    vec3 v_pl = mix(vec3(1.0), pl, v_det);
    // RIPPLES on bare sand and, softer, on snow (wind-blown): a tint, not a shade - on sand the crest
    // pale and the trough a deeper ochre, on snow the trough blue
    float bare = (1.0 - canyon) * (1.0 - rock_t) * (1.0 - salt);
    float sand_w = clamp((1.0 - biome_grass) * (1.0 - snow) * bare, 0.0, 1.0);
    float snow_w = clamp(snow * (1.0 - rock_t), 0.0, 1.0);
    vec2 v_rip = vec2(sand_w, snow_w) * (ripple_strength * v_det);
    // CRACKS: the salt flat's deep ones, the rock's light facets (mix(lo, 1.08, R) each, as 1 + x + y R)
    float salt_w = clamp(salt * (1.0 - canyon) * (1.0 - rock_t), 0.0, 1.0) * crack_strength;
    float rock_w = rock_t * mix(1.0, 0.5, cliff_c) * rock_facets;
    vec2 v_crack = (salt_w * vec2(0.35 - 1.0, 1.08 - 0.35) + rock_w * vec2(0.62 - 1.0, 1.08 - 0.62)) * v_det;
    // THE GRASS IS A FUNCTION OF THE WORLD POINT, ON EVERY LEVEL, so two nodes meeting on a seam
    // lift their shared vertices alike whatever their levels and whenever each was built. It used to
    // be the near level only, with the border rows flagged flat where the neighbour was coarser -
    // a flag baked from the neighbours at build time, and stale whenever a neighbour changed level
    // before this node was rebuilt: one side up 0.3 m, the other flat, the sky through the slit
    // (measured: half the frames of a drive had one). Hence straight up, not along NORMAL (a coarse
    // node's normals differ), and THE BORDER RULE: a vertex on a node's border at an odd metre
    // takes the mean of its two neighbours along the border - exactly what a level-1 neighbour,
    // whose edge runs straight between those two, draws there. Inside a node every vertex is its
    // own blade, as before. Grass grows in the meadow and, sparser, on sand (sand_grass), none on
    // rock, in the canyon or on mountains; amount scales both height and density.
    float amount = grass_amount;
    float drift = clamp(snow * (1.0 - rock_t), 0.0, 1.0);   // snow is painted over a canyon too
    float fade = 1.0 - smoothstep(grass_fade.x, grass_fade.y, ground_d);
#ifdef PROBE_NO_LIFT
    fade = 0.0;
#endif
    if (fade > 0.0 && (amount > 0.03 || drift > 0.03)) {
        vec2 p = floor(world_pos.xz + 0.5);           // vertices stand on whole metres
        float lift;
        if (edge > 0.5 && mod(edge > 1.5 ? p.y : p.x, 2.0) > 0.5) {
            vec2 along = edge > 1.5 ? vec2(0.0, 1.0) : vec2(1.0, 0.0);
            lift = 0.5 * (blade_at(p - along, amount) + blade_at(p + along, amount)
                    + drift_at(p - along, drift) + drift_at(p + along, drift));
        } else {
            lift = blade_at(p, amount) + drift_at(p, drift);
        }
        // the crust has no normals of its own (the lift is straight up), so its lumps are TONED: a
        // high vertex brighter, a low one a shade blue - without it a white crust on white snow
        // showed only on the skyline. Per vertex, into the colour it rides on: the tone is the
        // vertex's own, and a varying of it was a multiply a pixel.
        float lump = drift * fade * (hash2D(p + vec2(17.1, 3.7)) - 0.5);
        v_base_col *= vec3(1.0) + lump * vec3(0.30, 0.24, 0.10);
        VERTEX.y += lift * fade;
    }
    v_bd = v_base_col * v_pd;
    v_bl = v_base_col * v_pl;
#ifdef PROBE_FLAT_VERTEX
    v_bd = vec3(0.5); v_bl = vec3(0.5); v_rip = vec2(0.0); v_crack = vec2(0.0);
#endif
    v_rc = vec4(v_rip, v_crack);
    v_hd = vec2(v_haze, v_det);
}

void fragment() {
    mediump vec3 base_col = v_bd;
    mediump float v_det = v_hd.y;
    mediump vec2 v_rip = v_rc.xy;
    mediump vec2 v_crack = v_rc.zw;

#ifndef PROBE_NO_DETAIL
    // The detail masks, one fetch on the ground's plane (DETAIL_FAR above); every strength comes
    // from the vertex with the fade in it.
    // past a fade of 1/255 the detail cannot change a byte of the colour: no fetch there (the 40 m band
    // before DETAIL_FAR), and the divide by a uniform is a multiply the driver can hoist
    if (v_det > 0.004) {
        mediump vec4 dt = texture(ground_detail, v_wpos * (1.0 / detail_world_size));
        // the patches' strength is the uniform times v_det - a varying of it was one more slot a vertex
        mediump float k = (1.0 + (dt.a - 0.5) * (2.0 * patch_strength * v_det)) * (1.0 + v_crack.x + v_crack.y * dt.r);
        // each dab shifts the hue: dark ones toward the biome's cool shade, light ones its warm light
        mediump vec3 rip = RIP_SAND * v_rip.x + RIP_SNOW * v_rip.y;
        base_col = clamp(k * (vec3(1.0) + rip * (dt.g - 0.53)) * mix(v_bd, v_bl, dt.b), 0.0, 1.0);
    }
#endif

    ALBEDO    = base_col;
#ifdef FAST_GROUND
    mediump float shade = 0.0;
#ifndef PROBE_NO_SHADOW
    if (sun_shadow_strength > 0.0 && v_shsel.w > 0.0) {
        vec2 sp = v_wpos;
        mediump float s = 0.0;
        if (v_shsel.x < 0.0) {
            s = textureLod(sun_shadow_map, sp * sun_shadow_uv0.x + sun_shadow_uv0.yz, 0.0).r;
        } else if (v_shsel.y < 0.0) {
            s = textureLod(sun_shadow_map1, sp * sun_shadow_uv1.x + sun_shadow_uv1.yz, 0.0).r;
        } else if (v_shsel.z < 0.0) {
            s = textureLod(sun_shadow_map2, sp * sun_shadow_uv2.x + sun_shadow_uv2.yz, 0.0).r;
        }
        shade = s * v_shsel.w * sun_shadow_strength;
    }
#endif
    ALBEDO   *= ground_amb.rgb + ground_sun.rgb * (v_sun * (1.0 - shade));   // mediump: a colour
#endif
    ROUGHNESS = 0.9;

    // the haze last, over everything: the air between the camera and the surface
#ifndef PROBE_NO_HAZE
    FOG = vec4(world_haze.rgb, v_hd.x);
#endif
}
