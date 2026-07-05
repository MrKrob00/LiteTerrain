@tool
extends EditorPlugin

var sculpt_node     = null
var brush_radius    = 3.0
var brush_strength  = 0.1
var sculpt_mode     = "raise"
var panel           = null
var radius_slider   = null
var strength_slider = null
var mode_label      = null

var _dirty_chunks: Dictionary = {}

# ── Stroke-level undo/redo (image mode) ──────────────────────────────────────
# Image mode edits md in place — by itself it has no history. To make Ctrl+Z/Ctrl+Y behave
# sanely, snapshot the heights at the START of a stroke (button pressed) and commit ONE
# history step at the END of the stroke (button released) — not per painted pixel.
var _stroke_active := false
var _stroke_before := PackedFloat32Array()

# ── Dab spacing (throttle) ────────────────────────────────────────────────────
# _sculpt is called on EVERY mouse move, and apply_brush loops over (2r+1)² cells. With slow
# strokes or jitter that is dozens of overlapping dabs in one spot — pure wasted work.
# Apply a new dab only when the cursor has moved at least a fraction of the radius away from
# the previous one (neighbouring dabs still overlap, so coverage doesn't suffer).
const DAB_SPACING_FRAC := 0.25
var _have_last_dab := false
var _last_dab_pos  := Vector3.ZERO

# ---------- Noise generation parameters ----------
var gen_seed:             int   = 42
var gen_scale:           float  = 150.0   # continental frequency scale
var gen_octaves:          int   = 6       # FBM octaves
var gen_power:           float  = 4.0    # ^N curve: high → flat plains, sharp peaks
var gen_mountain_amount: float  = 0.8    # ridge contribution
var gen_ridge_sharpness: float  = 2.5    # how knife-sharp ridges are
var gen_amplitude:       float  = 30.0   # max height in world units
var gen_smooth:           int   = 1      # blur passes after generation
var gen_size:             int   = 0      # image-mode target size (0 = keep current)

# ─────────────────────────────────────────────────
# Helper builders
# ─────────────────────────────────────────────────
func _sep() -> HSeparator:
	var s = HSeparator.new()
	s.custom_minimum_size = Vector2(0, 6)
	return s

func _lbl(t: String) -> Label:
	var l = Label.new()
	l.text = t
	return l

func _slider(mn: float, mx: float, val: float, step: float = 0.0) -> HSlider:
	var sl = HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.value    = val
	if step > 0.0:
		sl.step = step
	return sl

