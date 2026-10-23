@tool
class_name TerrainBiomes
extends Resource

## The single source of truth for biomes: the landform generator (terrain_gen.gd), the masks the
## terrain bakes into vertex colour (chunk_terrain.gd) and the material colours all read from
## here, so a biome's colour cannot drift away from its terrain.
##
## A biome is a 0..1 MASK of world-XZ noise. Layers stack in this order:
##   base DESERT ↔ MEADOW split  →  SALT FLATS on the desert  →  CANYON on top  →  MOUNTAINS on top.
## Every layer is always on: the switches that could turn one off were never used, and a world
## without its canyons is not a setting the game has.
##
## Settings alone cannot add a biome of your own: each layer's colour is written out in
## glsl.gdshader (vertex(), where v_base_col is assembled), so a new layer means editing the
## shader as well as adding its mask here.

# ── Base land split: DESERT ↔ MEADOW ──────────────────────────────────────────
@export_group("Desert / Meadow")
## Biome patch size in world units. Smaller fits several biomes on screen at once.
@export_range(30.0, 1000.0, 1.0) var biome_scale: float = 340.0
## Split threshold: above 0.5 gives more sand, below it more meadow.
@export_range(0.0, 1.0, 0.01) var biome_bias: float = 0.5
## Transition width. Narrower gives a crisp border instead of a muddle.
@export_range(0.02, 0.5, 0.01) var biome_blend: float = 0.07
## Noise contrast stretched before the threshold: higher packs the patches and hardens edges.
@export_range(0.5, 4.0, 0.1) var biome_contrast: float = 1.8
@export var color_sand: Color = Color(0.87, 0.74, 0.49)
@export var color_grass: Color = Color(0.36, 0.60, 0.21)
## Dune ridge wavelength, m. (Their height follows the world's Height, terrain_gen._gen_dune_amp.)
@export_range(5.0, 200.0, 1.0) var dune_wavelength: float = 34.0
## How far to flatten hills in the desert: 0 is a table, 1 is as hilly as the meadow.
@export_range(0.0, 1.0, 0.05) var desert_flatten: float = 0.4

# ── SALT FLATS ────────────────────────────────────────────────────────────────
# A DRIED LAKE BED, after TerraTech's Salt Flats (the player's screenshot): ground near flat to the
# horizon, cracked into tiles. It lies only INSIDE the desert and never under mountains; the
# generator flattens the land under it (terrain_gen.raw_height_at) and the canyon does not cut it
# (carve_at). Stacking: desert/meadow -> salt on the desert -> canyon -> mountains.
@export_group("Salt flats")
@export_range(30.0, 1500.0, 1.0) var salt_scale: float = 520.0
## Higher is rarer. Value noise is centred, so this sits above the others' 0.66-0.71.
@export_range(0.0, 1.0, 0.01) var salt_threshold: float = 0.70
## Wider than the other edges: the flattening rides on it, and a narrow edge is a cliff.
@export_range(0.02, 0.5, 0.01) var salt_edge: float = 0.08
@export var color_salt: Color = Color(0.90, 0.84, 0.74)

# ── CANYON ────────────────────────────────────────────────────────────────────
@export_group("Canyon")
@export_range(30.0, 1000.0, 1.0) var canyon_scale: float = 450.0
## Higher threshold means rarer canyons.
## THE THRESHOLD IS FITTED TO THE NOISE DISTRIBUTION, not chosen by eye. The old hash gave a uniform
## 0..1, native value noise is centred — at the same threshold 0.70 the canyon came out 18.8% of the area
## instead of the previous 24.4%. Measured on five seeds, a 4 km patch: 0.66 returns 24.2%.
@export_range(0.0, 1.0, 0.01) var canyon_threshold: float = 0.66
## Narrower edge means a steeper outer wall.
@export_range(0.02, 0.5, 0.01) var canyon_edge: float = 0.05
@export var color_canyon: Color = Color(0.70, 0.30, 0.15)
## Height of one colour stratum. Must match the geometry terrace or the banding slides
## along the wall.
@export_range(2.0, 12.0, 0.5) var canyon_band_height: float = 6.0
## Scale of the mesa-height variation — the large buttes (landform only).
@export_range(20.0, 400.0, 1.0) var canyon_butte_scale: float = 110.0

# ── MOUNTAINS ─────────────────────────────────────────────────────────────────
@export_group("Mountains")
@export_range(30.0, 1500.0, 1.0) var mountain_scale: float = 420.0
## By the same measurement: 0.72 gave 18.5% mountains instead of the previous 20.0%, 0.71 hits the target.
@export_range(0.0, 1.0, 0.01) var mountain_threshold: float = 0.71
@export_range(0.02, 0.5, 0.01) var mountain_edge: float = 0.05
## (How high a mountain rises follows the world's Height: terrain_gen._gen_mtn_rise.)

