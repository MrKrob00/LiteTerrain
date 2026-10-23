## PROCEDURAL TERRAIN, STORED AND DRAWN IN CHUNKS.
##
## THE ONLY GROUND IN THE PROJECT — the game and the menu backdrop both stand on it. No window and no height array for
## the whole world: a chunk asks the generator for its own vertices itself, and that is the only place the ground
## comes from. So the world has no edge, memory equals what is on screen, and a distant chunk
## costs nothing.
##
## LOD IS CHUNK MERGING. A node of level L covers 2^L × 2^L base chunks and is drawn with the SAME
## 16×16 quads at step 2^L: four chunks become one, a quarter of the polygons, the same silhouette.
## Nothing is thinned out and no mesh is simplified.
##
## THE SEAM BETWEEN LEVELS IS CLOSED BY PULLING THE EDGE IN, not by a skirt (there are no skirts anywhere). The fine neighbour
## knows the coarse one's level and lays the extra vertices of its edge on the segment between the shared ones — and the shared ones
## match exactly, because both sides take the height at the same world point.
##
## WHICH NODES and WHICH OF THEM ARE SEEN are two passes at two rates: the leaf set comes from
## distance alone and is cached (`_build_leaves`), the frustum is a flat pass over it (`_select`).
@tool
@icon("res://addons/lite_terrain/icon.png")
class_name ChunkTerrain
extends StaticBody3D

# ── What we draw ───────────────────────────────────────────────────────────
const CHUNK := 16                 ## cells along a base chunk's side
const VERTS := CHUNK + 1          ## vertices along any node's side, at any level
const APRON := VERTS + 2          ## the same grid with a one-cell apron — the normals need it
## The top level: 16 x 128 = 2048 m a node. It was 5 (512 m) while the view ended at 1400 m; with the
## draw distance the player's (up to 10 km, Main.VIEW_MAX) every node past 1 km stayed 512 m with 32 m
## cells, so the far ground was thousands of nodes of sub-pixel triangles. The key keeps 3 bits for it.
const MAX_LOD := 7
## Split a node while its distance is less than its size times this. Two is
## not a matter of taste: with it neighbouring leaves cannot differ by more than one level, and
## the edge only has to be pulled in toward a neighbour twice as coarse.
const LOD_QUALITY := 2.0

## SUB-PIXEL GROUND IS NOT SPLIT (`_subpixel`): a node the distance rule would split stays whole when
## its children's cells would cover fewer than SUBPX_MIN pixels on screen - seen at a grazing angle a
## far plain's cell is a fraction of a pixel tall however wide it is, and the GPU shades every such
## triangle as whole 2x2 quads. The size is the cell's projection by the camera's own pixels per
## radian, times how squarely the ground faces the eye: the height gap to the node over the distance,
## plus the node's own relief over its width (a mountain face looks at the camera; a plain does not).
## Never nearer than SUBPX_NEAR (the grass lift and its level-1 borders live in front of it), and never
## more than SUBPX_EXTRA levels coarser than distance alone - neighbours then differ by three levels
## at most, under the four `_snap_row` can stitch.
const SUBPX_MIN := 2.0
const SUBPX_NEAR := 256.0
const SUBPX_EXTRA := 2

## THE INSPECTOR HOLDS WHAT SHAPES THE LOOK: the ground's material, the biomes and the behind-a-hill
## switch (the player: "a heap of useless settings" - the ENGINE's tuning numbers went). The menu
## backdrop's own numbers are set from its script (menu_stage_3d `_make_map`), and every tuning
## number nobody changes is a constant below. Gone: `camera` (the ground always takes the camera the
## scene is DRAWN with, and a path stored once pointed at the editor viewport's camera, which a
## running game does not have) and the frustum culling switch (always on).
const GROUND_SHADER := preload("res://addons/lite_terrain/glsl.gdshader")
## THE GROUND'S MATERIAL, its shader's settings in the inspector (the player: "return the shader
## that was in the export" - for a commit it was made in code and its settings turned into a group
## of the node's own, and both were wrong). A plain text resource with no texture slot of its own:
## the binary `terrain_shader.res` it replaces carried a tile texture the shader no longer read and
## shipped it in every build. The node draws with a COPY (`_setup_materials`), and the copy takes
## from `biomes` the colours, rock, snow, grass and canyon bands, and from the game the grass fade
## and the trample - those are tuned there; everything else is tuned here. The
## editor's preview takes a change at the next "Build in scene": the engine says nothing when a
## shader parameter changes.
@export var surface_material: Material = preload("res://addons/lite_terrain/terrain_shader.tres")
@export var biomes: TerrainBiomes = null : set = _set_biomes
## WHAT STANDS BEHIND A HILL IS NOT DRAWN (`is_point_hidden`, asked by veins, loose items and
## machines). On by default (the player's call); the ray reads the DRAWN ground's heights, see there.
@export var enable_occlusion_culling: bool = true

@export_group("Render")
## How far ground is drawn. In the game the player's own setting (garage SETTINGS) wins once saved;
## this is its starting value (`Main._ready`). The menu backdrop draws much less (MENU_VIEW).
@export_range(200.0, 10000.0, 10.0) var view_distance: float = 1400.0
## THE HAZE (the global `haze_range`'s strength): off, the far ground and the trees show their own
## colour to the edge. The haze still stretches with the draw distance (`Main._apply_view`).
@export var haze_enabled: bool = true:
	set(v):
		haze_enabled = v
		_apply_haze()

@export_group("Biomes")
## Which biomes the world has; off, its mask is zero everywhere (the desert's off means all meadow).
## Read before the ground is built - in the editor press "Build in scene" again after a change.
@export var desert_enabled: bool = true:
	set(v):
		desert_enabled = v
		_push_switches()
@export var canyons_enabled: bool = true:
	set(v):
		canyons_enabled = v
		_push_switches()
@export var mountains_enabled: bool = true:
	set(v):
		mountains_enabled = v
		_push_switches()
@export var salt_flats_enabled: bool = true:
	set(v):
		salt_flats_enabled = v
		_push_switches()

@export_group("Vertex lift")
## The meadow's grass lift (`TerrainBiomes.grass_height`) and the snow's crust (the material's
## `snow_height`); off, the ground is drawn at its own heights - fewer moved vertices, same triangles.
@export var grass_lift_enabled: bool = true:
	set(v):
		grass_lift_enabled = v
		_push_biomes()
@export var snow_lift_enabled: bool = true:
	set(v):
		snow_lift_enabled = v
		_push_biomes()
@export_group("")
## MARGIN PAST THE SCREEN EDGE, IN METRES, AND ONLY ON THE SIDE PLANES.
##
## On the near plane a margin literally means "draw what is behind the camera": its normal points
## backwards, and any plus lets the ground behind the camera in. While the margin was applied to all six planes
## at once it could not be set positive — hence the old −0.05, which was not a margin but
## a slight OVER-cull that suppressed the ground behind the camera at the price of nodes on the screen edge.
##
## Now near and far are computed exactly and the side planes get an honest margin: a node that
## is about to slide into the frame from the side gets computed in advance.
const FRUSTUM_MARGIN := 12.0
## Nothing nearer than this is ever hidden: up close the test means nothing and a blink costs most.
const OCCL_MIN_DIST := 40.0
## How far the ground has to stand ABOVE the line of sight to hide a thing - the margin that also
## covers a test asked a few frames late.
const OCCL_BIAS := 1.5

## How many nodes are assembled per pool pass. One pass at a time — a second would write into the same slots.
const BUILD_BATCH := 24
## Rebuilds per tick caused by a neighbour changing. A seam for a frame or two is cheaper than a dip.
const STITCH_BUDGET := 16
## Nodes whose seams are checked a tick. A new set of leaves asked every node in the frame at once -
## eight probes of six lookups each, ~12 ms in one tick on the optimize=none build, the spike of the
## player's "terrain lod up to 30 ms in fights"; the rest waits for the next tick, which comes at once
## (`_stitch_more` keeps the tick from idling).
const STITCH_CHECKS := 40
var _stitch_more: bool = false
## Seconds between LOD passes; the selection is also recomputed whenever the camera moves.
const LOD_INTERVAL := 0.15
## A tick with the camera still and nothing landed since the last one waits this long instead.
const LOD_IDLE := 1.0
var _tick_ep: int = -1

## Streamed collision tiles. The menu keeps them off on a map being prepared (set_collision_streaming).
var enable_streaming_collision: bool = true
## Cells around a body that get ground. The radius has to cover not only where the body stands
## but where it is driving: a tile is now COMPUTED, not cut from a ready array, and asking for it
## at the moment of arrival means arriving into the void.
const COLLISION_RADIUS := 12
## How many seconds ahead we look along the body's velocity. A machine at 15 m/s covers more than
## a chunk in that time, so the tile is born before the ground under the wheel runs out.
const COLLISION_LOOKAHEAD := 1.2

## Nominal world size for whoever asks get_dims (laying out shops, veins and points).
## The ground itself has no edge; this is only the square the game lays its things out in.
const WORLD_CELLS := 2048

## Whether to ask the slot for the seed (G.world_seed). Off — forced_seed is used: that is how the menu backdrop
## gets its own ground without touching the player's save.
var follow_world_settings: bool = true
## FLAT GROUND. Not an export: set from G when the proving ground comes up, and a checkbox in the
## inspector would be a second source that argues with the first.
var flat_ground: bool = false
## The ground colour on the proving ground is plain meadow: grass is there, canyon and mountains are not (see _mesh_arrays).
## COLOR.r CARRIES TWO THINGS: the vertex's BORDER CODE and the SALT FLAT mask - the other three
## channels are canyon, meadow and mountain, and a fifth biome needs a home. r = EDGE_STEP x code +
## SALT_SPAN x salt; code 0 inside the node, 1 on a border running along x (the north and south
## rows), 2 along z. The shader's grass takes its border rule from it (glsl.gdshader). The code is
## a fact of the vertex's place in its OWN node, never of the neighbours: a flag read off the
## neighbours at build time goes stale the moment one of them changes level.
const EDGE_STEP := 1.0 / 3.0
const SALT_SPAN := 0.3
const FLAT_COLOR := Color(0.0, 0.0, 1.0, 0.0)
## THE WORLD'S SEED: the same seed gives the same ground in the editor's preview and in the running game.
## Used whenever the ground is not following an autoload's `world_seed` (`follow_world_settings`) — which is
## always the case in a project that has no such autoload, and for the menu's round and the editor's preview.
@export var forced_seed: int = 0

signal terrain_ready
## The ground under `area` (world XZ) changed: an edit landed or was forgotten. Whoever keeps heights
## of their own asks again there (`sun_shadows.gd`'s ground shade keeps its grid between refreshes).
signal ground_changed(area: Rect2)
var terrain_is_ready: bool = false
## The loading screen reads these two: what is being computed and what share is done.
var gen_step: String = ""
var gen_frac: float = 0.0
var _gen: LiteTerrainGen = null
## ONE MATERIAL FOR EVERY LEVEL: the grass is the same function of the world point on all of them
## (glsl.gdshader), so there is nothing left to tell a near node from a far one.
var _mat: Material = null
var _cam: Camera3D = null
var _y_lo: float = -60.0
var _y_hi: float = 240.0

## key → {inst, sig, lod, gx, gz}. A live node is one whose mesh is in the tree right now.
var _live: Dictionary = {}
## key → true. What the camera wants this tick; the neighbour's level is taken from it too.
var _want: Dictionary = {}
## key → PackedFloat32Array(APRON²). A node's heights. Collision takes the same ones from level 0.
##
## THE CEILING HERE DECIDES HOW MUCH IT COSTS TO GO BACK. Rebuilding a mesh from ready heights is
## vertices and colour, a millisecond; computing heights again is four times the cost and from scratch. While
## the cache held 768 entries, going half a kilometre away and back meant recomputing everything passed.
## An entry is 1.5 KB, so three thousand of them cost four and a half megabytes.
var _hc: Dictionary = {}
const HC_CAP := 3072
## HOW MUCH GROUND IS KEPT ONCE OUT OF VIEW (the settings' "Terrain cache"): scales the ceilings of
## kept heights (HC_CAP) and kept meshes (LIVE_CAP). More = less rebuilding when turning/returning,
## at the cost of memory; less = leaner on a phone.
var cache_scale: float = 1.0:
	set(v):
		cache_scale = clampf(v, 0.25, 4.0)
func _hc_cap() -> int:
	return int(HC_CAP * cache_scale)
func _live_cap() -> int:
	return int(LIVE_CAP * cache_scale)

var _jobs: Array = []          # mesh queue
## THE COLLISION TILE QUEUE IS SEPARATE AND FIRST. While it was shared with the meshes, a tile under a wheel
## waited for dozens of nodes the player would only see to be computed: the ground under the machine
## ran out every few metres. A mesh is what you look at, a tile is what you drive on.
var _col_jobs: Array = []
var _batch: Array = []         # what the pool is computing right now
var _out: Array = []           # pool results, one per job
var _group: int = -1
var _busy: bool = false
var _lod_timer: float = 0.0
var _queued: Dictionary = {}   # key → job (or true for collision), so a second one is not started
## BUILT MESHES WAITING FOR THEIR LEVEL CHANGE TO BE WHOLE (_place_mesh, _release_held): key -> the
## entry `_live` will hold. A level change is several meshes - the replacement and every neighbour's
## restitch - and each shown the moment it landed met a neighbour still built for the old levels:
## a crack as tall as the ground climbs over a cell (measured up to 1.3 m while driving).
var _staged: Dictionary = {}
var _held_dirty: bool = false
var _held_check_t: float = 0.0
## How long a held mesh may wait before it goes up as it is. A level change waits long: the old
## ground stands meanwhile, so the cost is coarser ground for a moment, not a hole. Fresh ground
## waits briefly: until it is up there is no ground there at all.
const HOLD_MAX_MS := 4000
const FRESH_HOLD_MS := 300
## While a release is being tried: key -> drawn or not, over what `_live` says (`_drawn_key_at`).
var _ovl: Dictionary = {}

func _ready() -> void:
	# IN THE EDITOR THE NODE TOUCHES NOTHING BY ITSELF. The script is @tool for the preview (see preview_build), and
	# any property edit from here would mark the scene modified and one day get saved.
	if Engine.is_editor_hint():
		return
	collision_layer = 1
	collision_mask = 0
	await get_tree().process_frame
	_apply_haze()
	var game: Node = get_node_or_null("/root/G") if follow_world_settings else null
	if game != null and game.get("world_seed") == null:
		game = null            # some other autoload that happens to be called G
	var seed_value: int = forced_seed
	if game != null and game.get("world_seed") != null:
		seed_value = int(game.get("world_seed"))
	# FLAT PROVING-GROUND GROUND. The flag comes from the same place as the seed — from G, not an export in the scene:
	# the proving ground's world is the very same one (node_3d.tscn), and a second scene for one checkbox would mean
	# a second copy of the HUD, camera and machine that starts lagging behind the first with the first edit.
	flat_ground = game != null and game.get("proving_ground") == true
	# WHERE TO BUILD THE FIRST GROUND. In a saved world the machine returns to its place only AFTER
	# the terrain is ready: world_persist itself waits for it. So there is nothing to build around the camera
	# — it stands wherever the scene opened. The point is taken from the save, where the first machine writes it.
	# A new world is not affected: there is no save, we build around the camera.
	var inv := global_transform.affine_inverse()
	var start := Vector3.ZERO
	var saved = game.saved_start_point() if (game != null and game.has_method("saved_start_point")) else null
	if saved is Vector3:
		start = inv * (saved as Vector3)
	else:
		_cam = _active_camera()
		if _cam != null:
			start = inv * _cam.global_position
	# A NEW WORLD STARTS ON THE NEAREST PLAIN (start_point, world_persist._fresh_start moves the
	# machine there): wherever the scene opened could be a canyon floor or a mountainside.
	await setup_procedural(seed_value, start, game != null and saved == null and not flat_ground)

func _set_biomes(v: TerrainBiomes) -> void:
	biomes = v
	_push_switches()
	_push_biomes()

func _push_switches() -> void:
	if biomes == null:
		return
	biomes.desert_on = desert_enabled
	biomes.canyon_on = canyons_enabled
	biomes.mountains_on = mountains_enabled
	biomes.salt_on = salt_flats_enabled

## The haze's strength is a GLOBAL every hazed shader reads. In the world `Main._apply_view` owns it
## (the range follows the draw distance) and asks `haze_strength`; with no Main (the menu) the map
## writes the project's own range with its strength. Never READ the global back at run time:
## `global_shader_parameter_get` is editor-only and prints an error on every call.
func _apply_haze() -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	var main: Node = get_node_or_null("/root/Main")
	if main != null and main.has_method("_apply_view"):
		main._apply_view()
		return
	var h: Vector4 = _haze_default()
	h.z = haze_strength()
	RenderingServer.global_shader_parameter_set(&"haze_range", h)

