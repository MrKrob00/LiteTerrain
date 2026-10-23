# LiteTerrain

**Version 2.0** · Godot 4.6 / 4.7 · tuned for mobile (Compatibility renderer)

Procedural terrain stored and drawn in CHUNKS. One node builds the whole world from a seed: no
heightmap file, no world-sized array, no edge. A chunk asks the generator for its own vertices,
LOD merges four chunks into one mesh instead of decimating anything, and collision is cut only
under the bodies that need it.

Biomes — desert, meadow, salt flats, canyon, mountains — live in one resource that drives the
landform, the masks and the colours at once, so a biome's shape cannot drift away from its look.

> **2.0 is a new design, not an update of 1.x.** The 1.x line was a single node script (`map.gd`)
> over a baked height map, with a dock for sculpting, noise generation and baking. 2.0 has no
> height map at all: the ground IS the seed. The sculpt brush, the generate/bake buttons, the
> `LiteTerrain` node, `use_image_data` and the `Dark/` tile textures are gone, and the node is now
> `ChunkTerrain`. A project that used 1.x terrain data has to rebuild its scenes — there is nothing
> to convert, because 2.0 reads no height files.

## Architecture

```
                         ┌──────────────────────────────────────────────┐
  Add Node → ChunkTerrain│  ChunkTerrain  (chunk_terrain.gd)            │
                         │  the node: LOD tree · build queue · thread   │
                         │  pool · collision tiles · edits · occlusion  │
                         └───────┬───────────────────────────┬──────────┘
                    asks for     │                           │  writes colours, masks,
                    heights      ▼                           ▼  settings
          ┌──────────────────────────────┐     ┌──────────────────────────────┐
          │ LiteTerrainGen               │     │ TerrainBiomes (a Resource)   │
          │ (terrain_gen.gd)             │◄────│ (terrain_biomes.gd)          │
          │ height_at(x, z): noise, blur │masks│ biome masks, their noise,    │
          │ and the canyon cut at ONE    │     │ the colours handed on to the │
          │ world point; sample_grid     │     │ shader                       │
          └──────────────────────────────┘     └───────────────┬──────────────┘
                                                               │ vertex COLOR + uniforms
                                                               ▼
                                          ┌──────────────────────────────────┐
                                          │ glsl.gdshader  (terrain_shader.  │
                                          │ tres, ground_detail.png)         │
                                          │ biome colour · slope rock · grass│
                                          │ lift · detail masks · haze       │
                                          └──────────────────────────────────┘

  Editor only:  plugin.gd ─► terrain_inspector.gd ─► preview_panel.gd
                (viewport camera, shader globals)    ("Build in scene" / "Clear")
```

Each layer has one job and one door:

- **The generator answers by point and nothing else.** `height_at(wx, wz)` is the ground; a chunk is a
  grid of it. Nothing in it touches the scene or a file, so it runs on worker threads and the same
  seed gives the same world in the editor, in the game and on a phone.
- **The node owns time and memory**: which nodes exist this tick (distance), which of them are drawn
  (frustum), what is computed next (queues), what is kept (caches) and which collision tiles are cut.
- **The biomes are data**: one resource drives the landform, the masks and the colours, and bakes the
  masks into the vertices, so the shader never recomputes them.
- **The shader only reads**: colour, rock, snow, grass and detail from vertex data and a few uniforms.

## Files

| File | What it is |
|---|---|
| `chunk_terrain.gd` | `ChunkTerrain`, the node: LOD selection, the build queue, collision tiles, edits. |
| `terrain_gen.gd` | `LiteTerrainGen`: the height at a world point (`height_at`) and grids of it (`sample_grid`). |
| `terrain_biomes.gd` | `TerrainBiomes`: the biome masks, their noise and the colours handed to the shader. |
| `glsl.gdshader` | The ground shader: biome colour, slope rock, grass lift, detail masks, haze. |
| `terrain_shader.tres` | The ground's material (a ShaderMaterial on `glsl.gdshader`); every uniform shows in the inspector. |
| `ground_detail.png` | Four tileable detail masks in one texture. |
| `plugin.gd`, `terrain_inspector.gd`, `preview_panel.gd` | Editor only: the buttons at the top of the node's inspector that build the ground round the editor camera, and the shader globals. |

