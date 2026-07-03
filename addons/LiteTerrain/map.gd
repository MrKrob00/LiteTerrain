# map.gd
@tool
@icon("res://addons/LiteTerrain/lite_terrain.svg")
class_name LiteTerrain
extends StaticBody3D

@export var camera: Camera3D
@export_range(-0.5, 0.5, 0.01) var frustum_margin: float = 0.05
@export var enable_frustum_culling: bool = true
## Run AABB frustum tests on worker threads — main thread never blocks.
## Results arrive with ~1 frame latency (imperceptible). Disable on platforms
## with unreliable WorkerThreadPool or for debugging.
@export var enable_threaded_frustum: bool = true

# ── Occlusion culling settings ────────────────────────────────────────────────
## Hide chunks whose AABB top sits below the terrain horizon seen from the camera.
## Uses the elevation-angle (horizon) method: samples the heightmap along the
## XZ ray from the camera to each chunk and tracks the maximum terrain angle.
## If the terrain horizon exceeds the angle to the chunk top, the chunk is occluded.
@export var enable_occlusion_culling: bool = true
## XZ distance (world units) below which chunks are never occlusion-culled.
## Keeps nearby chunks always visible regardless of geometry.
@export_range(0.0, 200.0, 1.0) var occlusion_min_dist: float = 40.0
## Added to the chunk AABB top before the horizon test.
## Raises the occluder bar so only clearly dominant ridges trigger culling;
## prevents popping when the camera nearly grazes a ridge line.
@export_range(0.0, 10.0, 0.5) var occlusion_bias: float = 1.5
## Heightmap samples taken along each camera→chunk ray.
## More samples = fewer missed occluders, more CPU cost.
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
const LOD_STEPS: Array[int] = [1, 2, 4, 8]
const LOD_COUNT: int        = 4

# How often (seconds) the LOD check runs — no need every frame
const LOD_UPDATE_INTERVAL: float = 0.15

# ── Streaming settings ────────────────────────────────────────────────────────
## Chunks within this XZ radius (world units) are meshed immediately at startup.
## Chunks outside it are queued and streamed in during gameplay via _process().
@export_range(20.0, 500.0, 10.0) var stream_initial_radius: float = 100.0
## How many chunks are meshed per streaming batch. Lower = fewer frame hitches.
@export_range(4, 128, 4) var stream_batch_size: int = 32

# ── Macro-chunk settings ──────────────────────────────────────────────────────
# Groups of MACRO_SIZE×MACRO_SIZE individual chunks are merged into one
# MeshInstance3D (shadows OFF) for dist ≥ lod_distance_1.
# 4×4 = 16 chunks → 1 draw call instead of 16 (+ saves ~16 shadow passes).
const MACRO_SIZE: int = 4

# Resolved in _refresh_refs(); a bare LiteTerrain node (no children yet)
# must not hard-crash, so no @onready $-lookups here.
var collision:     CollisionShape3D = null
var mesh_instance: MeshInstance3D   = null

# Heightmap resolution used when the editor auto-creates the shape.
# 257 = 16×16 chunks of chunk_size 16 (chunks span width-1 cells).
const DEFAULT_MAP_SIZE: int = 257

# ── Runtime chunk state ───────────────────────────────────────────────────────
var _chunk_instances: Array[MeshInstance3D] = []
var _chunk_aabbs:    Array[AABB]           = []

# _chunk_meshes[i][lod] → ArrayMesh (or null for degenerate chunks)
# Pre-built for all 4 LOD levels at startup; no runtime rebuild needed.
var _chunk_meshes:   Array = []

# Current LOD level that is actually displayed for each chunk
var _chunk_lod:      Array[int] = []

var _chunks_x:      int = 0
var _visible_chunks: Dictionary = {}
var _frontier:       Dictionary = {}
var frustum_old
var _lod_timer:     float = 0.0

# ── Occlusion culling runtime state ──────────────────────────────────────────
const OCCLUSION_UPDATE_INTERVAL: float = 0.20   # seconds between full occlusion passes
var _occlusion_timer: float = 0.0
var _occluded_chunks: Dictionary = {}           # ci → true  (passed frustum, failed occlusion)
var _occluded_macros: Dictionary = {}           # mi → true

# ── Async frustum culling state (WorkerThreadPool) ────────────────────────────
# Pattern: main thread snapshots frustum+transform → workers test all AABBs in
# parallel → main thread applies visibility changes next frame.
# _chunk_aabbs must NOT be written while _ft_group_id ≥ 0 (update_chunks waits).
var _ft_snap_frustum: Array[Plane] = []         # captured on main thread, read-only by workers
var _ft_snap_gt:      Transform3D  = Transform3D()
var _ft_snap_margin:  float        = 0.0
var _ft_results:      PackedByteArray = PackedByteArray()  # 1=in frustum, 0=out
var _ft_group_id:     int          = -1         # -1 = no task in flight
var _ft_chunk_count:  int          = 0          # snapshot of _chunk_aabbs.size() at dispatch

# ── Streaming runtime state ───────────────────────────────────────────────────
# Chunks outside stream_initial_radius are queued here and built in background.
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

