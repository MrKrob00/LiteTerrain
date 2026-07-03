# LiteTerrain

Lightweight heightmap terrain for Godot 4, tuned for mobile. One node builds its
own collision body, its collision shape, and its render mesh, then keeps the map
cheap on weak hardware with quadtree LOD and streaming collision. It ships with an
editor dock for creating, generating, sculpting, and baking terrain.

It was built and tuned on an Adreno 610 (a low-end mobile GPU), so the defaults
lean toward performance.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [The terrain node](#the-terrain-node)
- [Appearance](#appearance)
- [Runtime API](#runtime-api)
- [Physics and collision](#physics-and-collision)
- [Sculpting](#sculpting)
- [Generating terrain](#generating-terrain)
- [Baking and shipping a big map](#baking-and-shipping-a-big-map)
- [Performance tuning](#performance-tuning)
- [How it works](#how-it-works)
- [Property reference](#property-reference)
- [Shader reference](#shader-reference)
- [Troubleshooting](#troubleshooting)

## Requirements

- Godot 4.x.
- Renderer: Compatibility (GLES3) is recommended. The plugin is tuned for mobile,
  but it also runs on Forward+.

## Install

1. Copy the `lite_terrain` folder into your project's `res://addons/`.
2. Open Project Settings, go to the Plugins tab, and enable LiteTerrain.
3. A dock named LiteTerrain appears on the left. Everything is driven from there.

## Quick start

1. Open a 3D scene.
2. In the LiteTerrain dock, press "Create Terrain Node". This bakes a flat 128x128
   heightmap into the addon folder (`terrain_height.res`) and assembles a ready
   terrain: a StaticBody3D with the `LiteTerrain` script, a CollisionShape3D, and a
   MeshInstance3D, with the terrain shader already applied. It comes up in image
   mode with streaming collision on, so it renders and runs well on both small and
   large maps out of the box.
3. Select the node, then shape the terrain in one of two ways:
   - Press "Generate Terrain" to build noise-based terrain. Set the seed, scale,
     octaves, amplitude, map size, and the other parameters first.
   - Or sculpt by hand with the Raise, Lower, and Flatten buttons. Paint with the
     left mouse button in the viewport. Radius and strength are in the dock. Each
     brush stroke is one undo step (Ctrl+Z to undo, Ctrl+Y to redo).
4. Press "Bake to files" to write the runtime data: the heightmap
   (`terrain_height.res`) and a preview mesh (`terrain_mesh.res`). This makes the
   map load fast at runtime.
5. Optionally press "Generate PNG" to export the heightmap as a grayscale image
   (`terrain_heightmap.png`), useful for a minimap or for editing in another tool.

The dock remembers its brush and generation settings per project, so you do not
have to set them again every session.

## The terrain node

The node class is `LiteTerrain` (`map.gd`). It extends StaticBody3D and uses two
children, a `CollisionShape3D` and a `MeshInstance3D`. You do not have to add them:
the node creates them itself if they are missing, so you can drop in a single
LiteTerrain node. The "Create Terrain Node" button also sets everything up for you.

The node holds map and streaming settings. The appearance (tile texture, blend,
tile size, zone colors, grass, low quality) lives on the material, not on the node.
See [Appearance](#appearance).

The node properties you will touch most often:

| Property | Default | What it does |
|---|---|---|
| `camera` | empty | Optional. Leave empty and the terrain uses the current active camera automatically, and follows camera switches. Set it only to force LOD from a specific camera. |
| `surface_material` | addon `terrain_shader.res` | The material used for the terrain. All appearance settings live on it. |
| `use_image_data` | `true` | On: the heightmap lives in an R32F image (`heightmap_path`) and collision streams under moving bodies. Recommended for large maps. Off: a single HeightMapShape3D holds the whole map. |
| `heightmap_path` | addon `terrain_height.res` | The R32F resource the runtime loads when `use_image_data` is on. Hidden in the inspector when it is off. |
| `max_render_distance` | `1400.0` | How far terrain is drawn. Keep it close to your fog distance. |

The full list is in the [Property reference](#property-reference).

## Appearance

The look is driven entirely by the material (`surface_material`, the bundled
`terrain_shader.res` by default). Select the material and edit its Shader Parameters
in the inspector. These are not duplicated onto the node, so there is one place to
change them. The defaults live in the shader (`glsl.gdshader`) and the bundled
material, so a fresh terrain already looks right.

Common ones:

| Shader parameter | Default | What it does |
|---|---|---|
| `tile_texture` | `Dark/6.png` | Surface tile texture. Pick any texture you like. |
| `texture_blend` | `0.1` | How much the tile texture shows over the height colors. `0` is colors only, `1` is texture only. |
| `tile_world_size` | `31.0` | World units per texture tile. The shader tiles by world position, so the look is automatic at any map size, in game and in editor. |
| `low_quality` | `false` | Simplifies the per-pixel shader for weak GPUs. See Performance tuning. |
| `color_sand` / `color_grass` / `color_snow` / `color_rock` | terrain tones | Zone and slope colors. |
| `grass_density` / `grass_height` | `0.4` / `0.15` | Grass amount and height. |

The full uniform list is in the [Shader reference](#shader-reference).

## Runtime API

```gdscript
terrain.terrain_height_at(world_pos: Vector3) -> float   # ground height under a world point
terrain.get_dims() -> Vector2i                           # heightmap width and depth in cells
```

Use `terrain_height_at` to place objects on the ground instead of dropping them
from the air:

```gdscript
body.global_position.y = terrain.terrain_height_at(body.global_position) + clearance
```

The node also exposes a sculpt and data API used by the dock (`is_image_mode`,
`get_heights`, `set_heightmap`, `apply_brush`, `raycast_heightmap`, `apply_heightmap`).
You rarely need these directly, but they are there if you build your own tooling.

## Physics and collision

The terrain gives itself collision, so you do not add a CollisionShape3D by hand.

Out of the box, the defaults are image mode with streaming collision. Streaming means
the terrain does not carry one giant collision shape. Instead it creates a small
collision window that follows each moving body, which is what keeps a large map cheap.

It tracks bodies automatically, with no setup. Every moving physics body in the scene
(RigidBody3D, VehicleBody3D, CharacterBody3D) gets a collision window sized by
`collision_radius`. You drop the terrain in, add your player, and the ground is there.

Things to know:

- Only terrain inside an active window has collision. A body far from any tracked body
  sits on no ground. Increase `collision_radius` if a fast body outruns its window.
- A body that rides on another body (for example a part welded to a vehicle) is
  skipped, since the parent body's window already covers it.
- Bullets, triggers (Area3D), and static bodies are never tracked. Only moving bodies
  get windows.
- The plugin uses `HeightMapShape3D`, which works with both the default Godot physics
  and the Jolt physics engine. It was tuned on Jolt. The `collision_overlap` setting
  overlaps neighbouring collision tiles so a wheel does not catch on the seam between
  them. If you see a small bump when crossing tile boundaries on the default physics
  engine, adjust `collision_overlap`.

## Sculpting

Select the terrain node, pick a mode in the dock, and paint in the viewport with
the left mouse button.

- Raise and Lower move the surface up or down under the brush.
- Flatten pulls the surface toward the average height inside the brush. At full
  strength one pass flattens completely, and it never overshoots.
- Radius and Strength are set with the dock sliders. Radius can also be changed by
  scrolling the mouse wheel over the viewport while the terrain is selected. The
  wheel and the slider share the same range.
- Each brush stroke, from mouse down to mouse up, is a single Undo or Redo step
  (Ctrl+Z and Ctrl+Y).

In image mode the mesh preview and the heightmap file update when you release the
mouse, so undo and redo stay in sync with the file on disk.

## Generating terrain

Press "Generate Terrain" to fill the map with layered noise. The parameters:

| Parameter | Default | Meaning |
|---|---|---|
| Seed | 42 | Noise seed. Same seed gives the same terrain. |
| Scale | 150 | Size of the land masses. Larger means broader features. |
| Octaves | 6 | Detail layers in the base noise. |
| Plains Power | 4.0 | Flattens low ground and keeps peaks high. Higher means flatter plains and sharper peaks. |
| Mountains | 80 percent | How strongly ridges are added on high ground. |
| Ridge Sharpness | 2.5 | How knife-edged the mountain ridges are. |
| Amplitude | 30 | Maximum height in world units. |
| Smooth Passes | 1 | Box-blur passes after generation, to soften spikes. |
| Map Size | 0 | Target size in image mode. `0` keeps the current size. This is how the map grows. |

Generation replaces the whole heightmap and writes it to the R32F file, so the
runtime and a reopened editor both load the new terrain.

## Baking and shipping a big map

For large maps, use image mode:

1. Turn on `use_image_data` (it is on by default).
2. Press "Bake to files" to write `terrain_height.res` (the heightmap) and
   `terrain_mesh.res` (the preview mesh).
3. Press "Detach big resources from scene". This replaces the large in-scene shape
   and mesh with tiny placeholders.
4. Save the scene.

After this the runtime loads the baked `.res` and streams a small collision window
under tracked bodies, so the scene file stays small and nothing heavy loads at
startup.

## Performance tuning

Built in already: quadtree LOD (coarser meshes with distance), a resident macro
grid plus streamed chunks so memory stays bounded, streaming collision (a small
shape window under tracked bodies instead of one giant shape), and frustum and
range culling.

Extra levers when the GPU is fill-bound, which is the common case on mobile with a
full-screen terrain shader:

1. `low_quality` (material shader parameter). Simplifies the per-pixel terrain shader
   by dropping the noise variation and the tile-texture fetch. Off by default so the
   look does not change. Turn it on for weak devices. All pixels take the same
   branch, so it is cheap on mobile GPUs.
2. `scaling_3d/scale` (Project Settings, Rendering). The single biggest lever when
   fill-bound. `0.75` is a good mobile default, `0.6` to `0.65` for weaker GPUs.
   Compare `0.5` against `1.0` to see how fill-bound you actually are.
3. `max_render_distance` (node property). How far chunks stream and draw. Keep it
   near your fog distance so you do not draw terrain that fog hides.
4. Directional shadows are expensive on mobile. Lower the shadow atlas size and max
   distance, or disable shadows, and compare FPS.
5. `grass_density` and `grass_height` (shader). Grass is a vertex cost. Lower them,
   or set density to `0`, on the weakest hardware.

## How it works

This section is for people who want to modify the plugin.

### Data model: image mode versus shape mode

The heightmap is a flat array of float heights (`md`), width `w` by depth `d`.

- Image mode (`use_image_data` on) is the default. The heights come from an R32F
  image saved as a `.res` (`heightmap_path`), and that image is the single source
  of truth for both the render mesh and the collision. In the editor, sculpting
  edits the array directly and hit-testing is done by ray-marching the heightmap,
  so no physics shape is needed while you work.
- Shape mode (`use_image_data` off) is the legacy path. One HeightMapShape3D holds
  both the data and the collision for the whole map. Simple, but it does not scale
  to very large maps.

### Chunks and quadtree LOD

The map is split into square chunks of `chunk_size` cells. Each chunk is prebuilt at
several LOD levels, where the vertex step doubles per level (`LOD_STEPS` is
`[1, 2, 4]`). Closer chunks use a finer step and more triangles, farther chunks use
a coarser step. The thresholds are `lod_distance_0`, `lod_distance_1`, and
`lod_distance_2`.

Neighbouring chunks at different LOD levels would crack at the seam, so each chunk
carries a stitch signature that encodes its own step and the step on each of its
four borders. A chunk is rebuilt whenever its required signature changes, which
makes seam stitching self-healing no matter the order of LOD changes.

### Macro chunks

Groups of `MACRO_SIZE` by `MACRO_SIZE` chunks (4 by 4, so 16 chunks) are merged into
one MeshInstance3D with shadows off for distant terrain. This turns 16 draw calls
into 1 and saves the matching shadow passes.

### Streaming collision

With `enable_streaming_collision` on, collision is a grid of tiled HeightMapShape3D
cells rather than one huge shape. Each tracked body marks the cells within
`collision_radius` as needed, and bodies that share a cell share its shape. The tile
size is `collision_cell`.

Every moving body is tracked (RigidBody3D, VehicleBody3D, CharacterBody3D), with no
node paths to configure. A body that rides on another tracked body is skipped, since
the top body's window already covers it. Discovery uses an initial scan plus the
tree's `node_added` and `node_removed` signals, so there is no per-frame polling. The
window set is recomputed every frame as bodies move.

Tiles are grown by `collision_overlap` cells on each side so neighbouring tiles
overlap. This buries each tile's boundary edge under the neighbour's matching
surface, so a wheel does not snag on the seam when crossing between tiles.

Note the trade-off: only terrain inside a window has collision. Bodies far from any
tracked body sit on no ground. Size the windows to cover your play area, or keep
streaming collision off until the map is genuinely large.

### The shader

`glsl.gdshader` colors the terrain by height zones (sand, grass, snow) and by slope
(rock), adds optional per-pixel noise and a tile texture, and displaces grass in the
vertex stage. Its uniforms are grouped in the inspector under Quality, Texture,
Colors, Terrain, Grass, and Trample. The `low_quality` toggle skips the noise and
tile fetch for a direct fill saving. The optional `trample_map` presses grass down
under objects and defaults to black, meaning no effect, so you can ignore it.

### Editor state

Sculpt and generation settings from the dock are stored in the editor's per-project
metadata (inside `.godot/`, not committed to your repository), so each machine keeps
its own values across sessions.

## Property reference

Culling and drawing:

| Property | Default | What it does |
|---|---|---|
| `enable_frustum_culling` | `true` | Skip drawing chunks outside the camera frustum. |
| `frustum_margin` | `-0.05` | Frustum test margin. Negative culls a little more aggressively. |
| `max_render_distance` | `1400.0` | Draw distance for chunks. Keep near fog distance. |
| `enable_occlusion_culling` | `false` | Hide chunks below the terrain horizon. Off by default because the horizon method can false-cull on a steep top-down camera. |
| `occlusion_min_dist` | `40.0` | Chunks closer than this are never occlusion-culled. |
| `occlusion_bias` | `1.5` | Added to a chunk top before the horizon test. Higher is more conservative. |
| `occlusion_samples` | `8` | Heightmap samples per camera-to-chunk ray. |

LOD and chunks:

| Property | Default | What it does |
|---|---|---|
| `enable_lod` | `true` | Turn LOD on or off without changing the distances. |
| `lod_distance_0` | `40.0` | Below this distance a chunk uses full resolution. |
| `lod_distance_1` | `80.0` | Below this distance a chunk uses one quarter of the triangles. |
| `lod_distance_2` | `160.0` | Below this distance a chunk uses one sixteenth of the triangles. |
| `chunk_size` | `16` | Cells per chunk side. |
| `editor_lod` | `false` | Off bakes one full-resolution merged mesh in the editor. On builds the whole map with LOD and rebuilds only after the editor camera stops moving. |

Streaming and collision:

| Property | Default | What it does |
|---|---|---|
| `use_image_data` | `true` | Image mode master switch. See How it works. |
| `heightmap_path` | addon `terrain_height.res` | The R32F resource loaded in image mode. |
| `enable_streaming_collision` | `true` | Stream a small collision window under tracked bodies. |
| `stream_batch_size` | `8` | Chunks meshed per streaming batch. Lower means fewer frame hitches. |
| `collision_cell` | `16` | Heightmap cells per collision tile. |
| `collision_radius` | `8` | Cells covered around each tracked body. |
| `collision_overlap` | `8` | Cells each tile is grown on every side so tiles overlap. |

Appearance lives on the material, not the node. `surface_material` (default
`terrain_shader.res`) is the only node property here; edit the rest as shader
parameters on that material. See [Shader reference](#shader-reference).

## Shader reference

Parameters in `glsl.gdshader`, by inspector group. Edit them on the material.

- Quality: `low_quality`.
- Texture: `tile_texture`, `tile_world_size`, `texture_blend`.
- Colors: `color_sand`, `color_grass`, `color_snow`, `color_rock`.
- Terrain: `height_grass_start`, `height_snow_start`, `zone_blend`,
  `rock_threshold`, `rock_blend`, `color_variation`.
- Grass: `grass_density`, `grass_height`, `grass_min_height`, `grass_max_height`,
  `bend_radius`, `lod_grass_enabled`.
- Trample: `trample_map`, `trample_center`, `trample_size`.

All of these live on the material, not the node, so there is a single place to edit
them. Tiling is computed from world position inside the shader (`tile_world_size`),
so there is no manual tile scale to keep in sync. The internal parameters
`lod_grass_enabled` and the trample fields are driven by the plugin at runtime; you
do not set them by hand. `pixels_per_tile` used to be a parameter but is now a fixed
constant in the shader (it only quantizes the noise and grass grid), so it no longer
clutters the inspector.

## Troubleshooting

Generating a small map used to raise an error. This is fixed. The generator now
clamps the map to at least 32 by 32, and degenerate chunks are skipped.

The map looks flat or wrong after opening the project. Make sure the terrain was
baked. In image mode the runtime loads `heightmap_path`. If that file is missing,
the node falls back to the embedded shape and warns in the output. Press
"Bake to files".

The player falls through the terrain. With streaming collision on, ground exists only
inside a window under a tracked body. Only moving bodies are tracked (RigidBody3D,
VehicleBody3D, CharacterBody3D), not Area3D or StaticBody3D, so make sure your player
is one of those. A body far from any tracked body also has no ground under it.

A body falls through the ground far from any tracked body. Only terrain inside a
window has collision. Increase `collision_radius` so the window keeps up.

The tile texture does not show. On the material, raise `texture_blend` above `0`, and
make sure `low_quality` is off, since low quality skips the tile fetch.

## Notes

- The plugin is designed for the Compatibility (GLES3) backend for mobile.
- The bundled `Dark` folder holds sixteen tile textures. The default is `Dark/6.png`.