## Install

1. Copy `addons/lite_terrain/` into your project's `addons/` folder (or install it from the Asset Store).
2. **Project > Project Settings > Plugins** → enable **LiteTerrain**.

Enabling the plugin declares the global shader uniforms the ground shader reads (see
[Shader globals](#shader-globals)); without the haze pair the shader does not compile. They are
written to `project.godot` and Godot reads them at start-up, so **restart the editor once** after
enabling the plugin for the first time (before that you may see a one-time "Global uniform
'world_haze' does not exist" message).

## Quick start

1. Add a **ChunkTerrain** node to a 3D scene (by name — the script has a `class_name`).
2. Set `forced_seed` in the inspector (any integer; the same seed is the same world).
3. Give it a `TerrainBiomes` resource in `biomes`, or leave it empty and it makes one.
4. Press **Build in scene** at the top of its inspector to build the real ground round the editor
   camera; after changing the material's settings press it again to see them.
5. Make sure the scene has a current `Camera3D` and a `DirectionalLight3D` (the ground is lit like any
   other lit surface), then run it: the ground is built round the camera the scene is drawn with, and
   collision tiles follow every `RigidBody3D` / `CharacterBody3D`.

There is nothing to generate into a file and nothing to bake: the ground IS the seed.

## The node

`ChunkTerrain` extends StaticBody3D and makes everything it needs itself (chunk meshes, collision
shapes as internal children), so the scene stays a single node.

In the inspector:

| Property | What it does |
|---|---|
| `surface_material` | The ground's material: `terrain_shader.tres` by default, every uniform in the inspector. The node draws with a copy, into which `biomes` writes its part (see the shader reference). |
| `biomes` | The `TerrainBiomes` resource. |
| `enable_occlusion_culling` | What stands behind a hill is not drawn (`is_point_hidden`, for veins, props and machines you place on the ground). |
| `forced_seed` | The world's seed. The editor preview builds with it. |
| Render: `view_distance`, `haze_enabled` | How far ground is drawn (200 m – 10 km); whether the distance haze is on. |
| Biomes: `desert_enabled`, `canyons_enabled`, `mountains_enabled`, `salt_flats_enabled` | Switch a biome off for the whole map; landform, colour and masks all agree. |
| Vertex lift: `grass_lift_enabled`, `snow_lift_enabled` | The grass blades and the snow crust, lifted in the vertex stage. |

Fields a script can set (a menu backdrop or a second map would):

| Field | What it does |
|---|---|
| `follow_world_settings` | On: if an autoload called `G` exists and has `world_seed`, that is the seed (one world per save slot). Otherwise — and in any project without such an autoload — `forced_seed`. |
| `keep_radius` | Inside what radius nothing built is ever dropped. |
| `ready_ring`, `ready_view` | What must be up before `terrain_ready`: chunks with collision round the start, then the view out to this many metres. |
| `enable_streaming_collision` | Collision tiles round moving bodies. |

Constants, not settings: `FRUSTUM_MARGIN`, `BUILD_BATCH`, `STITCH_BUDGET`, `LOD_INTERVAL`,
`APPLY_BUDGET`, `COLLISION_RADIUS`, `COLLISION_LOOKAHEAD`, `WORLD_CELLS` (a NOMINAL square for
`get_dims`, not an edge), `OCCL_MIN_DIST`, `OCCL_BIAS`. The camera is always the one the scene is
drawn with, the material always `glsl.gdshader`, frustum culling always on.

## Biomes

A biome is a 0..1 **mask** of world-XZ value noise (`TerrainBiomes.cv_noise`, handed to the masks
as `biomes.noise`). Layers stack in this order:

```
base DESERT ↔ MEADOW  →  SALT FLATS on the desert  →  CANYON  →  MOUNTAINS
```

| Group | Settings |
|---|---|
| Desert / Meadow | `biome_scale`, `biome_bias`, `biome_blend`, `biome_contrast`, `color_sand`, `color_grass`, `dune_wavelength`, `desert_flatten` |
| Salt flats | `salt_scale`, `salt_threshold`, `salt_edge`, `color_salt` |
| Canyon | `canyon_scale`, `canyon_threshold`, `canyon_edge`, `color_canyon`, `canyon_band_height`, `canyon_butte_scale` |
| Mountains | `mountain_scale`, `mountain_threshold`, `mountain_edge` |
| Snow / rock | `color_snow`, `snow_frac`, `snow_blend_frac`, `color_rock`, `rock_threshold`, `rock_blend` |
| Grass | `grass_density`, `grass_height`, `sand_grass`, `grass_shade` |

- Every layer is on unless its switch on the node says otherwise. `mask_offset` is not a setting: it
  is worked out from the seed (`offset_for_seed`) wherever a world is built.
- Heights in metres follow the world's Height, not knobs: dunes, a mountain's rise, the gorge depth
  (`terrain_gen.prepare_sampling`) and the snow line (`snow_frac` × Height).
- Rock follows SLOPE, snow follows the mountain mask AND height, grass grows on the meadow and,
  sparser, on sand (`sand_grass`).
- `canyon_band_height` sizes both the colour strata and the geometry terraces.
- The size of a biome patch is set by its `*_scale` and nothing else (a mask is one octave and a
  threshold, so it has no size floor; lowering a threshold removes slivers but changes how much of
  the map the biome covers).
- A new biome is a shader edit too: each layer's colour is a `mix()` in `glsl.gdshader`'s `vertex()`.

The masks are baked into the vertex COLOR per vertex (`ChunkTerrain._biome_colour`): `.g` canyon,
`.b` meadow, `.a` mountain, and `.r` carries two things — the vertex's border code (0 inside its
node, 1 on a border along x, 2 along z) and the salt flat: `EDGE_STEP` × code + `SALT_SPAN` × salt.

The grass is the same function of the world point on every level (`blade_at` in the shader): each
vertex lifted straight up, a border vertex at an odd metre taking the mean of its two neighbours
along the border, so a seam between any two levels lifts alike whenever each side was built. It
fades out before level 2 begins (`ChunkTerrain.grass_fade`).

## Runtime API

```gdscript
terrain.terrain_height_at(world_pos: Vector3) -> float  # ground height under a world point
terrain.ground_sample(world_pos: Vector3) -> Vector3    # (height, dh/dx, dh/dz): the same patch, with its slope
terrain.biome_at(world_pos: Vector3) -> Vector3         # (canyon, meadow, mountain) masks
terrain.salt_at(world_pos: Vector3) -> float
terrain.world_height() -> float                         # the Height the world was built with
terrain.terrain_is_ready                                # the near ground is up (a bool and a signal, terrain_ready)
terrain.set_collision_streaming(on: bool)
terrain.is_point_hidden(world_pos: Vector3, height := 1.0, was_hidden := false) -> bool  # behind a hill?
terrain.set_grass_trample(tex: Texture2D, center: Vector2, size: float)  # a texture that presses the grass flat
terrain.stop_generation()                               # wait out the running tasks; call before freeing
```

A height is read from a BUILT level-0 chunk when one holds that cell, and asked of the generator
only otherwise (`_memo_h`). WAIT FOR THE GROUND BY THE CLOCK, NOT BY FRAMES: readiness is worker
threads computing heights, which is real seconds. Use `terrain_height_at` only after
`terrain_ready`; before it the answer is not the ground.

### Editing the ground at runtime

```gdscript
terrain.flatten_area(center: Vector3, half_extent: Vector2, height: float, feather := 4.0, record := true)
terrain.ground_edits() -> Array          # plain dictionaries, JSON-ready
terrain.apply_ground_edits(list: Array)  # replay them on load
terrain.reset_heights()                  # forget every edit
```

A pad is a RECTANGLE (buildings are oblong). Edits are a LIST applied on top of the generator in
one function, so the mesh, the collision and a height query see the same ground; replay them before
restoring anything that stands on them. Every edit carries a running number, so a save replayed
twice cannot deepen a pad. The edit list is the only thing worth saving: the ground itself is the seed.

## Collision

A collision tile IS a base chunk, cut from the same heights as the level-0 mesh. Tiles have their
OWN queue and it goes first (a tile is what a body drives on, a mesh what it looks at), and they
are asked for along each body's CORRIDOR: where it is plus where it will be in
`COLLISION_LOOKAHEAD` seconds. Moving bodies (`RigidBody3D`, `CharacterBody3D`) are found through the
tree's `node_added` / `node_removed`; a body riding another is covered by its parent, a sleeping
one and one carrying the meta `asleep` get no tiles. The terrain itself is on collision layer 1
and scans nothing (mask 0). `StaticBody3D` and `Area3D` never ask for ground. Tested with both
Godot Physics and Jolt.

**A body needs ground under it before it is released.** The first ring of tiles is built round the
camera (or the saved start point) before `terrain_ready`; a tile is *computed*, not cut from a ready
array, so one asked for later takes a moment. A body placed outside the ring, or dropped from a
height onto ground whose tile is not up yet, can fall below the surface — a height field has no
thickness, so it never comes back. Keep such a body frozen (or off) until
`has_collision_at(world_pos)` is true:

```gdscript
await terrain.terrain_ready
while not terrain.has_collision_at(body.global_position):
    await get_tree().physics_frame
body.freeze = false
```

## Shader globals

The ground shader reads global uniforms, which a project declares in its `[shader_globals]` section.
The plugin adds the ones that are missing when it loads, with the values the ground was tuned with,
and leaves a project's own values alone:

| Global | Type | Default | Read | What it is |
|---|---|---|---|---|
| `world_haze` | color | (0.86, 0.80, 0.70) | always | The distance haze's colour — also what the sky's horizon should be. |
| `haze_range` | vec4 | (150, 750, 0.85, 0) | always | x, y: where the haze begins and ends (m); z: its strength. The node rewrites z from `haze_enabled`. |
| `sun_dir` | vec4 | (0.836, 0.402, 0.374, 0) | `fast_ground` | Direction toward the sun. |
| `ground_amb` | vec4 | (0.24, 0.22, 0.19, 0) | `fast_ground` | Ambient tint of the ground's own lighting. |
| `ground_sun` | vec4 | (1.0, 0.93, 0.80, 0) | `fast_ground` | Sun tint of the ground's own lighting; `.a` wraps the diffuse term. |

Change them at run time with `RenderingServer.global_shader_parameter_set()` — for example from a
day/night cycle. They stay in the project when the plugin is disabled: a shader that is still
compiled cannot lose them.

### `fast_ground`: a cheaper ground for phones

By default the ground is lit by the scene's `DirectionalLight3D` and environment like any surface.
Setting `terrain.fast_ground = true` swaps it for an unshaded variant of the same shader that lights
itself per vertex from `sun_dir`, `ground_amb` and `ground_sun`, and reads up to three sun-shadow maps
you hand over with `set_sun_shadows(maps, uvs, strength)`. It skips the engine's whole light loop for
the ground, which is most of the screen on a fill-bound GPU — the price is that you keep those three
globals current yourself. The game this was built for does it with a day/night cycle and its own
shadow cascades.

## How it works (short)

- **No data model.** `LiteTerrainGen.height_at(wx, wz)` is noise, a five-tap blur and the canyon
  cut at one world point; that is the only ground there is. At step 1 the blur's taps are the
  neighbouring vertices, so a chunk costs (n+2)² raw heights instead of 5n² (`_sample_unit`).
- **LOD is chunk merging.** A node of level L covers 2^L × 2^L chunks of 16 cells and is drawn
  with the same 16×16 quads at step 2^L. Neighbours differ by one level at most, and the finer one
  snaps its edge onto the coarser's line — no skirts anywhere.
- **Sub-pixel ground is not split.** A node the distance rule would split stays whole when its
  children's cells would cover under two pixels on screen — the far plain seen at a grazing angle.
- **Two questions, two rates.** The leaf set comes from distance alone and is cached
  (`_build_leaves`, rebuilt after 16 m of camera travel); the frustum is a flat pass over it.
- **Compute in a batch, land on a budget.** The pool computes `BUILD_BATCH` chunks at once; the
  main thread lands at most `APPLY_BUDGET` meshes a frame (none of that while loading).
- **A node is hidden only when other ground covers it** (`_covered`): a LOD change is a
  replacement still in the queue, and hiding the old node at once opened a hole.
- **A level change goes up as one unit**: a built mesh that does not meet what is drawn round it is
  held until all of its change is built, so no T-junction crack shows while driving.
- **One material, no instance uniforms**: the grass is the same function of the world point on
  every level. An instance uniform on a chunk takes 16 slots of the global shader buffer each, and
  there are hundreds of chunks.
- **Behind a hill reads the drawn ground** (`is_point_hidden`): the heights the drawn node's mesh
  was built from, never the generator — cheaper, and what the screen shows.

## Shader reference

`glsl.gdshader`, worn by the node's `surface_material` (`terrain_shader.tres`), where every uniform
shows in the inspector. The node draws with a copy of that material, into which the biomes write the
colours, snow, rock, sand grass, canyon bands, grass density/height/shade and the detail texture
(`TerrainBiomes.apply_to_material`): tune those in the biomes, everything else on the material.

- **Texture**: `ground_detail`, `detail_world_size`, `ripple_strength`, `grass_detail`,
  `patch_strength`, and the per-biome stroke tints `*_dark` / `*_light`, `rock_facets`.
- **Colours / terrain / biomes**: `color_*`, `snow_line`, `snow_blend`, `rock_threshold`,
  `rock_blend`, `sand_grass`, `canyon_band_h`, `crack_strength`.
- **Grass**: `grass_density`, `grass_height`, `grass_shade`, `grass_fade` (set by the node),
  `snow_height`.
- **Trample**: `trample_map`, `trample_center`, `trample_size`, `trample_on` (set through
  `set_grass_trample`).
- **Sun shadows**: `sun_shadow_map*`, `sun_shadow_uv*`, `sun_shadow_strength` (set through
  `set_sun_shadows`; optional — the ground draws without them).
- **Globals**: see [Shader globals](#shader-globals).

## Troubleshooting

**Nothing appears.** The node builds round the camera the scene is DRAWN with — check one is
`current`.

**The ground is pink or invisible.** The shader could not compile because a global uniform is
missing: disable and enable the plugin once (it declares them), or add the globals from the table
above under **Project Settings > Shader Globals** (at least `world_haze` and `haze_range`).

**A body falls through the ground.** It was released before its tile existed, or it was placed
outside the first ring: wait for `terrain_ready` and then for `has_collision_at(pos)` (see
[Collision](#collision)). Reading a height before `terrain_is_ready` has the same cause.

**A hole opens while driving.** See `_covered` above: if you touch that rule, this is what breaks.

**The editor preview is somewhere else.** It builds round the editor viewport's camera, which the
plugin hands over when the mouse moves over the 3D view.

## License

MIT — see `LICENSE`.