# ── Editor chunk cache ────────────────────────────────────────────────────────
# The editor uses a single MeshInstance3D with one surface per chunk.
# Editor always renders LOD 0 (full resolution) for accurate sculpting.
var _ed_cache: Array = []
var _ed_cx:    int   = 0

# ── LOD material cache ────────────────────────────────────────────────────────
# Two static material variants replace per-instance shader parameters.
# set_instance_shader_parameter() allocates a slot in the global_shader_variables
# buffer (GLES3 limit: 4096). With hundreds of chunks this overflows instantly.
# Swapping materials uses zero buffer slots and costs nothing at runtime.
var _mat_lod0:     Material = null  # lod_grass_enabled = 1.0  (LOD 0, close)
var _mat_lod_high: Material = null  # lod_grass_enabled = 0.0  (LOD 1+, distant)

# ─────────────────────────────────────────────────────────────────────────────
# Cached heightmap dimensions/data — refreshed by _refresh_refs() because the
# plugin swaps shape.map_data through undo/redo after _ready() has run.
var w:  int = 0
var d:  int = 0
var md: PackedFloat32Array = PackedFloat32Array()

# ─────────────────────────────────────────────────────────────────────────────
# Ready
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	if Engine.is_editor_hint():
		# Deferred: children cannot be added while the parent scene is still
		# setting up (Create Node dialog / instantiation path).
		_editor_setup.call_deferred()
		return
	if not _refresh_refs():
		push_warning("LiteTerrain: node needs a CollisionShape3D child with a HeightMapShape3D and a MeshInstance3D child")
		return
	mesh_instance.visible = false
	await get_tree().process_frame
	_chunks_x = ceili(float(collision.shape.map_width - 1) / chunk_size)
	if not camera:
		camera = _find_game_camera()
	await _build_chunks_from_map_data()
	if camera:
		_full_scan()


# Resolve child references and cache heightmap dimensions.
# Returns false while the node is not fully set up yet.
func _refresh_refs() -> bool:
	if collision == null or not is_instance_valid(collision):
		collision = get_node_or_null("CollisionShape3D")
	if mesh_instance == null or not is_instance_valid(mesh_instance):
		mesh_instance = get_node_or_null("MeshInstance3D")
	if collision == null or mesh_instance == null:
		return false
	if collision.shape == null or not (collision.shape is HeightMapShape3D):
		return false
	w  = collision.shape.map_width
	d  = collision.shape.map_depth
	md = collision.shape.map_data
	return true


# Editor-only: create any missing children so a bare LiteTerrain node
# (from the Create Node dialog or the dock button) works out of the box.
func _editor_setup() -> void:
	if not is_inside_tree():
		return
	collision = get_node_or_null("CollisionShape3D")
	mesh_instance = get_node_or_null("MeshInstance3D")

	if collision == null:
		collision = CollisionShape3D.new()
		collision.name = "CollisionShape3D"
		add_child(collision)
	if collision.shape == null:
		var hm := HeightMapShape3D.new()
		hm.map_width = DEFAULT_MAP_SIZE
		hm.map_depth = DEFAULT_MAP_SIZE
		var flat := PackedFloat32Array()
		flat.resize(DEFAULT_MAP_SIZE * DEFAULT_MAP_SIZE)
		hm.map_data = flat
		collision.shape = hm

	if mesh_instance == null:
		mesh_instance = MeshInstance3D.new()
		mesh_instance.name = "MeshInstance3D"
		var mat_path := (get_script() as Script).resource_path.get_base_dir().path_join("terrain_shader.res")
		if ResourceLoader.exists(mat_path):
			mesh_instance.material_override = load(mat_path)
		add_child(mesh_instance)

	# Persist auto-created children in the edited scene
	var root := get_tree().edited_scene_root
	if root != null and (root == self or root.is_ancestor_of(self)):
		if collision.owner == null:
			collision.owner = root
		if mesh_instance.owner == null:
			mesh_instance.owner = root

	update()


# ─────────────────────────────────────────────────────────────────────────────
# Public API  (called by plugin.gd)
# ─────────────────────────────────────────────────────────────────────────────

# Full rebuild — call after noise generation or on first open.
func update() -> void:
	if not is_node_ready() or not _refresh_refs():
		return
	if md.size() == 0:
		return
	if Engine.is_editor_hint():
		_rebuild_editor_full()

# Partial update — only rebuild the listed chunk indices.
# In the editor this is the hot path on every sculpt stroke.
func update_chunks(chunk_indices: Array) -> void:
	# If a frustum task is in flight it holds read references to _chunk_aabbs.
	# Wait for it to finish before we write new AABB data (avoids data race).
	if _ft_group_id >= 0:
		WorkerThreadPool.wait_for_group_task_completion(_ft_group_id)
		_ft_group_id = -1
	if not _refresh_refs():        # also refreshes the md/w/d cache (see update())
		return
	if Engine.is_editor_hint():
		if _ed_cache.is_empty():
			update()
			return
		for ci in chunk_indices:
			if ci < 0 or ci >= _ed_cache.size():
				continue
			_ed_cache[ci] = _chunk_surface_arrays(ci % _ed_cx, ci / _ed_cx)
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
			_macro_instances[mi].set_surface_override_material(0, mat)