# ─────────────────────────────────────────────────
# Dock UI
# ─────────────────────────────────────────────────
func _enter_tree() -> void:
	# Pull in the dock settings saved last time (brush + generation) so they don't
	# have to be set again on every session.
	_load_settings()

	# Wrap everything in a ScrollContainer so the dock is scrollable on tablets
	var scroll = ScrollContainer.new()
	scroll.name = "LiteTerrain"
	scroll.custom_minimum_size = Vector2(220, 0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	panel = VBoxContainer.new()
	panel.custom_minimum_size = Vector2(220, 0)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# ── Setup: one-click terrain node ───────────
	panel.add_child(_lbl("── Setup ──"))
	var create_btn = Button.new()
	create_btn.text = "➕ Create Terrain Node"
	create_btn.tooltip_text = "Adds a single LiteTerrain node (image mode, flat 128×128). Children are created automatically."
	create_btn.pressed.connect(_create_terrain)
	panel.add_child(create_btn)

	# ── Sculpt ──────────────────────────────────
	panel.add_child(_sep())
	panel.add_child(_lbl("── Terrain Sculpt ──"))

	panel.add_child(_lbl("Mode:"))
	mode_label = _lbl(_mode_text())
	panel.add_child(mode_label)

	var raise_btn = Button.new()
	raise_btn.text = "▲ Raise"
	raise_btn.pressed.connect(_on_raise)
	panel.add_child(raise_btn)

	var lower_btn = Button.new()
	lower_btn.text = "▼ Lower"
	lower_btn.pressed.connect(_on_lower)
	panel.add_child(lower_btn)

	var flatten_btn = Button.new()
	flatten_btn.text = "⬛ Flatten"
	flatten_btn.pressed.connect(_on_flatten)
	panel.add_child(flatten_btn)

	var radius_label = _lbl("Radius: " + str(snapped(brush_radius, 0.5)))
	panel.add_child(radius_label)
	radius_slider = _slider(1.0, 200.0, brush_radius)
	radius_slider.value_changed.connect(func(v: float) -> void:
		brush_radius = v
		radius_label.text = "Radius: " + str(snapped(v, 0.5))
	)
	radius_slider.drag_ended.connect(func(_c: bool) -> void: _save_settings())
	panel.add_child(radius_slider)

	var strength_label = _lbl("Strength: " + str(int(round(brush_strength * 1000.0))))
	panel.add_child(strength_label)
	strength_slider = _slider(1.0, 1000.0, brush_strength * 1000.0)
	strength_slider.value_changed.connect(func(v: float) -> void:
		brush_strength = v / 1000.0
		strength_label.text = "Strength: " + str(int(v))
	)
	strength_slider.drag_ended.connect(func(_c: bool) -> void: _save_settings())
	panel.add_child(strength_slider)

	# ── Noise Generation ─────────────────────────
	panel.add_child(_sep())
	panel.add_child(_lbl("── Noise Generation ──"))

	var seed_lbl = _lbl("Seed: " + str(gen_seed))
	panel.add_child(seed_lbl)
	var seed_spin = SpinBox.new()
	seed_spin.min_value = 0
	seed_spin.max_value = 99999
	seed_spin.value     = gen_seed
	seed_spin.value_changed.connect(func(v: float) -> void:
		gen_seed = int(v)
		seed_lbl.text = "Seed: " + str(gen_seed)
		_save_settings()
	)
	panel.add_child(seed_spin)

	# Scale (continental frequency)
	var scale_lbl = _lbl("Scale: " + str(int(gen_scale)))
	panel.add_child(scale_lbl)
	var scale_sl = _slider(10.0, 600.0, gen_scale)
	scale_sl.value_changed.connect(func(v: float) -> void:
		gen_scale = v
		scale_lbl.text = "Scale: " + str(int(v))
	)
	scale_sl.drag_ended.connect(func(_c: bool) -> void: _save_settings())
	panel.add_child(scale_sl)

	var oct_lbl = _lbl("Octaves: " + str(gen_octaves))
	panel.add_child(oct_lbl)
	var oct_spin = SpinBox.new()
	oct_spin.min_value = 1
	oct_spin.max_value = 8
	oct_spin.value     = gen_octaves
	oct_spin.value_changed.connect(func(v: float) -> void:
		gen_octaves = int(v)
		oct_lbl.text = "Octaves: " + str(gen_octaves)
		_save_settings()
	)
	panel.add_child(oct_spin)

	# Power curve  (^N — higher = flatter plains, sharper peaks)
	var pow_lbl = _lbl("Plains Power (^N): " + str(snapped(gen_power, 0.1)))
	panel.add_child(pow_lbl)
	var pow_sl = _slider(1.0, 8.0, gen_power, 0.1)
	pow_sl.value_changed.connect(func(v: float) -> void:
		gen_power = v
		pow_lbl.text = "Plains Power (^N): " + str(snapped(v, 0.1))
	)
	pow_sl.drag_ended.connect(func(_c: bool) -> void: _save_settings())
	panel.add_child(pow_sl)

	# Mountain ridge amount
	var mount_lbl = _lbl("Mountains: " + str(int(gen_mountain_amount * 100)) + " %")
	panel.add_child(mount_lbl)
	var mount_sl = _slider(0.0, 1.0, gen_mountain_amount, 0.01)
	mount_sl.value_changed.connect(func(v: float) -> void:
		gen_mountain_amount = v
		mount_lbl.text = "Mountains: " + str(int(v * 100)) + " %"
	)
	mount_sl.drag_ended.connect(func(_c: bool) -> void: _save_settings())
	panel.add_child(mount_sl)

	# Ridge sharpness  (higher = knife-edge ridges)
	var ridge_lbl = _lbl("Ridge Sharpness: " + str(snapped(gen_ridge_sharpness, 0.1)))
	panel.add_child(ridge_lbl)
	var ridge_sl = _slider(1.0, 8.0, gen_ridge_sharpness, 0.1)
	ridge_sl.value_changed.connect(func(v: float) -> void:
		gen_ridge_sharpness = v
		ridge_lbl.text = "Ridge Sharpness: " + str(snapped(v, 0.1))
	)
	ridge_sl.drag_ended.connect(func(_c: bool) -> void: _save_settings())
	panel.add_child(ridge_sl)

	# Amplitude (max height in world units)
	var amp_lbl = _lbl("Amplitude: " + str(int(gen_amplitude)))
	panel.add_child(amp_lbl)
	var amp_sl = _slider(1.0, 300.0, gen_amplitude)
	amp_sl.value_changed.connect(func(v: float) -> void:
		gen_amplitude = v
		amp_lbl.text = "Amplitude: " + str(int(v))
	)
	amp_sl.drag_ended.connect(func(_c: bool) -> void: _save_settings())
	panel.add_child(amp_sl)

	# Smooth passes (simple box-blur after generation)
	var smooth_lbl = _lbl("Smooth Passes: " + str(gen_smooth))
	panel.add_child(smooth_lbl)
	var smooth_spin = SpinBox.new()
	smooth_spin.min_value = 0
	smooth_spin.max_value = 12
	smooth_spin.value     = gen_smooth
	smooth_spin.value_changed.connect(func(v: float) -> void:
		gen_smooth = int(v)
		smooth_lbl.text = "Smooth Passes: " + str(gen_smooth)
		_save_settings()
	)
	panel.add_child(smooth_spin)

	# Map size (image mode only). 0 = keep the current size.
	var size_lbl = _lbl("Map Size (0 = keep): " + str(gen_size))
	panel.add_child(size_lbl)
	var size_spin = SpinBox.new()
	size_spin.min_value = 0
	size_spin.max_value = 8192
	size_spin.step      = 64
	size_spin.value     = gen_size
	size_spin.value_changed.connect(func(v: float) -> void:
		gen_size = int(v)
		size_lbl.text = "Map Size (0 = keep): " + str(gen_size)
		_save_settings()
	)
	panel.add_child(size_spin)

	var gen_btn = Button.new()
	gen_btn.text = "🌍 Generate Terrain"
	gen_btn.pressed.connect(_generate_noise)
	panel.add_child(gen_btn)

	# ── Bake → R32F heightmap image (runtime data source) ────────────────────
	panel.add_child(_sep())
	panel.add_child(_lbl("── Runtime Export ──"))
	var bake_btn = Button.new()
	bake_btn.text = "💾 Bake → files (height + mesh)"
	bake_btn.pressed.connect(_bake_heightmap)
	panel.add_child(bake_btn)

	var png_btn = Button.new()
	png_btn.text = "🖼 Generate PNG (heightmap)"
	png_btn.tooltip_text = "Exports the heightmap as a grayscale PNG (for a minimap / external editing)."
	png_btn.pressed.connect(_generate_png)
	panel.add_child(png_btn)

	var detach_btn = Button.new()
	detach_btn.text = "✂ Detach big resources from scene"
	detach_btn.pressed.connect(_detach_big_resources)
	panel.add_child(detach_btn)

	scroll.add_child(panel)
	add_control_to_dock(DOCK_SLOT_LEFT_UL, scroll)


func _exit_tree() -> void:
	# Save the dock state when the editor closes / the plugin is disabled.
	_save_settings()
	if panel:
		var scroll = panel.get_parent()
		if scroll:
			remove_control_from_docks(scroll)
			scroll.queue_free()
		else:
			remove_control_from_docks(panel)
			panel.queue_free()


# ─────────────────────────────────────────────────
# Sculpt mode callbacks
# ─────────────────────────────────────────────────
func _on_raise() -> void:
	sculpt_mode = "raise"
	mode_label.text = _mode_text()
	_save_settings()

func _on_lower() -> void:
	sculpt_mode = "lower"
	mode_label.text = _mode_text()
	_save_settings()

func _on_flatten() -> void:
	sculpt_mode = "flatten"
	mode_label.text = _mode_text()
	_save_settings()

func _mode_text() -> String:
	match sculpt_mode:
		"lower":   return "▼ Lower"
		"flatten": return "⬛ Flatten"
		_:         return "▲ Raise"


# ─────────────────────────────────────────────────
# Persist the dock's brush + generation settings across editor sessions.
# Stored in the editor's per-project metadata (.godot/, not in the repository), so every
# session picks up the previous state — no need to set everything up again.
# ─────────────────────────────────────────────────
const SETTINGS_META_SECTION := "lite_terrain"
const SETTINGS_META_KEY      := "dock_settings"

func _save_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	es.set_project_metadata(SETTINGS_META_SECTION, SETTINGS_META_KEY, {
		"brush_radius":        brush_radius,
		"brush_strength":      brush_strength,
		"sculpt_mode":         sculpt_mode,
		"gen_seed":            gen_seed,
		"gen_scale":           gen_scale,
		"gen_octaves":         gen_octaves,
		"gen_power":           gen_power,
		"gen_mountain_amount": gen_mountain_amount,
		"gen_ridge_sharpness": gen_ridge_sharpness,
		"gen_amplitude":       gen_amplitude,
		"gen_smooth":          gen_smooth,
		"gen_size":            gen_size,
	})

func _load_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	var d = es.get_project_metadata(SETTINGS_META_SECTION, SETTINGS_META_KEY, {})
	if typeof(d) != TYPE_DICTIONARY:
		return
	brush_radius        = float(d.get("brush_radius",        brush_radius))
	brush_strength      = float(d.get("brush_strength",      brush_strength))
	sculpt_mode         = str(d.get("sculpt_mode",           sculpt_mode))
	gen_seed            = int(d.get("gen_seed",              gen_seed))
	gen_scale           = float(d.get("gen_scale",           gen_scale))
	gen_octaves         = int(d.get("gen_octaves",           gen_octaves))
	gen_power           = float(d.get("gen_power",           gen_power))
	gen_mountain_amount = float(d.get("gen_mountain_amount", gen_mountain_amount))
	gen_ridge_sharpness = float(d.get("gen_ridge_sharpness", gen_ridge_sharpness))
	gen_amplitude       = float(d.get("gen_amplitude",       gen_amplitude))
	gen_smooth          = int(d.get("gen_smooth",            gen_smooth))
	gen_size            = int(d.get("gen_size",              gen_size))


# ─────────────────────────────────────────────────
# Node selection
# ─────────────────────────────────────────────────
func _handles(object) -> bool:
	return object is StaticBody3D or object is CollisionShape3D

func _edit(object) -> void:
	# Switching the selected node aborts an uncommitted stroke — so the "before" snapshot of
	# one terrain is never applied to another.
	_stroke_active = false
	_stroke_before = PackedFloat32Array()
	_have_last_dab = false
	if object is StaticBody3D:
		sculpt_node = object
	elif object is CollisionShape3D:
		sculpt_node = object.get_parent()


# ─────────────────────────────────────────────────
# Viewport input (sculpting)
# ─────────────────────────────────────────────────
func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if sculpt_node == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	# Feed the editor camera so map.gd can drive its editor LOD (editor_lod).
	if sculpt_node.has_method("set_editor_camera"):
		sculpt_node.set_editor_camera(viewport_camera)

	if event is InputEventMouseButton:
		# Wheel = brush size. The range matches the slider (1..200), otherwise scrolling would
		# reset a configured large radius down to 20. The step is proportional to the radius so
		# large brushes are reachable in a reasonable number of scroll ticks.
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			brush_radius = clamp(brush_radius + maxf(1.0, brush_radius * 0.15), 1.0, 200.0)
			radius_slider.value = brush_radius
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			brush_radius = clamp(brush_radius - maxf(1.0, brush_radius * 0.15), 1.0, 200.0)
			radius_slider.value = brush_radius
			return EditorPlugin.AFTER_GUI_INPUT_STOP

		if (event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT) and not event.pressed:
			if _dirty_chunks.size() > 0 and sculpt_node and sculpt_node.has_method("update_chunks"):
				sculpt_node.update_chunks(_dirty_chunks.keys())
				_dirty_chunks.clear()
			# The stroke is finished when the button is released and NO other brush button is held.
			var other := MOUSE_BUTTON_RIGHT if event.button_index == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_LEFT
			if not Input.is_mouse_button_pressed(other):
				_have_last_dab = false            # the next stroke starts with fresh spacing
				if _stroke_active:
					_commit_stroke_undo()
			return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseMotion or event is InputEventMouseButton:
		var left  = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		var right = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)

		if not left and not right:
			return EditorPlugin.AFTER_GUI_INPUT_PASS

		var ray_origin = viewport_camera.project_ray_origin(event.position)
		var ray_dir    = viewport_camera.project_ray_normal(event.position)

		var hit_pos
		if sculpt_node.has_method("is_image_mode") and sculpt_node.is_image_mode():
			# Image mode: hit the heightmap by ray-marching it — no physics shape needed.
			var rh = sculpt_node.raycast_heightmap(ray_origin, ray_dir)
			if rh == null:
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			hit_pos = rh
		else:
			var space = sculpt_node.get_world_3d().direct_space_state
			var query = PhysicsRayQueryParameters3D.create(
				ray_origin, ray_origin + ray_dir * 1000.0)
			query.collide_with_bodies = true
			var result = space.intersect_ray(query)
			if result.is_empty():
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			hit_pos = result.position

		var raise = left
		if sculpt_mode == "lower":
			raise = false
		elif sculpt_mode == "raise":
			raise = true

		# Spacing: skip the dab if the cursor hasn't moved a fraction of the radius away from the
		# previous one. The first dab of a stroke is always applied (_have_last_dab = false). The
		# event is still consumed (STOP) so the camera doesn't move while painting.
		var spacing := maxf(1.0, brush_radius * DAB_SPACING_FRAC)
		if _have_last_dab and hit_pos.distance_to(_last_dab_pos) < spacing:
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		_last_dab_pos = hit_pos
		_have_last_dab = true

		_sculpt(hit_pos, raise)
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	return EditorPlugin.AFTER_GUI_INPUT_PASS


