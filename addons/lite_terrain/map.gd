# map.gd — the LiteTerrain terrain node: StaticBody3D + HeightMapShape3D collision + ArrayMesh,
# with quadtree LOD, streaming collision, and a grass shader. The LiteTerrain plugin assembles it
# with one button and can generate/sculpt/bake. class_name so it can be used as a type.
@tool
@icon("res://addons/lite_terrain/icon.png")
class_name LiteTerrain
extends StaticBody3D

## Camera used for LOD and culling. CAN BE LEFT EMPTY: by default the current active
## camera is used (get_viewport().get_camera_3d()) and the terrain follows it even across
## camera switches. Set it manually only if LOD must be computed from a DIFFERENT, non-active camera.
@export var camera: Camera3D

# Effective camera for this frame: the manual one (if set and alive) or the current active one.
# Refreshed every frame in _process, so nothing needs to be assigned.
var _cam: Camera3D = null

## Surface material. Defaults to the addon's terrain shader (zone colors + grass) so a
## freshly created node looks right immediately. You can plug in your own ShaderMaterial.
##
## APPEARANCE (tile texture, texture_blend, tile_world_size, zone colors, grass, low_quality)
## is configured DIRECTLY ON THE MATERIAL, in its Shader Parameters — it is not duplicated in the
## node's inspector. The defaults live in the shader itself (glsl.gdshader) and in this material.
@export var surface_material: Material = preload("res://addons/lite_terrain/terrain_shader.res")

# Hide inspector settings for features that are switched off (cleaner UX).
func _validate_property(property: Dictionary) -> void:
	# heightmap_path is only needed in image mode.
	if property.name == "heightmap_path" and not use_image_data:
		property.usage = PROPERTY_USAGE_NO_EDITOR
@export_range(-0.5, 0.5, 0.01) var frustum_margin: float = -0.05
@export var enable_frustum_culling: bool = true
## Macro groups whose XZ centre is farther than this from the camera are simply hidden,
## skipping the (more expensive) per-macro frustum AABB test. Set roughly to the fog/visibility
## distance — anything past it isn't visible anyway, so the frustum test would be wasted work.
## How far terrain is drawn. KEEP THIS ≈ the fog distance: with fog_density 0.002 the
## terrain is ~fully fogged by ~1500 m, so anything past that is rendered but invisible —
## pure waste that tanked FPS when looking toward the horizon. Raise it only if you also
## thin the fog (and accept the FPS cost of drawing more distant terrain).
@export var max_render_distance: float = 1400.0

# ── Occlusion culling settings ────────────────────────────────────────────────
## Hide chunks whose AABB top sits below the terrain horizon seen from the camera.
## Uses the elevation-angle (horizon) method: samples the heightmap along the
## XZ ray from the camera to each chunk and tracks the maximum terrain angle.
## If the terrain horizon exceeds the angle to the chunk top, the chunk is occluded.
@export var enable_occlusion_culling: bool = false
## XZ distance (world units) below which chunks are never occlusion-culled.
## NOTE: the horizon method false-culls on a steep top-down camera (black holes in the
## terrain), so occlusion is OFF by default — these knobs only matter if you re-enable it.
@export_range(0.0, 200.0, 1.0) var occlusion_min_dist: float = 40.0
## Added to the chunk AABB top before the horizon test (higher = more conservative).
@export_range(0.0, 10.0, 0.5) var occlusion_bias: float = 1.5
## Heightmap samples taken along each camera→chunk ray. More = fewer misses, more CPU.
@export_range(2, 24, 1) var occlusion_samples: int = 8

@export var chunk_size: int = 16

# ── LOD settings ─────────────────────────────────────────────────────────────
# Toggle LOD on/off without changing distances
@export var enable_lod: bool = true

# XZ distance thresholds (in world units) at which LOD switches:
#   dist < lod_distance_0  →  LOD 0  (step=1, full res, 512 tris/chunk)
#   dist < lod_distance_1  →  LOD 1  (step=2, ¼ tris, ~128/chunk)
#   dist < lod_distance_2  →  LOD 2  (step=4, 1/16 tris, ~32/chunk)
#   dist ≥ lod_distance_2  →  LOD 3  (step=8, 1/64 tris, ~8/chunk)
@export var lod_distance_0: float = 40.0
@export var lod_distance_1: float = 80.0
@export var lod_distance_2: float = 160.0

# Vertex sampling step per LOD level (index = LOD level)
const LOD_STEPS: Array[int] = [1, 2, 4]   # LOD3 (step 8) dropped — never shown at runtime
const LOD_COUNT: int        = 3

# How often (seconds) the LOD check runs — no need every frame
const LOD_UPDATE_INTERVAL: float = 0.15

# ── Editor view settings ──────────────────────────────────────────────────────
## OFF (default): the editor bakes ONE full-resolution merged mesh for the whole map
## (current behaviour — fine for small maps, heavy for huge ones).
## ON: the editor builds the WHOLE map but with LOD — distant chunks low-poly, near
## chunks full-res — using the same lod_distance_* thresholds as the game. The merged
## mesh is only rebuilt after the editor camera STOPS moving (no per-move lag), and on
## sculpt. Seams are snapped just like at runtime, so no LOD cracks.
@export var editor_lod: bool = false

# ── Streaming settings ────────────────────────────────────────────────────────
## How many chunks are meshed per streaming batch. Lower = fewer frame hitches.
@export_range(4, 128, 4) var stream_batch_size: int = 8

# ── Macro-chunk settings ──────────────────────────────────────────────────────
# Groups of MACRO_SIZE×MACRO_SIZE individual chunks are merged into one
# MeshInstance3D (shadows OFF) for dist ≥ lod_distance_1.
# 4×4 = 16 chunks → 1 draw call instead of 16 (+ saves ~16 shadow passes).
const MACRO_SIZE: int = 4

# ── Heightmap data source ─────────────────────────────────────────────────────
## Master heightmap (R32F Image saved as .res), the single source of truth for both
## the visual chunks and the streaming collision. Bake it from the editor terrain via
## the plugin's "Bake heightmap → image" button. If missing, falls back at runtime to
## the embedded CollisionShape3D HeightMapShape3D data (so nothing breaks pre-bake).
@export_file("*.res", "*.exr", "*.png") var heightmap_path: String = "res://addons/lite_terrain/terrain_height.res"

## Master decoupling switch. ON = the R32F image is the ONLY heightmap source, in the
## editor AND at runtime; the giant HeightMapShape3D is never used for data, the editor
## sculpts by ray-marching the heightmap (no physics needed), and runtime always uses
## the streaming collision window. This is what lets the map grow huge — detach the big
## terrain.res/terrain_mesh.res from the scene (plugin button) and nothing heavy loads.
## OFF (default) = previous behaviour (embedded shape is data + collision).
@export var use_image_data: bool = true:
	set(v):
		use_image_data = v
		notify_property_list_changed()   # hides/shows heightmap_path

# ── Streaming collision settings ──────────────────────────────────────────────
## Master switch. OFF (default) = current behaviour: the embedded HeightMapShape3D is
## both the data and the collision (whole map). ON = data comes from the R32F image and
## collision becomes a small window that follows the player — required for huge maps.
## NOTE while ON: only terrain inside the window has collision, so bodies far from the
## active vehicle (other parked vehicles, spread-out objects) sit on no ground. Size the
## window to cover your play area, or keep OFF until the map is genuinely large.
@export var enable_streaming_collision: bool = true
## Collision follows every MOVING physics body in the scene (RigidBody3D, VehicleBody3D,
## CharacterBody3D) automatically — no node paths to set up, works with any project. Each
## tracked body gets its own sliding HeightMapShape3D window; bodies that ride ON another
## body (e.g. parts welded to a vehicle) are skipped, the parent's window covers them.
## Bodies are discovered via node_added/node_removed signals — no per-frame polling.
##
## Collision is a GRID of tiled HeightMapShape3D cells. A body marks every cell within
## collision_radius as needed; bodies sharing a cell share its window.
@export_range(16, 256, 8) var collision_cell:   int = 16   # heightmap cells per collision tile
@export_range(4, 256, 4)  var collision_radius: int = 8    # cells covered around each tracked body
## Each tile is grown by this many cells on every side so neighbouring tiles OVERLAP.
## Jolt only smooths ("deactivates") the internal edges of a SINGLE heightfield — the
## boundary edge between two separate tiles stays live and a wheel snags on it when crossing.
## Overlapping the tiles buries each tile's boundary edge under the neighbour's coincident
## (same-height) surface, so the wheel always rolls on continuous ground. 0 = old behaviour.
@export_range(0, 32, 1) var collision_overlap:  int = 8

# Child nodes are NO LONGER required in the scene — the node creates them itself (see _ensure_children),
# so a LiteTerrain can be added as a single node, with no manual CollisionShape3D +
# MeshInstance3D assembly. If they already exist in the scene, the existing ones are used.
var collision: CollisionShape3D = null
var mesh_instance: MeshInstance3D = null

# Guarantees the CollisionShape3D and MeshInstance3D exist. Creates them as INTERNAL
# (INTERNAL_MODE_BACK): they are not shown in the scene tree, not saved into the .tscn, and
# are managed by the node itself — so LiteTerrain stays one clean node. get_node still
# finds them by name, so calling this again does not create duplicates.
func _ensure_children() -> void:
	collision = get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision == null:
		collision = CollisionShape3D.new()
		collision.name = "CollisionShape3D"
		add_child(collision, false, Node.INTERNAL_MODE_BACK)
	mesh_instance = get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh_instance == null:
		mesh_instance = MeshInstance3D.new()
		mesh_instance.name = "MeshInstance3D"
		add_child(mesh_instance, false, Node.INTERNAL_MODE_BACK)

# ── Runtime chunk state ───────────────────────────────────────────────────────
var _chunk_instances: Array[MeshInstance3D] = []
var _chunk_aabbs:    Array[AABB]           = []

# _chunk_meshes[i][lod] → ArrayMesh (or null for degenerate chunks)
# Pre-built for all 4 LOD levels at startup; no runtime rebuild needed.
var _chunk_meshes:   Array = []

# Current LOD level that is actually displayed for each chunk
var _chunk_lod:      Array[int] = []

# Per-chunk "stitch signature": encodes the chunk's LOD step plus the snap step
# on each of its 4 borders (see _stitch_signature). the quadtree LOD pass (_qt_apply) rebuilds a chunk
# whenever its current required signature differs from the one last applied, which
# makes seam stitching self-healing regardless of event order (LOD change, neighbour
# LOD change, macro toggle, streamed-in chunk). 0 = no mesh applied yet.
var _chunk_stitch_sig: Array[int] = []

var _chunks_x:      int = 0
var _lod_timer:     float = 0.0

# ── Streaming collision runtime state ─────────────────────────────────────────
var _col_active: bool       = false
var _col_bodies: Array      = []   # [{body:Node3D}]  every moving body we give ground to
var _col_cells:  Dictionary = {}   # cell_key -> CollisionShape3D (one tile per active cell)

# ── Occlusion culling runtime state ──────────────────────────────────────────
const OCCLUSION_UPDATE_INTERVAL: float = 0.20   # seconds between full occlusion passes
var _occlusion_timer: float = 0.0
var _occluded_chunks: Dictionary = {}           # ci → true  (passed frustum, failed occlusion)
var _occluded_macros: Dictionary = {}
var _occluded_nodes:  Dictionary = {}           # node → true (far coarse quadtree mesh, occluded)


# ── Streaming runtime state ───────────────────────────────────────────────────
# Chunks not built at startup are queued here and built in background (on demand).
var _stream_queue:    Array[int] = []   # chunk indices not yet meshed, sorted by dist
var _stream_batch:    Array[int] = []   # indices being processed in the current batch
var _stream_results:  Array      = []   # [ci] = [lod_meshes, aabb] | null (worker output)
var _stream_group_id: int        = -1
var _is_streaming:    bool       = false

# ── Macro-chunk runtime state ─────────────────────────────────────────────────
# _macro_instances[mi]  → one MeshInstance3D per MACRO_SIZE×MACRO_SIZE group
# _macro_aabbs[mi]      → merged AABB of all sub-chunks (for frustum culling)
# _macro_to_chunks[mi]  → Array[int] of individual chunk indices in the group
# _chunk_macro_idx[ci]  → which macro group this individual chunk belongs to
# _macro_active[mi]     → true while the macro instance is actively rendering
var _macro_instances:  Array[MeshInstance3D] = []
var _macro_aabbs:      Array[AABB]           = []
var _macro_to_chunks:  Array                 = []
var _chunk_macro_idx:  Array[int]            = []
var _macro_active:     Array[bool]           = []