func get_chunk_info() -> Dictionary:
	return {
		"chunk_size": chunk_size,
		"chunks_x":   ceili(float(collision.shape.map_width  - 1) / chunk_size),
		"map_width":  collision.shape.map_width,
		"map_depth":  collision.shape.map_depth,
	}


# ─────────────────────────────────────────────────────────────────────────────
# Editor chunk cache internals
# ─────────────────────────────────────────────────────────────────────────────

func _rebuild_editor_full() -> void:
	_ed_cx = ceili(float(w - 1) / chunk_size)
	var _ed_cz := ceili(float(d - 1) / chunk_size)
	_ed_cache.resize(_ed_cx * _ed_cz)
	for cz in _ed_cz:
		for cx in _ed_cx:
			_ed_cache[cz * _ed_cx + cx] = _chunk_surface_arrays(cx, cz)
	_apply_editor_cache()

# Editor always uses full resolution (step=1) so sculpting looks correct.
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
	var v_offset    := 0

	for arr in _ed_cache:
		if arr == null or arr.is_empty():
			continue
		var verts   := arr[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var idxs    := arr[Mesh.ARRAY_INDEX]  as PackedInt32Array
		var normals := arr[Mesh.ARRAY_NORMAL] as PackedVector3Array
		var uvs     := arr[Mesh.ARRAY_TEX_UV] as PackedVector2Array
		if verts == null or verts.is_empty():
			continue
		all_verts.append_array(verts)
		all_normals.append_array(normals)
		all_uvs.append_array(uvs)
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

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged)
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
#   Mesh data generated in parallel across all CPU cores for chunks within
#   stream_initial_radius. Same thread-safety contract as before: reads md/w/d
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

	# ── Sort all chunks by XZ distance from camera ────────────────────────────
	var cam_pos := camera.global_position if camera else Vector3.ZERO
	var sorted  := range(total)
	sorted.sort_custom(func(a: int, b: int) -> bool:
		var ax := (a % cxl + 0.5) * chunk_size - float(w) * 0.5
		var az := (a / cxl + 0.5) * chunk_size - float(d) * 0.5
		var bx := (b % cxl + 0.5) * chunk_size - float(w) * 0.5
		var bz := (b / cxl + 0.5) * chunk_size - float(d) * 0.5
		return (ax - cam_pos.x) * (ax - cam_pos.x) + (az - cam_pos.z) * (az - cam_pos.z) \
			 < (bx - cam_pos.x) * (bx - cam_pos.x) + (bz - cam_pos.z) * (bz - cam_pos.z))

	# ── Split: immediate (near camera) vs deferred (stream later) ────────────
	var initial: Array[int] = []
	var r2 := stream_initial_radius * stream_initial_radius
	for ci in sorted:
		var ax = (ci % cxl + 0.5) * chunk_size - float(w) * 0.5
		var az = (ci / cxl + 0.5) * chunk_size - float(d) * 0.5
		if (ax - cam_pos.x) * (ax - cam_pos.x) + (az - cam_pos.z) * (az - cam_pos.z) <= r2:
			initial.append(ci)
		else:
			_stream_queue.append(ci)

	# ── Phase 1: parallel full mesh build for initial (near-camera) chunks ────
	if not initial.is_empty():
		var build_task := func(i: int) -> void:
			_build_chunk_worker(initial[i], cxl)
		var gid := WorkerThreadPool.add_group_task(build_task, initial.size(), -1, true)
		WorkerThreadPool.wait_for_group_task_completion(gid)

	# ── Phase 2: create nodes on the main thread ──────────────────────────────
	var mat := _get_material()
	if _mat_lod0 == null:
		_setup_lod_materials(mat)
	_apply_built_results(initial, mat)

	# Macro system already knows all AABBs from Phase 0, so the group structure
	# is built for the full map. Unbuilt chunks contribute no geometry yet
	# (_build_macro_mesh guards for null meshes); their macro meshes are rebuilt
	# incrementally as _stream_apply_batch fills them in.
	_build_macro_chunks()

	_is_streaming = not _stream_queue.is_empty()


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
# MUST run on the main thread — adds nodes to the scene tree.
# Also classifies each new chunk into _visible_chunks or _frontier based on the
# current camera frustum, so it integrates seamlessly into the culling system.
func _apply_built_results(indices: Array, mat: Material) -> void:
	for ci in indices:
		if _stream_results[ci] == null:
			continue
		var lod_meshes: Array = _stream_results[ci][0]
		var first_aabb: AABB  = _stream_results[ci][1]
		_stream_results[ci]   = null

		var inst := MeshInstance3D.new()
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		inst.visible     = false
		add_child(inst)
		_chunk_instances[ci] = inst   # fill the pre-allocated slot
		_chunk_lod[ci]       = 0
		_chunk_meshes[ci]    = lod_meshes
		# Note: _chunk_aabbs[ci] was already filled by Phase 0 with an identical
		# value (same heightmap scan); we skip the redundant write to avoid any
		# potential race if a frustum task is still in flight.

		var start_mesh := _best_available_mesh(lod_meshes, 0)
		if start_mesh:
			inst.mesh = start_mesh
			var lod_mat := _mat_lod0 if _mat_lod0 else mat
			inst.set_surface_override_material(0, lod_mat)

		if camera and enable_frustum_culling:
			var frustum := camera.get_frustum()
			var margin  := frustum_margin * (camera.position * Vector3(1, 0, 1)).length() + chunk_size
			if _aabb_in_frustum(global_transform * first_aabb, frustum, margin):
				inst.visible = true
				_visible_chunks[ci] = true
			else:
				_frontier[ci] = true
		else:
			inst.visible = false