# ─────────────────────────────────────────────────
# Sculpt brush
# ─────────────────────────────────────────────────
func _sculpt(hit_pos: Vector3, raise: bool) -> void:
	# Image mode: edit the heightmap array directly, no HeightMapShape3D involved.
	if sculpt_node.has_method("is_image_mode") and sculpt_node.is_image_mode():
		# Stroke start — snapshot the heights BEFORE the edits (once per stroke) for undo.
		if not _stroke_active:
			_stroke_before = sculpt_node.get_heights().duplicate()
			_stroke_active = true
		var mode_int := 0
		if sculpt_mode != "flatten":
			mode_int = 1 if raise else -1
		var dirty: PackedInt32Array = sculpt_node.apply_brush(
				hit_pos, brush_radius, brush_strength, mode_int)
		for ci in dirty:
			_dirty_chunks[ci] = true
		return

	var col_shape = sculpt_node.get_node("CollisionShape3D")
	if col_shape == null:
		return
	var shape = col_shape.shape
	if not shape is HeightMapShape3D:
		return

	var width        = shape.map_width
	var depth        = shape.map_depth
	var map_data_old = shape.map_data.duplicate()
	var map_data     = shape.map_data

	var local_pos = sculpt_node.to_local(hit_pos)
	var cx = int(local_pos.x + width / 2.0)
	var cz = int(local_pos.z + depth / 2.0)

	var r     = int(ceil(brush_radius))
	var x_min = clamp(cx - r, 0, width - 1)
	var x_max = clamp(cx + r, 0, width - 1)
	var z_min = clamp(cz - r, 0, depth - 1)
	var z_max = clamp(cz + r, 0, depth - 1)

	if sculpt_mode == "flatten":
		var avg_height = 0.0
		var count      = 0
		for z in range(z_min, z_max + 1):
			for x in range(x_min, x_max + 1):
				var dx = x - cx
				var dz = z - cz
				if sqrt(dx*dx + dz*dz) <= brush_radius:
					avg_height += map_data[z * width + x]
					count += 1
		if count > 0:
			avg_height /= count
		for z in range(z_min, z_max + 1):
			for x in range(x_min, x_max + 1):
				var dx   = x - cx
				var dz   = z - cz
				var dist = sqrt(dx*dx + dz*dz)
				if dist <= brush_radius:
					var falloff = 1.0 - (dist / brush_radius)
					var index   = z * width + x
					# Lerp weight in [0,1] — same fix as in image mode: *5 without a clamp
					# overshot the average at high strength and broke the map.
					map_data[index] = lerp(map_data[index], avg_height, clampf(falloff * brush_strength, 0.0, 1.0))
	else:
		for z in range(z_min, z_max + 1):
			for x in range(x_min, x_max + 1):
				var dx   = x - cx
				var dz   = z - cz
				var dist = sqrt(dx*dx + dz*dz)
				if dist <= brush_radius:
					var falloff = 1.0 - (dist / brush_radius)
					var index   = z * width + x
					if raise:
						map_data[index] += brush_strength * falloff
					else:
						map_data[index] -= brush_strength * falloff

	var ur = get_undo_redo()
	ur.create_action("Sculpt Terrain", UndoRedo.MERGE_ALL)
	ur.add_do_property(shape, "map_data", map_data)
	ur.add_undo_property(shape, "map_data", map_data_old)
	ur.commit_action()

	if sculpt_node.has_method("get_chunk_info"):
		var info      = sculpt_node.get_chunk_info()
		var cs        = info["chunk_size"]
		var chunks_x  = info["chunks_x"]
		var map_w     = info["map_width"]
		var map_d     = info["map_depth"]
		var chunks_z  = ceili(float(map_d - 1) / cs)
		var total_chunks = chunks_x * chunks_z
		var cx_center = int(local_pos.x + map_w / 2.0) / cs
		var cz_center = int(local_pos.z + map_d / 2.0) / cs
		var cr        = int(ceil(brush_radius / cs)) + 1
		for dz in range(-cr, cr + 1):
			for dx in range(-cr, cr + 1):
				var ci = (cz_center + dz) * chunks_x + (cx_center + dx)
				if ci >= 0 and ci < total_chunks:
					_dirty_chunks[ci] = true


