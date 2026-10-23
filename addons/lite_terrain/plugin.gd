@tool
extends EditorPlugin

# THE WHOLE PLUGIN IS ONE INSPECTOR PANEL, THE VIEWPORT CAMERA AND THE SHADER GLOBALS. It has nothing else to do.
#
# It used to be a dock fifteen hundred lines long: a brush with modes and strength, height-map generation
# through seventeen sliders, a progress window with a time estimate and a "Stop" button, baking to .res, to a
# stream and to a grey PNG, a "create a terrain node" button. All of it served ONE kind of ground —
# a baked height map from a file (map.gd) — and the project no longer has it: both the world and the menu
# backdrop stand on chunked ground, which is computed from a seed and reads no files.
#
# What is left:
#   • the PREVIEW BUTTONS at the top of the node's inspector (terrain_inspector.gd ->
#     preview_panel.gd): build the real ground in the editor, which is how the ground material's
#     settings are seen while they are tuned;
#   • the EDITOR CAMERA, handed to the node: it has none of its own in the editor, and the preview
#     is built round where the view is;
#   • the SHADER GLOBALS: the ground shader reads global uniforms - the haze colour and range always, the sun
#     direction, ambient and sun tint in its optional self-lit `fast_ground` mode. They live in a project's
#     [shader_globals] section, so a project that installs the addon does not have them, and without the
#     haze pair the shader would not compile. Loading the plugin adds whichever are missing.
#
# The node itself is added the usual way, "Add Node → ChunkTerrain": the script has a class_name, so there
# is no need to register a custom type for it.

## Name → [type, default]. `world_haze` and `haze_range` are always read; the other three only by the
## `fast_ground` variant. The defaults are the look the ground was tuned with; a project that already
## declares one of them keeps its own value.
const SHADER_GLOBALS := {
	"world_haze":  ["color", Color(0.86, 0.8, 0.7, 1.0)],
	"haze_range":  ["vec4", Vector4(150.0, 750.0, 0.85, 0.0)],
	"sun_dir":     ["vec4", Vector4(0.836, 0.402, 0.374, 0.0)],
	"ground_amb":  ["vec4", Vector4(0.24, 0.22, 0.19, 0.0)],
	"ground_sun":  ["vec4", Vector4(1.0, 0.93, 0.8, 0.0)],
}

var _inspector: EditorInspectorPlugin = null
var _node: ChunkTerrain = null

func _enter_tree() -> void:
	_register_shader_globals()
	_inspector = preload("res://addons/lite_terrain/terrain_inspector.gd").new()
	add_inspector_plugin(_inspector)

func _exit_tree() -> void:
	if _inspector != null:
		remove_inspector_plugin(_inspector)
		_inspector = null

## Declares whichever of the globals the project does not have yet, every time the plugin loads (it is a
## no-op once they exist). They are left in place when the plugin is switched off: scenes that use the
## ground keep needing them, and a global cannot be taken away from a shader that is still compiled.
func _register_shader_globals() -> void:
	var added := false
	var live := RenderingServer.global_shader_parameter_get_list()
	for gname: String in SHADER_GLOBALS:
		var entry: Array = SHADER_GLOBALS[gname]
		var key: String = "shader_globals/" + gname
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, {"type": entry[0], "value": entry[1]})
			added = true
		# The editor reads the section only on start-up, so a global declared just now is added to the
		# running renderer too, or the shader would stay broken until the project is reopened.
		if not live.has(StringName(gname)):
			var kind: RenderingServer.GlobalShaderParameterType = RenderingServer.GLOBAL_VAR_TYPE_COLOR if entry[0] == "color" else RenderingServer.GLOBAL_VAR_TYPE_VEC4
			RenderingServer.global_shader_parameter_add(gname, kind, entry[1])
	if added:
		ProjectSettings.save()

func _handles(object) -> bool:
	return object is ChunkTerrain

func _edit(object) -> void:
	_node = object as ChunkTerrain

## The viewport camera is handed to the node and nothing else is touched: input passes on as if there
## were no plugin. The preview uses it to choose which nodes to build and where.
func _forward_3d_gui_input(viewport_camera: Camera3D, _event: InputEvent) -> int:
	if _node != null and is_instance_valid(_node):
		_node.set_editor_camera(viewport_camera)
	return EditorPlugin.AFTER_GUI_INPUT_PASS