# ─────────────────────────────────────────────────────────────────────────────
# LOD update  (runtime only)
# Runs every LOD_UPDATE_INTERVAL seconds.
#
# Step 1 — macro decision: any group whose XZ centre is ≥ lod_distance_1 from
#   the camera collapses into one merged mesh (no shadow casts, 1 draw call).
# Step 2 — individual LOD: close chunks (dist < lod_distance_1) switch between
#   LOD 0 (full res) and LOD 1 (¼ res) only.  LOD 2/3 is the macro system's job.
func _update_lod() -> void:
	if not camera:
		return

	var cam_pos := camera.global_position
	var mat     := _get_material()
	var cxl     := ceili(float(w - 1) / chunk_size)

	# ── Step 1: macro vs individual per group ─────────────────────────────────
	var macro_changed: Array[int] = []
	for mi in _macro_instances.size():
		var center     := global_transform * _macro_aabbs[mi].get_center()
		var dx         := cam_pos.x - center.x
		var dz         := cam_pos.z - center.z
		var dist       := sqrt(dx * dx + dz * dz)
		var want_macro := dist >= lod_distance_1
		if want_macro != _macro_active[mi]:
			_set_macro_mode(mi, want_macro)
			macro_changed.append(mi)

	# ── Step 2: per-chunk LOD — collect what changed ──────────────────────────
	var lod_changed: Array[int] = []
	for i in _chunk_instances.size():
		if not _chunk_instances[i]:   # not yet streamed in
			continue
		if _chunk_macro_idx.size() > i and _macro_active[_chunk_macro_idx[i]]:
			continue
		if not _chunk_instances[i].visible:
			continue

		var center     := global_transform * _chunk_aabbs[i].get_center()
		var dx         := cam_pos.x - center.x
		var dz         := cam_pos.z - center.z
		var dist       := sqrt(dx * dx + dz * dz)
		var target_lod := 1 if dist >= lod_distance_0 else 0

		if target_lod == _chunk_lod[i]:
			continue
		_chunk_lod[i] = target_lod
		lod_changed.append(i)

	if lod_changed.is_empty() and macro_changed.is_empty():
		return

	# ── Step 3: rebuild meshes with border stitching ──────────────────────────
	# Any chunk whose LOD changes, plus its LOD-0 neighbours (their seam with
	# this chunk may now need snapping added or removed).
	# Also include LOD-0 chunks on the boundary of any changed macro group.
	var to_rebuild: Dictionary = {}

	for i in lod_changed:
		to_rebuild[i] = true
		var cx := i % cxl
		var cz := i / cxl
		for off in [[0,-1],[0,1],[-1,0],[1,0]]:
			var ni := _get_chunk_idx(cx + off[0], cz + off[1])
			if ni >= 0 and ni < _chunk_lod.size() and _chunk_lod[ni] == 0:
				to_rebuild[ni] = true

	for mi in macro_changed:
		for ci in _macro_to_chunks[mi]:
			var cx: int = ci % cxl
			var cz: int = ci / cxl
			for off in [[0,-1],[0,1],[-1,0],[1,0]]:
				var ni := _get_chunk_idx(cx + off[0], cz + off[1])
				# Rebuild neighbours of ANY individual LOD (not just LOD-0) — a LOD-1
				# chunk adjacent to a macro group also needs seam stitching (step 2 vs 4).
				if ni >= 0 and ni < _chunk_lod.size() \
						and not (_chunk_macro_idx.size() > ni and _macro_active[_chunk_macro_idx[ni]]):
					to_rebuild[ni] = true

	for ci in to_rebuild:
		_apply_lod_mesh(ci, mat)