# ── Quadtree (runtime frustum + LOD selection) ────────────────────────────────
# Spatial hierarchy over the MACRO grid: each leaf = one macro group (4×4 chunks);
# internal nodes merge their children's AABBs up to a single root. Selection descends
# from the root every frame — any subtree fully outside the frustum, or entirely beyond
# max_render_distance, is pruned WITHOUT being visited. So per-frame cull/LOD cost scales
# with the visible area, not the map size (the far 3/4 of a huge map is never iterated),
# and because the selection is recomputed statelessly from the root it is instantly
# correct after a camera teleport (no temporal-coherence frontier to repair).
#   far leaf  → rendered as its merged macro mesh (1 draw call)
#   near leaf → expanded into its individual chunks at per-chunk LOD 0/1
var _qt_aabb:  Array[AABB] = []   # node → local-space merged AABB
var _qt_child: Array       = []   # node → Array[int] child node ids ([] = leaf)
var _qt_macro: Array[int]  = []   # leaf → macro index; internal node → -1
var _qt_built: bool        = false
# Each INTERNAL node also carries one coarse merged mesh (its whole footprint sampled at a
# step that grows with the node's size — ~constant triangle budget per node, with a skirt).
# The descend renders the COARSEST node whose on-screen error is acceptable, so distant
# terrain collapses into a few big low-poly meshes: you can see to the horizon (mountains)
# for a handful of draw calls instead of thousands of macros. Leaves keep using the macro
# meshes / individual chunks (fine near detail, grass, collision-matching).
var _qt_rect:  Array        = []   # node → Vector4i(x0, z0, x1, z1) cell rect
var _qt_step:  Array[int]   = []   # node → sample step of its coarse mesh
var _qt_size:  Array[float] = []   # node → max world XZ extent (LOD-selection metric)
var _qt_inst:  Array        = []   # node → MeshInstance3D (internal nodes only; null for leaves)
var _qt_node_results: Array = []   # threaded coarse-mesh build scratch
const QT_QUALITY: float = 1.1      # render a node coarsely once dist ≥ size * this (lower = coarser/faster)
const QT_SKIRT:   float = 0.0      # skirts removed (they were visible hanging at the edges of LOD nodes)
# Currently-rendered selection, kept for cheap show/hide diffing each frame.
var _qt_cur_macros: Dictionary = {}   # mi → true (macro mesh currently visible)
var _qt_cur_chunks: Dictionary = {}   # ci → lod  (chunk currently rendered individually)
var _qt_cur_nodes:  Dictionary = {}   # node → true (coarse internal mesh currently visible)
# Per-frame scratch sets (members so they aren't reallocated every frame).
var _qt_des_macros: Dictionary = {}
var _qt_des_chunks: Dictionary = {}
var _qt_des_nodes:  Dictionary = {}

# ── Chunk residency (memory cap for big maps) ─────────────────────────────────
# Individual chunk nodes/meshes are instantiated ONLY for macro groups near the camera.
# Far terrain is drawn by the always-resident macro meshes (built once, directly from the
# heightmap — no per-chunk dependency). This bounds resident memory to the play area
# instead of instantiating every chunk of the whole map at once — which is what blew the
# node/object/memory counters up and crashed on load. Chunks stream in on demand when the
# camera approaches a macro and are freed (evicted) when it leaves.
var _resident_set:  Dictionary = {}   # mi → true : this macro's chunks are instantiated
var _queued_chunks: Dictionary = {}   # ci → true : queued for (re)build (dedups enqueues)
var _macro_results: Array      = []   # [mi] → ArrayMesh : threaded macro-mesh build scratch
const QT_EVICT_MARGIN: float = 96.0   # free a macro's chunks only this far beyond the expand ring

# ── Editor chunk cache ────────────────────────────────────────────────────────
# The editor uses a single MeshInstance3D with one surface per chunk.
# Editor always renders LOD 0 (full resolution) for accurate sculpting.
var _ed_cache: Array = []
var _ed_cx:    int   = 0
var _ed_cz:    int   = 0
var _ed_lod:   Array[int] = []                 # per-chunk LOD level (editor)
# Editor camera (fed by plugin.gd) + camera-settle tracking for lag-free LOD rebuilds.
var _editor_cam:        Camera3D = null
var _editor_track_pos:  Vector3  = Vector3(INF, INF, INF)
var _editor_build_pos:  Vector3  = Vector3(INF, INF, INF)
var _editor_settle_t:   float    = 0.0

# ── LOD material cache ────────────────────────────────────────────────────────
# Two static material variants replace per-instance shader parameters.
# set_instance_shader_parameter() allocates a slot in the global_shader_variables
# buffer (GLES3 limit: 4096). With hundreds of chunks this overflows instantly.
# Swapping materials uses zero buffer slots and costs nothing at runtime.
var _mat_lod0:     Material = null  # lod_grass_enabled = 1.0  (LOD 0, close)
var _mat_lod_high: Material = null  # lod_grass_enabled = 0.0  (LOD 1+, distant)

# ── Heightmap (the data the whole system reads) ───────────────────────────────
# Filled by _load_heightmap() in _ready(): from the R32F image at runtime, or from
# the embedded HeightMapShape3D (editor, or as a pre-bake fallback at runtime).
var w:  int                = 0
var d:  int                = 0
var md: PackedFloat32Array = PackedFloat32Array()

# ─────────────────────────────────────────────────────────────────────────────
# Ready
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_ensure_children()
	if Engine.is_editor_hint():
		if use_image_data and _load_heightmap_image() != null:
			# Image mode: the R32F terrain_height.res is the source of truth. The internal MeshInstance3D
			# is not saved into the scene, so if there is no preview mesh yet, build it from the
			# heightmap. If a mesh is already set (old scenes with an external terrain_mesh.res), leave it
			# alone so a big mesh doesn't get embedded into the .tscn.
			_load_heightmap()
			if mesh_instance.mesh == null:
				_rebuild_editor_full()
			return
		if collision.shape is HeightMapShape3D:
			w  = collision.shape.map_width      # legacy: data from the embedded shape
			d  = collision.shape.map_depth
			md = collision.shape.map_data
			_recompute_height_bound()
		update()
		return
	mesh_instance.visible = false
	await get_tree().process_frame
	_cam = _active_camera()
	if use_image_data or enable_streaming_collision:
		_load_heightmap()                   # data from the R32F image (fallback: shape)
		_setup_streaming_collision()        # small sliding collision window
	else:
		# Legacy: the embedded HeightMapShape3D is both data and collision.
		if collision.shape is HeightMapShape3D:
			w  = collision.shape.map_width
			d  = collision.shape.map_depth
			md = collision.shape.map_data
		else:
			push_error("LiteTerrain: legacy mode needs a HeightMapShape3D on CollisionShape3D. Turn on use_image_data (default) or generate/bake terrain from the LiteTerrain dock.")
			return
	_chunks_x = ceili(float(w - 1) / chunk_size)
	await _build_chunks_from_map_data()
	if _cam:
		_full_scan()


# ─────────────────────────────────────────────────────────────────────────────
# Heightmap loading + streaming collision
# ─────────────────────────────────────────────────────────────────────────────

# Loads the master heightmap into w / d / md. Prefers the R32F image (scales to huge
# maps); falls back to the embedded HeightMapShape3D so the game still runs pre-bake.
func _load_heightmap() -> void:
	var img := _load_heightmap_image()
	if img != null:
		w  = img.get_width()
		d  = img.get_height()
		if img.get_format() != Image.FORMAT_RF:
			img.convert(Image.FORMAT_RF)
		md = img.get_data().to_float32_array()
		_recompute_height_bound()
		return
	# Fallback: read the heights out of the still-attached HeightMapShape3D.
	push_warning("map.gd: heightmap image not found at '%s' — using embedded CollisionShape3D data. Run 'Bake heightmap → image' in the LiteTerrain dock for big-map streaming." % heightmap_path)
	if collision.shape is HeightMapShape3D:
		w  = collision.shape.map_width
		d  = collision.shape.map_depth
		md = collision.shape.map_data
		_recompute_height_bound()

func _load_heightmap_image() -> Image:
	if heightmap_path.is_empty() or not ResourceLoader.exists(heightmap_path):
		return null
	var res = load(heightmap_path)
	if res is Image:
		return res as Image
	if res is Texture2D:
		return (res as Texture2D).get_image()
	return null

# ── Streaming collision (grid of tiled HeightMapShape3D cells) ─────────────────
# Each tracked body marks the grid cells within its radius as "needed"; one small
# HeightMapShape3D is created per needed cell. Cells TILE (no overlap → no doubled
# collision and no catchy edges inside the driving area), and bodies that share a cell
# share its window. Bodies are discovered via node_added/node_removed signals.
func _setup_streaming_collision() -> void:
	if md.is_empty() or w <= 0 or d <= 0:
		return
	collision.disabled = true            # the scene's CollisionShape3D is unused at runtime
	_clear_collision_cells()
	_col_bodies.clear()
	_col_active = true
	var scene_root := get_tree().current_scene
	if scene_root != null:
		# Track every moving body (RigidBody3D/VehicleBody3D/CharacterBody3D); _register_body filters.
		for n in scene_root.find_children("*", "PhysicsBody3D", true, false):
			_register_body(n)
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)
		get_tree().node_removed.connect(_on_node_removed)
	_update_collision_cells()

# A moving body worth giving ground collision to (excludes StaticBody3D, Area3D, etc.).
# VehicleBody3D is a RigidBody3D subclass, so it is covered by the RigidBody3D check.
func _is_trackable_body(n: Node) -> bool:
	return n is RigidBody3D or n is CharacterBody3D

# Highest trackable body in n's ancestor chain, or n itself if none above it. Used to skip
# sub-bodies (e.g. a part welded onto a vehicle) — the top body's window already covers them.
func _top_body(n: Node) -> Node:
	var top: Node = n
	var p := n.get_parent()
	while p != null:
		if _is_trackable_body(p):
			top = p
		p = p.get_parent()
	return top

func _register_body(n: Node) -> void:
	if not _col_active or not is_instance_valid(n):
		return
	if not _is_trackable_body(n):
		return
	if is_ancestor_of(n):
		return                            # our own collision shapes etc.
	if _top_body(n) != n:
		return                            # a sub-body — the top body's window already covers it
	for b in _col_bodies:
		if b["body"] == n:
			return                        # already tracked
	_col_bodies.append({"body": n})

func _unregister_body(n: Node) -> void:
	var kept := []
	for b in _col_bodies:
		if b["body"] != n:
			kept.append(b)
	_col_bodies = kept

func _on_node_added(n: Node) -> void:
	if _is_trackable_body(n):
		call_deferred("_register_body", n)   # defer so parent/position are settled

func _on_node_removed(n: Node) -> void:
	if _is_trackable_body(n):
		_unregister_body(n)

func _clear_collision_cells() -> void:
	for key in _col_cells:
		if is_instance_valid(_col_cells[key]):
			_col_cells[key].queue_free()
	_col_cells.clear()

# Recompute the set of grid cells needed (union of all bodies' footprints) and create /
# free cell tiles to match. Diff-only, so static bodies cause zero churn.
func _update_collision_cells() -> void:
	if not _col_active or md.is_empty() or collision_cell <= 0:
		return
	var cells_x := (w + collision_cell - 1) / collision_cell
	var cells_z := (d + collision_cell - 1) / collision_cell
	var desired := {}
	var dead := false
	for b in _col_bodies:
		var body: Node3D = b["body"]
		if body == null or not is_instance_valid(body):
			dead = true
			continue
		var r: int = collision_radius
		var local := global_transform.affine_inverse() * body.global_position
		var bx := int(round(local.x + float(w) * 0.5 - 0.5))
		var bz := int(round(local.z + float(d) * 0.5 - 0.5))
		var cx0 := clampi((bx - r) / collision_cell, 0, cells_x - 1)
		var cx1 := clampi((bx + r) / collision_cell, 0, cells_x - 1)
		var cz0 := clampi((bz - r) / collision_cell, 0, cells_z - 1)
		var cz1 := clampi((bz + r) / collision_cell, 0, cells_z - 1)
		for cz in range(cz0, cz1 + 1):
			for cx in range(cx0, cx1 + 1):
				desired[cz * cells_x + cx] = true
	for key in desired:
		if not _col_cells.has(key):
			_make_cell_tile(key, cells_x)
	for key in _col_cells.keys():
		if not desired.has(key):
			if is_instance_valid(_col_cells[key]):
				_col_cells[key].queue_free()
			_col_cells.erase(key)
	if dead:
		_prune_dead_bodies()

func _prune_dead_bodies() -> void:
	var kept := []
	for b in _col_bodies:
		if b["body"] != null and is_instance_valid(b["body"]):
			kept.append(b)
	_col_bodies = kept

func _make_cell_tile(key: int, cells_x: int) -> void:
	var cx := key % cells_x
	var cz := key / cells_x
	# This tile OWNS cells [ox, ox+collision_cell] but its shape is grown by collision_overlap
	# on every side (clamped to the map) so it overlaps its neighbours — see collision_overlap.
	# +1 already shares the boundary row with neighbours; the extra overlap buries the live
	# tile-edge Jolt would otherwise snag a wheel on.
	var ox := cx * collision_cell
	var oz := cz * collision_cell
	var sx0 := maxi(ox - collision_overlap, 0)
	var sz0 := maxi(oz - collision_overlap, 0)
	var sx1 := mini(ox + collision_cell + collision_overlap, w - 1)
	var sz1 := mini(oz + collision_cell + collision_overlap, d - 1)
	var W := sx1 - sx0 + 1
	var H := sz1 - sz0 + 1
	if W < 2 or H < 2:
		return
	var data := PackedFloat32Array()
	data.resize(W * H)
	for j in H:
		var srow := (sz0 + j) * w + sx0
		var drow := j * W
		for i in W:
			data[drow + i] = md[srow + i]
	var shape := HeightMapShape3D.new()
	shape.map_width  = W
	shape.map_depth  = H
	shape.map_data   = data
	var cs := CollisionShape3D.new()
	cs.shape = shape
	# position so the shape's cell (i,j) lands on the visual master cell (sx0+i, sz0+j).
	cs.position = Vector3(sx0 + float(W - w) * 0.5, 0.0, sz0 + float(H - d) * 0.5)
	add_child(cs)
	_col_cells[key] = cs


