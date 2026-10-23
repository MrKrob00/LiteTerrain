@tool
extends EditorInspectorPlugin

# Puts the ground's preview buttons (preview_panel.gd) at the top of the chunked ground's inspector,
# the way the face cube stands at the top of a block's.

## The chunked ground is recognised BY ABILITY, not by class: `is` against a script path is one more line
## that drifts apart when the file moves.
func _can_handle(object: Object) -> bool:
	return object != null and object.has_method("preview_build")

func _parse_begin(object: Object) -> void:
	var ed := preload("res://addons/lite_terrain/preview_panel.gd").new()
	ed.setup(object as Node)
	add_custom_control(ed)