# Applies the correct mesh to chunk ci, rebuilding with border snapping when
# the chunk is at LOD 0 and any neighbour is at a coarser step.
func _apply_lod_mesh(ci: int, mat: Material) -> void:
	if ci >= _chunk_lod.size() or ci >= _chunk_instances.size() or ci >= _chunk_meshes.size():
		return   # chunk index out of range
	if not _chunk_instances[ci]:
		return   # chunk not yet streamed in
	var target_lod := _chunk_lod[ci]
	var my_step    := LOD_STEPS[target_lod]
	var cxl        := ceili(float(w - 1) / chunk_size)
	var cx         := ci % cxl
	var cz         := ci / cxl

	# Stitching applies to ANY LOD level, not just LOD-0.
	# A LOD-1 (step=2) chunk adjacent to an active macro group (step=4) also
	# produces T-junction cracks without seam snapping.
	var ns := _neighbour_step(cx, cz,  0, -1)
	var ss := _neighbour_step(cx, cz,  0,  1)
	var ws := _neighbour_step(cx, cz, -1,  0)
	var es := _neighbour_step(cx, cz,  1,  0)

	if ns > my_step or ss > my_step or ws > my_step or es > my_step:
		# Rebuild this chunk's mesh with seam-snapped border vertices
		var x0 := cx * chunk_size
		var z0 := cz * chunk_size
		var x1 := mini(x0 + chunk_size, w - 1)
		var z1 := mini(z0 + chunk_size, d - 1)
		var data := _compute_chunk_data(x0, z0, x1, z1, my_step,
				ns if ns > my_step else 0,
				ss if ss > my_step else 0,
				ws if ws > my_step else 0,
				es if es > my_step else 0)
		if not data.is_empty():
			var am := ArrayMesh.new()
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data[0])
			_chunk_instances[ci].mesh = am
			var lod_mat := (_mat_lod0 if target_lod == 0 else _mat_lod_high) if _mat_lod0 else mat
			_chunk_instances[ci].set_surface_override_material(0, lod_mat)
			return

	# No stitching needed — use the pre-built LOD mesh
	var lod_mat := (_mat_lod0 if target_lod == 0 else _mat_lod_high) if _mat_lod0 else mat
	var display_mesh := _best_available_mesh(_chunk_meshes[ci], target_lod)
	if display_mesh:
		_chunk_instances[ci].mesh = display_mesh
	_chunk_instances[ci].set_surface_override_material(0, lod_mat)


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

			# Build merged LOD-2 mesh: step=4 → ~32 tris/chunk, negligible cost.
			# Unbuilt chunks contribute no geometry (_build_macro_mesh guards for null).
			var macro_mesh := _build_macro_mesh(c_list, 2)
			var inst       := MeshInstance3D.new()
			inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			inst.visible     = false   # activated by _set_macro_mode() only
			if macro_mesh:
				inst.mesh = macro_mesh
				inst.set_surface_override_material(0, mat)
			add_child(inst)
			_macro_instances.append(inst)


# Merges the lod_level mesh of every chunk in chunk_indices into a single
# ArrayMesh with one surface → one draw call.  Returns null if no geometry.
func _build_macro_mesh(chunk_indices: Array, lod_level: int) -> ArrayMesh:
	var all_verts   := PackedVector3Array()
	var all_idx     := PackedInt32Array()
	var all_normals := PackedVector3Array()
	var all_uvs     := PackedVector2Array()
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
		if verts == null or verts.is_empty():
			continue
		all_verts.append_array(verts)
		all_normals.append_array(norms)
		all_uvs.append_array(uvs)
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

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am


# Switches macro-group mi between merged (active=true) and individual rendering.
#   active=true  → hide 16 individual instances, show 1 merged (no shadows)
#   active=false → hide merged, restore individual visibility from frustum state
func _set_macro_mode(mi: int, active: bool) -> void:
	_macro_active[mi] = active
	if active:
		for ci in _macro_to_chunks[mi]:
			if not _chunk_instances[ci]:   # not yet streamed in
				continue
			_chunk_instances[ci].visible = false
		# Frustum validity is confirmed each frame by _update_macro_visibility()
		_macro_instances[mi].visible = true
	else:
		_macro_instances[mi].visible = false
		# Restore each chunk's last-known frustum visibility (also respect occlusion)
		for ci in _macro_to_chunks[mi]:
			if not _chunk_instances[ci]:   # not yet streamed in
				continue
			_chunk_instances[ci].visible = _visible_chunks.has(ci) and not _occluded_chunks.has(ci)


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
	# Frustum workers read _chunk_aabbs concurrently. Join before any writes
	# to shared chunk data — mirrors the same guard in update_chunks().
	if _ft_group_id >= 0:
		WorkerThreadPool.wait_for_group_task_completion(_ft_group_id)
		_ft_group_id = -1
		_ft_apply()

	var mat := _get_material()
	_apply_built_results(_stream_batch, mat)

	# Rebuild merged meshes for macro groups that just received new chunks
	var dirty_macros := {}
	for ci in _stream_batch:
		if _chunk_macro_idx.size() > ci:
			dirty_macros[_chunk_macro_idx[ci]] = true
	for mi in dirty_macros:
		if mi >= _macro_instances.size():
			continue
		var macro_mesh := _build_macro_mesh(_macro_to_chunks[mi], 2)
		if macro_mesh:
			_macro_instances[mi].mesh = macro_mesh
			_macro_instances[mi].set_surface_override_material(0, mat)

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
		w_step: int = 0, e_step: int = 0) -> Array:
	var vertices  = PackedVector3Array()
	var indices   = PackedInt32Array()
	var normals   = PackedVector3Array()
	var uvs       = PackedVector2Array()
	var local_idx = {}
	var idx       = 0
	var aabb_min  = Vector3(INF,  INF,  INF)
	var aabb_max  = Vector3(-INF, -INF, -INF)

	var sz = maxi(1, step)
	var xs = _sample_range(x0, x1, sz)
	var zs = _sample_range(z0, z1, sz)

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

			# North border (z == z0): snap x to n_step grid
			if z == z0 and n_step > step:
				var rem: int = x % n_step
				if rem != 0:
					h = lerp(float(md[z * w + x - rem]),
							 float(md[z * w + x - rem + n_step]),
							 float(rem) / float(n_step))

			# South border (z == z1): snap x to s_step grid
			elif z == z1 and s_step > step:
				var rem: int = x % s_step
				if rem != 0:
					h = lerp(float(md[z * w + x - rem]),
							 float(md[z * w + x - rem + s_step]),
							 float(rem) / float(s_step))

			# West border (x == x0): snap z to w_step grid
			if x == x0 and w_step > step:
				var rem: int = z % w_step
				if rem != 0:
					h = lerp(float(md[(z - rem) * w + x]),
							 float(md[(z - rem + w_step) * w + x]),
							 float(rem) / float(w_step))

			# East border (x == x1): snap z to e_step grid
			elif x == x1 and e_step > step:
				var rem: int = z % e_step
				if rem != 0:
					h = lerp(float(md[(z - rem) * w + x]),
							 float(md[(z - rem + e_step) * w + x]),
							 float(rem) / float(e_step))

			var pos = Vector3(x - w * 0.5 + 0.5, h, z - d * 0.5 + 0.5)
			vertices.append(pos)
			aabb_min = aabb_min.min(pos)
			aabb_max = aabb_max.max(pos)
			uvs.append(Vector2(float(x) / w, float(z) / d))

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

	var arr = Array()
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = vertices
	arr[Mesh.ARRAY_INDEX]  = indices
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_TEX_UV] = uvs
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
		_mat_lod0 = base_mat.duplicate()
		(_mat_lod0 as ShaderMaterial).set_shader_parameter("lod_grass_enabled", 1.0)
		_mat_lod_high = base_mat.duplicate()
		(_mat_lod_high as ShaderMaterial).set_shader_parameter("lod_grass_enabled", 0.0)
	else:
		# StandardMaterial3D or unknown — no grass parameter, use same ref for both
		_mat_lod0    = base_mat
		_mat_lod_high = base_mat