# ─────────────────────────────────────────────────────────────────────────────
# Public API  (called by plugin.gd)
# ─────────────────────────────────────────────────────────────────────────────

# Full rebuild — call after noise generation or on first open.
func update() -> void:
	if not is_node_ready() or collision == null or mesh_instance == null:
		return
	# Editor only: the plugin edits the HeightMapShape3D via undo/redo, so re-read it.
	# At runtime md comes from the R32F image and collision.shape is the small streaming
	# window — never overwrite md from it here.
	if Engine.is_editor_hint() and not use_image_data and collision.shape is HeightMapShape3D:
		w  = collision.shape.map_width
		d  = collision.shape.map_depth
		md = collision.shape.map_data
	if md.size() == 0:
		return
	if Engine.is_editor_hint():
		_rebuild_editor_full()

# Sets the whole heightmap and rebuilds. Used by the plugin's undo/redo for terrain
# generation: routing both the do and the undo through this NODE method keeps the
# action in a single EditorUndoRedoManager history, avoiding the "history mismatch"
# you get when one action touches both the scene node and the heightmap resource.
func apply_heightmap(data: PackedFloat32Array) -> void:
	if use_image_data:
		md = data                          # image mode: md is the source of truth
		_recompute_height_bound()
		if not Engine.is_editor_hint() and _col_active:
			_clear_collision_cells()       # heights changed → rebuild tiles from fresh md
			_update_collision_cells()
		update()
		return
	if collision != null and collision.shape is HeightMapShape3D:
		collision.shape.map_data = data
	update()


# ── Image-data heightmap API (editor sculpt without a physics shape) ───────────

func is_image_mode() -> bool:
	return use_image_data and not md.is_empty()

func get_heights() -> PackedFloat32Array:
	return md

func get_dims() -> Vector2i:
	return Vector2i(w, d)

# World-space terrain height under world_pos. Use it to place vehicles/objects ON the
# ground (e.g. body.global_position.y = map.terrain_height_at(body.global_position) + clearance)
# instead of spawning them in the air and letting them drop.
func terrain_height_at(world_pos: Vector3) -> float:
	if md.is_empty() or w <= 0:
		return 0.0
	var local := global_transform.affine_inverse() * world_pos
	var lh := _sample_height_local(local.x, local.z)
	return (global_transform * Vector3(local.x, lh, local.z)).y

# Replaces the whole heightmap AND its dimensions (used by 'generate' to make a bigger
# map). Editor-side: rebuilds the LOD preview at the new size. The plugin saves md to
# the R32F image afterwards; runtime then loads that image — no giant shape anywhere.
func set_heightmap(data: PackedFloat32Array, width: int, depth: int) -> void:
	if width <= 0 or depth <= 0 or data.size() != width * depth:
		push_error("map.gd: set_heightmap got %d values for %dx%d" % [data.size(), width, depth])
		return
	md = data
	w  = width
	d  = depth
	_chunks_x = ceili(float(w - 1) / chunk_size)
	_recompute_height_bound()
	if Engine.is_editor_hint():
		_rebuild_editor_full()

# Bilinear local-space height at local XZ. Clamps to the edge outside the map.
func _sample_height_local(lx: float, lz: float) -> float:
	if md.is_empty() or w <= 0:
		return 0.0
	var x0 := clampi(int(floor(lx + float(w) * 0.5 - 0.5)), 0, w - 1)
	var z0 := clampi(int(floor(lz + float(d) * 0.5 - 0.5)), 0, d - 1)
	var x1 := mini(x0 + 1, w - 1)
	var z1 := mini(z0 + 1, d - 1)
	var fx := clampf((lx + float(w) * 0.5 - 0.5) - float(x0), 0.0, 1.0)
	var fz := clampf((lz + float(d) * 0.5 - 0.5) - float(z0), 0.0, 1.0)
	var h0 = lerp(md[z0 * w + x0], md[z0 * w + x1], fx)
	var h1 = lerp(md[z1 * w + x0], md[z1 * w + x1], fx)
	return lerp(h0, h1, fz)

# Upper bound of the map heights (local units). Needed only by the editor's
# raycast_heightmap: there is guaranteed to be no terrain above it, so the empty air above the
# highest peak can be skipped without sampling. Kept always >= the real maximum — exact
# recompute on load/generate/undo, while the raise brush only pushes it up.
var _md_max := 0.0

func _recompute_height_bound() -> void:
	if not Engine.is_editor_hint():
		return
	var m := -INF
	for h in md:
		if h > m:
			m = h
	_md_max = m if md.size() > 0 else 0.0

# Ray-march the heightmap; returns the world hit position or null. Lets the editor
# sculpt with NO physics collision, so the giant HeightMapShape3D is never needed.
func raycast_heightmap(from_world: Vector3, dir_world: Vector3) -> Variant:
	if md.is_empty() or w <= 0:
		return null
	var inv := global_transform.affine_inverse()
	var o := inv * from_world
	var dir := (inv.basis * dir_world).normalized()
	var max_t := float(maxi(w, d)) * 2.0
	var t := 0.0
	# Skip empty air: while the ray is going down and is above the highest peak (_md_max)
	# there is nothing to sample — jump straight to the plane y = _md_max (minus 1 to start
	# slightly above and keep prev_gap > 0). Safe: there is no terrain above _md_max.
	if dir.y < -1e-6 and o.y > _md_max:
		t = maxf(0.0, (o.y - _md_max) / -dir.y - 1.0)
	var p0 := o + dir * t
	var prev_gap := p0.y - _sample_height_local(p0.x, p0.z)
	while t < max_t:
		t += 1.0
		var p := o + dir * t
		var gap := p.y - _sample_height_local(p.x, p.z)
		if gap <= 0.0 and prev_gap > 0.0:
			var lo := t - 1.0
			var hi := t
			for _i in 10:
				var mid := (lo + hi) * 0.5
				var pm := o + dir * mid
				if pm.y - _sample_height_local(pm.x, pm.z) > 0.0:
					lo = mid
				else:
					hi = mid
			var ph := o + dir * hi
			return global_transform * Vector3(ph.x, _sample_height_local(ph.x, ph.z), ph.z)
		prev_gap = gap
	return null

# In-place brush on md around a world centre; returns the editor chunk indices touched.
# mode: 1 = raise, -1 = lower, 0 = flatten.
func apply_brush(center_world: Vector3, radius: float, strength: float, mode: int) -> PackedInt32Array:
	var dirty := PackedInt32Array()
	if md.is_empty() or w <= 0:
		return dirty
	var local := global_transform.affine_inverse() * center_world
	var cx := int(round(local.x + float(w) * 0.5 - 0.5))
	var cz := int(round(local.z + float(d) * 0.5 - 0.5))
	var r := int(ceil(radius))
	var x_min := clampi(cx - r, 0, w - 1)
	var x_max := clampi(cx + r, 0, w - 1)
	var z_min := clampi(cz - r, 0, d - 1)
	var z_max := clampi(cz + r, 0, d - 1)
	# Hot path — runs on EVERY mouse move over (2r+1)² cells. Therefore:
	# compare squared distances (sqrt only for accepted cells, not during rejection);
	# no Vector2 allocations; hoist the row base and constant factors out of the loop.
	var r2 := radius * radius
	var inv_r := 1.0 / radius
	var avg := 0.0
	if mode == 0:
		var cnt := 0
		for z in range(z_min, z_max + 1):
			var dz := z - cz
			var dz2 := dz * dz
			var row := z * w
			for x in range(x_min, x_max + 1):
				var dx := x - cx
				if dx * dx + dz2 <= r2:
					avg += md[row + x]
					cnt += 1
		if cnt > 0:
			avg /= float(cnt)

	var add := float(mode) * strength      # raise/lower: the constant part, hoisted out of the loop
	for z in range(z_min, z_max + 1):
		var dz := z - cz
		var dz2 := dz * dz
		var row := z * w
		for x in range(x_min, x_max + 1):
			var dx := x - cx
			var d2 := dx * dx + dz2
			if d2 > r2:
				continue
			var falloff := 1.0 - sqrt(float(d2)) * inv_r
			var idx := row + x
			if mode == 0:
				# Flatten: pull toward the average. Weight in [0,1] (falloff≤1, strength≤1); the clamp
				# guards against strength>1 so lerp doesn't overshoot the average and break the map.
				md[idx] = lerp(md[idx], avg, clampf(falloff * strength, 0.0, 1.0))
			else:
				md[idx] += add * falloff
				if md[idx] > _md_max:      # keep the height upper bound current (for raycast)
					_md_max = md[idx]
	# Touched editor chunks (so the plugin can rebuild just those).
	if _ed_cx > 0:
		var seen := {}
		for cz2 in range(z_min / chunk_size, z_max / chunk_size + 1):
			for cx2 in range(x_min / chunk_size, x_max / chunk_size + 1):
				var ci := cz2 * _ed_cx + cx2
				if not seen.has(ci):
					seen[ci] = true
					dirty.append(ci)
	return dirty


# Partial update — only rebuild the listed chunk indices.
# In the editor this is the hot path on every sculpt stroke.
func update_chunks(chunk_indices: Array) -> void:
	if Engine.is_editor_hint() and not use_image_data and collision.shape is HeightMapShape3D:
		md = collision.shape.map_data  # legacy editor: re-read the sculpted shape data
	if Engine.is_editor_hint():
		if _ed_cache.is_empty():
			update()
			return
		for ci in chunk_indices:
			if ci < 0 or ci >= _ed_cache.size():
				continue
			var cx: int = ci % _ed_cx
			var cz: int = ci / _ed_cx
			if editor_lod:
				# Rebuild the dirty chunk plus its 4 neighbours so seam snapping stays valid.
				_ed_cache[ci] = _chunk_surface_arrays_lod(cx, cz)
				for off in [[0,-1],[0,1],[-1,0],[1,0]]:
					var nx: int = cx + off[0]
					var nz: int = cz + off[1]
					if nx >= 0 and nx < _ed_cx and nz >= 0 and nz < _ed_cz:
						_ed_cache[nz * _ed_cx + nx] = _chunk_surface_arrays_lod(nx, nz)
			else:
				_ed_cache[ci] = _chunk_surface_arrays(cx, cz)
		_apply_editor_cache()
		return

	# Runtime: rebuild all LOD levels for the specified chunks
	var mat  = _get_material()
	var cxl  = ceili(float(w - 1) / chunk_size)
	var dirty_macros := {}   # macro group indices that need their mesh rebuilt

	for ci in chunk_indices:
		if ci < 0 or ci >= _chunk_instances.size():
			continue
		if not _chunk_instances[ci]:   # skip chunks not yet streamed in
			continue
		var cx_l = ci % cxl
		var cz_l = ci / cxl
		var x0 = cx_l * chunk_size
		var z0 = cz_l * chunk_size
		var x1 = mini(x0 + chunk_size, w - 1)
		var z1 = mini(z0 + chunk_size, d - 1)

		var lod_meshes: Array = []
		for lod in LOD_COUNT:
			var data = _compute_chunk_data(x0, z0, x1, z1, LOD_STEPS[lod])
			if data.is_empty():
				lod_meshes.append(null)
				continue
			var am = ArrayMesh.new()
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data[0])
			lod_meshes.append(am)
			if lod == 0:
				_chunk_aabbs[ci] = data[1]
		_chunk_meshes[ci] = lod_meshes

		# Track which macro groups need rebuilding due to this chunk change
		if _chunk_macro_idx.size() > ci:
			dirty_macros[_chunk_macro_idx[ci]] = true

		# Apply the currently-active LOD — only when NOT in macro mode
		var in_macro: bool = _chunk_macro_idx.size() > ci and _macro_active[_chunk_macro_idx[ci]]
		if not in_macro:
			var cur_lod = _chunk_lod[ci] if ci < _chunk_lod.size() else 0
			var display_mesh = _best_available_mesh(lod_meshes, cur_lod)
			if display_mesh:
				_chunk_instances[ci].mesh = display_mesh
				_chunk_instances[ci].set_surface_override_material(0, mat)

	# Rebuild merged meshes for every macro group that had a sub-chunk change
	for mi in dirty_macros:
		var macro_mesh := _build_macro_mesh(_macro_to_chunks[mi], 2)
		if macro_mesh:
			_macro_instances[mi].mesh = macro_mesh
			_macro_instances[mi].set_surface_override_material(0, _mat_lod_high if _mat_lod_high else mat)

func get_chunk_info() -> Dictionary:
	return {
		"chunk_size": chunk_size,
		"chunks_x":   ceili(float(w - 1) / chunk_size),
		"map_width":  w,
		"map_depth":  d,
	}


# ─────────────────────────────────────────────────────────────────────────────
# Editor chunk cache internals
# ─────────────────────────────────────────────────────────────────────────────

func _rebuild_editor_full() -> void:
	_editor_ensure_cache_sized()
	if editor_lod:
		_editor_rebuild_lod()
		return
	for cz in _ed_cz:
		for cx in _ed_cx:
			_ed_cache[cz * _ed_cx + cx] = _chunk_surface_arrays(cx, cz)
	_apply_editor_cache()

func _editor_ensure_cache_sized() -> void:
	_ed_cx = ceili(float(w - 1) / chunk_size)
	_ed_cz = ceili(float(d - 1) / chunk_size)
	var total := _ed_cx * _ed_cz
	if _ed_cache.size() != total:
		_ed_cache.clear()
		_ed_cache.resize(total)
	if _ed_lod.size() != total:
		_ed_lod.resize(total)