func _haze_default() -> Vector4:
	var d = ProjectSettings.get_setting("shader_globals/haze_range", null)
	if d is Dictionary and d.get("value") is Vector4:
		return d["value"]
	return Vector4(150.0, 750.0, 1.0, 0.0)

func haze_strength() -> float:
	return _haze_default().z if haze_enabled else 0.0

func _biomes() -> TerrainBiomes:
	if biomes == null:
		biomes = TerrainBiomes.new()
		_push_switches()
	return biomes

# ─────────────────────────────────────────────────────────────────────────────
# Generator
# ─────────────────────────────────────────────────────────────────────────────

## THE GROUND IS BUILT ON THE NATURAL PRESET, the same numbers for the world and the menu backdrop.
## No sliders of its own on purpose: a second copy of these numbers is another landscape in one world.
func _proc_params() -> Dictionary:
	return LiteTerrainGen.natural_params(_biomes())

## WHERE A NEW WORLD'S MACHINE STANDS (world space), or null: a saved world comes back where it was.
var start_point: Variant = null

## THE NEAREST PLAIN TO `from` (local XZ, the generator's own points; the player's call: "spawning in
## a canyon is random and awkward - only on the nearest plains"). Rings PLAIN_STEP apart out to
## PLAIN_MAX, PLAIN_DIRS points a ring, the first that is no canyon and no mountain (masks under
## PLAIN_MASK) and level across PLAIN_SPAN (heights within PLAIN_RISE). Masks first: they are three
## noise reads, a height is five generator calls. The seed decides it, so a world always opens on the
## same spot. None found - the best-scored point seen, never the canyon itself.
const PLAIN_STEP := 40.0
const PLAIN_MAX := 2400.0
const PLAIN_DIRS := 16
const PLAIN_MASK := 0.05
const PLAIN_SPAN := 14.0
const PLAIN_RISE := 2.0
func _plain_near(from: Vector3) -> Vector3:
	return _plain_search(from, PLAIN_MAX)[1]

## THE NEAREST PLAIN WITHIN `reach` of a world point, or null: the respawn's question
## (`camera_controller._respawn_point`), the same rule a new world opens by. Flat ground is all plain.
func plain_near(from: Vector3, reach: float) -> Variant:
	if _gen == null:
		return null
	if flat_ground:
		return from
	var local: Vector3 = global_transform.affine_inverse() * from
	var got: Array = _plain_search(local, reach)
	if not got[0]:
		return null
	var p: Vector3 = got[1]
	return global_transform * Vector3(p.x, _gen.height_at(p.x, p.z), p.z)

## [found a plain, the point]: the first plain on rings `PLAIN_STEP` apart out to `reach`, else the
## least bad point seen.
func _plain_search(from: Vector3, reach: float) -> Array:
	var b := _biomes()
	var best := from
	var best_score := INF
	var r := 0.0
	while r <= reach:
		var n: int = 1 if r == 0.0 else PLAIN_DIRS
		for i in n:
			var a := TAU * float(i) / float(n)
			var p := Vector2(from.x + cos(a) * r, from.z + sin(a) * r)
			var bad: float = b.canyon_mask(p) + b.mountain_mask(p)
			if bad > PLAIN_MASK and bad >= best_score:
				continue
			var lo := INF
			var hi := -INF
			for dz in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					var h: float = _gen.height_at(p.x + dx * PLAIN_SPAN * 0.5, p.y + dz * PLAIN_SPAN * 0.5)
					lo = minf(lo, h)
					hi = maxf(hi, h)
			if bad <= PLAIN_MASK and hi - lo <= PLAIN_RISE:
				return [true, Vector3(p.x, from.y, p.y)]
			var score: float = bad + (hi - lo) / PLAIN_RISE
			if score < best_score:
				best_score = score
				best = Vector3(p.x, from.y, p.y)
		r += PLAIN_STEP
	return [false, best]

## The world comes up HERE AND AT ONCE: there is nothing to compute in advance, the first chunk is born by the first frame.
## around — where the player stands; the first ring is built around it.
func setup_procedural(seed_value: int, around: Vector3 = Vector3.ZERO, find_plain: bool = false) -> void:
	var gen := LiteTerrainGen.new()
	add_child(gen)
	gen.gen_seed = seed_value
	gen.apply_params(_proc_params())
	gen.flat = flat_ground
	gen.begin_sampling(_biomes())
	_gen = gen
	if find_plain:
		around = _plain_near(around)
		start_point = global_transform * Vector3(around.x, _gen.height_at(around.x, around.z), around.z)
	_y_lo = -world_height() * 0.5
	_y_hi = world_height() * 1.8
	_setup_materials(_get_material())
	_cam = _active_camera()
	# THE FIRST RING IS BUILT BEFORE READINESS, not a frame or two later: the player falls into the world right after
	# terrain_ready, and by that moment the ground under them must not be "soon" but already there.
	var in_game := not Engine.is_editor_hint()
	await _build_around(around, in_game)
	if in_game:
		set_collision_streaming(true)
	terrain_is_ready = true
	terrain_ready.emit()

## HOW MUCH GROUND TO HAVE BEFORE SHOWING ANYTHING, in chunks each way: 2 is 5×5
## of 16 m, i.e. 80 m around the start point. A field, not a constant, because this is a decision of the
## SCENE, not the engine: the game needs ground under the wheels in every direction from the machine that is about
## to drive off, while the menu backdrop needs a patch under two machines at the origin (menu_stage_3d sets 1),
## and every extra chunk here is the same milliseconds of waiting under the screen.
var ready_ring: int = 2

## HOW FAR WE WAIT FOR GROUND BEFORE LIFTING THE LOADING SCREEN, in metres from the camera. More means a longer
## entry but less emptiness around in the first frame.
var ready_view: float = 192.0

## We wait for THE GROUND UNDER THE PLAYER — a square of level-0 chunks around the point and their collision tiles — and
## nothing else. The rest of the ring is already queued by then (_process asks for it), but waiting
## for it under the loading screen is pointless: it will catch up behind the fade. While the exit condition was
## an empty queue, loading held until the last node across the whole view distance.
func _build_around(around: Vector3, with_collision: bool = true) -> void:
	gen_step = "world"
	gen_frac = 0.0
	var bx := int(floor(around.x / CHUNK))
	var bz := int(floor(around.z / CHUNK))
	var need: Array[int] = []
	for dz in range(-ready_ring, ready_ring + 1):
		for dx in range(-ready_ring, ready_ring + 1):
			var key := _key(0, bx + dx, bz + dz)
			# Into _want too: a ready mesh is shown only where the frame asks for it, and the first
			# descent of the tree has not happened yet.
			_want[key] = true
			need.append(key)
			_enqueue_mesh(0, bx + dx, bz + dz, 0)
			if with_collision:
				_enqueue_coll(bx + dx, bz + dz)
	var guard := 0
	while guard < 600:
		_job_tick()
		var done := 0
		for k in need:
			if _live.has(k) and (_col.has(k) or not with_collision):
				done += 1
		gen_frac = float(done) / float(need.size())
		if done >= need.size():
			break
		await get_tree().process_frame
		guard += 1
	await _build_view(around)
	gen_step = ""
	gen_frac = 0.0

## WHAT THE PLAYER WILL SEE IN THE FIRST FRAME. The ring above is the ground UNDER THE WHEELS: there is collision,
## you can drive, but it is empty around because the far nodes arrived after the screen
## had already gone dark. We also wait for the nodes the frame asks for that are closer than ready_view; the distance beyond them
## gets drawn in on the move and it goes unnoticed.
##
## Waiting for EVERYTHING to the horizon is impossible: a coarse node costs five times a fine one (at a step over a metre
## the blur does not reuse its neighbours), and the full set is tens of seconds.
func _build_view(centre: Vector3) -> void:
	gen_step = "view"
	# THE CAMERA NEAR THE POINT means it looks the same way, and only what is in the frame needs waiting for. Far away
	# (a loaded world: the machine has not returned to its place yet) we do not know where the player will look,
	# so we wait for a circle around the point, half the size: a circle is four times more nodes than a cone.
	var here := centre
	var cull := false
	var cam := _active_camera()
	if cam != null:
		var cl: Vector3 = global_transform.affine_inverse() * cam.global_position
		if cl.distance_squared_to(centre) < CAM_AT_START * CAM_AT_START:
			here = cl
			cull = true
			_cam = cam
	_sel_local = here
	# During loading the camera stands still, so the descent of the tree is done ONCE, not every frame.
	_select(here, cull)
	var need: Array[int] = []
	var view: float = ready_view if cull else ready_view * 0.5
	var r2: float = view * view
	for key in _want:
		var l := _key_lod(key)
		var gx := _key_gx(key)
		var gz := _key_gz(key)
		if _aabb_dist2(_node_aabb(l, gx, gz), here) > r2:
			continue
		need.append(key)
		if not _live.has(key):
			_enqueue_mesh(l, gx, gz, _signature(l, gx, gz))
	_sort_queues(here)
	var guard := 0
	while guard < 900:
		var done := 0
		for k in need:
			if _live.has(k):
				done += 1
		gen_frac = float(done) / float(maxi(need.size(), 1))
		if done >= need.size():
			break
		_job_tick()
		await get_tree().process_frame
		guard += 1

## TAKE THE MAP OFF THE COUNT. Called by whoever is about to free it: the pool's jobs write into arrays
## that live in this node, and without stopping they would write into destroyed ones. Waiting for the running group is
## the whole stop: nothing else reads the generator once it is done.
func stop_generation() -> void:
	_hlod_stop()
	if _group != -1:
		WorkerThreadPool.wait_for_group_task_completion(_group)
		_group = -1
	_busy = false
	_jobs.clear()
	_col_jobs.clear()
	_pending_dirty.clear()
	_batch.clear()
	_out.clear()
	_queued.clear()
	if _gen != null and is_instance_valid(_gen):
		_gen.queue_free()        # otherwise every preview leaves one more generator in the node
	_gen = null

func _exit_tree() -> void:
	stop_generation()

# ─────────────────────────────────────────────────────────────────────────────
# Heights
# ─────────────────────────────────────────────────────────────────────────────

func world_height() -> float:
	return _gen.gen_amplitude if _gen != null else LiteTerrainGen.NAT_AMPLITUDE

func get_dims() -> Vector2i:
	return Vector2i(WORLD_CELLS, WORLD_CELLS) if terrain_is_ready else Vector2i.ZERO

## THE GROUND AT A WORLD POINT: generator plus edits. The single door — mesh, collision and
## the outside height query all go through it, otherwise a pad would only look flat.
func _ground_at(wx: float, wz: float, edits: Array) -> float:
	return _edit_h(_gen.height_at(wx, wz), wx, wz, edits)

## A remembered height at a GRID NODE. It is asked dozens of times a frame and almost always near
## the same place, and one computation is five noise samples and three biome masks.
var _memo: Dictionary = {}
const MEMO_CAP := 1 << 16

## A CELL A BUILT LEVEL-0 CHUNK ALREADY HOLDS IS READ FROM IT (`_hc`, the heights its mesh or its
## collision tile was cut from, edits included), and the generator is asked only for a cell no such
## chunk covers. A new cell from the generator costs ~364 us on the optimize=none build against
## ~16 us for a remembered one, and every machine that moves meets new cells every tick - and level-0
## chunks and collision tiles stand exactly where machines drive.
func _memo_h(cx: int, cz: int) -> float:
	var k: int = ((cx & 0x3FFFFFF) << 26) | (cz & 0x3FFFFFF)
	var v = _memo.get(k)
	if v != null:
		return v
	if _memo.size() > MEMO_CAP:
		_memo.clear()
	var h: float
	var gx: int = floori(float(cx) / CHUNK)
	var gz: int = floori(float(cz) / CHUNK)
	var built = _hc.get(_key(0, gx, gz))
	if built != null and (built as PackedFloat32Array).size() == APRON * APRON:
		h = (built as PackedFloat32Array)[(cz - gz * CHUNK + 1) * APRON + (cx - gx * CHUNK + 1)]
	else:
		h = _ground_at(float(cx), float(cz), _flat_edits)
	_memo[k] = h
	return h

## The height at a whole-metre node of the grid, in the node's own axes: one remembered read where
## `terrain_height_at` reads four corners. For callers that only need the ground's shape (a slope).
func cell_height(cx: int, cz: int) -> float:
	return _memo_h(cx, cz) if _gen != null else 0.0

## The height under a world point. Bilinear over the four nodes of the cell — exactly as the mesh describes it
## and the collision cuts it, so the wheel and the picture do not disagree.
func terrain_height_at(world_pos: Vector3) -> float:
	if _gen == null:
		return 0.0
	var xf: Transform3D = global_transform
	var p: Vector3 = world_pos if xf == Transform3D.IDENTITY else xf.affine_inverse() * world_pos
	var x0 := int(floor(p.x))
	var z0 := int(floor(p.z))
	var tx: float = p.x - float(x0)
	var tz: float = p.z - float(z0)
	var h00 := _memo_h(x0, z0)
	var h10 := _memo_h(x0 + 1, z0)
	var h01 := _memo_h(x0, z0 + 1)
	var h11 := _memo_h(x0 + 1, z0 + 1)
	var h: float = lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)
	return h if xf == Transform3D.IDENTITY else (xf * Vector3(p.x, h, p.z)).y

## THE GROUND UNDER A WHEEL: (height, dh/dx, dh/dz) at a world point, from the same four cell
## corners `terrain_height_at` reads - the slope is that bilinear patch's own, so a wheel's normal
## and its height agree. It answers what a ray on layer 1 used to (the collision tile is cut from
## these very heights): a ray into Jolt's heightfield cost 46.8 us on the booted world against
## ~16 us here, and the two agreed within 8 mm over 300 points (`MachineBody._check_ground`).
func ground_sample(world_pos: Vector3) -> Vector3:
	if _gen == null:
		return Vector3.ZERO
	var xf: Transform3D = global_transform
	var p: Vector3 = world_pos if xf == Transform3D.IDENTITY else xf.affine_inverse() * world_pos
	var x0 := int(floor(p.x))
	var z0 := int(floor(p.z))
	var tx: float = p.x - float(x0)
	var tz: float = p.z - float(z0)
	var h00 := _memo_h(x0, z0)
	var h10 := _memo_h(x0 + 1, z0)
	var h01 := _memo_h(x0, z0 + 1)
	var h11 := _memo_h(x0 + 1, z0 + 1)
	var h: float = lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)
	if xf != Transform3D.IDENTITY:
		h = (xf * Vector3(p.x, h, p.z)).y
	return Vector3(h, lerpf(h10 - h00, h11 - h01, tz), lerpf(h01 - h00, h11 - h10, tx))

# ─────────────────────────────────────────────────────────────────────────────
# Terrain edits
# ─────────────────────────────────────────────────────────────────────────────
## An edit is seven numbers, and the ground is reproduced exactly from it. In a world with no edge it is the only
## memory of what the player built here.
const FLAT_EDITS_MAX := 1024
var _flat_edits: Array = []
var _edit_seq: int = 0

## An edit at one point. edits comes as a list, not read from a field: the list is handed to the threads, and
## it cannot be replaced under them with another (see flatten_area — a copy there, not an in-place append).
func _edit_h(h: float, wx: float, wz: float, edits: Array) -> float:
	for e in edits:
		var cx: float = e["cx"]
		var cz: float = e["cz"]
		var fe: float = e["fe"]
		var dx: float = maxf(absf(wx - cx) - e["ex"], 0.0)
		var dz: float = maxf(absf(wz - cz) - e["ez"], 0.0)
		if dx >= fe or dz >= fe:
			continue
		var dist: float = sqrt(dx * dx + dz * dz)
		if dist >= fe:
			continue
		h = lerpf(h, e["y"], clampf(1.0 - dist / fe, 0.0, 1.0))
	return h

## The edit's rectangle in world cells, with room for the falloff.
func _edit_rect(e: Dictionary) -> Rect2:
	var r: float = e["fe"]
	return Rect2(e["cx"] - e["ex"] - r, e["cz"] - e["ez"] - r,
			(e["ex"] + r) * 2.0, (e["ez"] + r) * 2.0)

func _edits_in(x0: float, z0: float, size: float) -> Array:
	if _flat_edits.is_empty():
		return _flat_edits
	var box := Rect2(x0, z0, size, size)
	var out: Array = []
	for e in _flat_edits:
		if _edit_rect(e).intersects(box):
			out.append(e)
	return out