func _get_material() -> Material:
	var mat: Material = null
	if mesh_instance.material_override != null:
		return mesh_instance.material_override
	if mesh_instance.mesh != null and mesh_instance.mesh.get_surface_count() > 0:
		mat = mesh_instance.get_surface_override_material(0)
		if mat == null:
			mat = mesh_instance.mesh.surface_get_material(0)
	if mat == null:
		mat = StandardMaterial3D.new()
	return mat


# ─────────────────────────────────────────────────────────────────────────────
# Camera / frustum culling  (runtime only)
# ─────────────────────────────────────────────────────────────────────────────

func _find_game_camera() -> Camera3D:
	for node in get_tree().root.find_children("*", "Camera3D", true, false):
		var cam = node as Camera3D
		if cam and cam.current:
			return cam
	return null

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not camera:
		camera = _find_game_camera()
		return

	# ── Background chunk streaming ────────────────────────────────────────────
	if _is_streaming:
		_stream_tick(delta)

	# ── Frustum culling ───────────────────────────────────────────────────────
	if enable_frustum_culling:
		if enable_threaded_frustum:
			# ── Async path ────────────────────────────────────────────────────
			# Step 1: if the previous task just finished, apply its results.
			if _ft_group_id >= 0 and WorkerThreadPool.is_group_task_completed(_ft_group_id):
				WorkerThreadPool.wait_for_group_task_completion(_ft_group_id)  # join (instant)
				_ft_group_id = -1
				_ft_apply()
			# Step 2: dispatch next task if none is in flight.
			# (If the previous task hasn't finished yet we simply reuse
			#  _visible_chunks from the last applied frame — zero stall.)
			if _ft_group_id < 0:
				_ft_dispatch()
		else:
			# ── Sync fallback ─────────────────────────────────────────────────
			# Drain any leftover async task before switching to sync mode.
			if _ft_group_id >= 0:
				WorkerThreadPool.wait_for_group_task_completion(_ft_group_id)
				_ft_group_id = -1
			_update_chunk_visibility()
		# Macro visibility: few AABBs, stays on main thread every frame
		_update_macro_visibility()
	else:
		# No frustum culling — show everything while still respecting macro mode and occlusion
		for i in _chunk_instances.size():
			if not _chunk_instances[i]:   # not yet streamed in
				continue
			var in_macro := _chunk_macro_idx.size() > i and _macro_active[_chunk_macro_idx[i]]
			_chunk_instances[i].visible = not in_macro and not _occluded_chunks.has(i)
		for mi in _macro_instances.size():
			_macro_instances[mi].visible = _macro_active[mi] and not _occluded_macros.has(mi)

	# ── Occlusion culling (throttled) ─────────────────────────────────────────
	if enable_occlusion_culling:
		_occlusion_timer += delta
		if _occlusion_timer >= OCCLUSION_UPDATE_INTERVAL:
			_occlusion_timer = 0.0
			_update_occlusion()
	elif not (_occluded_chunks.is_empty() and _occluded_macros.is_empty()):
		# Occlusion was just toggled off — restore full frustum-based visibility
		_clear_occlusion()

	# ── LOD update (throttled) ────────────────────────────────────────────────
	if enable_lod:
		_lod_timer += delta
		if _lod_timer >= LOD_UPDATE_INTERVAL:
			_lod_timer = 0.0
			_update_lod()