# Plugin feeds the editor camera here; the actual LOD rebuild is driven by _process so
# it can wait for the camera to settle (no rebuild churn while you fly around).
func set_editor_camera(c: Camera3D) -> void:
	_editor_cam = c

# Editor-only (called from _process): rebuild the LOD mesh once the camera has been
# still for ~0.35 s and moved enough since the last build. Nothing rebuilds while the
# camera moves, so navigating stays smooth — the lighter LOD merge runs only on settle.
func _editor_lod_tick(delta: float) -> void:
	if _editor_cam == null or _ed_cx <= 0:
		return
	var pos := _editor_cam.global_position
	if pos.distance_to(_editor_track_pos) > 2.0:
		_editor_track_pos = pos
		_editor_settle_t  = 0.0
		return
	_editor_settle_t += delta
	if _editor_settle_t >= 0.35 \
			and _editor_track_pos.distance_to(_editor_build_pos) > float(chunk_size) * 0.5:
		_editor_rebuild_lod()

# Picks each chunk's LOD by its XZ distance to the editor camera (same thresholds as
# the game), then rebuilds the whole merged editor mesh at those LODs with seam snapping.
func _editor_rebuild_lod() -> void:
	_editor_ensure_cache_sized()
	var cam_pos: Vector3 = _editor_cam.global_position if _editor_cam else global_position
	var cam_local := global_transform.affine_inverse() * cam_pos
	for cz in _ed_cz:
		for cx in _ed_cx:
			var ccx := (cx + 0.5) * chunk_size - w * 0.5
			var ccz := (cz + 0.5) * chunk_size - d * 0.5
			var dx := ccx - cam_local.x
			var dz := ccz - cam_local.z
			var dist := sqrt(dx * dx + dz * dz)
			var lod := 0
			if dist >= lod_distance_1:   lod = 2   # LOD3 (step 8) removed — unused at runtime
			elif dist >= lod_distance_0: lod = 1
			_ed_lod[cz * _ed_cx + cx] = lod
	for cz in _ed_cz:
		for cx in _ed_cx:
			_ed_cache[cz * _ed_cx + cx] = _chunk_surface_arrays_lod(cx, cz)
	_apply_editor_cache()
	_editor_build_pos = cam_pos

# Editor LOD step of the neighbour chunk, or 1 at the map edge (so no snap is forced).
func _ed_neighbour_step(cx: int, cz: int, dcx: int, dcz: int) -> int:
	var nx := cx + dcx
	var nz := cz + dcz
	if nx < 0 or nx >= _ed_cx or nz < 0 or nz >= _ed_cz:
		return 1
	return LOD_STEPS[_ed_lod[nz * _ed_cx + nx]]

# Builds chunk (cx,cz)'s surface arrays at its editor LOD, snapping borders toward any
# coarser neighbour (same anti-crack stitching as runtime).
func _chunk_surface_arrays_lod(cx: int, cz: int) -> Array:
	var ci := cz * _ed_cx + cx
	var step := LOD_STEPS[_ed_lod[ci]]
	var x0 := cx * chunk_size
	var z0 := cz * chunk_size
	var x1 := mini(x0 + chunk_size, w - 1)
	var z1 := mini(z0 + chunk_size, d - 1)
	var ns := _ed_neighbour_step(cx, cz,  0, -1)
	var ss := _ed_neighbour_step(cx, cz,  0,  1)
	var ws := _ed_neighbour_step(cx, cz, -1,  0)
	var es := _ed_neighbour_step(cx, cz,  1,  0)
	var res := _compute_chunk_data(x0, z0, x1, z1, step,
			ns if ns != step else 0,
			ss if ss != step else 0,
			ws if ws != step else 0,
			es if es != step else 0)
	return [] if res.is_empty() else res[0]

# Editor full-res chunk arrays (used when editor_lod is OFF).
func _chunk_surface_arrays(cx: int, cz: int) -> Array:
	var x0 = cx * chunk_size
	var z0 = cz * chunk_size
	var x1 = mini(x0 + chunk_size, w - 1)
	var z1 = mini(z0 + chunk_size, d - 1)
	var res = _compute_chunk_data(x0, z0, x1, z1, 1)
	return [] if res.is_empty() else res[0]

func _apply_editor_cache() -> void:
	var mat = _get_material()

	# Merge every chunk into ONE surface to avoid hitting MAX_MESH_SURFACES (256).
	# Same technique as _build_macro_mesh() — offset indices per chunk and combine.
	var all_verts   := PackedVector3Array()
	var all_idx     := PackedInt32Array()
	var all_normals := PackedVector3Array()
	var all_uvs     := PackedVector2Array()
	var all_colors  := PackedColorArray()
	var v_offset    := 0

	for arr in _ed_cache:
		if arr == null or arr.is_empty():
			continue
		var verts   := arr[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var idxs    := arr[Mesh.ARRAY_INDEX]  as PackedInt32Array
		var normals := arr[Mesh.ARRAY_NORMAL] as PackedVector3Array
		var uvs     := arr[Mesh.ARRAY_TEX_UV] as PackedVector2Array
		var cols    := arr[Mesh.ARRAY_COLOR]  as PackedColorArray
		if verts == null or verts.is_empty():
			continue
		all_verts.append_array(verts)
		all_normals.append_array(normals)
		all_uvs.append_array(uvs)
		if cols != null and cols.size() == verts.size():
			all_colors.append_array(cols)
		else:
			for _i in verts.size():
				all_colors.append(Color(1.0, 1.0, 1.0, 1.0))
		for raw_idx in idxs:
			all_idx.append(raw_idx + v_offset)
		v_offset += verts.size()

	if all_verts.is_empty():
		return

	var merged := Array()
	merged.resize(Mesh.ARRAY_MAX)
	merged[Mesh.ARRAY_VERTEX] = all_verts
	merged[Mesh.ARRAY_INDEX]  = all_idx
	merged[Mesh.ARRAY_NORMAL] = all_normals
	merged[Mesh.ARRAY_TEX_UV] = all_uvs
	merged[Mesh.ARRAY_COLOR]  = all_colors

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged)
	# Keep the rebuilt preview linked to its EXTERNAL .res path (if the scene already points
	# at one) so saving the scene writes a reference, not an embedded copy of this huge mesh.
	# The file itself is only rewritten by "Bake heightmap → image"; this just stops the
	# scene from swallowing the mesh. A built-in path looks like "res://scene.tscn::Id".
	if mesh_instance.mesh != null:
		var prev_path = mesh_instance.mesh.resource_path
		if not prev_path.is_empty() and not prev_path.contains("::"):
			am.take_over_path(prev_path)
	mesh_instance.mesh = am
	mesh_instance.set_surface_override_material(0, mat)


# ─────────────────────────────────────────────────────────────────────────────
# Runtime chunk building
# ─────────────────────────────────────────────────────────────────────────────

# Builds runtime MeshInstance3D chunks in three phases:
#
# Phase 0 — WorkerThreadPool (ALL chunks, fast):
#   Scans heightmap extremes to compute accurate AABBs for every chunk without
#   generating any mesh data. After this phase frustum/macro/occlusion are fully
#   operational for the whole map, even for chunks not yet meshed.
#
# Phase 1 — WorkerThreadPool (initial chunks near camera only):
#   Mesh data generated in parallel across all CPU cores for chunks of the macros
#   near the camera. Same thread-safety contract as before: reads md/w/d
#   (immutable), each task writes to its exclusive _stream_results[ci] slot.
#
# Phase 2 — main thread (initial chunks only):
#   MeshInstance3D nodes created; scene-tree ops are never thread-safe in Godot.
#
# Remaining chunks are queued in _stream_queue and meshed incrementally at
# runtime via _process() → _stream_tick() → WorkerThreadPool batches.

func _build_chunks_from_map_data() -> void:
	var cxl   := ceili(float(w - 1) / chunk_size)
	var czl   := ceili(float(d - 1) / chunk_size)
	var total := cxl * czl

	# Pre-allocate all chunk arrays to the full map size.
	# Unbuilt slots stay null / 0 / AABB() until streaming fills them in.
	# Every system that iterates these arrays guards against null (see below).
	_chunk_instances.resize(total)
	_chunk_lod.resize(total)
	_chunk_stitch_sig.resize(total)   # 0 = no mesh applied yet → forced rebuild on first LOD pass
	_chunk_meshes.resize(total)
	_chunk_aabbs.resize(total)
	_stream_results.resize(total)

	# ── Phase 0: parallel AABB scan for ALL chunks ────────────────────────────
	# Only reads heightmap extremes — no mesh generation, very fast even on
	# huge maps. Fills _chunk_aabbs so frustum/macro/occlusion work correctly
	# from the very first frame for every chunk, including not-yet-meshed ones.
	var aabb_task := func(ci: int) -> void:
		var cx := ci % cxl;  var cz := ci / cxl
		var x0 := cx * chunk_size;  var x1 := mini(x0 + chunk_size, w - 1)
		var z0 := cz * chunk_size;  var z1 := mini(z0 + chunk_size, d - 1)
		var min_h := INF;  var max_h := -INF
		for zz in range(z0, z1 + 1):
			for xx in range(x0, x1 + 1):
				var h := float(md[zz * w + xx])
				if h < min_h: min_h = h
				if h > max_h: max_h = h
		if min_h == INF:
			return
		_chunk_aabbs[ci] = AABB(
			Vector3(x0 - float(w) * 0.5 + 0.5, min_h, z0 - float(d) * 0.5 + 0.5),
			Vector3(x1 - x0, max_h - min_h, z1 - z0))
	var aabb_gid := WorkerThreadPool.add_group_task(aabb_task, total, -1, true)
	WorkerThreadPool.wait_for_group_task_completion(aabb_gid)

	# ── Materials + macro meshes (the always-resident far representation) ──────
	var mat := _get_material()
	if _mat_lod0 == null:
		_setup_lod_materials(mat)
	# Macro meshes are built directly from the heightmap (one merged step-4 mesh per group),
	# so they need NO individual chunks to exist — that's what lets us instantiate chunks
	# only near the camera. AABBs come from Phase 0.
	_build_macro_chunks()
	_build_quadtree()

	# ── Initial resident set: only chunks of macros near the camera ───────────
	# Every other chunk of the map is left uninstantiated; its macro mesh covers it until
	# the camera comes close (then it streams in on demand). Bounds startup memory.
	var cam_pos := _cam.global_position if _cam else Vector3.ZERO
	var load_r  := lod_distance_1 + QT_EVICT_MARGIN
	var load_d2 := load_r * load_r
	var near_chunks: Array[int] = []
	for mi in _macro_instances.size():
		var c := global_transform * _macro_aabbs[mi].get_center()
		var dx := cam_pos.x - c.x
		var dz := cam_pos.z - c.z
		if dx * dx + dz * dz <= load_d2:
			_resident_set[mi] = true
			for ci in _macro_to_chunks[mi]:
				near_chunks.append(ci)

	if not near_chunks.is_empty():
		var build_task := func(i: int) -> void:
			_build_chunk_worker(near_chunks[i], cxl)
		var gid := WorkerThreadPool.add_group_task(build_task, near_chunks.size(), -1, true)
		WorkerThreadPool.wait_for_group_task_completion(gid)
		_apply_built_results(near_chunks, mat)
		for ci in near_chunks:
			if ci >= 0 and ci < _chunk_instances.size() and _chunk_instances[ci]:
				_apply_lod_mesh(ci, mat)

	# Near chunks are built synchronously above; nothing is queued at startup. On-demand
	# streaming (_request_resident) fills the queue later as the camera moves.
	_stream_queue.clear()
	_is_streaming = false


# Computes all 4 LOD meshes for chunk ci and stores the result in _stream_results[ci].
# Thread-safe: reads only md/w/d (immutable during build), writes only to its
# exclusive _stream_results[ci] slot — same pattern as the original Phase 1.
func _build_chunk_worker(ci: int, cxl: int) -> void:
	var cx := ci % cxl;  var cz := ci / cxl
	var x0 := cx * chunk_size;  var x1 := mini(x0 + chunk_size, w - 1)
	var z0 := cz * chunk_size;  var z1 := mini(z0 + chunk_size, d - 1)
	var lod_meshes: Array = []
	var first_aabb := AABB()
	for lod in LOD_COUNT:
		var data := _compute_chunk_data(x0, z0, x1, z1, LOD_STEPS[lod])
		if data.is_empty():
			lod_meshes.append(null)
			continue
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data[0])
		lod_meshes.append(am)
		if lod == 0:
			first_aabb = data[1]
	_stream_results[ci] = [lod_meshes, first_aabb]


# Creates a MeshInstance3D for each ci in indices whose _stream_results[ci] is ready.
# MUST run on the main thread — adds nodes to the scene tree. Instances are created
# hidden; the quadtree's next descend decides their visibility and LOD.
func _apply_built_results(indices: Array, mat: Material) -> void:
	for ci in indices:
		if _stream_results[ci] == null:
			continue
		var lod_meshes: Array = _stream_results[ci][0]
		_stream_results[ci]   = null

		var inst := MeshInstance3D.new()
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		inst.visible     = false
		add_child(inst)
		_chunk_instances[ci] = inst
		_chunk_lod[ci]       = 0
		_chunk_stitch_sig[ci] = 1     # plain LOD-0, no border snap (= _stitch_signature for that state)
		_chunk_meshes[ci]    = lod_meshes
		# Note: _chunk_aabbs[ci] was already filled by Phase 0 with an identical
		# value (same heightmap scan); we skip the redundant write to avoid any
		# potential race if a frustum task is still in flight.

		var start_mesh := _best_available_mesh(lod_meshes, 0)
		if start_mesh:
			inst.mesh = start_mesh
			var lod_mat := _mat_lod0 if _mat_lod0 else mat
			inst.set_surface_override_material(0, lod_mat)

		# Created hidden. The quadtree's next descend (_qt_update) decides whether this
		# chunk renders individually, is covered by an active macro, or stays culled —
		# no frustum bookkeeping needed here.
		inst.visible = false




