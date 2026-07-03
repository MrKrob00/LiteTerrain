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

# ---------- Noise generation parameters ----------
var gen_seed:             int   = 42
var gen_scale:           float  = 150.0   # continental frequency scale
var gen_octaves:          int   = 6       # FBM octaves
var gen_power:           float  = 4.0    # ^N curve: high → flat plains, sharp peaks
var gen_mountain_amount: float  = 0.8    # ridge contribution
var gen_ridge_sharpness: float  = 2.5    # how knife-sharp ridges are
var gen_amplitude:       float  = 30.0   # max height in world units
var gen_smooth:           int   = 1      # blur passes after generation

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
	# Wrap everything in a ScrollContainer so the dock is scrollable on tablets
	var scroll = ScrollContainer.new()
	scroll.name = "Terraid3D"
	scroll.custom_minimum_size = Vector2(220, 0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	panel = VBoxContainer.new()
	panel.custom_minimum_size = Vector2(220, 0)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# ── Sculpt ──────────────────────────────────
	panel.add_child(_lbl("── Terrain Sculpt ──"))

	panel.add_child(_lbl("Mode:"))
	mode_label = _lbl("▲ Raise")
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

	var radius_label = _lbl("Radius: 3")
	panel.add_child(radius_label)
	radius_slider = _slider(1.0, 200.0, 3.0)
	radius_slider.value_changed.connect(func(v: float) -> void:
		brush_radius = v
		radius_label.text = "Radius: " + str(snapped(v, 0.5))
	)
	panel.add_child(radius_slider)

	var strength_label = _lbl("Strength: 10")
	panel.add_child(strength_label)
	strength_slider = _slider(1.0, 1000.0, 10.0)
	strength_slider.value_changed.connect(func(v: float) -> void:
		brush_strength = v / 1000.0
		strength_label.text = "Strength: " + str(int(v))
	)
	panel.add_child(strength_slider)

	# ── Noise Generation ─────────────────────────
	panel.add_child(_sep())
	panel.add_child(_lbl("── Noise Generation ──"))

	# Seed
	var seed_lbl = _lbl("Seed: 42")
	panel.add_child(seed_lbl)
	var seed_spin = SpinBox.new()
	seed_spin.min_value = 0
	seed_spin.max_value = 99999
	seed_spin.value     = gen_seed
	seed_spin.value_changed.connect(func(v: float) -> void:
		gen_seed = int(v)
		seed_lbl.text = "Seed: " + str(gen_seed)
	)
	panel.add_child(seed_spin)

	# Scale (continental frequency)
	var scale_lbl = _lbl("Scale: 150")
	panel.add_child(scale_lbl)
	var scale_sl = _slider(10.0, 600.0, gen_scale)
	scale_sl.value_changed.connect(func(v: float) -> void:
		gen_scale = v
		scale_lbl.text = "Scale: " + str(int(v))
	)
	panel.add_child(scale_sl)

	# Octaves
	var oct_lbl = _lbl("Octaves: 6")
	panel.add_child(oct_lbl)
	var oct_spin = SpinBox.new()
	oct_spin.min_value = 1
	oct_spin.max_value = 8
	oct_spin.value     = gen_octaves
	oct_spin.value_changed.connect(func(v: float) -> void:
		gen_octaves = int(v)
		oct_lbl.text = "Octaves: " + str(gen_octaves)
	)
	panel.add_child(oct_spin)

	# Power curve  (^N — higher = flatter plains, sharper peaks)
	var pow_lbl = _lbl("Plains Power (^N): 4.0")
	panel.add_child(pow_lbl)
	var pow_sl = _slider(1.0, 8.0, gen_power, 0.1)
	pow_sl.value_changed.connect(func(v: float) -> void:
		gen_power = v
		pow_lbl.text = "Plains Power (^N): " + str(snapped(v, 0.1))
	)
	panel.add_child(pow_sl)

	# Mountain ridge amount
	var mount_lbl = _lbl("Mountains: 80 %")
	panel.add_child(mount_lbl)
	var mount_sl = _slider(0.0, 1.0, gen_mountain_amount, 0.01)
	mount_sl.value_changed.connect(func(v: float) -> void:
		gen_mountain_amount = v
		mount_lbl.text = "Mountains: " + str(int(v * 100)) + " %"
	)
	panel.add_child(mount_sl)

	# Ridge sharpness  (higher = knife-edge ridges)
	var ridge_lbl = _lbl("Ridge Sharpness: 2.5")
	panel.add_child(ridge_lbl)
	var ridge_sl = _slider(1.0, 8.0, gen_ridge_sharpness, 0.1)
	ridge_sl.value_changed.connect(func(v: float) -> void:
		gen_ridge_sharpness = v
		ridge_lbl.text = "Ridge Sharpness: " + str(snapped(v, 0.1))
	)
	panel.add_child(ridge_sl)

	# Amplitude (max height in world units)
	var amp_lbl = _lbl("Amplitude: 30")
	panel.add_child(amp_lbl)
	var amp_sl = _slider(1.0, 300.0, gen_amplitude)
	amp_sl.value_changed.connect(func(v: float) -> void:
		gen_amplitude = v
		amp_lbl.text = "Amplitude: " + str(int(v))
	)
	panel.add_child(amp_sl)

	# Smooth passes (simple box-blur after generation)
	var smooth_lbl = _lbl("Smooth Passes: 1")
	panel.add_child(smooth_lbl)
	var smooth_spin = SpinBox.new()
	smooth_spin.min_value = 0
	smooth_spin.max_value = 12
	smooth_spin.value     = gen_smooth
	smooth_spin.value_changed.connect(func(v: float) -> void:
		gen_smooth = int(v)
		smooth_lbl.text = "Smooth Passes: " + str(gen_smooth)
	)
	panel.add_child(smooth_spin)

	var gen_btn = Button.new()
	gen_btn.text = "🌍 Generate Terrain"
	gen_btn.pressed.connect(_generate_noise)
	panel.add_child(gen_btn)

	scroll.add_child(panel)
	add_control_to_dock(DOCK_SLOT_LEFT_UL, scroll)


func _exit_tree() -> void:
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
	mode_label.text = "▲ Raise"

func _on_lower() -> void:
	sculpt_mode = "lower"
	mode_label.text = "▼ Lower"

func _on_flatten() -> void:
	sculpt_mode = "flatten"
	mode_label.text = "⬛ Flatten"


# ─────────────────────────────────────────────────
# Node selection
# ─────────────────────────────────────────────────
func _handles(object) -> bool:
	return object is StaticBody3D or object is CollisionShape3D

func _edit(object) -> void:
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

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			brush_radius = clamp(brush_radius + 0.5, 1.0, 20.0)
			radius_slider.value = brush_radius
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			brush_radius = clamp(brush_radius - 0.5, 1.0, 20.0)
			radius_slider.value = brush_radius
			return EditorPlugin.AFTER_GUI_INPUT_STOP

		if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			if _dirty_chunks.size() > 0 and sculpt_node and sculpt_node.has_method("update_chunks"):
				sculpt_node.update_chunks(_dirty_chunks.keys())
				_dirty_chunks.clear()
			return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseMotion or event is InputEventMouseButton:
		var left  = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		var right = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)

		if not left and not right:
			return EditorPlugin.AFTER_GUI_INPUT_PASS

		var ray_origin = viewport_camera.project_ray_origin(event.position)
		var ray_dir    = viewport_camera.project_ray_normal(event.position)

		var space = sculpt_node.get_world_3d().direct_space_state
		var query = PhysicsRayQueryParameters3D.create(
			ray_origin,
			ray_origin + ray_dir * 1000.0
		)
		query.collide_with_bodies = true
		var result = space.intersect_ray(query)

		if result.is_empty():
			return EditorPlugin.AFTER_GUI_INPUT_PASS

		var raise = left
		if sculpt_mode == "lower":
			raise = false
		elif sculpt_mode == "raise":
			raise = true

		_sculpt(result.position, raise)
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	return EditorPlugin.AFTER_GUI_INPUT_PASS