# ── Snow and rock ─────────────────────────────────────────────────────────────
# Snow follows the MOUNTAIN biome rather than altitude: the colour comes from its mask.
@export_group("Snow / rock")
@export var color_snow: Color = Color(0.94, 0.96, 1.00)
## FROM WHAT HEIGHT SNOW LIES, as a SHARE OF THE WORLD'S HEIGHT, and how soft that line is. The
## mountain mask says WHERE the mountain region is, but says nothing about how far the ground
## actually rose there: snow painted from the mask alone landed as white patches on flat ground
## inside the region.
##
## A SHARE, not metres, and this is the whole point of these two fields. Metres held here meant a
## number that only made sense next to the Height that produced it - and that Height is not in this
## resource. So the generator "helpfully" overwrote the metres on every run: a slider you could drag
## that moved back, an output stored in an input, a scene diff after every Generate, and a value
## that reached the shader once and was wrong ever after for any world that did not run the
## generator at load (apply_to_material now does the arithmetic).
@export_range(0.0, 1.5, 0.01) var snow_frac: float = 0.55
@export_range(0.01, 0.6, 0.01) var snow_blend_frac: float = 0.12
## The softest the snow line may be, in metres. On a low world the fraction alone gives a line so
## sharp it reads as a cut-out.
const SNOW_BLEND_MIN := 8.0

## The two in metres, for a world of this Height. One door: the shader, the props and anything else
## asking "where does snow start" go through here.
func snow_line_at(world_height: float) -> float:
	return world_height * snow_frac

func snow_blend_at(world_height: float) -> float:
	return maxf(world_height * snow_blend_frac, SNOW_BLEND_MIN)
@export var color_rock: Color = Color(0.50, 0.50, 0.54)
## How steep a slope has to be before the surface turns to rock.
@export_range(0.0, 1.0, 0.01) var rock_threshold: float = 0.7
@export_range(0.0, 0.5, 0.01) var rock_blend: float = 0.15

# ── Grass ─────────────────────────────────────────────────────────────────────
@export_group("Grass")
## The share of meadow vertices lifted as blades: 1 is every one. It stood at 0.4 once, and the
## meadow came out bald in patches; the trample map (tyre tracks) presses down the same vertices,
## so where none is lifted there is no track either.
@export_range(0.0, 1.0, 0.01) var grass_density: float = 1.0
## THE GAME'S NUMBERS ARE THE DEFAULTS (0.3 m, 0.1 on sand): the world scene set them over 0.15 and
## 0, and the menu - the same ground, said to show the land the player is about to drive into -
## drew the meadow at half the height and the desert bare.
@export_range(0.0, 1.0, 0.01) var grass_height: float = 0.3
## How much grass the DESERT gets relative to the meadow. 0 is dry sand. Rock, canyon and
## mountains never carry grass.
@export_range(0.0, 0.5, 0.01) var sand_grass: float = 0.1
## Below 0.65 the grass is slightly darker than the ground — a soft shadow at the root
## rather than a bright patch.
@export_range(0.4, 1.2, 0.01) var grass_shade: float = 0.80

## THE SIZE OF A BIOME PATCH IS DECIDED BY `scale`, AND ONLY BY IT. A mask is one noise octave and a threshold, with no minimum
## size: near the threshold, slivers of two or three chunks are always born, and those are exactly what
## catch the eye while driving. Measured over connected patches on 6×6 km, three seeds:
##
##   meadow  230 → median 224 m, every sixth patch under 128 m;  340 → 352 m and every twenty-
##          fifth. It does not improve further: a 50/50 border always gives isthmuses.
##   canyon  250 → median 208 m, every seventh under 128 m;  450 → 464 m and every thirtieth.
##   mountains 420 → median 336 m, no small ones at all. We leave it alone.
##
## THE THRESHOLD IS LEFT AS IT WAS. Lowering it to 0.58 removes the small ones entirely, but the canyon's share of the map
## grows from 22% to 39% — that is a different world, not the same one with bigger patches.
##
## Blurring the noise itself (as the heights are blurred) DOES NOT WORK, checked: blurring moves the threshold line,
## but does not remove the braids — at a radius of 80 m there were even more small ones.
# ── Masks (the same maths the shader assumes) ─────────────────────────────────
# Each layer samples the noise at its own offset, otherwise canyons and mountains would
# land on one and the same patch.
const CANYON_OFFSET := Vector2(101.0, 53.0)
const MOUNTAIN_OFFSET := Vector2(211.0, 77.0)
const SALT_OFFSET := Vector2(331.0, 19.0)