func flatten_area(center_world: Vector3, half_extent: Vector2, height: float,
		feather: float = 4.0, record: bool = true) -> void:
	if _gen == null:
		return
	var inv := global_transform.affine_inverse()
	var local: Vector3 = inv * center_world
	var target: float = (inv * Vector3(center_world.x, height, center_world.z)).y
	var e := {
		"cx": local.x, "cz": local.z,
		"ex": maxf(half_extent.x, 0.0), "ez": maxf(half_extent.y, 0.0),
		"fe": maxf(feather, 0.001), "y": target,
		"n": (_edit_seq + 1) if record else 0,
	}
	# THE SAME EDIT A SECOND TIME IS NOT AN EDIT. Whoever asks for a pad usually asks for it together with
	# a building, and if the building did not stand, they come again with the same numbers (quest_arcs
	# polls its branch once a second). Recording a copy is wrong for three reasons: _edit_h
	# applies both, and the falloff at the edge comes out steeper than ordered; each copy is an extra pass
	# on EVERY height query in that rectangle, for ever; and when the list overflows it drops THE OLDEST
	# entry, i.e. copies silently eat the pads levelled earlier.
	if _same_edit_recorded(e, _flat_edits):
		return
	if record:
		_edit_seq += 1
	# A COPY, NOT AN IN-PLACE append: the jobs the pool is already computing hold a reference to the old list.
	# Appending to it would change an array under someone else's thread.
	var list := _flat_edits.duplicate()
	list.append(e)
	if list.size() > FLAT_EDITS_MAX:
		list.remove_at(0)
	_flat_edits = list
	_invalidate(_edit_rect(e))

## Whether there is already such a pad. Compared with a tolerance: the numbers come from a world point through
## an inverse matrix, and they never match bit for bit even for the same place.
const EDIT_SAME_XZ := 0.25        # m: centres closer than this count as one place
const EDIT_SAME_Y := 0.05         # m: and the pad's height is the same

func _same_edit_recorded(e: Dictionary, list: Array) -> bool:
	for o in list:
		if absf(o["cx"] - e["cx"]) < EDIT_SAME_XZ and absf(o["cz"] - e["cz"]) < EDIT_SAME_XZ \
				and absf(o["y"] - e["y"]) < EDIT_SAME_Y \
				and is_equal_approx(o["ex"], e["ex"]) and is_equal_approx(o["ez"], e["ez"]) \
				and is_equal_approx(o["fe"], e["fe"]):
			return true
	return false

## Edits out and back in (the world save); the format older saves already carry.
func ground_edits() -> Array:
	var out: Array = []
	for e in _flat_edits:
		out.append({"c": [e["cx"], e["y"], e["cz"]], "h": [e["ex"], e["ez"]],
				"y": e["y"], "f": e["fe"], "n": e["n"]})
	return out

func apply_ground_edits(list: Array) -> void:
	if list.is_empty() or _gen == null:
		return
	var dirty := Rect2()
	var first := true
	var acc := _flat_edits.duplicate()
	for raw in list:
		if not (raw is Dictionary) or not (raw.get("c") is Array) or not (raw.get("h") is Array):
			continue
		var c: Array = raw["c"]
		var hh: Array = raw["h"]
		if c.size() < 3 or hh.size() < 2:
			continue
		var e := {
			"cx": float(c[0]), "cz": float(c[2]),
			"ex": float(hh[0]), "ez": float(hh[1]),
			"fe": maxf(float(raw.get("f", 4.0)), 0.001), "y": float(raw.get("y", 0.0)),
			"n": int(raw.get("n", 0)),
		}
		# The save is topped up ONTO WHAT IS ALREADY THERE: loading runs over frames, and a quest branch manages
		# to ask for its pad before the save reaches it. Without this check the same
		# pad would be laid twice — see flatten_area.
		if _same_edit_recorded(e, acc):
			continue
		acc.append(e)
		_edit_seq = maxi(_edit_seq, e["n"])
		var r := _edit_rect(e)
		dirty = r if first else dirty.merge(r)
		first = false
	if first:
		return
	if acc.size() > FLAT_EDITS_MAX:
		acc = acc.slice(acc.size() - FLAT_EDITS_MAX)
	_flat_edits = acc
	_invalidate(dirty)

## The ground in the rectangle changed: forget its heights, rebuild the meshes and cut the tiles again.
##
## While a pool pass is running — DEFER. The jobs read _hc, and erasing an entry from it under someone else's
## thread means crashing the game exactly when the player is placing a base.
var _pending_dirty: Array = []

func _invalidate(area: Rect2) -> void:
	if _busy:
		_pending_dirty.append(area)
		return
	_memo.clear()
	for key in _hc.keys():
		if _node_rect(key).intersects(area):
			_hc.erase(key)
	for key in _live.keys():
		if _node_rect(key).intersects(area):
			var n: Dictionary = _live[key]
			_enqueue_mesh(n["lod"], n["gx"], n["gz"], n["sig"])
	for key in _col.keys():
		var r := _node_rect(key)
		if r.intersects(area):
			var cs = _col[key]
			if is_instance_valid(cs):
				cs.queue_free()
			_col.erase(key)
			_col_seen.erase(key)
	var o: Vector3 = global_transform.origin if is_inside_tree() else Vector3.ZERO
	ground_changed.emit(Rect2(area.position + Vector2(o.x, o.z), area.size))

## FORGET THE TERRAIN EDITS — and only them. The ground is computed from the seed, there is nothing to reset in it: it is
## already what it was born as. We recompute exactly the chunks the edits touched.
##
## THIS IS NOT A WORLD RESET. Written as "throw everything out and rebuild", this function killed a new
## save: world_persist._fresh_start calls it as its first line, and the collision under the player vanished that very
## moment — exactly when they are handed the starter kit.
func reset_heights() -> void:
	if _flat_edits.is_empty():
		return
	var area := _edit_rect(_flat_edits[0])
	for e in _flat_edits:
		area = area.merge(_edit_rect(e))
	_flat_edits = []
	_edit_seq = 0
	_invalidate(area)

# ─────────────────────────────────────────────────────────────────────────────
# Node keys and choosing the level
# ─────────────────────────────────────────────────────────────────────────────

func _key(lod: int, gx: int, gz: int) -> int:
	return (lod << 40) | ((gx & 0xFFFFF) << 20) | (gz & 0xFFFFF)

func _key_lod(k: int) -> int:
	return (k >> 40) & 0x7

func _key_gx(k: int) -> int:
	var v: int = (k >> 20) & 0xFFFFF
	return v - 0x100000 if v >= 0x80000 else v

func _key_gz(k: int) -> int:
	var v: int = k & 0xFFFFF
	return v - 0x100000 if v >= 0x80000 else v

func _node_rect(k: int) -> Rect2:
	var span: float = float(CHUNK << _key_lod(k))
	return Rect2(_key_gx(k) * span, _key_gz(k) * span, span, span)

func _node_aabb(lod: int, gx: int, gz: int) -> AABB:
	var span := float(CHUNK << lod)
	return AABB(Vector3(gx * span, _y_lo, gz * span), Vector3(span, _y_hi - _y_lo, span))

## THE LEVEL AT WHICH A BASE CHUNK IS DRAWN RIGHT NOW. We ask the leaf covering it: a leaf has exactly one set of its own
## coordinates at each level, so this is six dictionary checks, not a tree walk. From it a fine node learns which edge
## to pull in toward.
## THE LEAF SET, NOT THE FRAME: a neighbour off the screen is still drawn at its level the moment
## the camera turns to it. Asked of `_want`, it read as "nothing there", the node was built
## unsnapped, and every turn of the camera re-stitched the frame's edge twice over.
func _level_of(bcx: int, bcz: int) -> int:
	for l in MAX_LOD + 1:
		if _leaf_set.has(_key(l, bcx >> l, bcz >> l)):
			return l
	return -1

## WHAT WE HAVE ON THIS SIDE: how much COARSER the neighbour is — the edge has to be pulled in to its lattice.
## A coarser node never hears of a finer neighbour, so a level change re-stitches only the side
## that snaps. The grass needs no bit here any more (glsl.gdshader: the same lift on every level).
const SIDE_BITS := 8

## `drawn`: ask what is DRAWN there (`_drawn_key_at`) instead of the leaf set, and answer -1 when
## nothing in the frame is drawn on that side - a side with nothing across it cannot crack.
func _side_info(lod: int, gx: int, gz: int, dx: int, dz: int, drawn: bool = false) -> int:
	var n: int = 1 << lod
	var bx: int = gx * n
	var bz: int = gz * n
	var a: Vector2i
	var b: Vector2i
	if dx != 0:
		var px: int = bx - 1 if dx < 0 else bx + n
		a = Vector2i(px, bz)
		b = Vector2i(px, bz + n - 1)
	else:
		var pz: int = bz - 1 if dz < 0 else bz + n
		a = Vector2i(bx, pz)
		b = Vector2i(bx + n - 1, pz)
	var k := 0
	var seen := false
	for p in [a, b]:
		var l: int
		if drawn:
			# Drawn and in the frame: a crack against ground nobody can see is no reason to wait.
			var dk := _drawn_key_at(p.x, p.y)
			l = _key_lod(dk) if dk != -1 and _in_frame_key(dk) else -1
		else:
			l = _level_of(p.x, p.y)                  # -1: nothing is drawn there — no seam
		if l >= 0:
			seen = true
		if l > lod:
			k = maxi(k, l - lod)
	if drawn and not seen:
		return -1
	return mini(k, 4)

## THE NODE DRAWN OVER A BASE CHUNK RIGHT NOW: a live one no replacement has covered, as the overlay
## of a release being tried has it. The leaf set says what the ground is going to be; this is what
## stands there while it gets there.
func _drawn_key_at(bcx: int, bcz: int) -> int:
	for l in MAX_LOD + 1:
		var k: int = (l << 40) | (((bcx >> l) & 0xFFFFF) << 20) | ((bcz >> l) & 0xFFFFF)
		if _ovl.has(k):
			if _ovl[k]:
				return k
			continue
		var n = _live.get(k)
		if n != null and not n.get("cov", false):
			return k
	return -1

## Does a mesh built with `sig` meet whatever is drawn round it? Sides with nothing across are free.
const SIDES := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]

func _fits_drawn(lod: int, gx: int, gz: int, sig: int) -> bool:
	for s in 4:
		var d: int = _side_info(lod, gx, gz, SIDES[s].x, SIDES[s].y, true)
		if d >= 0 and d != ((sig >> (SIDE_BITS * s)) & 0xF):
			return false
	return true

## Is other ground drawn over this node's area - the coarse node it splits out of, or the finer
## ones it merges? Then it is a REPLACEMENT, and goes up together with its seams.
func _area_drawn(lod: int, gx: int, gz: int) -> bool:
	return _drawn_ancestor(lod, gx, gz) != -1 or not _drawn_under(lod, gx, gz).is_empty()

func _drawn_ancestor(lod: int, gx: int, gz: int) -> int:
	for l in range(lod + 1, MAX_LOD + 1):
		var k: int = (l << 40) | (((gx >> (l - lod)) & 0xFFFFF) << 20) | ((gz >> (l - lod)) & 0xFFFFF)
		var n = _live.get(k)
		if n != null and not n.get("cov", false):
			return k
	return -1

## Four neighbours in one number, a byte per side: north, south, west, east.
func _signature(lod: int, gx: int, gz: int) -> int:
	return _side_info(lod, gx, gz, 0, -1) \
		| (_side_info(lod, gx, gz, 0, 1) << SIDE_BITS) \
		| (_side_info(lod, gx, gz, -1, 0) << (SIDE_BITS * 2)) \
		| (_side_info(lod, gx, gz, 1, 0) << (SIDE_BITS * 3))

## A SPLIT GOES UP WHOLE: every leaf under the node it replaces is built, not only the ones in the
## frame. The coarse node is hidden only once all of its area is covered, and until then it and the
## children already up were drawn over each other, the children's edges against its coarse one.
func _enqueue_under(lod: int, gx: int, gz: int) -> void:
	var cl := lod - 1
	for dz in 2:
		for dx in 2:
			var cx := gx * 2 + dx
			var cz := gz * 2 + dz
			if _aabb_dist2(_node_aabb(cl, cx, cz), _leaf_at) > view_distance * view_distance:
				continue
			var ck := _key(cl, cx, cz)
			if _leaf_set.has(ck):
				if not _live.has(ck) and not _staged.has(ck) and not _queued_fresh(ck):
					_enqueue_mesh(cl, cx, cz, _signature(cl, cx, cz))
			elif cl > 0:
				_enqueue_under(cl, cx, cz)

# ─────────────────────────────────────────────────────────────────────────────
# Descending the tree: what to draw this tick
# ─────────────────────────────────────────────────────────────────────────────

## TWO DIFFERENT QUESTIONS, AND THEY HAVE TO BE ASKED AT DIFFERENT RATES.
##
## "To split a node or not" depends ONLY on distance (lod > 0 and d2 < (span·LOD_QUALITY)²) —
## the look direction does not enter into it at all. "Does the node fall in the frame" depends only on the
## frustum. Before, both were computed by one recursive walk on every LOD tick: the measurement gave 6.6 ms,
## a third of a 60 fps frame, and the walk ran four times as often while the camera turns. A flat pass over the cache
## costs 1.65 ms, and the walk itself repeats about once per sixteen metres of travel.
##
## Now THE LEAF SET IS CACHED — keys plus their rectangles in flat arrays — and what is left on the tick
## is a pass over it with the frustum check. The tree walk repeats only when the camera
## MOVED farther than LEAF_MOVE2.
##
## WHY THE THRESHOLD IS A WHOLE CHUNK, NOT A METRE. The camera goes IN ORBIT around the machine (RADIUS up to 20 m in
## camera_controller), i.e. on a pure turn it is not looking from one place: it travels
## along an arc a hundred metres long. A one-metre threshold would rebuild the set the whole way round, exactly where
## that is to be avoided. The price — the LOD level boundary lags by the same 16 m: a node that
## is due to split gets to travel an extra chunk coarse. This is ordinary hysteresis, not a hole: the ground
## is there, the seam is pulled in, and collision goes in its own queue along the body's corridor and does not touch the cache.
##
## Height is not put in the cache: all nodes have the same one (_y_lo.._y_hi) and it lives with the world — _pack_planes
## supplies it, once per tick instead of once per node.
var _leaf_keys := PackedInt64Array()
var _leaf_set: Dictionary = {}                # the same keys, for _level_of
## Bumped with every new set of leaves: a live node's seams are checked once per set (`gen`).
var _leaf_gen: int = 0
var _leaf_box := PackedFloat32Array()         # 4 per leaf: minx, minz, maxx, maxz
var _leaf_at: Vector3 = Vector3(1e9, 1e9, 1e9)
var _leaf_vd: float = -1.0
const LEAF_MOVE2 := 256.0                     # 16 m, one base chunk
## New relief rebuilds the leaves at most this often: a region seen for the first time is split by
## distance, and only once its leaves are built does the sub-pixel rule know enough to merge them.
const RELIEF_REBUILD_MS := 1000
var _leaf_ms: int = 0

## WHILE A HOLD IS UP THE GROUND IS TAKEN ROUND IT, NOT ROUND THE CAMERA (`hold_at` / `release_hold`;
## the player: holes where the machine lands at the end of the planetfall intro). The intro flies its
## camera from a kilometre up down to the start point at 62 m/s, looking mostly at the sky, and a leaf
## set taken round that camera rebuilt itself every 16 m of the flight, built fine ground under it
## that nobody saw (measured on the optimize=none build: 175 -> 395 meshes queued over the intro) and
## let the start point's ground go coarse, so the landing waited on a rebuild. With a hold the leaves
## are the ones a camera standing at the hold would want, still drawn only where the real camera
## looks; a leaf within HOLD_RADIUS of it is wanted off the frame too (built and kept: the engine
## culls what is not seen), the build queue runs nearest the hold first, and nothing near it is let go.
const HOLD_RADIUS := 400.0
var _hold := Vector3.ZERO      # in the node's axes
var _holding: bool = false

func hold_at(world_pos: Vector3) -> void:
	_hold = global_transform.affine_inverse() * world_pos
	_holding = true
	_leaf_vd = -1.0                # the leaves are taken again on the next tick

func release_hold() -> void:
	if _holding:
		_holding = false
		_leaf_vd = -1.0

func _near_hold(lod: int, gx: int, gz: int) -> bool:
	return _holding and _aabb_dist2(_node_aabb(lod, gx, gz), _hold) <= HOLD_RADIUS * HOLD_RADIUS