# ─────────────────────────────────────────────────
# End of an image-mode stroke → one undo/redo step.
# The "before" snapshot was taken at stroke start; now take the "after" and register an
# action that swaps the whole heightmap between the two states. Ctrl+Z returns the map to
# "before", Ctrl+Y to "after". set_heightmap does a full preview rebuild, and
# _persist_heightmap rewrites the .res so the disk keeps up with undo/redo.
# ─────────────────────────────────────────────────
func _commit_stroke_undo() -> void:
	_stroke_active = false
	if sculpt_node == null or not (sculpt_node.has_method("is_image_mode") and sculpt_node.is_image_mode()):
		return
	var after: PackedFloat32Array = sculpt_node.get_heights().duplicate()
	if _stroke_before.size() != after.size() or after.is_empty():
		return
	if _stroke_before == after:      # the stroke changed nothing — don't pollute the history
		return
	var dims: Vector2i = sculpt_node.get_dims()
	var ur = get_undo_redo()
	ur.create_action("Sculpt Terrain", UndoRedo.MERGE_DISABLE, sculpt_node)
	ur.add_do_method(sculpt_node, "set_heightmap", after, dims.x, dims.y)
	ur.add_do_method(self, "_persist_heightmap")
	ur.add_undo_method(sculpt_node, "set_heightmap", _stroke_before, dims.x, dims.y)
	ur.add_undo_method(self, "_persist_heightmap")
	# execute=false: the live md already equals "after", no point running a full rebuild now.
	ur.commit_action(false)
	# ...but the .res on disk is still "before" — sync it once after the stroke.
	_persist_heightmap()
	_stroke_before = PackedFloat32Array()