## WHERE THE BIOMES SIT, moved by the SEED. The masks come from a hash-based value noise with
## fixed constants, so without this every seed produced new hills in exactly the same desert,
## with the canyon in exactly the same corner — the world changed shape but not geography.
##
## It lives in the RESOURCE and not in the generator because two different places read these
## masks: the generator carves the landform by them, and the terrain colours and ore veins by
## the same call at runtime. One offset, one answer, no way for them to disagree.
## NOT AN EXPORT: it is an OUTPUT - always worked out from the seed (offset_for_seed, by the
## generator and the menu) - and as an export it was saved into the scenes with whatever seed the
## editor last previewed.
var mask_offset: Vector2 = Vector2.ZERO

## THE NOISE THE MASKS ARE BUILT ON, in one place, and every mask reads it HERE - its callers used
## to each carry their own copy of those lines (the generator, the terrain, the menu backdrop), and a
## copy is how the painted region and the carved region drifted apart once already. The masks took it
## as a Callable once (`biomes.noise`), always this very function: a Callable dispatch and a wrapper
## frame per mask, ~13% of `raw_height_at` on the optimize=none build, for a choice nobody made.
##
## IT IS NATIVE NOISE NOW, AND THAT IS THE WHOLE POINT. This used to be eight lines of GDScript —
## four hashes and three lerps — and those eight lines were where the world's loading time lived.
## Measured, 200k calls each:
##
##   FastNoiseLite.get_noise_2d, SIX octaves, C++   0.84 us
##   this function, ONE octave, GDScript           17.34 us      ← twenty times slower, doing less
##   three biome masks per point                   60.5  us
##   LiteTerrainGen.height_at per point           391    us
##
## And 441 points per chunk x 25 chunks x 391 us is 4.3 s, which is exactly the starting ring the
## player waited through. Practically all of it was this function, called three times per mask and
## five times over for the blur.
##
## `TYPE_VALUE` is the same KIND of noise — value noise on a lattice with smooth interpolation —
## so the world keeps its character: patches of the same scale, the same thresholds, the same
## smoothstep edges. It is not the same PATTERN: the hash differs, so every seed now draws a
## different layout than it did before. Nothing was tuned around a particular seed.
##
## THE SEED OF THE NOISE ITSELF STAYS FIXED. What moves a world is `mask_offset`, which shifts
## where the masks are sampled (offset_for_seed); leaving the noise seed alone keeps that the only
## thing a seed changes, and keeps this one shared instance valid for every caller.
##
## The instance is STATIC: one per run, not one per resource. Masks are asked for hundreds of
## thousands of times per chunk, and a FastNoiseLite per TerrainBiomes would be a second lattice
## the moment anything duplicated the resource — which the menu does for every round.
static var _nz: FastNoiseLite = null

static func cv_noise(p: Vector2) -> float:
	if _nz == null:
		_nz = FastNoiseLite.new()
		_nz.noise_type = FastNoiseLite.TYPE_VALUE
		_nz.fractal_type = FastNoiseLite.FRACTAL_NONE
		# ONE LATTICE CELL IS ONE UNIT OF `p`. The callers have already divided the world point by their own
		# scale (biome_scale and others), i.e. p arrives in "pattern cells"; the default frequency
		# 0.01 would stretch every region a hundred times.
		_nz.frequency = 1.0
		_nz.seed = 0
	# RANGE 0..1, like the old hash: the mask thresholds (biome_bias 0.5, canyon_threshold 0.70)
	# are set in it, while the engine gives -1..1.
	return _nz.get_noise_2d(p.x, p.y) * 0.5 + 0.5

## Offset from a seed. Any deterministic spread does; this one just has to be far enough that
## neighbouring seeds do not overlap their patterns.
static func offset_for_seed(seed_value: int) -> Vector2:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return Vector2(rng.randf_range(-4000.0, 4000.0), rng.randf_range(-4000.0, 4000.0))

## WHICH BIOMES THE WORLD HAS: the map's inspector switches (`ChunkTerrain` "Biomes"), handed over
## by the map before it builds (`_push_switches`). Not exports here and never saved with the resource:
## the map is where they are set. Asked at the masks themselves, the one door every consumer goes
## through - landform, colour, veins and props, the plain start and the menu's audition alike.
var desert_on := true
var canyon_on := true
var mountains_on := true
var salt_on := true