## cull = false — take everything around the point, with no frame culling. Needed by entering a saved world:
## the ground is built around the machine, while the camera at that moment still looks from the scene origin.
func _select(at: Vector3, cull: bool = true) -> void:
	var lc: Vector3 = _hold if _holding else at
	var mx: float = lc.x - _leaf_at.x
	var mz: float = lc.z - _leaf_at.z
	# We do not check against height: the distance to a node is measured along the ground (see _aabb_dist2), and raising the
	# camera in orbit does not change the leaf set.
	var now_ms: int = Time.get_ticks_msec()
	if _leaf_vd != view_distance or mx * mx + mz * mz > LEAF_MOVE2 \
			or (_relief_new and now_ms - _leaf_ms > RELIEF_REBUILD_MS):
		_relief_new = false
		_leaf_ms = now_ms
		_measure_px()
		_build_leaves(lc)
	_prev_want = _want
	_want = {}
	var n: int = _leaf_keys.size()
	if not (cull and is_instance_valid(_cam)):
		for i in n:
			_want[_leaf_keys[i]] = true
		return
	_pack_planes()
	for i in n:
		var b: int = i * 4
		var vis := true
		for q in 6:
			var q3: int = q * 3
			if _pl[q3] * _leaf_box[b + _pi[q * 2]] \
					+ _pl[q3 + 1] * _leaf_box[b + _pi[q * 2 + 1]] \
					+ _pl[q3 + 2] > 0.0:
				vis = false
				break
		if vis or (_holding and _box_near_hold(b)):
			_want[_leaf_keys[i]] = true

func _box_near_hold(b: int) -> bool:
	var dx: float = maxf(maxf(_leaf_box[b] - _hold.x, 0.0), _hold.x - _leaf_box[b + 2])
	var dz: float = maxf(maxf(_leaf_box[b + 1] - _hold.z, 0.0), _hold.z - _leaf_box[b + 3])
	return dx * dx + dz * dz <= HOLD_RADIUS * HOLD_RADIUS

func _build_leaves(at: Vector3) -> void:
	_leaf_gen += 1
	_cover_ep += 1
	_leaf_keys.clear()
	_leaf_set.clear()
	_leaf_box.clear()
	_leaf_at = at
	_leaf_vd = view_distance
	var top := CHUNK << MAX_LOD
	var r: int = int(ceil(view_distance / float(top)))
	var g0x: int = int(floor(at.x / float(top)))
	var g0z: int = int(floor(at.z / float(top)))
	for gz in range(g0z - r, g0z + r + 1):
		for gx in range(g0x - r, g0x + r + 1):
			_descend(MAX_LOD, gx, gz, at)

## Counts only distance, and the arithmetic here is UNROLLED (no _node_aabb, no _aabb_dist2, no
## _key): a call in GDScript costs more than the formula itself, and there were four of them per node.
func _descend(lod: int, gx: int, gz: int, cam: Vector3) -> void:
	var span := float(CHUNK << lod)
	var x0: float = gx * span
	var z0: float = gz * span
	var x1: float = x0 + span
	var z1: float = z0 + span
	var dx: float = maxf(maxf(x0 - cam.x, 0.0), cam.x - x1)
	var dz: float = maxf(maxf(z0 - cam.z, 0.0), cam.z - z1)
	var d2: float = dx * dx + dz * dz
	if d2 > view_distance * view_distance:
		return
	var split := span * LOD_QUALITY
	if lod > 0 and d2 < split * split and not _subpixel(lod, gx, gz, cam, d2, span):
		var cx := gx * 2
		var cz := gz * 2
		_descend(lod - 1, cx, cz, cam)
		_descend(lod - 1, cx + 1, cz, cam)
		_descend(lod - 1, cx, cz + 1, cam)
		_descend(lod - 1, cx + 1, cz + 1, cam)
		return
	var key: int = (lod << 40) | ((gx & 0xFFFFF) << 20) | (gz & 0xFFFFF)
	_leaf_keys.append(key)
	_leaf_set[key] = true
	_leaf_box.append(x0)
	_leaf_box.append(z0)
	_leaf_box.append(x1)
	_leaf_box.append(z1)

## Would this node's CHILDREN draw sub-pixel cells? (see SUBPX_MIN) Unknown relief answers no: the
## node then splits as distance says, its children are built, and their relief decides next time.
func _subpixel(lod: int, gx: int, gz: int, cam: Vector3, d2: float, span: float) -> bool:
	if _px_per_rad <= 0.0 or d2 < SUBPX_NEAR * SUBPX_NEAR:
		return false
	var d: float = sqrt(d2)
	var dist_lod: int = int(floor(log(d / (float(CHUNK) * LOD_QUALITY)) / log(2.0))) if d > CHUNK * LOD_QUALITY else 0
	if lod - dist_lod > SUBPX_EXTRA:
		return false
	var r = _relief_of(lod, gx, gz)
	if r == null:
		return false
	var lo: float = (r as Vector2).x
	var hi: float = (r as Vector2).y
	var gap: float = maxf(maxf(lo - cam.y, cam.y - hi), 0.0)
	var d3: float = sqrt(d2 + gap * gap)
	var face: float = clampf(gap / d3 + (hi - lo) / span, 0.0, 1.0)
	var cell: float = float(1 << (lod - 1))
	return cell * _px_per_rad * face / d3 < SUBPX_MIN

## A node's height range: its own built heights, else its four children's, else the nearest built
## ancestor's (wider, so it splits sooner - the safe side). Cached; `_hc` is pruned, this is not read
## for anything that has to be exact.
var _relief: Dictionary = {}
const RELIEF_CAP := 16384
## Set when ground landed that told the relief something new: the leaves are rebuilt for it.
var _relief_new: bool = false
var _px_per_rad: float = 0.0

func _relief_own(key: int) -> Variant:
	var r = _relief.get(key)
	if r != null:
		return r
	var h = _hc.get(key)
	if h == null or (h as PackedFloat32Array).is_empty():
		return null
	var lo := INF
	var hi := -INF
	for v in (h as PackedFloat32Array):
		lo = minf(lo, v)
		hi = maxf(hi, v)
	if _relief.size() > RELIEF_CAP:
		_relief.clear()
	_relief[key] = Vector2(lo, hi)
	return _relief[key]

func _relief_of(lod: int, gx: int, gz: int) -> Variant:
	var own = _relief_own(_key(lod, gx, gz))
	if own != null:
		return own
	var lo := INF
	var hi := -INF
	var all := true
	for dz in 2:
		for dx in 2:
			var c = _relief_own(_key(lod - 1, gx * 2 + dx, gz * 2 + dz))
			if c == null:
				all = false
				break
			lo = minf(lo, (c as Vector2).x)
			hi = maxf(hi, (c as Vector2).y)
		if not all:
			break
	if all:
		_relief[_key(lod, gx, gz)] = Vector2(lo, hi)
		return Vector2(lo, hi)
	for l in range(lod + 1, MAX_LOD + 1):
		var a = _relief_own(_key(l, gx >> (l - lod), gz >> (l - lod)))
		if a != null:
			return a
	return null

## Pixels per radian of the camera the ground is drawn for, at the 3D buffer's real resolution
## (`scaling_3d_scale`): a lower render scale makes the same cell fewer pixels.
func _measure_px() -> void:
	if not is_instance_valid(_cam):
		return
	var vp := _cam.get_viewport()
	var h: float = vp.get_visible_rect().size.y * vp.scaling_3d_scale
	_px_per_rad = h / (2.0 * tan(deg_to_rad(_cam.fov) * 0.5))

func _aabb_dist2(aabb: AABB, p: Vector3) -> float:
	var mx: Vector3 = aabb.position + aabb.size
	var dx: float = maxf(maxf(aabb.position.x - p.x, 0.0), p.x - mx.x)
	var dz: float = maxf(maxf(aabb.position.z - p.z, 0.0), p.z - mx.z)
	return dx * dx + dz * dz

## Where the camera looks, in the node's axes. Set in _pack_planes, read there too.
var _cam_fwd_local: Vector3 = Vector3.FORWARD
## Above this |n·forward| a plane counts as near or far — those get no margin. For a side one the
## angle to the view axis is half the field of view plus a right angle, so the dot product is much
## smaller; they cannot be confused.
const AXIAL_DOT := 0.9

## THE FRUSTUM, FOLDED FOR A FLAT PASS. Six planes become 6×(nx, nz, shift) and
## 6×(which corner to take by x, which by z): for an AABB the corner nearest a plane is chosen by the sign of
## the normal, and the sign does not change within a tick — so it is an index into _leaf_box, computed once.
## The node's height (the same for all), the plane's d and the margin are already folded into the shift, so in the loop over nodes
## two multiplications and a comparison remain: no Plane, no Vector3 and no calls.
var _pl := PackedFloat32Array()
var _pi := PackedInt32Array()

func _pack_planes() -> void:
	var inv := global_transform.affine_inverse()
	# Where the camera looks, in our axes: it tells the near and far planes from the side ones
	# (see FRUSTUM_MARGIN). By position in the array — not possible: plane order is an engine detail, and
	# the normal speaks for itself.
	_cam_fwd_local = (inv.basis * (-_cam.global_transform.basis.z)).normalized()
	_frame_memo.clear()
	_pl.resize(18)
	_pi.resize(12)
	var i := 0
	for raw in _cam.get_frustum():
		if i == 6:
			break
		var p: Plane = inv * (raw as Plane)
		var nn: Vector3 = p.normal
		# Near and far exactly, with no margin: a plus on the near one is the ground behind the back.
		var m: float = 0.0 if absf(nn.dot(_cam_fwd_local)) > AXIAL_DOT else FRUSTUM_MARGIN
		_pl[i * 3] = nn.x
		_pl[i * 3 + 1] = nn.z
		_pl[i * 3 + 2] = nn.y * (_y_lo if nn.y >= 0.0 else _y_hi) - p.d - m
		_pi[i * 2] = 0 if nn.x >= 0.0 else 2
		_pi[i * 2 + 1] = 1 if nn.z >= 0.0 else 3
		i += 1
	# There are always six planes, but the array outlives the tick: a shortfall would leave the previous
	# frustum in the tail. We pad it with a plane that culls nothing.
	while i < 6:
		_pl[i * 3] = 0.0
		_pl[i * 3 + 1] = 0.0
		_pl[i * 3 + 2] = -1e9
		_pi[i * 2] = 0
		_pi[i * 2 + 1] = 1
		i += 1

# ─────────────────────────────────────────────────────────────────────────────
# Assembly: queue → thread pool → tree
# ─────────────────────────────────────────────────────────────────────────────

const JOB_MESH := 0
const JOB_COLL := 1

## A QUEUED JOB SIGNED FOR THESE LEAVES, OR ONE THE POOL HAS TAKEN, IS NOT SIGNED AGAIN: a signature
## reads the leaf set and nothing else (`_level_of`), and the LOD tick asked one for every queued node
## every tick - 40-50 calls a node over a backlog of hundreds - to write the same number back.
func _queued_fresh(key: int) -> bool:
	var q = _queued.get(key)
	return q is Dictionary and (q.get("started", false) or int(q.get("sg", -1)) == _leaf_gen)

func _enqueue_mesh(lod: int, gx: int, gz: int, sig: int) -> void:
	var key := _key(lod, gx, gz)
	var q = _queued.get(key)
	if q != null:
		# Still waiting in the queue: build it for the newest neighbours. One the pool has taken is
		# read by a worker thread and is left alone; it is re-asked when it lands.
		if q is Dictionary and not q.get("started", false):
			q["sig"] = sig
			q["sg"] = _leaf_gen
		return
	var span := float(CHUNK << lod)
	var job := {
		"kind": JOB_MESH, "key": key, "lod": lod, "gx": gx, "gz": gz, "sig": sig, "sg": _leaf_gen,
		"edits": _edits_in(gx * span, gz * span, span),
		# The node's middle — the queue is later sorted by it, from the camera (see _sort_queues).
		"cx": gx * span + span * 0.5, "cz": gz * span + span * 0.5,
	}
	_queued[key] = job
	_jobs.append(job)

func _enqueue_coll(bcx: int, bcz: int) -> void:
	var key := _key(0, bcx, bcz)
	if _col.has(key) or _queued.has(key | (1 << 50)):
		return
	_queued[key | (1 << 50)] = true
	_col_jobs.append({
		"kind": JOB_COLL, "key": key, "lod": 0, "gx": bcx, "gz": bcz, "sig": 0,
		"edits": _edits_in(bcx * float(CHUNK), bcz * float(CHUNK), float(CHUNK)),
		"cx": bcx * CHUNK + CHUNK * 0.5, "cz": bcz * CHUNK + CHUNK * 0.5,
	})

## THE NEAREST IS COMPUTED FIRST. The queue is filled by walking the tree, i.e. in the order of top-level
## cells, and without sorting a node a kilometre away could be born before the one the player looks at:
## the surrounding ground would show up in chunks from anywhere.
## SORTED WHEN A BATCH IS TAKEN, NOT AT EVERY LOD TICK, AND NATIVELY (`_job_tick`): only the head is
## ever read, and only at a launch, while the tick runs every one or two frames with the camera
## turning - and a GDScript comparator over a backlog of hundreds was thousands of calls a tick. The
## key is the distance in whole square metres over the job's index, one PackedInt64Array sort.
func _sort_queues(at: Vector3) -> void:
	for q in [_col_jobs, _jobs]:
		var n: int = q.size()
		if n < 2:
			continue
		var keys := PackedInt64Array()
		keys.resize(n)
		for i in n:
			var j: Dictionary = q[i]
			var dx: float = float(j["cx"]) - at.x
			var dz: float = float(j["cz"]) - at.z
			keys[i] = (int(dx * dx + dz * dz) << 21) | i
		keys.sort()
		var sorted: Array = []
		sorted.resize(n)
		for i in n:
			sorted[i] = q[keys[i] & 0x1FFFFF]
		q.assign(sorted)

## One pool pass at a time: jobs write into _out by their number, and a second pass would overwrite
## both the array and the fields under the first.
func _job_tick() -> void:
	if _busy:
		if not WorkerThreadPool.is_group_task_completed(_group):
			return
		WorkerThreadPool.wait_for_group_task_completion(_group)
		_group = -1
		_busy = false
		_apply_batch()
		while not _pending_dirty.is_empty():
			_invalidate(_pending_dirty.pop_front())
	_drain_apply()
	# The landing queue has not been cleared — we do not compute a new batch. This is BACKPRESSURE, not a delay:
	# without it at speed the pool would compute faster than the main thread manages to lay, and the queue
	# would grow together with memory, and the ground would lag behind anyway.
	if not _apply_q.is_empty():
		return
	if _gen == null or (_jobs.is_empty() and _col_jobs.is_empty()):
		return
	if _holding or _sel_local.x < 1e8:
		_sort_queues(_hold if _holding else _sel_local)
	# Collision first, whole: its queue is short (tiles around the bodies), and waiting for it is not an option.
	_batch = _col_jobs.slice(0, BUILD_BATCH)
	_col_jobs = _col_jobs.slice(_batch.size())
	if _batch.size() < BUILD_BATCH:
		var rest: int = BUILD_BATCH - _batch.size()
		_batch.append_array(_jobs.slice(0, rest))
		_jobs = _jobs.slice(mini(rest, _jobs.size()))
	for j in _batch:
		j["started"] = true                      # a worker reads it from here on (_enqueue_mesh)
	_out.clear()
	_out.resize(_batch.size())
	_busy = true
	_group = WorkerThreadPool.add_group_task(_build_job, _batch.size(), -1, false, "ChunkTerrain")

## A pool job. It reads only the generator (unchanged after begin_sampling), its own edit list
## and its own slot in _out.
func _build_job(i: int) -> void:
	var job: Dictionary = _batch[i]
	var lod: int = job["lod"]
	var step := float(1 << lod)
	var x0 := float(job["gx"] * (CHUNK << lod))
	var z0 := float(job["gz"] * (CHUNK << lod))
	var h: PackedFloat32Array = _hc.get(job["key"], PackedFloat32Array())
	if h.size() != APRON * APRON:
		h = _gen.sample_grid(x0 - step, z0 - step, APRON, step)
		if not job["edits"].is_empty():
			for j in APRON:
				var wz := z0 + float(j - 1) * step
				for x in APRON:
					h[j * APRON + x] = _edit_h(h[j * APRON + x], x0 + float(x - 1) * step, wz,
							job["edits"])
	if job["kind"] == JOB_COLL:
		_out[i] = {"heights": h}
		return
	_out[i] = {"heights": h, "mesh": _mesh_arrays(h, step, job["sig"], x0, z0)}