func _full_scan() -> void:
	# Cancel any in-flight async task before we rebuild _visible_chunks from scratch.
	if _ft_group_id >= 0:
		WorkerThreadPool.wait_for_group_task_completion(_ft_group_id)
		_ft_group_id = -1
	_visible_chunks.clear()
	_frontier.clear()

	if enable_threaded_frustum and camera and not _chunk_aabbs.is_empty():
		# Dispatch and wait synchronously — called once at startup, blocking is OK here.
		_ft_dispatch()
		if _ft_group_id >= 0:
			WorkerThreadPool.wait_for_group_task_completion(_ft_group_id)
			_ft_group_id = -1
			_ft_apply()
	else:
		# Original single-threaded path (fallback / no camera yet)
		if not camera:
			return
		var frustum := camera.get_frustum()
		var margin  := frustum_margin * (camera.position * Vector3(1, 0, 1)).length() + chunk_size
		for i in _chunk_instances.size():
			if not _chunk_instances[i]:   # not yet streamed in
				continue
			var world_aabb := global_transform * _chunk_aabbs[i]
			if _aabb_in_frustum(world_aabb, frustum, margin):
				_chunk_instances[i].visible = not _occluded_chunks.has(i)
				_visible_chunks[i] = true
			else:
				_chunk_instances[i].visible = false
		for i in _visible_chunks:
			for nb in _get_neighbors(i):
				if not _visible_chunks.has(nb):
					_frontier[nb] = true


# ─────────────────────────────────────────────────────────────────────────────
# Async frustum culling  —  WorkerThreadPool
# ─────────────────────────────────────────────────────────────────────────────

# Snapshot current camera state on the main thread and kick off a group task.
# Workers read _chunk_aabbs[] (read-only) and _ft_snap_frustum (read-only).
# Writes only to distinct indices of _ft_results (PackedByteArray, thread-safe).
func _ft_dispatch() -> void:
	if not camera or _chunk_aabbs.is_empty():
		return

	var new_frustum := camera.get_frustum()
	# Skip dispatch if the camera hasn't moved — results would be identical.
	if new_frustum == _ft_snap_frustum:
		return

	_ft_chunk_count  = _chunk_aabbs.size()
	_ft_snap_frustum = new_frustum          # fresh Array[Plane], kept alive by member var
	_ft_snap_gt      = global_transform
	_ft_snap_margin  = frustum_margin * (camera.position * Vector3(1, 0, 1)).length() \
					   + chunk_size
	_ft_results.resize(_ft_chunk_count)

	# Each worker call gets its own index (0…_ft_chunk_count-1).
	# bind() appends the extra args after the system-provided index.
	_ft_group_id = WorkerThreadPool.add_group_task(
			_ft_worker.bind(_ft_snap_gt, _ft_snap_frustum, _ft_snap_margin),
			_ft_chunk_count, -1, true, "frustum_cull")


# Worker — executes on a WorkerThreadPool thread.
# MUST be pure math: no scene-tree, no node property writes, no GDScript Mutex.
# Reads: _chunk_aabbs (read-only during task lifetime), bound args (read-only).
# Writes: _ft_results[idx] — each thread writes to its own unique index only.
func _ft_worker(idx: int, gt: Transform3D, frustum: Array[Plane], margin: float) -> void:
	if idx >= _chunk_aabbs.size():
		_ft_results[idx] = 0
		return
	var world_aabb := gt * _chunk_aabbs[idx]
	_ft_results[idx] = 1 if _aabb_in_frustum(world_aabb, frustum, margin) else 0


# Apply the completed task's results on the main thread.
# Mirrors the newly-visible / newly-hidden logic of _update_chunk_visibility.
func _ft_apply() -> void:
	var n := mini(_ft_results.size(), _chunk_instances.size())
	if n == 0:
		return

	var newly_visible: Array[int] = []
	var newly_hidden:  Array[int] = []

	for i in n:
		var in_frustum := _ft_results[i] != 0
		if in_frustum and not _visible_chunks.has(i):
			newly_visible.append(i)
		elif not in_frustum and _visible_chunks.has(i):
			newly_hidden.append(i)

	for i in newly_visible:
		_visible_chunks[i] = true
		_frontier.erase(i)
		if _chunk_macro_idx.size() <= i or not _macro_active[_chunk_macro_idx[i]]:
			if _chunk_instances[i]:   # guard: chunk may not be streamed in yet
				_chunk_instances[i].visible = not _occluded_chunks.has(i)
		for nb in _get_neighbors(i):
			if not _visible_chunks.has(nb):
				_frontier[nb] = true

	for i in newly_hidden:
		_visible_chunks.erase(i)
		_frontier[i] = true
		if _chunk_macro_idx.size() <= i or not _macro_active[_chunk_macro_idx[i]]:
			if _chunk_instances[i]:   # guard: chunk may not be streamed in yet
				_chunk_instances[i].visible = false
		for nb in _get_neighbors(i):
			if not _visible_chunks.has(nb):
				var has_vis := false
				for nnb in _get_neighbors(nb):
					if _visible_chunks.has(nnb):
						has_vis = true
						break
				if not has_vis:
					_frontier.erase(nb)