# Rewrites the R32F heightmap into the file the node loads (its heightmap_path) so the disk
# keeps up with sculpt/undo/redo. Without this, edits would live only in memory until Bake.
func _persist_heightmap() -> void:
	if sculpt_node == null or not sculpt_node.has_method("get_heights"):
		return
	var data: PackedFloat32Array = sculpt_node.get_heights()
	var dims: Vector2i = sculpt_node.get_dims()
	if dims.x <= 0 or dims.y <= 0 or data.size() != dims.x * dims.y:
		return
	var img := Image.create_from_data(dims.x, dims.y, false, Image.FORMAT_RF, data.to_byte_array())
	ResourceSaver.save(img, _heightmap_target())


# ─────────────────────────────────────────────────
# Bake the sculpted HeightMapShape3D into an R32F image
# ─────────────────────────────────────────────────
# map.gd loads this image at runtime as the heightmap source of truth and builds a
# small streaming collision window from it — so the map can be huge without the giant
# HeightMapShape3D physics body. Run this whenever you change the terrain in-editor.
const HEIGHTMAP_PATH := "res://addons/lite_terrain/terrain_height.res"
const MESH_PATH      := "res://addons/lite_terrain/terrain_mesh.res"

# Where to write the heightmap: ALWAYS to the selected node's heightmap_path (otherwise bake/
# generate would save to one place while the node loads from another — and the terrain would
# come up empty after reopening). Fall back to the constant if the node's path is empty.
func _heightmap_target() -> String:
	if sculpt_node != null:
		var p := str(sculpt_node.get("heightmap_path"))
		if p != "":
			return p
	return HEIGHTMAP_PATH