## A pool job, from outside: how many nodes are waiting to be assembled.
func pending_jobs() -> int:
	return _jobs.size() + _col_jobs.size() + (_batch.size() if _busy else 0)

## COMPUTING CAN BE DONE IN A BATCH, LANDING CANNOT. The threads compute BUILD_BATCH chunks in parallel, and
## that is right: they compute in their own slices and bother nobody. But landing happens on the
## MAIN thread and is expensive per chunk: an ArrayMesh, uploading vertices to the GPU, a new node in the
## scene tree. Twenty-four of those in one frame are the 30 fps standing still the player measured
## against 22 while moving over new ground.
##
## So the results go INTO A QUEUE, and from it no more than APPLY_BUDGET go into a frame.
## The total time is the same, the spike is smeared out.
##
## COLLISION GOES OUTSIDE THE BUDGET. A tile is what the machine drives on; delaying it by a frame means
## letting it fall through. A mesh is what you look at, and it will wait.
const APPLY_BUDGET := 4
var _apply_q: Array = []

func _apply_batch() -> void:
	for i in _batch.size():
		var job: Dictionary = _batch[i]
		var res = _out[i]
		if res == null:
			continue
		var key: int = job["key"]
		_hc[key] = res["heights"]
		if int(job["lod"]) >= 2 and not _relief.has(key):
			_relief_new = true             # near ground is never merged for size (SUBPX_NEAR)
		if job["kind"] == JOB_COLL:
			_queued.erase(key | (1 << 50))
			_make_tile(key, job["gx"], job["gz"], res["heights"])
			continue
		_apply_q.append({"job": job, "mesh": res["mesh"]})
	_batch.clear()
	_out.clear()
	_prune_heights()

## We land APPLY_BUDGET meshes per frame. While the queue is not empty, a new batch is not started into the pool
## (see _job_tick): otherwise at fast driving the queue would grow faster than it is cleared,
## and the ground would lag more and more, and memory would rise.
func _drain_apply() -> void:
	# WHILE LOADING IS RUNNING — NO BUDGET. The screen is closed by the fade anyway, there is nothing to smooth, and
	# maximum throughput is what is needed: the player looks at the loading bar, not at frames.
	# The budget turns on when the ground is ready and they have started looking at it.
	var n: int = _apply_q.size() if not terrain_is_ready else mini(APPLY_BUDGET, _apply_q.size())
	for i in n:
		var e: Dictionary = _apply_q.pop_front()
		var job: Dictionary = e["job"]
		_queued.erase(int(job["key"]))
		_place_mesh(int(job["key"]), job, e["mesh"])

func _place_mesh(key: int, job: Dictionary, arrays: Array) -> void:
	if arrays.is_empty():
		var gone = _live.get(key)
		if gone != null and is_instance_valid(gone["inst"]):
			gone["inst"].queue_free()
		_live.erase(key)
		_cover_ep += 1
		_drop_staged(key)
		_hlod_dirty = true
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays[0])
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = Vector3(job["gx"] * (CHUNK << job["lod"]), 0.0, job["gz"] * (CHUNK << job["lod"]))
	mi.custom_aabb = arrays[1]
	mi.material_override = _mat
	# THE GROUND CASTS NO SHADOW, IT ONLY RECEIVES. Measured on the device: 17 fps with shadows, 25
	# without — a third of the frames for one setting. The shadows are already configured frugally (one split, hard, map
	# 1024), so the cost is not in quality but in WHAT is drawn into the map: the near two levels are
	# tens of thousands of ground triangles against a couple of thousand for the machines.
	#
	# The shadow the player actually sees is the MACHINE's shadow on the ground, and it stays. What goes
	# is the terrain's own shadow: a mountain stops shading the valley. The loss is real and acknowledged.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	add_child(mi)
	var entry := {"inst": mi, "sig": job["sig"], "lod": job["lod"], "gx": job["gx"], "gz": job["gz"],
			"seen": float(Time.get_ticks_msec()) * 0.001}
	if int(job["lod"]) >= HLOD_MIN_LOD and int(job["lod"]) <= HLOD_SPAN_LOD:
		entry["arr"] = arrays[0]           # the cluster merges these (HLOD), never re-reads the GPU
		entry["aabb"] = arrays[1]
	# Loading: the screen is behind the fade and nothing is drawn yet - straight in.
	if not terrain_is_ready:
		_go_live(key, entry)
		return
	# A RESTITCH, or FRESH GROUND (nothing else drawn over its area), THAT MEETS WHAT IS DRAWN goes up
	# now - fresh ground most of all: until it is up there is no ground there. A finer neighbour of
	# fresh ground already snaps to it: its seams come from the leaves, not from what was drawn.
	# Everything else waits for `_release_held`, which runs once the frame's meshes have landed.
	var lod: int = job["lod"]
	var gx: int = job["gx"]
	var gz: int = job["gz"]
	if (_live.has(key) or not _area_drawn(lod, gx, gz)) and _fits_drawn(lod, gx, gz, int(job["sig"])):
		_go_live(key, entry)
		return
	_drop_staged(key)
	entry["t"] = Time.get_ticks_msec()
	_staged[key] = entry
	_held_dirty = true

## Put a built mesh on screen in place of the node's old one. If it managed to leave the frame while being computed,
## we still lay it, only hidden: it is already computed, and the camera goes back and forth.
func _go_live(key: int, entry: Dictionary) -> void:
	var shown: bool = _want.has(key)
	var old = _live.get(key)
	if old != null:
		if old.get("cov", false):
			entry["cov"] = true            # still under the ground that covered it
			shown = false
		elif is_instance_valid(old["inst"]):
			shown = shown or (old["inst"] as Node3D).visible
		if is_instance_valid(old["inst"]):
			old["inst"].queue_free()
	(entry["inst"] as Node3D).visible = shown
	_live[key] = entry                     # no "gen": its seams are checked when the frame wants it
	_cover_ep += 1
	_hlod_dirty = true

func _drop_staged(key: int) -> void:
	var s = _staged.get(key)
	if s != null and is_instance_valid(s["inst"]):
		s["inst"].queue_free()
	_staged.erase(key)

## RELEASE WHAT FITS, once the frame's meshes have landed:
##  - A LEVEL CHANGE GOES UP AS ONE UNIT: the old node and every leaf replacing it (a split), or the
##    new node and the finer ones it replaces (a merge), once all of it is built - and only when
##    every drawn neighbour of its area has a mesh that meets it, its own or a held restitch that
##    goes up in the same frame. Changes that need each other go up together; one waiting on a
##    change still building waits with it (`_unit_fits` over the overlay of all of them).
##  - A RESTITCH, or GROUND WITH NOTHING ELSE DRAWN OVER ITS AREA, goes up alone once its seams meet
##    what is drawn round it.
## A side facing nothing in the frame does not count (`_fits_drawn`): a crack nobody sees is not
## worth holding ground for, and what is off the frame is not built until the camera turns to it.
## `HOLD_MAX_MS` / `FRESH_HOLD_MS` are the last resort - a mesh held that long goes up as it is, as
## all of them used to.
func _release_held() -> void:
	_held_dirty = false
	if _staged.is_empty():
		return
	var units := {}
	for key in _staged:
		if _live.has(key):
			continue                             # a restitch: a support for units, or alone below
		var e: Dictionary = _staged[key]
		var l: int = e["lod"]
		var anc := _drawn_ancestor(l, int(e["gx"]), int(e["gz"]))
		if anc != -1:
			if not units.has(anc):
				var add: Array = []
				var whole: bool = _gather_under(_key_lod(anc), _key_gx(anc), _key_gz(anc), add)
				units[anc] = {"add": add, "hide": [anc]} if whole else {}
			continue
		var under: Array = _drawn_under(l, int(e["gx"]), int(e["gz"]))
		if not under.is_empty():
			units[key] = {"add": [key], "hide": under}  # a merge; with nothing under it, fresh ground
	for uid in units.keys():
		if (units[uid] as Dictionary).is_empty():
			units.erase(uid)
	var used := {}
	var settled := false
	for _pass in 6:
		if units.is_empty():
			break
		_ovl.clear()
		for uid in units:
			for h in units[uid]["hide"]:
				_ovl[h] = false
			for a in units[uid]["add"]:
				_ovl[a] = true
		used.clear()
		var bad: Array = []
		for uid in units:
			if not _unit_fits(uid, units[uid], used):
				bad.append(uid)
		_ovl.clear()
		if bad.is_empty():
			settled = true
			break
		for uid in bad:
			units.erase(uid)
	if not settled:
		units.clear()                            # nothing proven to fit: nothing goes up this pass
	for uid in units:
		var u: Dictionary = units[uid]
		for h in u["hide"]:
			var n = _live.get(h)
			if n != null:
				if is_instance_valid(n["inst"]):
					(n["inst"] as Node3D).visible = false
				n["cov"] = true
				_hlod_dirty = true
		for a in u["add"]:
			_up(a)
	for k in used:
		_up(k)
	var now := Time.get_ticks_msec()
	for key in _staged.keys():
		if not _staged.has(key):
			continue                             # went up with the ground next to it
		var e: Dictionary = _staged[key]
		var l: int = e["lod"]
		var gx: int = e["gx"]
		var gz: int = e["gz"]
		var fresh: bool = not _live.has(key) and not _area_drawn(l, gx, gz)
		if now - int(e["t"]) > (FRESH_HOLD_MS if fresh else HOLD_MAX_MS):
			_up(key)
		elif _live.has(key):
			if _fits_drawn(l, gx, gz, int(e["sig"])):
				_up(key)                         # a restitch: its neighbours are not touched
		elif fresh and _fits_drawn(l, gx, gz, int(e["sig"])):
			_up(key)

## Bring one held mesh (or a leaf already built and covered) up.
func _up(key: int) -> void:
	var e = _staged.get(key)
	if e != null:
		_staged.erase(key)
		if _leaf_set.has(key) or _live.has(key):
			_go_live(key, e)
		elif is_instance_valid(e["inst"]):
			e["inst"].queue_free()               # the leaves moved on while it was building
		return
	var n = _live.get(key)
	if n != null and n.get("cov", false):
		n["cov"] = false
		_hlod_dirty = true
		if is_instance_valid(n["inst"]):
			(n["inst"] as Node3D).visible = _want.has(key)

## Every leaf under an old node, built (held or live) - false while any is still building.
func _gather_under(lod: int, gx: int, gz: int, add: Array) -> bool:
	var cl := lod - 1
	if cl < 0:
		return false
	for dz in 2:
		for dx in 2:
			var cx := gx * 2 + dx
			var cz := gz * 2 + dz
			var ck := _key(cl, cx, cz)
			if _leaf_set.has(ck):
				if _staged.has(ck) or _live.has(ck):
					add.append(ck)
				else:
					return false
			elif _aabb_dist2(_node_aabb(cl, cx, cz), _leaf_at) > view_distance * view_distance:
				continue                         # past the view: no ground there at all
			elif not _gather_under(cl, cx, cz, add):
				return false
	return true

## The drawn finer nodes over this node's area, two levels down: a merge is one level at a time
## while driving, and a deeper one (a teleport) is left to the hold timeout. Twenty lookups, not a
## pass over every live node for every held mesh.
func _drawn_under(lod: int, gx: int, gz: int) -> Array:
	var out: Array = []
	for d in [1, 2]:
		var l: int = lod - d
		if l < 0:
			break
		var n: int = 1 << d
		for dz in n:
			for dx in n:
				var k: int = (l << 40) | (((gx * n + dx) & 0xFFFFF) << 20) | ((gz * n + dz) & 0xFFFFF)
				var e = _live.get(k)
				if e != null and not e.get("cov", false):
					out.append(k)
	return out

## With the overlay of every unit going up: does this unit's new ground meet what is round it, and
## does every drawn neighbour of its area meet it back - with its own mesh, or a held restitch
## (`used`: it goes up in the same frame)?
func _unit_fits(uid: int, u: Dictionary, used: Dictionary) -> bool:
	for a in u["add"]:
		var e = _staged.get(a)
		if e == null:
			e = _live.get(a)
		if e == null or not _fits_drawn(int(e["lod"]), int(e["gx"]), int(e["gz"]), int(e["sig"])):
			return false
	for n in _drawn_round(uid):
		if _ovl.has(n) or not _in_frame_key(n):
			continue
		var live: Dictionary = _live[n]
		if _fits_drawn(int(live["lod"]), int(live["gx"]), int(live["gz"]), int(live["sig"])):
			continue
		var st = _staged.get(n)
		if st != null and _fits_drawn(int(st["lod"]), int(st["gx"]), int(st["gz"]), int(st["sig"])):
			used[n] = true
			continue
		return false
	return true

## The drawn nodes bordering a node's area, read through the overlay. Probed every quarter of a
## side: leaves next to each other differ by a level at most, so nothing drawn beside a node of
## level L is narrower than a quarter of it even mid-change.
func _drawn_round(key: int) -> Array:
	var n: int = 1 << _key_lod(key)
	var bx: int = _key_gx(key) * n
	var bz: int = _key_gz(key) * n
	var seen := {}
	for i in range(0, n, maxi(1, n >> 2)):
		var k := _drawn_key_at(bx + i, bz - 1)
		if k != -1: seen[k] = true
		k = _drawn_key_at(bx + i, bz + n)
		if k != -1: seen[k] = true
		k = _drawn_key_at(bx - 1, bz + i)
		if k != -1: seen[k] = true
		k = _drawn_key_at(bx + n, bz + i)
		if k != -1: seen[k] = true
	return seen.keys()

## Is this node anywhere in the frame (the planes of the last selection)? Remembered until the
## planes change (`_pack_planes`): a release asks it of the same few nodes many times over.
var _frame_memo: Dictionary = {}

func _in_frame_key(key: int) -> bool:
	if _pl.size() < 18:
		return true
	var hit = _frame_memo.get(key)
	if hit != null:
		return hit
	var span := float(CHUNK << _key_lod(key))
	var x0: float = _key_gx(key) * span
	var z0: float = _key_gz(key) * span
	var inside := true
	for q in 6:
		var q3: int = q * 3
		var bx: float = x0 if _pi[q * 2] == 0 else x0 + span
		var bz: float = z0 if _pi[q * 2 + 1] == 1 else z0 + span
		if _pl[q3] * bx + _pl[q3 + 1] * bz + _pl[q3 + 2] > 0.0:
			inside = false
			break
	_frame_memo[key] = inside
	return inside

## THE NEAR CIRCLE IS ALWAYS KEPT. Everything closer than KEEP_RADIUS to the player is dropped neither by
## time nor by the ceiling: it is the ground they will turn to face in a second. The rest of the memory
## works as before — what was seen recently lies for another NODE_GRACE seconds and is evicted oldest first.
##
## A circle of 320 m is about a hundred and fifty nodes of all levels: a fifth of the mesh ceiling and
## a twentieth of the height ceiling. Cheap precisely because the far levels cover a lot with one node.
## The menu backdrop keeps less (menu_stage_3d MENU_KEEP).
var keep_radius: float = 320.0

func _near_player(key: int) -> bool:
	if _near_hold(_key_lod(key), _key_gx(key), _key_gz(key)):
		return true
	if keep_radius <= 0.0:
		return false
	return _aabb_dist2(_node_aabb(_key_lod(key), _key_gx(key), _key_gz(key)), _sel_local) \
			<= keep_radius * keep_radius

## We keep heights for what is drawn, lies under collision, or stands in the near circle.
func _prune_heights() -> void:
	if _hc.size() <= _hc_cap():
		return
	for key in _hc.keys():
		if _hc.size() <= _hc_cap():
			return
		if _live.has(key) or _want.has(key) or _col.has(key) or _near_player(key):
			continue
		_hc.erase(key)

# ─────────────────────────────────────────────────────────────────────────────
# A node's mesh
# ─────────────────────────────────────────────────────────────────────────────