func _update_chunk_visibility() -> void:
	var frustum = camera.get_frustum()
	if frustum_old == frustum:
		return
	frustum_old = frustum
	var margin = frustum_margin * (camera.position * Vector3(1, 0, 1)).distance_to(Vector3.ZERO) + chunk_size

	var newly_visible = []
	var newly_hidden  = []

	for i in _frontier:
		if i >= _chunk_aabbs.size():
			continue
		var world_aabb = global_transform * _chunk_aabbs[i]
		if _aabb_in_frustum(world_aabb, frustum, margin):
			newly_visible.append(i)

	for i in _visible_chunks:
		if i >= _chunk_aabbs.size():
			continue
		var world_aabb = global_transform * _chunk_aabbs[i]
		if not _aabb_in_frustum(world_aabb, frustum, margin):
			newly_hidden.append(i)

	for i in newly_visible:
		_visible_chunks[i] = true
		_frontier.erase(i)
		# Don't show individual instances that belong to an active macro group —
		# the macro MeshInstance3D owns rendering for that region.
		if _chunk_macro_idx.size() <= i or not _macro_active[_chunk_macro_idx[i]]:
			if _chunk_instances[i]:   # guard: chunk may not be streamed in yet
				_chunk_instances[i].visible = not _occluded_chunks.has(i)
		for n in _get_neighbors(i):
			if not _visible_chunks.has(n):
				_frontier[n] = true

	for i in newly_hidden:
		if _chunk_instances[i]:   # guard: chunk may not be streamed in yet
			_chunk_instances[i].visible = false   # safe in both individual & macro modes
		_visible_chunks.erase(i)
		_frontier[i] = true
		for n in _get_neighbors(i):
			if not _visible_chunks.has(n):
				var has_visible_neighbor = false
				for nn in _get_neighbors(n):
					if _visible_chunks.has(nn):
						has_visible_neighbor = true
						break
				if not has_visible_neighbor:
					_frontier.erase(n)


# Frustum-culls macro instances independently of the individual-chunk frontier.
# One AABB check per group replaces 16 individual checks for far-away terrain.
# Called only when enable_frustum_culling is true (see _process).
func _update_macro_visibility() -> void:
	if _macro_instances.is_empty():
		return
	var frustum := camera.get_frustum()
	# Margin scaled to the macro group's XZ footprint so large groups aren't
	# clipped too aggressively near the frustum edge.
	var margin  := frustum_margin * (camera.position * Vector3(1, 0, 1)).distance_to(Vector3.ZERO) \
				   + chunk_size * MACRO_SIZE * 0.5
	for mi in _macro_instances.size():
		if not _macro_active[mi]:
			continue
		var world_aabb := global_transform * _macro_aabbs[mi]
		_macro_instances[mi].visible = _aabb_in_frustum(world_aabb, frustum, margin) \
				and not _occluded_macros.has(mi)


func _get_neighbors(i: int) -> Array:
	var neighbors = []
	var total = _chunk_instances.size()
	var cz = i / _chunks_x
	var cx = i % _chunks_x
	if cx > 0:                            neighbors.append(i - 1)
	if cx < _chunks_x - 1:               neighbors.append(i + 1)
	if cz > 0:                            neighbors.append(i - _chunks_x)
	if cz < (total / _chunks_x) - 1:     neighbors.append(i + _chunks_x)
	return neighbors


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
	if not camera:
		return

	# One affine_inverse per frame — all chunk AABBs live in local space
	var cam_local := global_transform.affine_inverse() * camera.global_position

	var new_occ_chunks := {}
	var new_occ_macros  := {}

	# ── Individual chunks ─────────────────────────────────────────────────────
	# When frustum culling is on, only test visible chunks (saves CPU).
	# When off, iterate all because _visible_chunks may be empty.
	var chunks_to_test: Array
	if enable_frustum_culling:
		chunks_to_test = _visible_chunks.keys()
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
			var in_frustum := not enable_frustum_culling or _visible_chunks.has(ci)
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
				var frustum    := camera.get_frustum()
				var margin     := frustum_margin * \
						(camera.position * Vector3(1, 0, 1)).distance_to(Vector3.ZERO) \
						+ chunk_size * MACRO_SIZE * 0.5
				_macro_instances[mi].visible = _aabb_in_frustum(world_aabb, frustum, margin) and not now
			else:
				_macro_instances[mi].visible = not now

	_occluded_chunks = new_occ_chunks
	_occluded_macros = new_occ_macros


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
		_chunk_instances[ci].visible = _visible_chunks.has(ci) or not enable_frustum_culling
	for mi in _occluded_macros:
		if mi >= _macro_instances.size() or not _macro_active[mi]:
			continue
		if enable_frustum_culling:
			var world_aabb := global_transform * _macro_aabbs[mi]
			var frustum    := camera.get_frustum()
			var margin     := frustum_margin * \
					(camera.position * Vector3(1, 0, 1)).distance_to(Vector3.ZERO) \
					+ chunk_size * MACRO_SIZE * 0.5
			_macro_instances[mi].visible = _aabb_in_frustum(world_aabb, frustum, margin)
		else:
			_macro_instances[mi].visible = true
	_occluded_chunks.clear()
	_occluded_macros.clear()


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