# The heightmap PNG goes next to the heightmap itself (the heightmap_path folder), not into
# the project root — the plugin shouldn't litter someone else's res://.
func _heightmap_png_target() -> String:
	return _heightmap_target().get_base_dir().path_join("terrain_heightmap.png")

func _bake_heightmap() -> void:
	if sculpt_node == null:
		push_warning("LiteTerrain: select the terrain StaticBody3D node first")
		return

	var width: int
	var depth: int
	var data: PackedFloat32Array

	if sculpt_node.has_method("is_image_mode") and sculpt_node.is_image_mode():
		# Image mode: the heights live in md, NOT in the CollisionShape3D (which after
		# 'Detach' is just a 2x2 placeholder — baking from it would wipe the heightmap).
		var dims: Vector2i = sculpt_node.get_dims()
		width  = dims.x
		depth  = dims.y
		data   = sculpt_node.get_heights()
	else:
		var col_shape = sculpt_node.get_node_or_null("CollisionShape3D")
		if col_shape == null or not (col_shape.shape is HeightMapShape3D):
			push_warning("LiteTerrain: no HeightMapShape3D found on the selected node")
			return
		var shape = col_shape.shape
		width = shape.map_width
		depth = shape.map_depth
		data  = shape.map_data

	if width <= 0 or depth <= 0 or data.size() != width * depth:
		push_error("LiteTerrain: bad heightmap (%d values for %dx%d) — nothing baked" % [data.size(), width, depth])
		return
	# ── Physical: R32F heightmap image (runtime data + streaming collision) ──────
	# Exact round-trip with md = img.get_data().to_float32_array().
	var img := Image.create_from_data(width, depth, false, Image.FORMAT_RF, data.to_byte_array())
	var hm_path := _heightmap_target()
	var err := ResourceSaver.save(img, hm_path)
	if err == OK:
		print("LiteTerrain: baked heightmap %dx%d -> %s" % [width, depth, hm_path])
	else:
		push_error("LiteTerrain: failed to save heightmap (error %d)" % err)

	# ── Visual: editor preview mesh → external .res ──────────────────────────────
	# Without this the generated ArrayMesh is unique-to-scene and gets embedded into the
	# .tscn on save (bloat + manual re-link each time). take_over_path() makes the live
	# mesh point at the file, so the scene just references it externally.
	var mi = sculpt_node.get_node_or_null("MeshInstance3D")
	if mi != null and mi.mesh != null:
		var merr := ResourceSaver.save(mi.mesh, MESH_PATH)
		if merr == OK:
			mi.mesh.take_over_path(MESH_PATH)
			print("LiteTerrain: baked visual mesh → %s" % MESH_PATH)
		else:
			push_error("LiteTerrain: failed to save visual mesh (error %d)" % merr)
	else:
		push_warning("LiteTerrain: MeshInstance3D has no mesh to bake yet")


# The "Create Terrain Node" button: adds ONE LiteTerrain node. It creates its own
# CollisionShape3D and MeshInstance3D (_ensure_children); nothing is assembled by hand.
const TERRAIN_SCRIPT   := "res://addons/lite_terrain/map.gd"
const NEW_MAP_SIZE     := 128
const PLUGIN_HEIGHTMAP := "res://addons/lite_terrain/terrain_height.res"

func _create_terrain() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_warning("LiteTerrain: open a scene first")
		return
	var script := load(TERRAIN_SCRIPT)
	if script == null:
		push_error("LiteTerrain: %s not found" % TERRAIN_SCRIPT)
		return

	# A flat starter heightmap into the addon folder — so image mode works out of the box.
	var flat := PackedFloat32Array()
	flat.resize(NEW_MAP_SIZE * NEW_MAP_SIZE)
	var img := Image.create_from_data(NEW_MAP_SIZE, NEW_MAP_SIZE, false, Image.FORMAT_RF, flat.to_byte_array())
	ResourceSaver.save(img, PLUGIN_HEIGHTMAP)
	EditorInterface.get_resource_filesystem().scan()

	var body := StaticBody3D.new()
	body.name = "LiteTerrain"
	body.set_script(script)
	body.set("heightmap_path", PLUGIN_HEIGHTMAP)

	var parent: Node = root
	var sel := EditorInterface.get_selection().get_selected_nodes()
	if sel.size() > 0 and sel[0] is Node:
		parent = sel[0]

	# One node. It creates its own CollisionShape3D and MeshInstance3D as INTERNAL children
	# (invisible in the scene tree) and builds the preview in _ready from the baked flat map.
	var ur := get_undo_redo()
	ur.create_action("Create Terrain")
	ur.add_do_method(parent, "add_child", body)
	ur.add_do_method(body, "set_owner", root)
	ur.add_do_reference(body)
	ur.add_undo_method(parent, "remove_child", body)
	ur.commit_action()

	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(body)
	print("LiteTerrain: created a LiteTerrain node (%dx%d, image mode). Next: Generate/Sculpt." % [NEW_MAP_SIZE, NEW_MAP_SIZE])


