# LiteTerrain

<img src="icon.png" width="128" align="right" alt="LiteTerrain icon">

Lightweight heightmap terrain for Godot 4, tuned for mobile. One `LiteTerrain` node builds its own collision body, collision shape, and render mesh, then keeps the map cheap on weak hardware with quadtree LOD and streaming collision. An editor dock drives everything: creating, generating, sculpting, and baking terrain.

Built and tuned on an Adreno 610 (a low-end mobile GPU), so the defaults lean toward performance.

## Features

- **One-node terrain** — press "Create Terrain Node" in the dock (or add a `LiteTerrain` node) and you get a ready terrain: collision, mesh, and the terrain shader, with no manual wiring.
- **Sculpt brushes** — Raise / Lower / Flatten with radius and strength, dab spacing for smooth strokes, and stroke-level undo/redo.
- **Noise generation** — continental FBM + ridge noise with seed, scale, octaves, plains power, mountain amount, ridge sharpness, amplitude, smoothing, and target map size.
- **Image-mode heightmaps** — the map lives in an R32F image instead of one giant `HeightMapShape3D`, so big maps load fast and stay light.
- **Streaming collision** — collision windows follow every moving physics body automatically (RigidBody3D, VehicleBody3D, CharacterBody3D). No setup.
- **Quadtree LOD + culling** — coarse far meshes with skirts, frustum culling, and render-distance control, tuned for mobile GPUs.
- **Baking & export** — bake the heightmap and a preview mesh to `.res` files, or export the heightmap as a grayscale PNG.
- **Terrain shader** — height/slope zone colors, world-space tile texturing, grass, and a `low_quality` toggle for weak GPUs.

## Installation

### From the Asset Library
Search for **LiteTerrain** in the Godot editor's AssetLib tab, install, then enable it in **Project > Project Settings > Plugins**.

### Manually
1. Copy `addons/LiteTerrain/` into your project's `addons/` directory.
2. Enable **LiteTerrain** in **Project > Project Settings > Plugins**.

## Quick start

1. Open a 3D scene and press **➕ Create Terrain Node** in the LiteTerrain dock.
2. Press **Generate Terrain** for noise-based terrain, or sculpt by hand with Raise / Lower / Flatten (left mouse button paints, each stroke is one undo step).
3. Press **Bake to files** when the map is ready, so it loads fast at runtime.

Full documentation — node properties, runtime API (`terrain_height_at`), physics details, performance tuning, shader reference, troubleshooting — is in [`addons/LiteTerrain/README.md`](addons/LiteTerrain/README.md).

## Compatibility

Godot 4.x. Compatibility (GLES3) renderer is recommended — the plugin is tuned for mobile — but it also runs on Forward+. Works with both Godot Physics and Jolt.

## License

[MIT](LICENSE) © MrKrob00