# ─────────────────────────────────────────────────
# Sculpt brush
# ─────────────────────────────────────────────────
func _sculpt(hit_pos: Vector3, raise: bool) -> void:
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
					map_data[index] = lerp(map_data[index], avg_height, falloff * brush_strength * 5.0)
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
# Noise terrain generation
# ─────────────────────────────────────────────────
func _generate_noise() -> void:
	if sculpt_node == null:
		push_warning("Terraid3D: select a terrain StaticBody3D node first")
		return
	var col_shape = sculpt_node.get_node_or_null("CollisionShape3D")
	if col_shape == null:
		push_warning("Terraid3D: no CollisionShape3D child found")
		return
	var shape = col_shape.shape
	if not shape is HeightMapShape3D:
		push_warning("Terraid3D: shape is not a HeightMapShape3D")
		return

	var width = shape.map_width
	var depth = shape.map_depth
	var map_data_old = shape.map_data.duplicate()

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

	# ── Undo/redo + apply ────────────────────────
	var ur = get_undo_redo()
	ur.create_action("Generate Terrain Noise")
	ur.add_do_property(shape, "map_data", new_data)
	ur.add_undo_property(shape, "map_data", map_data_old)
	# add_do_method/add_undo_method: виконуються при commit та при redo/undo відповідно.
	# Без цього undo відкочує map_data але меш залишається старим.
	ur.add_do_method(sculpt_node, "update")
	ur.add_undo_method(sculpt_node, "update")
	ur.commit_action()
	# sculpt_node.update() вже викликається з commit_action() через add_do_method