# ─────────────────────────────────────────────────
# Export the heightmap as a grayscale PNG (heights normalized to 0..255). Good for a minimap
# or editing in an external tool. Data is taken the same way as for bake (image mode or from the shape).
# ─────────────────────────────────────────────────
func _generate_png() -> void:
	if sculpt_node == null:
		push_warning("LiteTerrain: select a terrain node")
		return
	var width: int
	var depth: int
	var data: PackedFloat32Array
	if sculpt_node.has_method("is_image_mode") and sculpt_node.is_image_mode():
		var dims: Vector2i = sculpt_node.get_dims()
		width = dims.x
		depth = dims.y
		data  = sculpt_node.get_heights()
	else:
		var col = sculpt_node.get_node_or_null("CollisionShape3D")
		if col == null or not (col.shape is HeightMapShape3D):
			push_warning("LiteTerrain: no HeightMapShape3D")
			return
		width = col.shape.map_width
		depth = col.shape.map_depth
		data  = col.shape.map_data
	if width <= 0 or depth <= 0 or data.size() != width * depth:
		push_error("LiteTerrain: bad heightmap (%d values for %dx%d)" % [data.size(), width, depth])
		return

	var mn := INF
	var mx := -INF
	for h in data:
		mn = minf(mn, h)
		mx = maxf(mx, h)
	var rng := maxf(mx - mn, 0.0001)

	var img := Image.create(width, depth, false, Image.FORMAT_L8)
	for z in depth:
		for x in width:
			var v := (data[z * width + x] - mn) / rng
			img.set_pixel(x, z, Color(v, v, v))

	var png_path := _heightmap_png_target()
	var err := img.save_png(png_path)
	if err == OK:
		print("LiteTerrain: heightmap PNG %dx%d -> %s (min %.1f, max %.1f)" % [width, depth, png_path, mn, mx])
		EditorInterface.get_resource_filesystem().scan()
	else:
		push_error("LiteTerrain: failed to save PNG (error %d)" % err)


# Replaces the big terrain.res / terrain_mesh.res references on the scene nodes with
# tiny placeholders so saving the scene no longer drags in the huge resources. Use this
# once you're in image mode (use_image_data ON + heightmap baked), then save the scene.
func _detach_big_resources() -> void:
	if sculpt_node == null:
		push_warning("LiteTerrain: select the terrain StaticBody3D node first")
		return
	if not (sculpt_node.has_method("is_image_mode") and sculpt_node.is_image_mode()):
		push_warning("LiteTerrain: enable 'Use Image Data' on the map and bake the heightmap first")
		return
	var col = sculpt_node.get_node_or_null("CollisionShape3D")
	if col != null:
		var small := HeightMapShape3D.new()
		small.map_width = 2
		small.map_depth = 2
		col.shape = small
	var mi = sculpt_node.get_node_or_null("MeshInstance3D")
	if mi != null:
		mi.mesh = null
	print("LiteTerrain: detached big resources — now SAVE THE SCENE (Ctrl+S) to drop their refs.")