## 0 is desert, 1 is meadow. wp is world XZ.
func meadow_mask(wp: Vector2) -> float:
	if not desert_on:
		return 1.0
	var n: float = cv_noise(wp / biome_scale + mask_offset)
	n = clampf((n - 0.5) * biome_contrast + 0.5, 0.0, 1.0)
	return smoothstep(biome_bias - biome_blend, biome_bias + biome_blend, n)

func canyon_mask(wp: Vector2) -> float:
	if not canyon_on:
		return 0.0
	var n: float = cv_noise(wp / canyon_scale + CANYON_OFFSET + mask_offset)
	return smoothstep(canyon_threshold - canyon_edge, canyon_threshold + canyon_edge, n)

func mountain_mask(wp: Vector2) -> float:
	if not mountains_on:
		return 0.0
	return mountain_mask_n(mountain_n(wp))

## The mountains' noise at a point: the mask and the dome both read it, and a caller wanting both
## (`terrain_gen.raw_height_at`) reads it once and hands it to `mountain_mask_n` / `mountain_dome_n`.
func mountain_n(wp: Vector2) -> float:
	return cv_noise(wp / mountain_scale + MOUNTAIN_OFFSET + mask_offset)

func mountain_mask_n(n: float) -> float:
	if not mountains_on:
		return 0.0
	return smoothstep(mountain_threshold - mountain_edge, mountain_threshold + mountain_edge, n)

func mountain_dome_n(n: float) -> float:
	if not mountains_on:
		return 0.0
	return smoothstep(mountain_threshold - mountain_edge, 0.95, n)

## 0..1: a salt flat here. Only on the desert, never under the mountains - the same masks decide.
func salt_mask(wp: Vector2) -> float:
	var m: float = salt_raw(wp)
	if m <= 0.0:
		return 0.0
	return m * (1.0 - meadow_mask(wp)) * (1.0 - mountain_mask(wp))

## The salt mask BEFORE the desert and the mountains take their share: for a caller that has those
## two masks in hand already (terrain_gen.raw_height_at - two noise reads a point less on the
## world's hottest path; salt_mask in full cost it 17%, measured).
func salt_raw(wp: Vector2) -> float:
	if not salt_on:
		return 0.0
	var n: float = cv_noise(wp / salt_scale + SALT_OFFSET + mask_offset)
	return smoothstep(salt_threshold - salt_edge, salt_threshold + salt_edge, n)

## The mountain dome — not the mask but its interior: it ramps up smoothly from the
## threshold to the peak, and the generator raises the landform by it so the slopes stay
## gentle enough to drive on.
func mountain_dome(wp: Vector2) -> float:
	if not mountains_on:
		return 0.0
	return mountain_dome_n(mountain_n(wp))

# ── Handing values to the shader ──────────────────────────────────────────────
## Writes the COLOURS and grass settings into the material's uniforms. Noise thresholds and
## scales do not go here: the terrain (chunk_terrain._biome_colour) computes the biome masks and
## bakes them into the vertex COLOR, and the shader only reads those.
##
## `world_height` is the Height the ground was generated with; the snow line is worked out from it
## here, because the shader compares against a world Y and needs metres. The caller knows the
## Height (ChunkTerrain.world_height), this resource does not and must not guess.
## The ground's detail masks (art/ground_detail.py): cracks, ripples, grass, patches in one texture.
const GROUND_DETAIL := preload("res://addons/lite_terrain/ground_detail.png")

func apply_to_material(mat: ShaderMaterial, world_height: float) -> void:
	if mat == null:
		return
	mat.set_shader_parameter("color_sand", color_sand)
	mat.set_shader_parameter("color_grass", color_grass)
	mat.set_shader_parameter("color_canyon", color_canyon)
	mat.set_shader_parameter("canyon_band_h", canyon_band_height)
	mat.set_shader_parameter("color_snow", color_snow)
	mat.set_shader_parameter("snow_line", snow_line_at(world_height))
	mat.set_shader_parameter("snow_blend", snow_blend_at(world_height))
	mat.set_shader_parameter("color_rock", color_rock)
	mat.set_shader_parameter("rock_threshold", rock_threshold)
	mat.set_shader_parameter("rock_blend", rock_blend)
	mat.set_shader_parameter("grass_density", grass_density)
	mat.set_shader_parameter("grass_height", grass_height)
	mat.set_shader_parameter("sand_grass", sand_grass)
	mat.set_shader_parameter("grass_shade", grass_shade)
	mat.set_shader_parameter("color_salt", color_salt)
	mat.set_shader_parameter("ground_detail", GROUND_DETAIL)