## A node's vertices, normals, biome colour and triangles. h is an APRON² grid with a one-cell apron of
## the step: the apron is needed by the normals, otherwise a lighting change would be visible along the chunk's edge.
func _mesh_arrays(h: PackedFloat32Array, step: float, sig: int, x0: float, z0: float) -> Array:
	if h.size() != APRON * APRON:
		return []
	var b := _biomes()
	var vh := PackedFloat32Array()
	vh.resize(VERTS * VERTS)
	for j in VERTS:
		for i in VERTS:
			vh[j * VERTS + i] = h[(j + 1) * APRON + (i + 1)]
	# PULLING THE EDGE IN TO A COARSE NEIGHBOUR. Its vertices stand every r of ours, and we lay the extra ones
	# on the straight line between them — the very one the neighbour draws its own edge along. Corner vertices are multiples of
	# any r, so two edges at a corner do not get in each other's way.
	var sn: int = sig & 0xFF
	var ss: int = (sig >> SIDE_BITS) & 0xFF
	var sw: int = (sig >> (SIDE_BITS * 2)) & 0xFF
	var se: int = (sig >> (SIDE_BITS * 3)) & 0xFF
	var kn: int = sn & 0xF
	var ks: int = ss & 0xF
	var kw: int = sw & 0xF
	var ke: int = se & 0xF
	if kn > 0:
		_snap_row(vh, 0, 1 << kn, true)
	if ks > 0:
		_snap_row(vh, VERTS - 1, 1 << ks, true)
	if kw > 0:
		_snap_row(vh, 0, 1 << kw, false)
	if ke > 0:
		_snap_row(vh, VERTS - 1, 1 << ke, false)

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	verts.resize(VERTS * VERTS)
	norms.resize(VERTS * VERTS)
	cols.resize(VERTS * VERTS)
	var y_lo := INF
	var y_hi := -INF
	for j in VERTS:
		var wz := z0 + float(j) * step
		for i in VERTS:
			var vi := j * VERTS + i
			var y: float = vh[vi]
			y_lo = minf(y_lo, y)
			y_hi = maxf(y_hi, y)
			verts[vi] = Vector3(float(i) * step, y, float(j) * step)
			# The normal is taken over the apron, not the grid's edge: the neighbouring chunk computes the same difference at the same
			# point, so there is no seam in the lighting.
			var a := (j + 1) * APRON + (i + 1)
			var hl: float = h[a - 1]
			var hr: float = h[a + 1]
			var hu: float = h[a - APRON]
			var hd: float = h[a + APRON]
			norms[vi] = Vector3(hl - hr, 2.0 * step, hu - hd).normalized()
			var wp := Vector2(x0 + float(i) * step, wz)
			# .r — edge code and salt flat (see EDGE_STEP), .g canyon, .b meadow, .a mountains. The ground colour
			# lives in the vertices, the shader only reads them.
			var edge: int = 1 if (j == 0 or j == VERTS - 1) else (2 if (i == 0 or i == VERTS - 1) else 0)
			# On the proving ground we do not ask for masks at all: there is one biome by definition, and three masks per
			# vertex are exactly the work the ground was made flat to avoid.
			cols[vi] = (Color(EDGE_STEP * edge, FLAT_COLOR.g, FLAT_COLOR.b, FLAT_COLOR.a)
					if flat_ground else _biome_colour(b, wp, edge))

	var idx := PackedInt32Array()
	idx.resize(CHUNK * CHUNK * 6)
	var n := 0
	for j in CHUNK:
		for i in CHUNK:
			var i00 := j * VERTS + i
			var i10 := i00 + 1
			var i01 := i00 + VERTS
			var i11 := i01 + 1
			idx[n] = i00; idx[n + 1] = i10; idx[n + 2] = i11
			idx[n + 3] = i00; idx[n + 4] = i11; idx[n + 5] = i01
			n += 6

	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	var span := float(CHUNK) * step
	return [arr, AABB(Vector3(0.0, y_lo, 0.0), Vector3(span, maxf(y_hi - y_lo, 0.01), span))]

## One side of the grid onto the neighbour's coarse lattice. along_x — the edge runs along x (north/south).
func _snap_row(vh: PackedFloat32Array, line: int, r: int, along_x: bool) -> void:
	for i in VERTS:
		var rem := i % r
		if rem == 0:
			continue
		var i0 := i - rem
		var i1 := mini(i0 + r, VERTS - 1)
		var t := float(rem) / float(r)
		if along_x:
			vh[line * VERTS + i] = lerpf(vh[line * VERTS + i0], vh[line * VERTS + i1], t)
		else:
			vh[i * VERTS + line] = lerpf(vh[i0 * VERTS + line], vh[i1 * VERTS + line], t)

# ─────────────────────────────────────────────────────────────────────────────
# HLOD: far leaves drawn as one mesh per cluster
# ─────────────────────────────────────────────────────────────────────────────
## THE FAR GROUND IS DRAWN BY CLUSTER, NOT BY LEAF (the player's call). Every leaf of level
## HLOD_MIN_LOD..HLOD_SPAN_LOD that is drawn (live, not covered) belongs to the cluster of the
## HLOD_SPAN_LOD cell it stands in, and a settled cluster is ONE mesh - the members' own arrays
## concatenated, moved by their offsets - drawn in one call while the members stay in place with their
## render layers at 0 (`MachineBatch`'s trick): everything that reads the leaves (seams, the held level
## changes, `_drawn_key_at`, the occlusion test) sees them as before. The levels are the sub-pixel
## LOD's business; this only decides how many calls draw them.
## A CLUSTER IS NEVER STALE ON SCREEN: at the end of any frame the ground changed (`_hlod_dirty`) the
## members are counted again, and one whose set differs from what its mesh holds is SPLIT at once -
## the mesh hidden, the members drawn by themselves, which is exactly the path that ran before. It is
## merged again once its set has held still HLOD_SETTLE_MS, on a worker thread; a merge that comes back
## for a set that has moved on since is thrown away.
const HLOD_MIN_LOD := 2
const HLOD_SPAN_LOD := 6
const HLOD_SETTLE_MS := 400
var _hlod_dirty: bool = false
## Off: every cluster split, the leaves drawn by themselves (measurements, and a way back).
var hlod_enabled: bool = true
## cluster Vector2i -> {"inst", "built", "want", "since", "task", "job", "members"}
var _clusters: Dictionary = {}

func _hlod_tick() -> void:
	if Engine.is_editor_hint():
		return
	if not hlod_enabled:
		if not _clusters.is_empty():
			_hlod_stop()
		return
	var now: int = Time.get_ticks_msec()
	if _hlod_dirty:
		_hlod_dirty = false
		_hlod_recount(now)
	for ck in _clusters.keys():
		var c: Dictionary = _clusters[ck]
		if c["task"] != -1:
			if not WorkerThreadPool.is_task_completed(c["task"]):
				continue
			WorkerThreadPool.wait_for_task_completion(c["task"])
			c["task"] = -1
			_hlod_land(ck, c)
		elif int(c["want"]) != int(c["built"]) and now - int(c["since"]) >= HLOD_SETTLE_MS:
			_hlod_start(ck, c)
		if c["members"].is_empty() and c["task"] == -1:
			if is_instance_valid(c["inst"]):
				c["inst"].queue_free()
			_clusters.erase(ck)

## Who is in each cluster now; a cluster whose set moved is split this frame.
func _hlod_recount(now: int) -> void:
	var sets: Dictionary = {}
	for key in _live:
		var l: int = _key_lod(key)
		if l < HLOD_MIN_LOD or l > HLOD_SPAN_LOD:
			continue
		var n: Dictionary = _live[key]
		var inst = n["inst"]
		if not is_instance_valid(inst) or not (inst as Node3D).visible or not n.has("arr"):
			continue
		var sh: int = HLOD_SPAN_LOD - l
		var ck := Vector2i(_key_gx(key) >> sh, _key_gz(key) >> sh)
		var e = sets.get(ck)
		if e == null:
			e = {"sig": 0, "m": {}}
			sets[ck] = e
		e["sig"] = int(e["sig"]) + hash([key, (inst as Object).get_instance_id()])
		e["m"][key] = inst
	for ck in sets.keys():
		if not _clusters.has(ck):
			_clusters[ck] = {"inst": null, "built": 0, "want": 0, "since": now, "task": -1, "job": null,
					"members": {}}
	for ck in _clusters.keys():
		var c: Dictionary = _clusters[ck]
		var e = sets.get(ck)
		var sig: int = int(e["sig"]) if e != null else 0
		var mem: Dictionary = e["m"] if e != null else {}
		if sig == int(c["want"]) and sig == int(c["built"]):
			continue
		if sig != int(c["want"]):
			c["want"] = sig
			c["since"] = now
		# split: the mesh goes, everyone draws itself (members that left included)
		if is_instance_valid(c["inst"]):
			(c["inst"] as Node3D).visible = false
		for k in c["members"]:
			var old = c["members"][k]
			if is_instance_valid(old):
				(old as VisualInstance3D).layers = 1
		for k in mem:
			(mem[k] as VisualInstance3D).layers = 1
		c["built"] = -1 if sig != 0 else 0
		c["members"] = mem

## Snapshot the members' arrays and merge them on a worker thread.
func _hlod_start(ck: Vector2i, c: Dictionary) -> void:
	var parts: Array = []
	var origin := Vector3(ck.x * float(CHUNK << HLOD_SPAN_LOD), 0.0, ck.y * float(CHUNK << HLOD_SPAN_LOD))
	for k in c["members"]:
		var n = _live.get(k)
		if n == null or not n.has("arr"):
			c["since"] = Time.get_ticks_msec()       # a member left meanwhile: wait for the recount
			return
		var l: int = _key_lod(k)
		var off := Vector3(_key_gx(k) * float(CHUNK << l), 0.0, _key_gz(k) * float(CHUNK << l)) - origin
		parts.append([n["arr"], off, n["aabb"]])
	if parts.is_empty():
		return
	var job := {"parts": parts, "sig": int(c["want"]), "out": null}
	c["job"] = job
	c["task"] = WorkerThreadPool.add_task(_hlod_merge.bind(job), false, "ChunkTerrain HLOD")

## Worker: one surface out of the members' surfaces. Reads only the arrays handed to it.
func _hlod_merge(job: Dictionary) -> void:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var box := AABB()
	var first := true
	for p in job["parts"]:
		var arr: Array = p[0]
		var off: Vector3 = p[1]
		var base: int = verts.size()
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var i0: int = verts.size()
		verts.append_array(v)
		for i in v.size():
			verts[i0 + i] += off
		norms.append_array(arr[Mesh.ARRAY_NORMAL])
		cols.append_array(arr[Mesh.ARRAY_COLOR])
		var ix: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var j0: int = idx.size()
		idx.append_array(ix)
		for j in ix.size():
			idx[j0 + j] += base
		var b: AABB = (p[2] as AABB)
		b.position += off
		box = b if first else box.merge(b)
		first = false
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = norms
	out[Mesh.ARRAY_COLOR] = cols
	out[Mesh.ARRAY_INDEX] = idx
	job["out"] = [out, box]

## Main thread: the merge is put up only if the set it was made of is still the set.
func _hlod_land(ck: Vector2i, c: Dictionary) -> void:
	var job = c["job"]
	c["job"] = null
	if job == null or job["out"] == null or int(job["sig"]) != int(c["want"]):
		c["since"] = Time.get_ticks_msec() - HLOD_SETTLE_MS   # moved on: merge the new set next frame
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, job["out"][0])
	var mi: MeshInstance3D = c["inst"] if is_instance_valid(c["inst"]) else null
	if mi == null:
		mi = MeshInstance3D.new()
		mi.material_override = _mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(ck.x * float(CHUNK << HLOD_SPAN_LOD), 0.0, ck.y * float(CHUNK << HLOD_SPAN_LOD))
		add_child(mi)
		c["inst"] = mi
	mi.mesh = mesh
	mi.custom_aabb = job["out"][1]
	mi.visible = true
	for k in c["members"]:
		var m = c["members"][k]
		if is_instance_valid(m):
			(m as VisualInstance3D).layers = 0
	c["built"] = int(job["sig"])

func _hlod_stop() -> void:
	for ck in _clusters:
		var c: Dictionary = _clusters[ck]
		if c["task"] != -1:
			WorkerThreadPool.wait_for_task_completion(c["task"])
		if is_instance_valid(c["inst"]):
			c["inst"].queue_free()
		for k in c["members"]:
			var m = c["members"][k]
			if is_instance_valid(m):
				(m as VisualInstance3D).layers = 1
	_clusters.clear()

## How many calls the ground costs now: clusters drawn, leaves drawn by themselves (in the frame or not).
func hlod_stats() -> Vector2i:
	var merged := 0
	for ck in _clusters:
		var c: Dictionary = _clusters[ck]
		if is_instance_valid(c["inst"]) and (c["inst"] as Node3D).visible:
			merged += 1
	var alone := 0
	for key in _live:
		var inst = _live[key]["inst"]
		if is_instance_valid(inst) and (inst as Node3D).visible and (inst as VisualInstance3D).layers != 0:
			alone += 1
	return Vector2i(merged, alone)

# ─────────────────────────────────────────────────────────────────────────────
# Collision: a tile = a base chunk
# ─────────────────────────────────────────────────────────────────────────────
## A tile is cut FROM THE SAME HEIGHTS as the level-0 mesh (an APRON² grid at step 1) — so under a
## near chunk it comes free, and farther away it costs one sample. The apron gives the neighbours a shared
## row, so there are no holes at the joint.
var _col: Dictionary = {}        # key → CollisionShape3D
var _col_seen: Dictionary = {}   # key → when the tile was last needed
var _col_bodies: Array = []
var _col_active: bool = false
const COL_TILE_GRACE := 6.0

func set_collision_streaming(on: bool) -> void:
	_col_active = on and enable_streaming_collision
	if not _col_active:
		_clear_collision()
	elif _col_bodies.is_empty():
		_setup_bodies()

func _setup_bodies() -> void:
	_col_bodies.clear()
	var tree := get_tree()
	if tree == null:
		return
	var root := tree.current_scene
	if root != null:
		for n in root.find_children("*", "PhysicsBody3D", true, false):
			_register_body(n)
	if not tree.node_added.is_connected(_on_node_added):
		tree.node_added.connect(_on_node_added)
		tree.node_removed.connect(_on_node_removed)

## A movable body that needs ground. StaticBody3D and Area3D do not count.
func _is_trackable(n: Node) -> bool:
	return n is RigidBody3D or n is CharacterBody3D

## The topmost movable body up the parent chain. A part welded to a machine does not ask for its own
## window — the machine's window covers it.
func _top_body(n: Node) -> Node:
	var top: Node = n
	var p := n.get_parent()
	while p != null:
		if _is_trackable(p):
			top = p
		p = p.get_parent()
	return top

func _on_node_added(n: Node) -> void:
	if _is_trackable(n):
		call_deferred("_register_body", n)   # the parent and position are already in place by then

func _on_node_removed(n: Node) -> void:
	if _is_trackable(n):
		_col_bodies.erase(n)

func _register_body(n: Node) -> void:
	if not _col_active or not is_instance_valid(n) or not _is_trackable(n):
		return
	if is_ancestor_of(n) or _top_body(n) != n or _col_bodies.has(n):
		return
	_col_bodies.append(n)

func _clear_collision() -> void:
	for cs in _col.values():
		if is_instance_valid(cs):
			cs.queue_free()
	_col.clear()
	_col_seen.clear()

func _col_tick() -> void:
	if not _col_active or _gen == null:
		return
	var want := {}
	var r: int = COLLISION_RADIUS
	var dead := false
	var inv := global_transform.affine_inverse()
	for raw in _col_bodies:
		if raw == null or not is_instance_valid(raw):
			dead = true
			continue
		var body: Node3D = raw
		# A sleeping body does not need ground: a sleeping enemy is frozen whole, and a lying block does not
		# move. The loop runs every frame, so the window comes back the same frame it
		# wakes up. Frozen ones (anchor, carried) we do NOT skip — freeze is not rest.
		if body.get_meta("asleep", false):
			continue
		if body is RigidBody3D and (body as RigidBody3D).sleeping and not (body as RigidBody3D).freeze:
			continue
		# A machine CRUISING far from the camera is driven on these heights, not by Jolt (enemy_vehicle
		# FAR CRUISE): no ground under it, or every metre it covers adds and frees tiles on this one
		# static body. It asks again for the tile under it before it lands (has_collision_at).
		if body.has_method("is_cruising") and body.is_cruising():
			continue
		# A CORRIDOR, NOT A POINT: we ask for ground both where the body stands and where it will be in
		# COLLISION_LOOKAHEAD seconds. A tile is now computed, and asking for it at the moment of arrival means
		# arriving into the void. Moving the window wholesale forward is not allowed — at high speed the body
		# would fall out of its own window.
		var p0: Vector3 = inv * body.global_position
		var p1: Vector3 = p0
		if COLLISION_LOOKAHEAD > 0.0 and body is RigidBody3D:
			p1 += inv.basis * ((body as RigidBody3D).linear_velocity * COLLISION_LOOKAHEAD)
		var bx0: int = int(floor((minf(p0.x, p1.x) - r) / CHUNK))
		var bx1: int = int(floor((maxf(p0.x, p1.x) + r) / CHUNK))
		var bz0: int = int(floor((minf(p0.z, p1.z) - r) / CHUNK))
		var bz1: int = int(floor((maxf(p0.z, p1.z) + r) / CHUNK))
		for bz in range(bz0, bz1 + 1):
			for bx in range(bx0, bx1 + 1):
				want[_key(0, bx, bz)] = Vector2i(bx, bz)
	var now: float = float(Time.get_ticks_msec()) * 0.001
	for key in want:
		_col_seen[key] = now
		if not _col.has(key):
			var g: Vector2i = want[key]
			_enqueue_coll(g.x, g.y)
	# A tile lives a few more seconds after it stops being needed: creating it
	# is the physics baking a height field, and a machine driving along the border would otherwise re-create
	# the same tiles every frame.
	for key in _col.keys():
		if want.has(key) or now - float(_col_seen.get(key, 0.0)) < COL_TILE_GRACE:
			continue
		if is_instance_valid(_col[key]):
			_col[key].queue_free()
		_col.erase(key)
		_col_seen.erase(key)
	if dead:
		var alive: Array = []
		for b in _col_bodies:
			if b != null and is_instance_valid(b):
				alive.append(b)
		_col_bodies = alive