# ─────────────────────────────────────────────────
# Noise terrain generation
# ─────────────────────────────────────────────────
func _generate_noise() -> void:
	_save_settings()   # persist the current generation parameters to disk
	if sculpt_node == null:
		push_warning("LiteTerrain: select a terrain StaticBody3D node first")
		return

	var image_mode: bool = sculpt_node.has_method("is_image_mode") and sculpt_node.is_image_mode()
	var width: int
	var depth: int
	var shape = null
	var map_data_old := PackedFloat32Array()

	if image_mode:
		# Size from the Map Size field (0 = keep current). This is how the map grows.
		var dims: Vector2i = sculpt_node.get_dims()
		width  = gen_size if gen_size > 0 else dims.x
		depth  = gen_size if gen_size > 0 else dims.y
		if width  <= 0: width  = 512
		if depth  <= 0: depth  = 512
	else:
		var col_shape = sculpt_node.get_node_or_null("CollisionShape3D")
		if col_shape == null:
			push_warning("LiteTerrain: no CollisionShape3D child found")
			return
		shape = col_shape.shape
		if not shape is HeightMapShape3D:
			push_warning("LiteTerrain: shape is not a HeightMapShape3D")
			return
		width = shape.map_width
		depth = shape.map_depth
		map_data_old = shape.map_data.duplicate()

	# Enforce a minimum map size — too small (< 2 chunks) produces degenerate chunks and errors.
	width  = maxi(width, 32)
	depth  = maxi(depth, 32)

	# ── Layer 1: Continental FBM ─────────────────
	# Low-frequency simplex FBM defines the overall land masses.
	# After remapping to [0,1], we raise to gen_power (e.g. ^4):
	# values below 0.5 collapse toward 0 (flat plains),
	# while values above 0.7 stay high (mountain bases).
	var base_noise = FastNoiseLite.new()
	base_noise.seed             = gen_seed
	base_noise.noise_type       = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	base_noise.fractal_type     = FastNoiseLite.FRACTAL_FBM
	base_noise.fractal_octaves  = gen_octaves
	base_noise.frequency        = 1.0 / gen_scale
	base_noise.fractal_lacunarity = 2.0
	base_noise.fractal_gain     = 0.5

	# ── Layer 2: Ridge noise ─────────────────────
	# A separate FBM sampled at slightly higher frequency.
	# Formula:  ridge = (1 - |n|) ^ sharpness
	# This creates a network of sharp crests wherever the raw
	# noise crosses zero.  We then mask it by the continental
	# elevation so ridges only form on already-high terrain.
	var ridge_noise = FastNoiseLite.new()
	ridge_noise.seed              = gen_seed + 17
	ridge_noise.noise_type        = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	ridge_noise.fractal_type      = FastNoiseLite.FRACTAL_FBM
	ridge_noise.fractal_octaves   = maxi(gen_octaves - 1, 1)
	ridge_noise.frequency         = 1.0 / (gen_scale * 0.55)
	ridge_noise.fractal_lacunarity = 2.2
	ridge_noise.fractal_gain      = 0.45

	var new_data = PackedFloat32Array()
	new_data.resize(width * depth)

	for z in depth:
		for x in width:
			# ── Continental base ──────────────────
			var raw = base_noise.get_noise_2d(float(x), float(z))
			var base = (raw + 1.0) * 0.5            # remap to [0, 1]

			# Power curve: flattens plains, keeps peaks elevated.
			# ^4 means 0.5^4 = 0.0625 (flat), 0.9^4 = 0.66 (hill).
			var continental = pow(base, gen_power)

			# ── Ridge ────────────────────────────
			var rn    = ridge_noise.get_noise_2d(float(x), float(z))
			var ridge = 1.0 - abs(rn)               # peaks where rn ≈ 0
			ridge = pow(ridge, gen_ridge_sharpness)  # sharpen crest

			# Mountain mask: ridges grow in only where the continental
			# base is already elevated (smoothstep 0.25 → 0.65).
			# Below 0.25 → plains, no ridges; above 0.65 → full ridges.
			var mountain_mask = smoothstep(0.25, 0.65, continental)

			# ── Combine ──────────────────────────
			var h = continental + ridge * gen_mountain_amount * mountain_mask
			new_data[z * width + x] = h * gen_amplitude

	# ── Optional blur passes ─────────────────────
	# Simple 5-tap box blur to soften extreme spikes.
	# Each pass slightly reduces aliasing without destroying ridges.
	for _p in gen_smooth:
		var buf = new_data.duplicate()
		for z in range(1, depth - 1):
			for x in range(1, width - 1):
				buf[z * width + x] = (
					new_data[z * width + x]         +
					new_data[z * width + (x - 1)]   +
					new_data[z * width + (x + 1)]   +
					new_data[(z - 1) * width + x]   +
					new_data[(z + 1) * width + x]
				) * 0.2
		new_data = buf

	if image_mode:
		# Set md + size, rebuild the editor preview, and write the heightmap image so the
		# runtime (and re-opening the editor) loads it. No undo here — it's a full regen.
		sculpt_node.set_heightmap(new_data, width, depth)
		var img := Image.create_from_data(width, depth, false, Image.FORMAT_RF, new_data.to_byte_array())
		var gm_path := _heightmap_target()
		var gerr := ResourceSaver.save(img, gm_path)
		if gerr == OK:
			print("LiteTerrain: generated %dx%d -> %s" % [width, depth, gm_path])
		else:
			push_error("LiteTerrain: failed to save generated heightmap (error %d)" % gerr)
		return

	# ── Legacy (shape) undo/redo + apply ─────────
	# Route BOTH the do and the undo through the node's apply_heightmap() so the whole
	# action lives in the scene-node history. (Mixing add_do_property on the heightmap
	# resource with add_do_method on the node caused "UndoRedo history mismatch".)
	# custom_context = sculpt_node pins the action to the node's history as well.
	var ur = get_undo_redo()
	ur.create_action("Generate Terrain Noise", UndoRedo.MERGE_DISABLE, sculpt_node)
	ur.add_do_method(sculpt_node, "apply_heightmap", new_data)
	ur.add_undo_method(sculpt_node, "apply_heightmap", map_data_old)
	ur.commit_action()