# Applies the correct mesh to chunk ci, rebuilding with border snapping when
# the chunk is at LOD 0 and any neighbour is at a coarser step.
func _apply_lod_mesh(ci: int, mat: Material) -> void:
	if ci >= _chunk_lod.size() or ci >= _chunk_instances.size() or ci >= _chunk_meshes.size():
		return
	if not _chunk_instances[ci]:
		return   # chunk not yet streamed in
	var target_lod := _chunk_lod[ci]
	var my_step    := LOD_STEPS[target_lod]
	var cxl        := ceili(float(w - 1) / chunk_size)
	var cx         := ci % cxl
	var cz         := ci / cxl

	# Stitching applies to ANY LOD level, not just LOD-0.
	# A LOD-1 (step=2) chunk adjacent to an active macro group (step=4) also
	# produces T-junction cracks without seam snapping. Snap only toward COARSER
	# neighbours (step > my_step); pass 0 for the rest.
	var n_snap := _border_snap(cx, cz,  0, -1, my_step)
	var s_snap := _border_snap(cx, cz,  0,  1, my_step)
	var w_snap := _border_snap(cx, cz, -1,  0, my_step)
	var e_snap := _border_snap(cx, cz,  1,  0, my_step)

	# Record the signature of the mesh we are about to apply, so the quadtree LOD pass can tell
	# when this chunk needs rebuilding again (its LOD or any neighbour's step changed).
	if ci < _chunk_stitch_sig.size():
		_chunk_stitch_sig[ci] = _encode_sig(my_step, n_snap, s_snap, w_snap, e_snap)

	var lod_mat := (_mat_lod0 if target_lod == 0 else _mat_lod_high) if _mat_lod0 else mat

	if n_snap != 0 or s_snap != 0 or w_snap != 0 or e_snap != 0:
		# Rebuild this chunk's mesh with seam-snapped border vertices
		var x0 := cx * chunk_size
		var z0 := cz * chunk_size
		var x1 := mini(x0 + chunk_size, w - 1)
		var z1 := mini(z0 + chunk_size, d - 1)
		var data := _compute_chunk_data(x0, z0, x1, z1, my_step,
				n_snap, s_snap, w_snap, e_snap)
		if not data.is_empty():
			var am := ArrayMesh.new()
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data[0])
			_chunk_instances[ci].mesh = am
			_chunk_instances[ci].set_surface_override_material(0, lod_mat)
			return

	# No stitching needed — use the pre-built LOD mesh
	var display_mesh := _best_available_mesh(_chunk_meshes[ci], target_lod)
	if display_mesh:
		_chunk_instances[ci].mesh = display_mesh
	_chunk_instances[ci].set_surface_override_material(0, lod_mat)


# Returns the neighbour's LOD step if it DIFFERS from my_step, else 0. Used both for
# height snapping (only when the value is COARSER, i.e. > my_step) and for grass-seam
# flattening (whenever it is non-zero, i.e. any LOD difference, either direction).
func _border_snap(cx: int, cz: int, dcx: int, dcz: int, my_step: int) -> int:
	var s := _neighbour_step(cx, cz, dcx, dcz)
	return s if s != my_step else 0


# Packs a chunk's LOD step and its 4 border snap steps into one int. Two chunks with
# the same signature produce byte-identical meshes, so the quadtree LOD pass only rebuilds when
# the signature actually changes. Each value is ≤ 8, so 4 bits per field is plenty.
func _encode_sig(my_step: int, n_snap: int, s_snap: int, w_snap: int, e_snap: int) -> int:
	return my_step | (n_snap << 4) | (s_snap << 8) | (w_snap << 12) | (e_snap << 16)


# Current required signature for chunk ci (its LOD step + the snap step each border
# needs given its neighbours right now). Compared against _chunk_stitch_sig to decide
# whether the chunk's mesh is stale and must be rebuilt.
func _stitch_signature(ci: int) -> int:
	var cxl := ceili(float(w - 1) / chunk_size)
	var cx := ci % cxl
	var cz := ci / cxl
	var my_step := LOD_STEPS[_chunk_lod[ci]]
	return _encode_sig(my_step,
			_border_snap(cx, cz,  0, -1, my_step),
			_border_snap(cx, cz,  0,  1, my_step),
			_border_snap(cx, cz, -1,  0, my_step),
			_border_snap(cx, cz,  1,  0, my_step))


# Returns the flat chunk index for grid position (cx, cz), or -1 if out of bounds.
func _get_chunk_idx(cx: int, cz: int) -> int:
	var cxl := ceili(float(w - 1) / chunk_size)
	var czl := ceili(float(d - 1) / chunk_size)
	if cx < 0 or cx >= cxl or cz < 0 or cz >= czl:
		return -1
	return cz * cxl + cx


# Returns the LOD vertex-step of the neighbour at (cx+dcx, cz+dcz).
# Macro groups report step=4 (their merged mesh uses LOD 2).
# Map-edge neighbours return 1 (same as LOD 0, so no snap triggered).
func _neighbour_step(cx: int, cz: int, dcx: int, dcz: int) -> int:
	var ni := _get_chunk_idx(cx + dcx, cz + dcz)
	if ni < 0 or ni >= _chunk_lod.size():
		return 1   # map boundary or not-yet-built chunk — no snap
	if _chunk_macro_idx.size() > ni and _macro_active[_chunk_macro_idx[ni]]:
		return LOD_STEPS[2]   # macro group uses LOD-2 step (= 4)
	return LOD_STEPS[_chunk_lod[ni]]

# Returns the mesh at `preferred_lod`, falling back to the next finer LOD
# if the preferred one happens to be null (tiny edge-chunks may skip coarse LODs).
func _best_available_mesh(lod_meshes: Array, preferred_lod: int) -> ArrayMesh:
	var lod = preferred_lod
	while lod > 0 and lod_meshes[lod] == null:
		lod -= 1
	return lod_meshes[lod]


# ─────────────────────────────────────────────────────────────────────────────
# Macro-chunk building & management
# ─────────────────────────────────────────────────────────────────────────────

# Groups individual chunks into MACRO_SIZE×MACRO_SIZE cells.
# Each cell gets one MeshInstance3D (shadows OFF) whose mesh is the merged
# LOD-2 geometry of all sub-chunks.
# Called once, at the end of _build_chunks_from_map_data(), after every
# _chunk_aabbs entry is populated (by Phase 0 — includes unbuilt chunks).
func _build_macro_chunks() -> void:
	var mat := _get_material()
	var cxl := ceili(float(w - 1) / chunk_size)   # individual chunks wide
	var czl := ceili(float(d - 1) / chunk_size)   # individual chunks deep
	var _macro_cx := ceili(float(cxl) / MACRO_SIZE)
	var _macro_cz := ceili(float(czl) / MACRO_SIZE)

	_chunk_macro_idx.resize(_chunk_instances.size())

	# ── Pass A: group structure + merged AABB (cheap, main thread) ────────────
	for mz in _macro_cz:
		for mx in _macro_cx:
			# The macro index for this group is the current length of _macro_to_chunks
			# (assigned before the append, so it equals mz*_macro_cx + mx).
			var mi_now  := _macro_to_chunks.size()
			var c_list  := []
			var grp_aabb := AABB()
			var first   := true

			for dz in MACRO_SIZE:
				for dx in MACRO_SIZE:
					var cx := mx * MACRO_SIZE + dx
					var cz := mz * MACRO_SIZE + dz
					if cx >= cxl or cz >= czl:
						continue
					var ci := cz * cxl + cx
					c_list.append(ci)
					_chunk_macro_idx[ci] = mi_now
					if first:
						grp_aabb = _chunk_aabbs[ci]   # Phase 0 guaranteed all AABBs filled
						first    = false
					else:
						grp_aabb = grp_aabb.merge(_chunk_aabbs[ci])

			_macro_to_chunks.append(c_list)
			_macro_aabbs.append(grp_aabb)
			_macro_active.append(false)

	# ── Pass B: build each macro's merged step-4 mesh in parallel ─────────────
	# Built directly from the heightmap over the whole group extent — independent of
	# whether any individual chunk is instantiated, so chunks can be freed/streamed freely.
	var macro_n := _macro_instances_target_count()
	_macro_results.clear()
	_macro_results.resize(macro_n)
	if macro_n > 0:
		var macro_task := func(mi: int) -> void:
			_build_macro_worker(mi, cxl)
		var mgid := WorkerThreadPool.add_group_task(macro_task, macro_n, -1, true)
		WorkerThreadPool.wait_for_group_task_completion(mgid)

	# ── Pass C: create the macro MeshInstance3D nodes (main thread) ───────────
	for mi in macro_n:
		var inst := MeshInstance3D.new()
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		inst.visible     = false   # the quadtree shows/hides macros each frame
		var macro_mesh: ArrayMesh = _macro_results[mi]
		if macro_mesh:
			inst.mesh = macro_mesh
			inst.set_surface_override_material(0, _mat_lod_high if _mat_lod_high else mat)
		add_child(inst)
		_macro_instances.append(inst)
	_macro_results.clear()


# Number of macro groups (= entries already pushed into _macro_to_chunks by Pass A).
func _macro_instances_target_count() -> int:
	return _macro_to_chunks.size()


# Threaded worker: builds macro mi's merged LOD-2 (step-4) mesh straight from the
# heightmap over the group's full XZ extent. One surface, ~512 tris. Pure math + a
# fresh ArrayMesh (same off-thread pattern as _build_chunk_worker).
func _build_macro_worker(mi: int, cxl: int) -> void:
	var c_list: Array = _macro_to_chunks[mi]
	if c_list.is_empty():
		return
	var first_ci: int = c_list[0]
	var mgx := (first_ci % cxl) / MACRO_SIZE
	var mgz := (first_ci / cxl) / MACRO_SIZE
	var x0  := mgx * MACRO_SIZE * chunk_size
	var z0  := mgz * MACRO_SIZE * chunk_size
	var x1  := mini(x0 + MACRO_SIZE * chunk_size, w - 1)
	var z1  := mini(z0 + MACRO_SIZE * chunk_size, d - 1)
	# Skirt so the macro↔coarse-node seam (different LOD steps) never shows a crack.
	var data := _compute_chunk_data(x0, z0, x1, z1, LOD_STEPS[2], 0, 0, 0, 0, QT_SKIRT)
	if data.is_empty():
		return
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data[0])
	_macro_results[mi] = am


# Merges the lod_level mesh of every chunk in chunk_indices into a single
# ArrayMesh with one surface → one draw call.  Returns null if no geometry.
func _build_macro_mesh(chunk_indices: Array, lod_level: int) -> ArrayMesh:
	var all_verts   := PackedVector3Array()
	var all_idx     := PackedInt32Array()
	var all_normals := PackedVector3Array()
	var all_uvs     := PackedVector2Array()
	var all_colors  := PackedColorArray()
	var v_offset    := 0

	for ci in chunk_indices:
		if ci < 0 or ci >= _chunk_meshes.size():
			continue
		if not _chunk_meshes[ci]:   # chunk not yet streamed in
			continue
		var src := _best_available_mesh(_chunk_meshes[ci], lod_level)
		if src == null or src.get_surface_count() == 0:
			continue
		var arrays  := src.surface_get_arrays(0)
		var verts   := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var idxs    := arrays[Mesh.ARRAY_INDEX]  as PackedInt32Array
		var norms   := arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
		var uvs     := arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array
		var cols    := arrays[Mesh.ARRAY_COLOR]  as PackedColorArray
		if verts == null or verts.is_empty():
			continue
		all_verts.append_array(verts)
		all_normals.append_array(norms)
		all_uvs.append_array(uvs)
		if cols != null and cols.size() == verts.size():
			all_colors.append_array(cols)
		else:
			# Source lacks colours — treat as all-interior so grass behaves as before.
			for _i in verts.size():
				all_colors.append(Color(1.0, 1.0, 1.0, 1.0))
		for raw_idx in idxs:
			all_idx.append(raw_idx + v_offset)
		v_offset += verts.size()

	if all_verts.is_empty():
		return null

	var arr := Array()
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = all_verts
	arr[Mesh.ARRAY_INDEX]  = all_idx
	arr[Mesh.ARRAY_NORMAL] = all_normals
	arr[Mesh.ARRAY_TEX_UV] = all_uvs
	arr[Mesh.ARRAY_COLOR]  = all_colors

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am




# ─────────────────────────────────────────────────────────────────────────────
# Chunk streaming  (called from _process when _is_streaming == true)
# ─────────────────────────────────────────────────────────────────────────────

# Ticked once per frame while there are unbuilt chunks.
# Non-blocking: dispatches workers, then checks back next frame.
# The main thread never stalls — it applies a batch only when it's already done.
func _stream_tick(_delta: float) -> void:
	# Step 1: apply the completed batch
	if _stream_group_id >= 0 and WorkerThreadPool.is_group_task_completed(_stream_group_id):
		WorkerThreadPool.wait_for_group_task_completion(_stream_group_id)   # instant join
		_stream_group_id = -1
		_stream_apply_batch()
	# Step 2: kick off the next batch while the queue has work
	if _stream_group_id < 0 and not _stream_queue.is_empty():
		_stream_dispatch_batch()