func _make_tile(key: int, bcx: int, bcz: int, h: PackedFloat32Array) -> void:
	if _col.has(key) or h.size() != APRON * APRON:
		return
	var shape := HeightMapShape3D.new()
	shape.map_width = APRON
	shape.map_depth = APRON
	shape.map_data = h
	var cs := CollisionShape3D.new()
	cs.shape = shape
	# The grid covers cells [x0−1 … x0+CHUNK+1], its middle is x0 + CHUNK/2.
	cs.position = Vector3(bcx * CHUNK + CHUNK * 0.5, 0.0, bcz * CHUNK + CHUNK * 0.5)
	add_child(cs)
	_col[key] = cs
	# MARK THE TIME AT ONCE. Without recording _col_seen considers the tile unneeded from second zero and tears
	# it down on the very first tick — and the starting ring's tiles are born before the machine takes
	# its place, that is, before anyone has asked for them.
	_col_seen[key] = float(Time.get_ticks_msec()) * 0.001

## Is a collision tile up under this world point - what a machine coming back from its cruise waits for.
func has_collision_at(world: Vector3) -> bool:
	var p: Vector3 = global_transform.affine_inverse() * world
	return _col.has(_key(0, int(floor(p.x / CHUNK)), int(floor(p.z / CHUNK))))

func collision_stats() -> Vector2i:
	return Vector2i(_col.size(), _col_bodies.size())

# ─────────────────────────────────────────────────────────────────────────────
# Biomes, materials, statistics
# ─────────────────────────────────────────────────────────────────────────────

## (canyon, meadow, mountains) at a world point — the same masks that are baked into the vertices.
func biome_at(world_pos: Vector3) -> Vector3:
	var b := _biomes()
	var p: Vector3 = global_transform.affine_inverse() * world_pos
	var wp := Vector2(p.x, p.z)
	var c := _biome_colour(b, wp, 0)
	return Vector3(c.g, c.b, c.a)

## THE VERTEX'S BIOMES, one door for the bake and for `biome_at`: r the border code and the salt
## flat (EDGE_STEP / SALT_SPAN), g canyon, b meadow, a mountain. THE SALT FLAT WINS OVER THE CANYON
## in colour as it does in the landform (terrain_gen.carve_at): the canyon's mask is taken by it, or
## a lake bed under a canyon mask was painted terracotta from shore to shore.
func _biome_colour(b: TerrainBiomes, wp: Vector2, edge: int) -> Color:
	var salt: float = b.salt_mask(wp)
	return Color(EDGE_STEP * edge + SALT_SPAN * salt,
			b.canyon_mask(wp) * (1.0 - salt), b.meadow_mask(wp), b.mountain_mask(wp))

## 0..1: a salt flat at this world point - the mask baked into COLOR.r.
func salt_at(world_pos: Vector3) -> float:
	var b := _biomes()
	var p: Vector3 = global_transform.affine_inverse() * world_pos
	return b.salt_mask(Vector2(p.x, p.z))

## ── THE GROUND FOR A WORKER THREAD ─────────────────────────────────────────
## What a task off the main thread may read to know the ground: the generator (it only reads once
## `begin_sampling` is behind it - the chunk builds run on it), the edits as they stand (the list is
## REPLACED on every edit, never changed in place, so the one handed over stays what it was) and the
## biomes. `_memo` and `_hc` belong to the main thread and are never read: a height here is
## `_memo_h`'s miss path, the function the chunks are built from. Asked on the main thread; empty with
## no generator or a moved map (the callers hand world points as the map's own cells). The caller
## keeps the generator alive by waiting for its task before the map leaves the tree.
func thread_ground() -> Dictionary:
	if _gen == null or global_transform != Transform3D.IDENTITY:
		return {}
	return {"gen": _gen, "edits": _flat_edits, "biomes": _biomes()}

## `cell_height` for a worker (`thread_ground`).
func thread_cell_height(g: Dictionary, cx: int, cz: int) -> float:
	var x := float(cx)
	var z := float(cz)
	return _edit_h((g["gen"] as LiteTerrainGen).height_at(x, z), x, z, g["edits"])

## `terrain_height_at` for a worker: the same bilinear patch over the same four nodes.
func thread_height_at(g: Dictionary, wx: float, wz: float) -> float:
	var x0 := int(floor(wx))
	var z0 := int(floor(wz))
	var tx: float = wx - float(x0)
	var tz: float = wz - float(z0)
	return lerpf(lerpf(thread_cell_height(g, x0, z0), thread_cell_height(g, x0 + 1, z0), tx),
			lerpf(thread_cell_height(g, x0, z0 + 1), thread_cell_height(g, x0 + 1, z0 + 1), tx), tz)

## `biome_at` for a worker: (canyon, meadow, mountain).
func thread_biome(g: Dictionary, wx: float, wz: float) -> Vector3:
	var b: TerrainBiomes = g["biomes"]
	var c := _biome_colour(b, Vector2(wx, wz), 0)
	return Vector3(c.g, c.b, c.a)

## `salt_at` for a worker.
func thread_salt(g: Dictionary, wx: float, wz: float) -> float:
	var b: TerrainBiomes = g["biomes"]
	return b.salt_mask(Vector2(wx, wz))

func _get_material() -> Material:
	if surface_material != null:
		return surface_material
	var m := ShaderMaterial.new()
	m.shader = GROUND_SHADER
	return m

## Its own instance of the base material: parameters are written into it, not into the shared resource.
## THE FAST GROUND: the ground's own shader as an unshaded variant that lights itself
## (glsl.gdshader, FAST_GROUND). Set while shadows are off (Main._apply_shadows): unshaded receives no
## shadow, and with none to receive the engine's lighting was 12 ms of the phone's 47 ms frame
## (measured on the device: "ground unshaded" against "ground no shadow"). It swaps the SHADER of the one
## material every chunk and HLOD cluster shares, carrying every uniform across.
var fast_ground: bool = false:
	set(v):
		if v == fast_ground:
			return
		fast_ground = v
		_apply_fast_ground()
var _lit_shader: Shader = null
var _fast_shader: Shader = null

func _apply_fast_ground() -> void:
	var sm := _mat as ShaderMaterial
	if sm == null or sm.shader == null:
		return
	if _lit_shader == null:
		_lit_shader = sm.shader
	var to: Shader = _lit_shader
	if fast_ground:
		if _fast_shader == null:
			_fast_shader = Shader.new()
			_fast_shader.code = _lit_shader.code.replace(
					"render_mode diffuse_lambert, specular_disabled;",
					"render_mode unshaded;\n#define FAST_GROUND")
		to = _fast_shader
	if sm.shader == to:
		return
	var keep := {}
	for u in sm.shader.get_shader_uniform_list():
		keep[u["name"]] = sm.get_shader_parameter(u["name"])
	sm.shader = to
	for k in keep:
		sm.set_shader_parameter(k, keep[k])

func _setup_materials(base: Material) -> void:
	if base is ShaderMaterial:
		_mat = base.duplicate()
		(_mat as ShaderMaterial).set_shader_parameter("grass_fade", grass_fade())
		_push_biomes()
		_lit_shader = null
		_fast_shader = null
		if fast_ground:
			_apply_fast_ground()
	else:
		_mat = base

## WHERE THE GRASS FADES OUT, metres from the camera over the ground. A level-0 node meets a level-1
## one anywhere past 44 m and the shader's border rule makes those seams agree; it cannot make a
## level-1 border agree with a level-2 edge, so the lift is gone before level 2 can begin - its split
## distance less twice the leaf hysteresis (the camera is up to a leaf step from the point the leaves
## were cut around, and a node waiting to be split is drawn a while longer).
const GRASS_FADE_BAND := 24.0

func grass_fade() -> Vector2:
	var end: float = float(CHUNK << 2) * LOD_QUALITY - 2.0 * sqrt(LEAF_MOVE2)
	return Vector2(end - GRASS_FADE_BAND, end)

func _push_biomes() -> void:
	if biomes == null:
		return
	if _mat is ShaderMaterial:
		biomes.apply_to_material(_mat as ShaderMaterial, world_height())
		var sm := _mat as ShaderMaterial
		if not grass_lift_enabled:
			sm.set_shader_parameter("grass_height", 0.0)
		if _snow_h < 0.0:
			var s = sm.get_shader_parameter("snow_height")
			_snow_h = float(s) if s != null else 0.3
		sm.set_shader_parameter("snow_height", _snow_h if snow_lift_enabled else 0.0)

var _snow_h := -1.0                  # the material's own snow crust, kept to turn it back on

## THE SUN'S SHADOW CASCADES (sun_shadows.gd), read by the fast ground only: near to far, a map and
## its window each - uv = world XZ * x + yz, w the window's half in metres, 0 for a map not built yet.
## Strength 0 skips the fetch. The maps are handed over only when they change: the near window moves
## every frame of a drive, its map stays the same texture.
const SUN_SHADOW_MAPS := [&"sun_shadow_map", &"sun_shadow_map1", &"sun_shadow_map2"]
const SUN_SHADOW_UVS := [&"sun_shadow_uv0", &"sun_shadow_uv1", &"sun_shadow_uv2"]
var _sun_maps: Array = []
func set_sun_shadows(maps: Array, uvs: Array, strength: float) -> void:
	if not (_mat is ShaderMaterial):
		return
	var m := _mat as ShaderMaterial
	if m != _sun_mat or maps != _sun_maps:
		_sun_mat = m
		_sun_maps = maps.duplicate()
		for k in SUN_SHADOW_MAPS.size():
			m.set_shader_parameter(SUN_SHADOW_MAPS[k], maps[k] if k < maps.size() else null)
	for k in SUN_SHADOW_UVS.size():
		m.set_shader_parameter(SUN_SHADOW_UVS[k], uvs[k] if k < uvs.size() else Vector4.ZERO)
	m.set_shader_parameter(&"sun_shadow_strength", strength if fast_ground and not maps.is_empty() else 0.0)
var _sun_mat: ShaderMaterial = null

## THE GROUND'S HEIGHT OFF ANY NODE WHOSE HEIGHTS ARE STILL HELD (`_hc`), the finest first, NAN where
## none is. `drawn_height` answers only under the frame; this answers wherever ground was built - behind
## the camera, off the frustum, and inside `keep_radius` for good (`_prune_heights` keeps those). The
## sun shadow's ground shade marches over it (`sun_shadows.gd`): on the drawn heights alone nine cells in
## ten of its near grid were empty - everything the camera was not looking at - measured on the real
## driver, 17122 of 19044.
func known_height(wx: float, wz: float) -> float:
	if _gen == null:
		return NAN
	var p: Vector3 = global_transform.affine_inverse() * Vector3(wx, 0.0, wz)
	var bcx: int = floori(p.x / CHUNK)
	var bcz: int = floori(p.z / CHUNK)
	for l in MAX_LOD + 1:
		var hs = _hc.get(_key(l, bcx >> l, bcz >> l))
		if hs != null and (hs as PackedFloat32Array).size() == APRON * APRON:
			var span := float(CHUNK << l)
			var cell := float(1 << l)
			var h: float = _grid_h(hs, (p.x - float(bcx >> l) * span) / cell, (p.z - float(bcz >> l) * span) / cell)
			return (global_transform * Vector3(p.x, h, p.z)).y
	return NAN

## A number that moves whenever a node is built or dropped or the leaf set changes (`_cover_ep`): the
## sun shadow asks it before reading again the heights it had none for, so ground that cannot have
## changed is not asked twice.
func built_epoch() -> int:
	return _cover_ep

## A ROW OF `known_height`, written into `out` from index `at`: `count` points from (x0, z) every `step`
## along world X, `none` where no height is held. One call and one inverse for the row, and the node
## looked up once per level-0 chunk - which node answers depends on that chunk alone - where a call a
## point was most of what the sun shadow's ground shade cost (2.7 ms a frame at 20 m/s on the real
## driver, optimize=none). `out` is written in place (a packed array is passed by reference).
func known_heights_into(out: PackedFloat32Array, at: int, x0: float, z: float, step: float, count: int, none: float = NAN) -> void:
	if _gen == null:
		for i in count:
			out[at + i] = none
		return
	var xf: Transform3D = global_transform
	var plain: bool = xf == Transform3D.IDENTITY
	var inv: Transform3D = xf.affine_inverse()
	var hs := _no_h
	var last_x: int = 1 << 40
	var last_z: int = 1 << 40
	var cell := 1.0
	var gx0 := 0.0
	var gz0 := 0.0
	for i in count:
		var p: Vector3 = Vector3(x0 + float(i) * step, 0.0, z)
		if not plain:
			p = inv * p
		var bcx: int = floori(p.x / CHUNK)
		var bcz: int = floori(p.z / CHUNK)
		if bcx != last_x or bcz != last_z:
			last_x = bcx
			last_z = bcz
			hs = _no_h
			for l in MAX_LOD + 1:
				var got = _hc.get(_key(l, bcx >> l, bcz >> l))
				if got != null and (got as PackedFloat32Array).size() == APRON * APRON:
					hs = got
					var span := float(CHUNK << l)
					cell = float(1 << l)
					gx0 = float(bcx >> l) * span
					gz0 = float(bcz >> l) * span
					break
		if hs.size() != APRON * APRON:
			out[at + i] = none
			continue
		var h: float = _grid_h(hs, (p.x - gx0) / cell, (p.z - gz0) / cell)
		out[at + i] = h if plain else (xf * Vector3(p.x, h, p.z)).y

## The DRAWN ground's height at a world XZ, NAN where nothing is drawn: what the screen shows, read
## off the heights the drawn node was built from (`_drawn_h`, the occlusion test's own read).
func drawn_height(wx: float, wz: float) -> float:
	if _gen == null:
		return NAN
	var p: Vector3 = global_transform.affine_inverse() * Vector3(wx, 0.0, wz)
	var h: float = _drawn_h(p.x, p.z)
	return h if is_nan(h) else (global_transform * Vector3(p.x, h, p.z)).y

func set_grass_trample(tex: Texture2D, center: Vector2, size: float) -> void:
	if _mat is ShaderMaterial:
		var m := _mat as ShaderMaterial
		m.set_shader_parameter("trample_map", tex)
		m.set_shader_parameter("trample_center", center)
		m.set_shader_parameter("trample_size", size)
		# the shader fetches the map in its VERTEX stage only while one is handed over (glsl.gdshader)
		m.set_shader_parameter("trample_on", tex != null)

## (nodes on screen, of them level 0, jobs in the queue) — you can see what exactly is drawn.
func render_stats() -> Vector3i:
	var fine := 0
	for key in _want:
		if _key_lod(key) == 0:
			fine += 1
	return Vector3i(_want.size(), fine, pending_jobs())

# ─────────────────────────────────────────────────────────────────────────────
# Occlusion
# ─────────────────────────────────────────────────────────────────────────────
## Is the point `height` over `world_pos` behind the ground, seen from the camera? A ray from the eye
## to it, stepped over the ground: hidden once a step's ground stands `OCCL_BIAS` over the line.
## THE GROUND IS THE ONE THE FRAME DRAWS (`_drawn_h`), not the generator's: a far node samples every
## 2^L m and cuts its peaks, so the true ground hid a vein over a ridge the screen drew lower - and a
## point no near chunk holds was a generator call, ~364 us on the optimize=none build, at every step
## of every ray. That is why this test was off: "a ray over the ground cost more than drawing the
## bush behind the hill". A step over ground with no drawn heights hides nothing.
const OCCL_STEP := 8.0
const OCCL_MAX_STEPS := 28
## Hysteresis: a thing already hidden needs this much more to come back, or it blinks on the edge.
const OCCL_HYST := 0.5
var _no_h := PackedFloat32Array()      # what a point with no drawn heights reads

