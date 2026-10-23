@tool
extends HBoxContainer

# THE GROUND IN THE EDITOR: two buttons at the top of the map's inspector. The chunked ground has no
# height file to look at, so without them the ground - and what its material's settings do to it -
# could only be seen by running the game. "Build in scene" builds the same ground the game builds,
# round the editor camera, from the node's `forced_seed`, with the material as it stands now (press
# it again after a change); nothing is saved into the scene (ChunkTerrain.preview_build).
#
# THE SEED MAP ABOVE THEM IS GONE (the player's call: "remove WHAT THIS SEED GIVES, with the seed and
# the span"): it chose nothing the game shows - a world's seed is its save slot's, picked when the
# world is made, and the menu picks its own.

var _node: Node = null

func setup(n: Node) -> void:
	_node = n
	add_theme_constant_override("separation", 4)
	var show_btn := Button.new()
	show_btn.text = "Build in scene"
	show_btn.tooltip_text = "Builds the same ground the game will, around the editor camera. Nothing is saved into the scene."
	show_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	show_btn.pressed.connect(_on_show)
	add_child(show_btn)
	var clear_btn := Button.new()
	clear_btn.text = "Clear"
	clear_btn.pressed.connect(_on_clear)
	add_child(clear_btn)

## Built round the EDITOR CAMERA, so it is handed to the node first: the node has none of its own in
## the editor, and without a point of view the first ring would stand at the origin - most likely not
## where anyone is looking.
func _on_show() -> void:
	if _node == null or not is_instance_valid(_node) or not _node.has_method("preview_build"):
		return
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam != null and _node.has_method("set_editor_camera"):
		_node.set_editor_camera(cam)
	var s = _node.get("forced_seed")
	_node.preview_build(int(s) if s != null else 0)

func _on_clear() -> void:
	if _node != null and is_instance_valid(_node) and _node.has_method("preview_clear"):
		_node.preview_clear()