func _stream_dispatch_batch() -> void:
	var count := mini(stream_batch_size, _stream_queue.size())
	_stream_batch = _stream_queue.slice(0, count)
	_stream_queue = _stream_queue.slice(count)
	var cxl := ceili(float(w - 1) / chunk_size)
	var task := func(i: int) -> void:
		_build_chunk_worker(_stream_batch[i], cxl)
	_stream_group_id = WorkerThreadPool.add_group_task(
			task, count, -1, true, "stream_chunk")


func _stream_apply_batch() -> void:
	var mat := _get_material()
	_apply_built_results(_stream_batch, mat)

	# Macro meshes are built once at startup and never rebuilt at runtime (the heightmap
	# doesn't change), so streamed-in chunks DON'T touch them — they only fill the
	# individual-chunk detail back in for a macro the camera is approaching.
	var touched := {}
	for ci in _stream_batch:
		_queued_chunks.erase(ci)
		if _chunk_macro_idx.size() > ci:
			touched[_chunk_macro_idx[ci]] = true

	# Seam-stitch each freshly-streamed chunk against its already-present neighbours
	# (snaps toward coarser/active-macro neighbours; a no-op when none differ).
	for ci in _stream_batch:
		if ci < 0 or ci >= _chunk_instances.size() or not _chunk_instances[ci]:
			continue
		if _chunk_macro_idx.size() > ci and _macro_active[_chunk_macro_idx[ci]]:
			continue
		_apply_lod_mesh(ci, mat)

	# A macro becomes "resident" once all its chunks are present — the quadtree may then
	# expand it into individual chunks instead of showing the merged macro mesh.
	for mi in touched:
		if _macro_all_present(mi):
			_resident_set[mi] = true

	if _stream_queue.is_empty():
		_is_streaming = false


# ─────────────────────────────────────────────────────────────────────────────
# Core geometry helper
# ─────────────────────────────────────────────────────────────────────────────

# Generates a sorted list of sample positions from `start` to `end` inclusive,
# stepping by `step`.  `end` is always included even if it's not on the grid —
# this guarantees chunk edges share the same vertex positions across LOD levels,
# which eliminates visible seams between adjacent chunks at different LODs.
func _sample_range(start: int, end: int, step: int) -> PackedInt32Array:
	var result = PackedInt32Array()
	var pos    = start
	while pos < end:
		result.append(pos)
		pos += step
	# Always include the boundary (avoids duplicate if step divides evenly)
	if result.is_empty() or result[result.size() - 1] != end:
		result.append(end)
	return result

# Returns [surface_arrays, AABB], or [] for a degenerate chunk.
# `step` controls LOD resolution:
#   step=1 → every vertex (LOD 0, full quality)
#   step=2 → every other vertex (LOD 1, ~4× fewer triangles)
#   step=4 → every 4th vertex  (LOD 2, ~16× fewer triangles)
#   step=8 → every 8th vertex  (LOD 3, ~64× fewer triangles)
# n/s/w/e_step: LOD step of the neighbour on that edge.
# When neighbour_step > step, border vertices that fall between the neighbour's
# sample positions are linearly interpolated so both meshes share the same
# height along the seam — eliminating T-junction cracks.
# Pass 0 (default) for edges that need no stitching.
func _compute_chunk_data(x0: int, z0: int, x1: int, z1: int, step: int = 1,
		n_step: int = 0, s_step: int = 0,
		w_step: int = 0, e_step: int = 0, skirt: float = 0.0) -> Array:
	var vertices  = PackedVector3Array()
	var indices   = PackedInt32Array()
	var normals   = PackedVector3Array()
	var uvs       = PackedVector2Array()
	var colors    = PackedColorArray()   # .r = grass mask: 0 on chunk borders, 1 inside
	var local_idx = {}
	var idx       = 0
	var aabb_min  = Vector3(INF,  INF,  INF)
	var aabb_max  = Vector3(-INF, -INF, -INF)

	var sz = maxi(1, step)
	var xs = _sample_range(x0, x1, sz)
	var zs = _sample_range(z0, z1, sz)
	# Degenerate chunk (fewer than 2×2 samples) — no quads can be built. On small maps this
	# used to trigger a mesh build error: return empty, such a chunk simply isn't drawn.
	if xs.size() < 2 or zs.size() < 2:
		return []

	# ── Vertices ──────────────────────────────────────────────────────────────
	for z in zs:
		for x in xs:
			var h = float(md[z * w + x])

			# ── Border snapping ───────────────────────────────────────────────
			# If this vertex is on an edge adjacent to a coarser-LOD chunk and
			# its position is not on the coarser grid, snap its height to the
			# linear interpolation of the two coarser neighbours.
			# Guarantee: chunk_size=16 is divisible by all possible steps (1,2,4,8),
			# so x0/z0 are always aligned with the neighbour grid — no clamping needed.

			# The neighbour sample (x-rem+step / z-rem+step) can go past the map EDGE on the outermost
			# border (there is no neighbour chunk there), giving an index one row/column beyond
			# md — that's where "Invalid access" came from. Clamp the upper index to the edge.

			# North border (z == z0): snap x to n_step grid
			if z == z0 and n_step > step:
				var rem: int = x % n_step
				if rem != 0:
					h = lerp(float(md[z * w + x - rem]),
							 float(md[z * w + mini(x - rem + n_step, w - 1)]),
							 float(rem) / float(n_step))

			# South border (z == z1): snap x to s_step grid
			elif z == z1 and s_step > step:
				var rem: int = x % s_step
				if rem != 0:
					h = lerp(float(md[z * w + x - rem]),
							 float(md[z * w + mini(x - rem + s_step, w - 1)]),
							 float(rem) / float(s_step))

			# West border (x == x0): snap z to w_step grid
			if x == x0 and w_step > step:
				var rem: int = z % w_step
				if rem != 0:
					h = lerp(float(md[(z - rem) * w + x]),
							 float(md[mini(z - rem + w_step, d - 1) * w + x]),
							 float(rem) / float(w_step))

			# East border (x == x1): snap z to e_step grid
			elif x == x1 and e_step > step:
				var rem: int = z % e_step
				if rem != 0:
					h = lerp(float(md[(z - rem) * w + x]),
							 float(md[mini(z - rem + e_step, d - 1) * w + x]),
							 float(rem) / float(e_step))

			var pos = Vector3(x - w * 0.5 + 0.5, h, z - d * 0.5 + 0.5)
			vertices.append(pos)
			aabb_min = aabb_min.min(pos)
			aabb_max = aabb_max.max(pos)
			uvs.append(Vector2(float(x) / w, float(z) / d))

			# Flatten grass ONLY on borders that touch a DIFFERENT-LOD neighbour (a real
			# LOD seam). There the grass vertex offset would re-open a crack, so the shader
			# skips it (COLOR.r = 0). On same-LOD borders grass stays on — otherwise every
			# chunk edge shows a dip/ridge in the grass. n/s/w/e_step != 0 means "neighbour
			# differs" (see _border_snap). Pass 0 (default build) = grass everywhere.
			var seam := (z == z0 and n_step != 0) or (z == z1 and s_step != 0) \
					 or (x == x0 and w_step != 0) or (x == x1 and e_step != 0)
			colors.append(Color(0.0, 0.0, 0.0, 1.0) if seam else Color(1.0, 1.0, 1.0, 1.0))

			# Finite-difference normal — uses step-wide neighbours so normals
			# remain smooth at lower LODs instead of having discontinuities.
			var hl = md[z * w + maxi(x - sz, 0)]
			var hr = md[z * w + mini(x + sz, w - 1)]
			var hu = md[maxi(z - sz, 0) * w + x]
			var hd = md[mini(z + sz, d - 1) * w + x]
			normals.append(Vector3(hl - hr, 2.0 * sz, hu - hd).normalized())

			local_idx[z * w + x] = idx
			idx += 1

	# ── Triangles ─────────────────────────────────────────────────────────────
	# Iterate over the sample-position arrays — no manual index arithmetic,
	# so we always connect exactly the vertices we generated above.
	for zi in range(zs.size() - 1):
		for xi in range(xs.size() - 1):
			var i00 = local_idx.get(zs[zi]     * w + xs[xi],     -1)
			var i10 = local_idx.get(zs[zi]     * w + xs[xi + 1], -1)
			var i01 = local_idx.get(zs[zi + 1] * w + xs[xi],     -1)
			var i11 = local_idx.get(zs[zi + 1] * w + xs[xi + 1], -1)
			if i00 < 0 or i10 < 0 or i01 < 0 or i11 < 0:
				continue
			indices.append_array([i00, i10, i11])
			indices.append_array([i00, i11, i01])

	if vertices.is_empty() or indices.is_empty():
		return []

	# ── Optional skirt ────────────────────────────────────────────────────────
	# A vertical apron dropped `skirt` units below every border edge. It fills the
	# T-junction cracks where this mesh abuts a neighbour built at a different LOD step
	# (the multi-level quadtree), so seams never show a gap. Built two-sided (both
	# windings) so it's visible from any angle, and inline here so the per-frame arrays
	# stay local (no helper mutating a passed-in Packed array).
	if skirt > 0.0:
		var zlast: int = zs[zs.size() - 1]
		var xlast: int = xs[xs.size() - 1]
		var bottom := {}
		var bkeys: Array = []
		for x in xs:
			bkeys.append(zs[0] * w + x)
			bkeys.append(zlast * w + x)
		for z in zs:
			bkeys.append(z * w + xs[0])
			bkeys.append(z * w + xlast)
		for gk in bkeys:
			if bottom.has(gk):
				continue
			var ti: int = local_idx.get(gk, -1)
			if ti < 0:
				continue
			var tv: Vector3 = vertices[ti]
			bottom[gk] = vertices.size()
			vertices.append(Vector3(tv.x, tv.y - skirt, tv.z))
			normals.append(normals[ti])
			uvs.append(uvs[ti])
			colors.append(colors[ti])
		var edges: Array = []
		for xi in range(xs.size() - 1):
			edges.append([zs[0] * w + xs[xi],  zs[0] * w + xs[xi + 1]])
			edges.append([zlast * w + xs[xi],  zlast * w + xs[xi + 1]])
		for zi in range(zs.size() - 1):
			edges.append([zs[zi] * w + xs[0],     zs[zi + 1] * w + xs[0]])
			edges.append([zs[zi] * w + xlast,     zs[zi + 1] * w + xlast])
		for e in edges:
			var a: int  = local_idx.get(e[0], -1)
			var b: int  = local_idx.get(e[1], -1)
			var ba: int = bottom.get(e[0], -1)
			var bb: int = bottom.get(e[1], -1)
			if a < 0 or b < 0 or ba < 0 or bb < 0:
				continue
			indices.append_array([a, b, bb, a, bb, ba])
			indices.append_array([a, bb, b, a, ba, bb])

	var arr = Array()
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = vertices
	arr[Mesh.ARRAY_INDEX]  = indices
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR]  = colors
	return [arr, AABB(aabb_min, aabb_max - aabb_min)]


# ─────────────────────────────────────────────────────────────────────────────
# Material helpers
# ─────────────────────────────────────────────────────────────────────────────

# Duplicates the base material twice and bakes lod_grass_enabled into each copy.
# This is called once at chunk-build time. Subsequent LOD switches just swap
# which of these two material references an instance points to — zero per-instance
# shader-parameter slots consumed, so the GLES3 4096-slot buffer is never touched.
func _setup_lod_materials(base_mat: Material) -> void:
	if base_mat is ShaderMaterial:
		# Duplicate the base material: all appearance parameters (tile texture, blend,
		# tile_world_size, colors, grass, low_quality) are inherited from it as-is — the node doesn't
		# touch them, they are configured on the material itself. Only lod_grass_enabled differs.
		_mat_lod0 = base_mat.duplicate()
		(_mat_lod0 as ShaderMaterial).set_shader_parameter("lod_grass_enabled", 1.0)
		_mat_lod_high = base_mat.duplicate()
		(_mat_lod_high as ShaderMaterial).set_shader_parameter("lod_grass_enabled", 0.0)
	else:
		# StandardMaterial3D or unknown — no grass parameter, use same ref for both
		_mat_lod0    = base_mat
		_mat_lod_high = base_mat

# Called by grass.gd every frame. Grass only renders on the LOD0 (close) material, which is
# a private duplicate of the base — so the trample map MUST be set here, not on the base
# material grass.gd would otherwise find. tex = top-down flatten texture, center/size =
# the world-space window it covers (follows the camera).
func set_grass_trample(tex: Texture2D, center: Vector2, size: float) -> void:
	if _mat_lod0 is ShaderMaterial:
		var m := _mat_lod0 as ShaderMaterial
		m.set_shader_parameter("trample_map", tex)
		m.set_shader_parameter("trample_center", center)
		m.set_shader_parameter("trample_size", size)

func _get_material() -> Material:
	var mat: Material = null
	if mesh_instance.mesh != null and mesh_instance.mesh.get_surface_count() > 0:
		mat = mesh_instance.get_surface_override_material(0)
		if mat == null:
			mat = mesh_instance.mesh.surface_get_material(0)
	if mat == null and surface_material != null:
		mat = surface_material            # fresh node → the addon's terrain shader
	if mat == null:
		mat = StandardMaterial3D.new()
	return mat