func is_point_hidden(world_pos: Vector3, height: float = 1.0, was_hidden: bool = false) -> bool:
	if not enable_occlusion_culling or _gen == null:
		return false
	var hid := _point_hidden(world_pos, height, was_hidden)
	return hid

func _point_hidden(world_pos: Vector3, height: float, was_hidden: bool) -> bool:
	if not is_instance_valid(_cam):
		_cam = _active_camera()
		if _cam == null:
			return false
	var inv: Transform3D = global_transform.affine_inverse()
	var eye: Vector3 = inv * _cam.global_position
	var top: Vector3 = inv * Vector3(world_pos.x, world_pos.y + maxf(height, 0.1), world_pos.z)
	var dist := eye.distance_to(top)
	if dist < OCCL_MIN_DIST:
		return false
	var steps: int = mini(int(dist / OCCL_STEP), OCCL_MAX_STEPS)
	if steps < 2:
		return false
	# An eye under the drawn ground (a camera pushed into a slope) would see every ray blocked at
	# its first step and empty the world: nothing is hidden from there.
	if _drawn_h(eye.x, eye.z) > eye.y:
		return false
	var bias: float = OCCL_BIAS + (OCCL_HYST if was_hidden else 0.0)
	# The node under the ray is looked up only when the ray leaves it: a far node spans many steps.
	var hs: PackedFloat32Array = _no_h
	var x0 := 0.0
	var z0 := 0.0
	var x1 := -1.0
	var z1 := -1.0
	var cell := 1.0
	for s in range(1, steps):
		var p: Vector3 = eye.lerp(top, float(s) / float(steps))
		if p.x < x0 or p.z < z0 or p.x >= x1 or p.z >= z1:
			var bcx: int = floori(p.x / CHUNK)
			var bcz: int = floori(p.z / CHUNK)
			var k: int = _drawn_key_at(bcx, bcz)
			var l: int = _key_lod(k) if k != -1 else 0
			hs = _hc.get(k, _no_h) if k != -1 else _no_h
			var span := float(CHUNK << l)
			x0 = float(bcx >> l) * span
			z0 = float(bcz >> l) * span
			x1 = x0 + span
			z1 = z0 + span
			cell = float(1 << l)
		if hs.size() != APRON * APRON:
			continue
		if _grid_h(hs, (p.x - x0) / cell, (p.z - z0) / cell) > p.y + bias:
			return true
	return false

## The drawn ground's height at a local point, NAN where nothing drawn has its heights.
## THE GROUND AS DRAWN at a world point (world height), NAN where nothing drawn has heights. A far
## node samples every 2^L m, so in a hollow its surface stands over the true ground by metres - what
## stands on the true ground there is drawn INSIDE the hill (enemy_vehicle's far cruise).
func drawn_height_at(world_pos: Vector3) -> float:
	var xf: Transform3D = global_transform
	var p: Vector3 = xf.affine_inverse() * world_pos
	var h: float = _drawn_h(p.x, p.z)
	if is_nan(h):
		return NAN
	return (xf * Vector3(p.x, h, p.z)).y

func _drawn_h(x: float, z: float) -> float:
	var bcx: int = floori(x / CHUNK)
	var bcz: int = floori(z / CHUNK)
	var k: int = _drawn_key_at(bcx, bcz)
	if k == -1:
		return NAN
	var hs: PackedFloat32Array = _hc.get(k, _no_h)
	if hs.size() != APRON * APRON:
		return NAN
	var l: int = _key_lod(k)
	var span := float(CHUNK << l)
	var cell := float(1 << l)
	return _grid_h(hs, (x - float(bcx >> l) * span) / cell, (z - float(bcz >> l) * span) / cell)

## Bilinear over a node's height grid (APRON², one cell of apron), at grid coordinates inside it.
func _grid_h(hs: PackedFloat32Array, fx: float, fz: float) -> float:
	var i: int = clampi(int(fx), 0, CHUNK - 1)
	var j: int = clampi(int(fz), 0, CHUNK - 1)
	var tx: float = fx - float(i)
	var tz: float = fz - float(j)
	var r0: int = (j + 1) * APRON + i + 1
	var r1: int = r0 + APRON
	return lerpf(lerpf(hs[r0], hs[r0 + 1], tx), lerpf(hs[r1], hs[r1 + 1], tx), tz)

# ─────────────────────────────────────────────────────────────────────────────
# Preview in the editor
# ─────────────────────────────────────────────────────────────────────────────
## THE SAME GROUND THE GAME WILL SHOW, in the editor's viewport (the inspector's "Build in scene",
## preview_panel.gd): the chunked ground has no height file to look at, so without it the ground and
## what its material's settings do to it could only be seen by running the game.
##
## NOTHING GETS INTO THE SCENE: nodes are born without an owner, so the .tscn does not see them, and the preview
## builds no collision at all — machines need it, not eyes.
var _preview_on: bool = false

func preview_build(seed_value: int) -> void:
	preview_clear()
	_preview_on = true
	await setup_procedural(seed_value, _preview_eye())

func preview_clear() -> void:
	_preview_on = false
	stop_generation()
	for key in _live.keys():
		var n: Dictionary = _live[key]
		if is_instance_valid(n["inst"]):
			n["inst"].queue_free()
	_live.clear()
	_cover_ep += 1
	for key in _staged.keys():
		_drop_staged(key)
	_want.clear()
	_hc.clear()
	_memo.clear()
	_clear_collision()
	terrain_is_ready = false

## Where the editor camera stands, in our coordinates. The preview is built around it, not around zero:
## the node can stand anywhere, and they always look where they look.
func _preview_eye() -> Vector3:
	var c := _active_camera()
	if c == null:
		return Vector3.ZERO
	return global_transform.affine_inverse() * c.global_position

## The editor camera is set by the plugin (_forward_3d_gui_input): the node has none of its own in the editor.
##
## NOT AN EXPORT, and never was one on purpose: a camera written into an exported field marks the
## scene changed and is saved one day - node_3d.tscn once carried a path to the EDITOR VIEWPORT's
## camera (`../../../@Node3DEditorViewport@…/@Camera3D@…`), which a running game does not have, and
## the ground was left with no camera at all.
var _ed_cam: Camera3D = null

func set_editor_camera(c: Camera3D) -> void:
	if c != null:
		_ed_cam = c

func _active_camera() -> Camera3D:
	if Engine.is_editor_hint() and is_instance_valid(_ed_cam):
		return _ed_cam
	var vp := get_viewport()
	return vp.get_camera_3d() if vp != null else null

## The clusters are counted AFTER everything that frame moved the ground (landing, holds, the LOD
## tick's covers and retirements), so no cluster is ever drawn over a change for a frame.
func _process(delta: float) -> void:
	_ground_tick(delta)
	if _gen != null:
		_hlod_tick()

func _ground_tick(delta: float) -> void:
	if _gen == null:
		return
	if Engine.is_editor_hint() and not _preview_on:
		return
	_col_tick()
	_job_tick()
	# Held meshes are looked at when something landed or the LOD tick moved the ground, four times a
	# second at most - what they wait for is other meshes landing, and a pass is ~2 ms on the
	# optimize=none build - and twice a second for the ones waiting out their hold.
	_held_check_t -= delta
	if not _staged.is_empty() and _held_check_t <= 0.0 and (_held_dirty or _held_check_t <= -0.25):
		_held_check_t = 0.25
		_release_held()
	_lod_timer += delta
	var cam := _active_camera()
	if cam == null:
		return
	# THE CHOICE IS RECOMPUTED ON MOVEMENT, NOT ONLY ON THE TIMER. At speed in 0.15 s the camera
	# travels several metres and turns — a node that rode into the frame waited for the next tick
	# and all that time it simply was not there.
	var fwd: Vector3 = -cam.global_transform.basis.z
	var stirred: bool = cam.global_position.distance_squared_to(_sel_pos) > SEL_MOVE2 \
			or fwd.dot(_sel_fwd) < SEL_TURN_COS
	# NOTHING MOVED AND NOTHING LANDED SINCE THE LAST TICK: the same frame, the same leaves, the same
	# built set - what is left to do is the grace count, which a second can wait for.
	var idle: bool = not stirred and _cover_ep == _tick_ep and _jobs.is_empty() and not _stitch_more
	if _lod_timer < (LOD_INTERVAL * 0.25 if stirred else (LOD_IDLE if idle else LOD_INTERVAL)):
		return
	_lod_timer = 0.0
	_sel_pos = cam.global_position
	_sel_fwd = fwd
	_cam = cam
	var cam_local: Vector3 = global_transform.affine_inverse() * _cam.global_position
	_sel_local = cam_local
	_select(cam_local)
	var now: float = float(Time.get_ticks_msec()) * 0.001
	var split_seen := {}
	for key in _want:
		var n = _live.get(key)
		if n == null:
			if _staged.has(key):
				continue                   # built, waiting for the rest of its level change
			var l := _key_lod(key)
			var gx := _key_gx(key)
			var gz := _key_gz(key)
			if not _queued_fresh(key):
				_enqueue_mesh(l, gx, gz, _signature(l, gx, gz))
			var anc := _drawn_ancestor(l, gx, gz)
			if anc != -1 and not _leaf_set.has(anc) and not split_seen.has(anc):
				split_seen[anc] = true
				_enqueue_under(_key_lod(anc), _key_gx(anc), _key_gz(anc))
			continue
		n["seen"] = now
		n["inst"].visible = true
		n["cov"] = false
	# The neighbour changed level — the edge has to be pulled in again. A per-tick budget: a seam for a frame or two
	# is cheaper than rebuilding dozens of nodes at once. A NODE IS LOOKED AT ONCE PER SET OF LEAVES ("gen"),
	# when the frame wants it: a signature changes only when the leaves do, and computing one for
	# every node in the frame every tick is eight probes of six lookups a node. Scanning every built
	# leaf, off the screen too, was tried - three times the signatures, and the cracks while turning
	# came out the same (measured).
	var left: int = STITCH_BUDGET
	var checks: int = STITCH_CHECKS
	_stitch_more = false
	for key in _want:
		if left <= 0 or checks <= 0:
			_stitch_more = true
			break
		var n = _live.get(key)
		if n == null or int(n.get("gen", -1)) == _leaf_gen:
			continue
		checks -= 1
		var sig := _signature(n["lod"], n["gx"], n["gz"])
		n["gen"] = _leaf_gen
		if sig == int(n["sig"]):
			continue
		var st = _staged.get(key)
		if st != null and int(st["sig"]) == sig:
			continue                       # already built, waiting to go up
		var q = _queued.get(key)
		if q is Dictionary:                # already queued: no budget spent on asking again
			if not q.get("started", false):
				q["sig"] = sig
			continue
		_enqueue_mesh(n["lod"], n["gx"], n["gz"], sig)
		left -= 1
	_retire(now)
	_held_dirty = true
	_hlod_dirty = true
	_tick_ep = _cover_ep

## WHAT HAS LEFT THE FRAME IS HIDDEN, NOT THROWN OUT. Turning the camera changes half the visible set, and
## freeing meshes at once means rebuilding the same hundred nodes a second later — the terrace
## behind your back would appear in pieces. A mesh lives NODE_GRACE seconds after it stops being
## needed, and is thrown out earlier only when more than LIVE_CAP of them have accumulated.
const NODE_GRACE := 15.0
const LIVE_CAP := 420
## How far the camera must move (metres squared) or turn to recompute the choice
## before the timer. Four metres and a couple of degrees: less, and the recompute runs every frame for nothing.
## This threshold sets the TICK RATE and nothing more; rebuilding the tree is held by its own, much
## larger LEAF_MOVE2 — a tick on a turn costs one flat pass over the leaf cache.
## Closer than CAM_AT_START the camera is considered to stand at the same point as the first ground's build.
const CAM_AT_START := 32.0
const SEL_MOVE2 := 16.0
const SEL_TURN_COS := 0.999
var _sel_pos: Vector3 = Vector3(1e9, 1e9, 1e9)
## The same thing, but IN THE NODE'S AXES: nodes live in them, and _sel_pos is world — it measures the camera's shift.
var _sel_local: Vector3 = Vector3(1e9, 1e9, 1e9)
var _sel_fwd: Vector3 = Vector3.FORWARD

## WHETHER OTHER GROUND ALREADY COVERS THIS PLACE. A level change is not "the node left" but "the node was replaced":
## four fine ones stand in place of one coarse one or the other way round. But the replacement is still ONLY IN THE QUEUE, and
## the old one was put out the same tick — for a second or two a hole opened where it stood. That is exactly
## what looks like "chunks disappear while you drive".
func _covered(key: int) -> bool:
	var l := _key_lod(key)
	var gx := _key_gx(key)
	var gz := _key_gz(key)
	# Covered only by ground the LEAF SET asks for and that is already BUILT. Asked for, because a
	# live node that is itself hidden covers nothing - by it a whole chain would hide. The leaf set,
	# not the frame: a split builds all its children (_enqueue_under), the ones off the screen too,
	# and a built leaf is drawn whether or not it is in the frame.
	# ANY ANCESTOR AND ANY DEPTH BELOW, not only the parent and the four children: a node replaced
	# by leaves two levels finer (a fast drive, a respawn, the sub-pixel rule) was "not covered",
	# stayed drawn over the fine ground - another shape and colour, no collision under it - and near
	# the player nothing is ever dropped, so it stood there until the player drove away (the
	# player's "two maps with different seeds, only one with physics").
	var al := l + 1
	var ax := gx >> 1
	var az := gz >> 1
	while al <= MAX_LOD:
		var ak := _key(al, ax, az)
		if _leaf_set.has(ak):
			return _live.has(ak)                 # became coarser: an ancestor covers it
		al += 1
		ax >>= 1
		az >>= 1
	return l > 0 and _covered_below(l, gx, gz)

## Every leaf under (lod, gx, gz) is in the leaf set and built (the node itself not counted).
func _covered_below(lod: int, gx: int, gz: int) -> bool:
	if lod <= 0:
		return false
	for dz in 2:
		for dx in 2:
			var cl := lod - 1
			var cx := gx * 2 + dx
			var cz := gz * 2 + dz
			var ck := _key(cl, cx, cz)
			if _leaf_set.has(ck):
				if not _live.has(ck):
					return false
			elif not _covered_below(cl, cx, cz):
				return false
	return true

## WHETHER A NODE IS COVERED CHANGES ONLY WITH THE LEAF SET OR THE BUILT SET, so it is kept on the
## node by `_cover_ep`, bumped at every door that changes either (`_build_leaves`, a node placed or
## dropped). Asked afresh every tick it was ~4 of the tick's ~7 ms on the optimize=none build, for
## ~150 nodes out of the frame, and in a fight the tick runs every few frames (the player: "terrain
## lod up to 30 ms in fights").
var _cover_ep: int = 0
## The frame's set at the tick before (`_select` hands it over): a node in it and not in `_want` has
## just left the frame. THE WHOLE BUILT SET IS WALKED ONLY WHEN SOMETHING CAN HAVE CHANGED - the
## cover epoch moved, the cap is passed, or RETIRE_EVERY went by for the grace count; otherwise only
## the nodes that just left the frame are looked at. The walk itself was ~2 ms a tick for ~250
## nodes on the optimize=none build, every tick, with nothing to do.
var _prev_want: Dictionary = {}
var _retire_ep: int = -1
var _retire_at: float = -1e9
const RETIRE_EVERY := 1.0

func _retire(now: float) -> void:
	var over: int = _live.size() - _live_cap()
	var keys: Array
	if over > 0 or _retire_ep != _cover_ep or now - _retire_at >= RETIRE_EVERY:
		_retire_ep = _cover_ep
		_retire_at = now
		keys = _live.keys()
	else:
		for key in _prev_want:
			if not _want.has(key) and _live.has(key):
				keys.append(key)
	for key in keys:
		if _want.has(key):
			continue
		var n: Dictionary = _live[key]
		if not is_instance_valid(n["inst"]):
			_live.erase(key)
			_cover_ep += 1
			continue
		# Not covered — we leave it visible. Off screen the engine culls it anyway, but there will be no holes
		# where a node stands whose replacement is still being computed.
		if int(n.get("cov_ep", -1)) != _cover_ep:
			n["cov_ep"] = _cover_ep
			n["cov_v"] = _covered(key)
		if n["cov_v"]:
			n["inst"].visible = false
			n["cov"] = true
		if over <= 0 and now - float(n["seen"]) < NODE_GRACE:
			continue
		if _near_player(key):
			continue                   # the near circle is dropped neither by time nor by the ceiling
		n["inst"].queue_free()
		_live.erase(key)
		_cover_ep += 1
		over -= 1
