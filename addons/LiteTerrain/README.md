# LiteTerrain

A lightweight Godot 4 editor plugin for sculpting and generating heightmap-based terrain directly in the 3D viewport.

## Features

- **Sculpt brush** — raise, lower, and flatten terrain with a configurable radius/strength brush (left-click to sculpt, mouse wheel to resize).
- **Noise generation** — one-click procedural terrain (continental FBM + ridge noise) with seed, scale, octaves, power curve, mountain amount, ridge sharpness, amplitude, and smoothing controls.
- **Chunked runtime renderer** (`map.gd`) — LOD, frustum culling, and horizon-based occlusion culling for the generated terrain mesh, plus streaming for large maps.
- Full undo/redo support for both sculpting and generation.

## Installation

1. Copy the `addons/LiteTerrain` folder into your project's `addons/` directory.
2. In Godot, go to **Project > Project Settings > Plugins** and enable **LiteTerrain**.

## Usage

1. Click **➕ Add LiteTerrain Node** in the LiteTerrain dock (left), or add a **LiteTerrain** node from the Create Node dialog. The collision and mesh helpers are managed internally — the node is a single clean entry in the scene tree.
2. With the node selected, click **Generate Terrain** for a procedural base, then use the Raise/Lower/Flatten brush to hand-sculpt details.

The heightmap and material are exposed as the node's **Terrain Shape** and **Terrain Material** inspector properties. Old-style scenes with visible `CollisionShape3D`/`MeshInstance3D` children are migrated automatically on load.

## Contents

| File | Purpose |
| --- | --- |
| `plugin.cfg` / `plugin.gd` | Editor plugin entry point and sculpt/generation dock. |
| `map.gd` | Runtime terrain node: chunking, LOD, culling, streaming. |
| `glsl.gdshader` | Height/slope-based terrain shader (sand/grass/rock/snow zones + tiled texture overlay). |
| `terrain_shader.res` | Ready-to-use `ShaderMaterial` for `glsl.gdshader`. |
| `Dark/` | Prototype tile textures used by the default material. |

Note: no pre-baked heightmap or mesh is shipped — `HeightMapShape3D` data and the render mesh are created by you (via Generate/Sculpt and the first bake) rather than bundled with the plugin.