# ─────────────────────────────────────────────────────────────────────────────
# Camera / frustum culling  (runtime only)
# ─────────────────────────────────────────────────────────────────────────────

# Current working camera: the manual override (if set and valid) or the viewport's active
# camera. get_viewport().get_camera_3d() always returns the camera the scene is currently
# rendered with — including switches, spring-arms, etc. No tree searching needed.
func _active_camera() -> Camera3D:
	if is_instance_valid(camera):
		return camera
	var vp := get_viewport()
	return vp.get_camera_3d() if vp != null else null

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		if editor_lod:
			_editor_lod_tick(delta)
		return

	# The current active camera — every frame, with no manual assignment. Follows camera
	# switches (e.g. the view change on death / getting into a vehicle).
	_cam = _active_camera()

	# ── Streaming collision: keep tiled collision cells under the tracked bodies ──
	# Collision doesn't need a camera — update it even when there is no active camera yet.
	if _col_active:
		_update_collision_cells()

	# Everything below (chunk streaming, LOD, culling) depends on the camera.
	if _cam == null:
		return

	# ── Background chunk streaming ────────────────────────────────────────────
	if _is_streaming:
		_stream_tick(delta)

	# ── Quadtree frustum culling + LOD selection ──────────────────────────────
	# One descend from the root each frame handles culling AND macro/chunk LOD; the
	# heavier work (per-chunk LOD reassignment + seam-stitch rebuilds) is throttled.
	_lod_timer += delta
	var do_lod := _lod_timer >= LOD_UPDATE_INTERVAL
	if do_lod:
		_lod_timer = 0.0
	_qt_update(do_lod)

	# ── Occlusion culling (throttled) ─────────────────────────────────────────
	if enable_occlusion_culling:
		_occlusion_timer += delta
		if _occlusion_timer >= OCCLUSION_UPDATE_INTERVAL:
			_occlusion_timer = 0.0
			_update_occlusion()
	elif not (_occluded_chunks.is_empty() and _occluded_macros.is_empty() and _occluded_nodes.is_empty()):
		# Occlusion was just toggled off — restore full quadtree-based visibility
		_clear_occlusion()

func _full_scan() -> void:
	# Initial selection: one stateless quadtree descend picks the first frame's
	# visible macros/chunks (and their LOD). Same call that runs every frame.
	_qt_cur_macros.clear()
	_qt_cur_chunks.clear()
	_qt_cur_nodes.clear()
	_qt_update(true)


# ─────────────────────────────────────────────────────────────────────────────
# Quadtree — frustum culling + LOD selection  (runtime only)
# ─────────────────────────────────────────────────────────────────────────────

# Builds the macro-grid quadtree. Leaves are existing macro groups (so the merged
# macro meshes are reused as-is); internal nodes just carry a merged AABB for
# hierarchical frustum/range pruning. Called once, after _build_macro_chunks().
func _build_quadtree() -> void:
	_qt_aabb.clear()
	_qt_child.clear()
	_qt_macro.clear()
	_qt_rect.clear()
	_qt_step.clear()
	_qt_size.clear()
	_qt_inst.clear()
	_qt_built = false
	if _macro_aabbs.is_empty():
		return
	var cxl := ceili(float(w - 1) / chunk_size)
	var czl := ceili(float(d - 1) / chunk_size)
	var macro_cx := ceili(float(cxl) / MACRO_SIZE)
	var macro_cz := ceili(float(czl) / MACRO_SIZE)
	if macro_cx <= 0 or macro_cz <= 0:
		return
	_qt_build_node(0, 0, macro_cx, macro_cz, macro_cx)
	_qt_built = not _qt_aabb.is_empty()

	# ── Build each internal node's coarse merged mesh (threaded), then its instance ──
	var node_n := _qt_aabb.size()
	_qt_inst.resize(node_n)
	_qt_node_results.resize(node_n)
	var internal: Array[int] = []
	for n in node_n:
		if _qt_macro[n] < 0:
			internal.append(n)
	if not internal.is_empty():
		var node_task := func(i: int) -> void:
			_qt_node_worker(internal[i])
		var ngid := WorkerThreadPool.add_group_task(node_task, internal.size(), -1, true)
		WorkerThreadPool.wait_for_group_task_completion(ngid)
	var mat := _get_material()
	for n in internal:
		var m: ArrayMesh = _qt_node_results[n]
		var inst := MeshInstance3D.new()
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		inst.visible     = false
		if m:
			inst.mesh = m
			inst.set_surface_override_material(0, _mat_lod_high if _mat_lod_high else mat)
		add_child(inst)
		_qt_inst[n] = inst
	_qt_node_results.clear()


# Recursively builds a node covering the macro-grid rectangle
# [mx0, mx0+wsz) × [mz0, mz0+hsz). Splits the longer axis so nodes stay squarish.
# Returns the new node's id. Also records the node's cell rect / coarse-mesh step / world
# size, which the descend uses for LOD selection and the coarse-mesh build.
func _qt_build_node(mx0: int, mz0: int, wsz: int, hsz: int, macro_cx: int) -> int:
	var node_id := _qt_aabb.size()
	_qt_aabb.append(AABB())
	_qt_child.append([] as Array[int])
	_qt_macro.append(-1)
	# Cell rect of the whole node footprint (clamped to the heightmap edge).
	var rx0 := mx0 * MACRO_SIZE * chunk_size
	var rz0 := mz0 * MACRO_SIZE * chunk_size
	var rx1 := mini((mx0 + wsz) * MACRO_SIZE * chunk_size, w - 1)
	var rz1 := mini((mz0 + hsz) * MACRO_SIZE * chunk_size, d - 1)
	_qt_rect.append(Vector4i(rx0, rz0, rx1, rz1))
	# Step grows with node size → ~constant triangle budget per node regardless of level.
	_qt_step.append(maxi(wsz, hsz) * MACRO_SIZE)
	_qt_size.append(float(maxi(rx1 - rx0, rz1 - rz0)))

	if wsz <= 1 and hsz <= 1:
		var mi: int = mz0 * macro_cx + mx0
		_qt_macro[node_id] = mi
		_qt_aabb[node_id]  = _macro_aabbs[mi]
		return node_id

	var hw := (wsz + 1) >> 1
	var hh := (hsz + 1) >> 1
	var rects: Array = []
	if wsz > 1 and hsz > 1:
		rects = [[mx0, mz0, hw, hh], [mx0 + hw, mz0, wsz - hw, hh],
				 [mx0, mz0 + hh, hw, hsz - hh], [mx0 + hw, mz0 + hh, wsz - hw, hsz - hh]]
	elif wsz > 1:
		rects = [[mx0, mz0, hw, hsz], [mx0 + hw, mz0, wsz - hw, hsz]]
	else:
		rects = [[mx0, mz0, wsz, hh], [mx0, mz0 + hh, wsz, hsz - hh]]

	var children: Array[int] = []
	var box := AABB()
	var first := true
	for r in rects:
		if r[2] <= 0 or r[3] <= 0:
			continue
		var ch: int = _qt_build_node(r[0], r[1], r[2], r[3], macro_cx)
		children.append(ch)
		if first:
			box = _qt_aabb[ch]
			first = false
		else:
			box = box.merge(_qt_aabb[ch])
	_qt_child[node_id] = children
	_qt_aabb[node_id]  = box
	return node_id


# Threaded worker: builds internal node n's coarse merged mesh straight from the heightmap
# over its whole footprint, sampled at _qt_step[n], with a skirt to hide cross-LOD seams.
func _qt_node_worker(n: int) -> void:
	var r: Vector4i = _qt_rect[n]
	var data := _compute_chunk_data(r.x, r.y, r.z, r.w, _qt_step[n], 0, 0, 0, 0, QT_SKIRT)
	if data.is_empty():
		return
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data[0])
	_qt_node_results[n] = am


# Per-frame entry point: descend the tree to pick what renders, then diff the
# selection against what's currently shown. do_lod (throttled) also reassigns
# per-chunk LOD and rebuilds stale seam-stitched meshes.
func _qt_update(do_lod: bool) -> void:
	if not _qt_built or not _cam:
		return
	var frustum := _cam.get_frustum()
	var cam := _cam.global_position
	# Base slack (a macro half-footprint) so chunks don't pop at the screen edge.
	# frustum_margin tightens (<0) or loosens (>0) it as a ratio — the OLD formula
	# multiplied it by the camera's LOCAL XZ pos (≈0 on a spring arm), so it did nothing.
	var margin := chunk_size * MACRO_SIZE * 0.5 * (1.0 + frustum_margin)
	# Range cull: nodes whose nearest XZ point is past this are hidden without a
	# frustum test (fog hides them anyway). + a macro footprint of slack.
	var max_d := max_render_distance + chunk_size * MACRO_SIZE
	_qt_des_macros.clear()
	_qt_des_chunks.clear()
	_qt_des_nodes.clear()
	_qt_descend(0, frustum, cam, margin, max_d * max_d)
	_qt_apply(do_lod)
	# Free chunk nodes for macros the camera has left (throttled — runs with LOD).
	if do_lod:
		_qt_evict_far(cam)


func _qt_descend(node: int, frustum: Array[Plane], cam: Vector3, margin: float, max_d2: float) -> void:
	var world_aabb: AABB = global_transform * _qt_aabb[node]
	if _aabb_xz_dist2(world_aabb, cam) > max_d2:
		return                                   # whole subtree beyond render range
	if enable_frustum_culling and not _aabb_in_frustum(world_aabb, frustum, margin):
		return                                   # whole subtree off-screen — never descended
	var mi: int = _qt_macro[node]
	if mi >= 0:
		# Leaf macro: far → render merged macro mesh; near → expand into individual chunks.
		var center := world_aabb.position + world_aabb.size * 0.5
		var dx := cam.x - center.x
		var dz := cam.z - center.z
		if dx * dx + dz * dz >= lod_distance_1 * lod_distance_1:
			_qt_des_macros[mi] = true
		else:
			_qt_expand_macro(mi, frustum, cam, margin, max_d2)
	else:
		# Internal node: if far enough that its coarse mesh is good enough, render it and
		# stop (one big low-poly mesh for the whole subtree). Otherwise descend for detail.
		var nearest := sqrt(_aabb_xz_dist2(world_aabb, cam))
		if nearest >= _qt_size[node] * QT_QUALITY:
			_qt_des_nodes[node] = true
		else:
			for ch in _qt_child[node]:
				_qt_descend(ch, frustum, cam, margin, max_d2)


# A near macro renders as individual chunks. If its chunks aren't instantiated yet,
# request them (they stream in on background threads) and show the merged macro mesh in
# the meantime — no gap. Once resident, frustum/range-cull each chunk and pick its LOD.
func _qt_expand_macro(mi: int, frustum: Array[Plane], cam: Vector3, margin: float, max_d2: float) -> void:
	if not _resident_set.has(mi):
		_request_resident(mi)
		_qt_des_macros[mi] = true   # cover the region with the macro mesh until chunks arrive
		return
	for ci in _macro_to_chunks[mi]:
		if ci < 0 or ci >= _chunk_instances.size() or not _chunk_instances[ci]:
			continue
		var world_aabb: AABB = global_transform * _chunk_aabbs[ci]
		if _aabb_xz_dist2(world_aabb, cam) > max_d2:
			continue
		if enable_frustum_culling and not _aabb_in_frustum(world_aabb, frustum, margin):
			continue
		var center := world_aabb.position + world_aabb.size * 0.5
		var dx := cam.x - center.x
		var dz := cam.z - center.z
		var lod := 0
		if enable_lod and dx * dx + dz * dz >= lod_distance_0 * lod_distance_0:
			lod = 1
		_qt_des_chunks[ci] = lod


# Diffs the freshly-descended selection against what's currently rendered and toggles
# only the instances that changed. do_lod additionally commits per-chunk LOD and
# rebuilds any chunk whose seam-stitch signature went stale.
func _qt_apply(do_lod: bool) -> void:
	# ── Coarse internal nodes (the far, low-poly representation) ───────────────
	for node in _qt_des_nodes:
		var ninst: MeshInstance3D = _qt_inst[node]
		if ninst:
			ninst.visible = not _occluded_nodes.has(node)   # far mesh hidden if behind terrain
	for node in _qt_cur_nodes:
		if not _qt_des_nodes.has(node):
			var ninst2: MeshInstance3D = _qt_inst[node]
			if ninst2:
				ninst2.visible = false
	_qt_cur_nodes = _qt_des_nodes.duplicate()

	# ── Macros ────────────────────────────────────────────────────────────────
	for mi in _qt_des_macros:
		if not _qt_cur_macros.has(mi):
			_macro_active[mi] = true
			# The macro now owns this region — hide any individual chunks under it.
			for ci in _macro_to_chunks[mi]:
				if ci >= 0 and ci < _chunk_instances.size() and _chunk_instances[ci]:
					_chunk_instances[ci].visible = false
				_qt_cur_chunks.erase(ci)
		_macro_instances[mi].visible = not _occluded_macros.has(mi)
	for mi in _qt_cur_macros:
		if not _qt_des_macros.has(mi):
			_macro_active[mi] = false
			_macro_instances[mi].visible = false
	_qt_cur_macros = _qt_des_macros.duplicate()

	# ── Chunks ────────────────────────────────────────────────────────────────
	if do_lod:
		for ci in _qt_des_chunks:
			_chunk_lod[ci] = _qt_des_chunks[ci]
	for ci in _qt_des_chunks:
		var inst: MeshInstance3D = _chunk_instances[ci]
		if inst:
			inst.visible = not _occluded_chunks.has(ci)
	for ci in _qt_cur_chunks:
		if not _qt_des_chunks.has(ci):
			if ci < _chunk_instances.size() and _chunk_instances[ci]:
				_chunk_instances[ci].visible = false
	_qt_cur_chunks = _qt_des_chunks.duplicate()

	# ── Seam-stitch rebuilds over the active chunk set only (throttled) ────────
	# _chunk_lod is now current for every visible chunk, so _stitch_signature reflects
	# neighbour LODs (including step=4 for chunks inside an active macro). Rebuild only
	# the chunks whose signature changed — usually none once the view settles.
	if do_lod:
		var mat := _get_material()
		for ci in _qt_cur_chunks:
			if ci >= _chunk_instances.size() or not _chunk_instances[ci]:
				continue
			if _chunk_stitch_sig[ci] != _stitch_signature(ci):
				_apply_lod_mesh(ci, mat)


