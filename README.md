# Photon for Horizon

An unofficial port of [Photon Shaders](https://github.com/sixthsurge/photon) by SixthSurge to
[Horizon](https://playhorizon.dev)'s own native shader pack format (`.hshader`, **Shader API 0.2**). All credit for the
artistic direction and shading math goes to SixthSurge and Photon's contributors; this project is not affiliated with or
endorsed by them.

## Install

Download `photon-2.0.0.hshader` from the releases (or build it below), place it in your Horizon `shaderpacks` folder,
and select **Photon** under **Options > Video Settings > Shaders > Shader Packs**. **Shader Options...** exposes 64
settings across 7 pages (`Lighting`, `Shadows`, `Sky`, `Clouds`, `Fog`, `Water`, `Post-Processing`).

## What's ported

- **Atmosphere & Sky**: Bruneton precomputed atmospheric scattering LUT, sun disc with limb darkening, textured **Moon disc
  with full `moon_phase` lighting & phase brightness**, twinkling blackbody stars, optional Milky Way galaxy, **aurora
  borealis** (off / snowy biomes / always), **rainbows** opposite the sun, **crepuscular rays**, and custom **Nether**
  lava-haze & **End** void / cosmic nebula / gravitationally lensed **black hole accretion vortex**
- **Volumetric Clouds & Cloud Shadows**: Temporal-reprojected **Cumulus / Stratocumulus / Stratus**, **Altocumulus**,
  distant **Cumulus Congestus** (Quality presets), **Cirrus**, and twilight **Noctilucent** clouds, plus a dedicated
  `[[before_world]]` compute **cloud shadow map** shadowing terrain, entities, water, and volumetric fog
- **Shadows & Hardware Ray Tracing**: Distorted **PCSS / Variable Penumbra Shadows**, colored stained-glass & water
  shadows, **SSRT distant screen-space shadows** beyond shadow map range, and optional **Hardware RT contact shadows &
  reflections** (`has_ray_tracing`) on water and smooth LabPBR materials
- **Materials, Entities & Colored Lighting**: Foliage SSS & leaf sheen, waving plants and leaves, LabPBR normal &
  specular highlights, **rain puddles** with porosity darkening, animated raindrop ripples & **Land SSR** fallback,
  directional **water caustics** on underwater blocks and mobs, full **`[entity]`** shading (mobs, block entities,
  falling blocks, hurt/creeper flashes), **`[[lights]]` colored block lighting** (torches, soul fire, copper lights,
  redstone, froglights, sculk, amethyst, portals) and **`[[particle_lights]]`**, **SSAO** contact occlusion, and
  Purkinje shift
- **Water & Fog**: 3-octave animated Gerstner waves, Fresnel + SSR/RT reflections, biome-tinted absorption &
  refraction, analytic Overworld air fog with volumetric light shafts, border fog, Nether/End/underwater/lava/powder-snow
  fogs
- **Post-Processing**: 5-level **CoD:AW + progressive tent Bloom** via compute passes, temporal **Auto Exposure**,
  optional **Vogel-disc Depth of Field** (off by default), optional **camera-reprojected YCoCg TAA** (off by default),
  SDR & HDR **color grading / tonemapping** (`Lottes`, `ACES Fit`, `Hejl 2015`, `Uncharted 2`, `Tech`, `Reinhard-Jodie`),
  camera motion blur, **FXAA**, and edge-adaptive **EASU & CAS** sharpening

## Remaining Engine Gaps

These items depend on Horizon shader runtime features not yet exposed to packs:

- **First-person hand, held/dropped items, and particle shading**: Horizon's `[entity]` stage currently drives mobs and
  block entities; items, particles, and the first-person hand still use Horizon's built-in renderer (though particles
  contribute dynamic colored light via `[[particle_lights]]`)
- **Voxel Flood-Fill LPV GI**: Horizon provides a 3-D camera-centered `[[lights]]` color grid rather than full opaque
  voxel bounce propagation; block-light occlusion continues to come from vanilla sky/block light levels
- **Per-object `[motion]` vectors**: Horizon's `[motion]` motion guide is not enabled at runtime yet, so optional **TAA**
  reprojects via `frame.previous_view_projection` + `frame.camera_motion` (which can show slight ghosting on moving mobs
  when enabled)

## Building

```sh
python -P tools/bake_textures.py <photon>/shaders pack/textures   # Photon's 3-D textures as PNGs
python -P tools/gen_manifest.py tools/manifest_head.toml pack/horizon-shaders.toml
horizon-shader check pack
horizon-shader pack pack --out dist/photon-2.0.0.hshader
```

## Licence

Photon's licence (see [LICENSE](LICENSE)): free to share, but not for money, and not on sites that pay creators
(such as Modrinth or CurseForge) without SixthSurge's written permission. The atmosphere mapping functions are
Eric Bruneton's (BSD-3-Clause, also in LICENSE).