# Squared XZ distance from point p to the nearest point of aabb (0 if p is inside in XZ).
func _aabb_xz_dist2(aabb: AABB, p: Vector3) -> float:
	var minx := aabb.position.x
	var maxx := aabb.position.x + aabb.size.x
	var minz := aabb.position.z
	var maxz := aabb.position.z + aabb.size.z
	var dx := maxf(maxf(minx - p.x, p.x - maxx), 0.0)
	var dz := maxf(maxf(minz - p.z, p.z - maxz), 0.0)
	return dx * dx + dz * dz


# ── Chunk residency: stream individual chunks in/out as the camera moves ──────

# True once every (in-range) chunk of macro mi has been instantiated.
func _macro_all_present(mi: int) -> bool:
	for ci in _macro_to_chunks[mi]:
		if ci >= 0 and ci < _chunk_instances.size() and _chunk_instances[ci] == null:
			return false
	return true


# Queue macro mi's missing chunks for a background (re)build. Cheap and idempotent:
# already-present or already-queued chunks are skipped, so calling it every frame while
# the camera sits near a not-yet-resident macro costs almost nothing.
func _request_resident(mi: int) -> void:
	var added := false
	for ci in _macro_to_chunks[mi]:
		if ci < 0 or ci >= _chunk_instances.size():
			continue
		if _chunk_instances[ci] == null and not _queued_chunks.has(ci):
			_queued_chunks[ci] = true
			_stream_queue.append(ci)
			added = true
	if added:
		_is_streaming = true


# Free macro mi's individual chunk nodes + meshes. The macro mesh keeps covering the
# region, so nothing visually disappears — this just reclaims the memory.
func _evict_macro(mi: int) -> void:
	for ci in _macro_to_chunks[mi]:
		if ci < 0 or ci >= _chunk_instances.size():
			continue
		if _chunk_instances[ci]:
			_chunk_instances[ci].queue_free()
			_chunk_instances[ci] = null
		if ci < _chunk_meshes.size():
			_chunk_meshes[ci] = null
		_qt_cur_chunks.erase(ci)
		_queued_chunks.erase(ci)
	_resident_set.erase(mi)


# Evicts every resident macro whose centre is well beyond the expand ring. Iterates only
# the (small) resident set, and the QT_EVICT_MARGIN hysteresis stops a macro right at the
# boundary from thrashing load↔evict as the camera jitters.
func _qt_evict_far(cam: Vector3) -> void:
	if _resident_set.is_empty():
		return
	var evict_r  := lod_distance_1 + QT_EVICT_MARGIN
	var evict_d2 := evict_r * evict_r
	var to_evict: Array[int] = []
	for mi in _resident_set:
		var c := global_transform * _macro_aabbs[mi].get_center()
		var dx := cam.x - c.x
		var dz := cam.z - c.z
		if dx * dx + dz * dz > evict_d2:
			to_evict.append(mi)
	for mi in to_evict:
		_evict_macro(mi)




# ─────────────────────────────────────────────────────────────────────────────
# Software occlusion culling  (runtime only)
# ─────────────────────────────────────────────────────────────────────────────

# Periodic occlusion pass.  Iterates every frustum-visible chunk / active macro
# group, tests it with _is_aabb_occluded, and updates MeshInstance3D.visible
# only when the occluded/clear state flips (minimises property-write overhead).
#
# Results are stored in _occluded_chunks / _occluded_macros; frustum culling
# reads those dicts when it sets visibility, so the two systems cooperate without
# one overwriting the other's work.
func _update_occlusion() -> void:
	if not _cam:
		return

	# One affine_inverse per frame — all chunk AABBs live in local space
	var cam_local := global_transform.affine_inverse() * _cam.global_position

	var new_occ_chunks := {}
	var new_occ_macros  := {}
	var new_occ_nodes   := {}

	# ── Individual chunks ─────────────────────────────────────────────────────
	# When frustum culling is on, only test the quadtree's currently-visible chunks
	# (saves CPU). When off, iterate all because _qt_cur_chunks may be empty.
	var chunks_to_test: Array
	if enable_frustum_culling:
		chunks_to_test = _qt_cur_chunks.keys()
	else:
		chunks_to_test = range(_chunk_instances.size())

	for ci in chunks_to_test:
		if ci >= _chunk_aabbs.size():
			continue
		if not _chunk_instances[ci]:   # not yet streamed in
			continue
		# Chunks in an active macro group are covered by the macro test below
		if _chunk_macro_idx.size() > ci and _macro_active[_chunk_macro_idx[ci]]:
			continue
		if _is_aabb_occluded(_chunk_aabbs[ci], cam_local):
			new_occ_chunks[ci] = true

	# ── Active macro groups ───────────────────────────────────────────────────
	for mi in _macro_instances.size():
		if not _macro_active[mi]:
			continue
		if _is_aabb_occluded(_macro_aabbs[mi], cam_local):
			new_occ_macros[mi] = true

	# ── Far coarse quadtree meshes ────────────────────────────────────────────
	# The far, low-poly representation behind a ridge was still being drawn; test it too.
	for node in _qt_cur_nodes:
		if node < _qt_aabb.size() and _is_aabb_occluded(_qt_aabb[node], cam_local):
			new_occ_nodes[node] = true

	# ── Apply visibility — only when the occluded/clear state changes ─────────
	for ci in chunks_to_test:
		if ci >= _chunk_instances.size():
			continue
		if not _chunk_instances[ci]:   # not yet streamed in
			continue
		if _chunk_macro_idx.size() > ci and _macro_active[_chunk_macro_idx[ci]]:
			continue
		var was := _occluded_chunks.has(ci)
		var now  := new_occ_chunks.has(ci)
		if was != now:
			var in_frustum := not enable_frustum_culling or _qt_cur_chunks.has(ci)
			_chunk_instances[ci].visible = in_frustum and not now

	for mi in _macro_instances.size():
		if not _macro_active[mi]:
			continue
		var was := _occluded_macros.has(mi)
		var now  := new_occ_macros.has(mi)
		if was != now:
			if enable_frustum_culling:
				# Re-confirm frustum: don't accidentally un-hide a macro outside the view
				var world_aabb := global_transform * _macro_aabbs[mi]
				var frustum    := _cam.get_frustum()
				var margin     := chunk_size * MACRO_SIZE * 0.5 * (1.0 + frustum_margin)
				_macro_instances[mi].visible = _aabb_in_frustum(world_aabb, frustum, margin) and not now
			else:
				_macro_instances[mi].visible = not now

	# Coarse nodes: flip visibility only when occluded/clear state changed (and the node
	# is still in view this frame — _qt_cur_nodes is the current rendered set).
	for node in _qt_cur_nodes:
		var was_n := _occluded_nodes.has(node)
		var now_n := new_occ_nodes.has(node)
		if was_n != now_n and node < _qt_inst.size() and _qt_inst[node]:
			_qt_inst[node].visible = not now_n

	_occluded_chunks = new_occ_chunks
	_occluded_macros = new_occ_macros
	_occluded_nodes  = new_occ_nodes


# Restores full frustum-based visibility for every previously-occluded object.
# Called once when enable_occlusion_culling is toggled off at runtime.
func _clear_occlusion() -> void:
	for ci in _occluded_chunks:
		if ci >= _chunk_instances.size():
			continue
		if not _chunk_instances[ci]:   # not yet streamed in
			continue
		if _chunk_macro_idx.size() > ci and _macro_active[_chunk_macro_idx[ci]]:
			continue
		_chunk_instances[ci].visible = _qt_cur_chunks.has(ci) or not enable_frustum_culling
	for mi in _occluded_macros:
		if mi >= _macro_instances.size() or not _macro_active[mi]:
			continue
		if enable_frustum_culling:
			var world_aabb := global_transform * _macro_aabbs[mi]
			var frustum    := _cam.get_frustum()
			var margin     := chunk_size * MACRO_SIZE * 0.5 * (1.0 + frustum_margin)
			_macro_instances[mi].visible = _aabb_in_frustum(world_aabb, frustum, margin)
		else:
			_macro_instances[mi].visible = true
	# Restore far coarse meshes that occlusion had hidden (only those still in the cut).
	for node in _occluded_nodes:
		if node < _qt_inst.size() and _qt_inst[node]:
			_qt_inst[node].visible = _qt_cur_nodes.has(node)
	_occluded_chunks.clear()
	_occluded_macros.clear()
	_occluded_nodes.clear()


# Returns true when the given local-space AABB is fully hidden behind terrain
# as seen from cam_local (also in local space).
#
# Algorithm — elevation angle / terrain horizon method:
#   Cast an XZ ray from the camera toward the chunk's AABB centre.
#   For each heightmap sample along the ray compute:
#       terrain_angle = atan2(terrain_height − cam_y, horizontal_dist)
#   Track max_terrain_angle across all samples.
#   Separately compute:
#       chunk_angle = atan2(aabb_top + occlusion_bias − cam_y, dist_to_chunk)
#   If max_terrain_angle > chunk_angle the terrain horizon is above the chunk
#   top → the chunk cannot be seen → return true.
#
# The occlusion_bias term raises the effective target so only terrain that
# clearly dominates the skyline triggers culling, reducing false-positives
# (popping) when the camera barely grazes a ridge.
func _is_aabb_occluded(aabb: AABB, cam_local: Vector3) -> bool:
	# Guard: w must be positive and md must be populated before we read it.
	# md is refreshed by update_chunks() but w/d are @onready — they can
	# temporarily disagree with md.size() after a map resize.  Derive the
	# actual row-count from the live array so clampi stays within real bounds.
	var md_size = md.size()
	if md_size == 0 or w <= 0:
		return false
	var actual_d = md_size / w          # real depth regardless of stale d
	if actual_d <= 0:
		return false

	var center  := aabb.get_center()
	var dx      := center.x - cam_local.x
	var dz      := center.z - cam_local.z
	var dist_xz := sqrt(dx * dx + dz * dz)

	if dist_xz < occlusion_min_dist:
		return false

	# Biased AABB top — the target elevation we try to see over
	var target_y := aabb.position.y + aabb.size.y + occlusion_bias

	# Camera already above chunk top → always visible from above
	if cam_local.y >= target_y:
		return false

	# Elevation angle from the camera to the (biased) chunk top
	var chunk_angle := atan2(target_y - cam_local.y, dist_xz)

	var inv_dist := 1.0 / dist_xz
	var dir_x    := dx * inv_dist
	var dir_z    := dz * inv_dist

	var max_terrain_angle := -PI * 0.5   # start maximally below the horizon

	# Sample at t ∈ [10 %, 90 %] of the distance so we skip the camera's own
	# foot and the chunk's own geometry, reading only the terrain between them.
	for si in range(1, occlusion_samples):
		var t           := float(si) / float(occlusion_samples) * 0.9
		var sample_dist := t * dist_xz

		var lx := cam_local.x + dir_x * sample_dist
		var lz := cam_local.z + dir_z * sample_dist

		# local coords → heightmap grid indices
		# Vertex formula: pos = Vector3(x − w*0.5 + 0.5, h, z − d*0.5 + 0.5)
		# Inverse: x = lx + w*0.5 − 0.5
		# Use actual_d (derived from md.size()) instead of cached d to avoid
		# stale-cache OOB when the map was resized after _ready().
		var hx  := clampi(int(round(lx + float(w)        * 0.5 - 0.5)), 0, w        - 1)
		var hz  := clampi(int(round(lz + float(actual_d) * 0.5 - 0.5)), 0, actual_d - 1)
		var idx = hz * w + hx
		# Final safety net — prevents any remaining edge-case OOB
		if idx < 0 or idx >= md_size:
			continue

		var terrain_h     := float(md[idx])
		var terrain_angle := atan2(terrain_h - cam_local.y, sample_dist)

		if terrain_angle > max_terrain_angle:
			max_terrain_angle = terrain_angle

	# Terrain horizon is above the chunk top → chunk is occluded
	return max_terrain_angle > chunk_angle


func _aabb_in_frustum(aabb: AABB, frustum: Array[Plane], margin: float) -> bool:
	var bmin = aabb.position
	var bmax = aabb.position + aabb.size
	for plane in frustum:
		var nx = bmin.x if plane.normal.x >= 0.0 else bmax.x
		var ny = bmin.y if plane.normal.y >= 0.0 else bmax.y
		var nz = bmin.z if plane.normal.z >= 0.0 else bmax.z
		if plane.distance_to(Vector3(nx, ny, nz)) > margin:
			return false
	return true
