# Photon for Horizon

An unofficial port of [Photon Shaders](https://github.com/sixthsurge/photon) by SixthSurge to
[Horizon](https://playhorizon.dev)'s own native shader pack format (`.hshader`, **Shader API 0.2**). All credit for the
artistic direction and shading math goes to SixthSurge and Photon's contributors; this project is not affiliated with or
endorsed by them.

## Install

Download `photon-2.0.0.hshader` from the releases (or build it below), place it in your Horizon `shaderpacks` folder,
and select **Photon** under **Options > Video Settings > Shaders > Shader Packs**. **Shader Options...** exposes 64
settings across 7 pages (`Lighting`, `Shadows`, `Sky`, `Clouds`, `Fog`, `Water`, `Post-Processing`).

Needs a Horizon build from 2026-11-18 or later: the pack reads `RayHit.shade` and `EntityInput.full_light`, which
older builds refuse. With the pack loaded, Horizon turns off its TAA upscaling and frame generation (the pack has post
passes of its own), so **Resolution Scale** below 100% is the way to trade sharpness for speed: the pack draws at
the scaled size, its EASU & CAS pass sharpens that picture, and Horizon scales it to the window.

## What's ported

- **Atmosphere & Sky**: Bruneton precomputed atmospheric scattering LUT, sun disc with limb darkening, textured **Moon disc
  with full `moon_phase` lighting & phase brightness**, twinkling blackbody stars, optional Milky Way galaxy, **aurora
  borealis** (off / snowy biomes / always), **rainbows** opposite the sun, **crepuscular rays**, and custom **Nether**
  lava-haze & **End** void / cosmic nebula / gravitationally lensed **black hole accretion vortex**
- **Volumetric Clouds & Cloud Shadows**: **Cumulus / Stratocumulus / Stratus**, **Altocumulus**, distant **Cumulus
  Congestus** (Quality presets), **Cirrus**, and twilight **Noctilucent** clouds, drawn as Photon draws them: one ray
  per 4x4 pixels a frame on a 16-frame checkerboard (`CLOUDS_TEMPORAL_UPSCALING 4`), resolved into a half-res history
  that follows each layer's wind and keeps a per-pixel sample count, and blended over terrain only where the clouds are
  nearer than it. A dedicated `[[before_world]]` compute **cloud shadow map** shadows terrain, entities, water, and
  volumetric fog
- **Shadows & Hardware Ray Tracing**: Distorted **PCSS / Variable Penumbra Shadows**, colored stained-glass & water
  shadows, **SSRT distant screen-space shadows** beyond shadow map range, and optional **Hardware RT contact shadows &
  reflections** (`has_ray_tracing`) on water and smooth LabPBR materials
- **Materials, Entities & Colored Lighting**: Foliage SSS & leaf sheen, waving plants and leaves, LabPBR normal &
  specular highlights, **rain puddles** with porosity darkening, animated raindrop ripples & **Land SSR** fallback,
  directional **water caustics** on underwater blocks and mobs, full **`[entity]`** shading (mobs, block entities,
  falling blocks, hurt/creeper flashes), **`[[lights]]` colored block lighting** (torches, soul fire, copper lights,
  redstone, froglights, sculk, amethyst, portals) and **`[[particle_lights]]`** for moving and magic particles (not the
  flames of light blocks, which light through `[[lights]]` already), half-res **SSAO** accumulated over frames, and
  Purkinje shift
- **Water & Fog**: 3-octave animated Gerstner waves, Fresnel + SSR/RT reflections with the clouds reflected where
  they are on screen, biome-tinted absorption & refraction, Photon's analytic Overworld air fog (height falloff,
  morning mist, rain and snow densities, sunlight dimmed in rain, over the sky as well as terrain) with half-res
  volumetric light shafts accumulated over frames, border fog, Nether/End/underwater/lava/powder-snow fogs
- **Post-Processing**: 5-level **CoD:AW + progressive tent Bloom** via compute passes, optional temporal **Auto
  Exposure** metered over the whole frame (off by default, as in Photon), optional **Vogel-disc Depth of Field** and camera motion blur (off by default, folded
  into the grading pass), **SMAA 1x** (the default, with
  the area function computed in the shader instead of looked up) or **FXAA**,
  SDR & HDR **color grading / tonemapping** (`Lottes`, `ACES Fit`, `Hejl 2015`, `Uncharted 2`, `Tech`, `Reinhard-Jodie`),
  and edge-adaptive **EASU & CAS** sharpening

## Remaining Engine Gaps

These items depend on Horizon shader runtime features not yet exposed to packs:

- **First-person hand, held/dropped items, and particle shading**: Horizon's `[entity]` stage currently drives mobs and
  block entities; items, particles, and the first-person hand still use Horizon's built-in renderer (though particles
  contribute dynamic colored light via `[[particle_lights]]`)
- **Voxel Flood-Fill LPV GI**: Horizon provides a 3-D camera-centered `[[lights]]` color grid rather than full opaque
  voxel bounce propagation; block-light occlusion continues to come from vanilla sky/block light levels
- **Projection jitter**: Horizon does not jitter the projection, so Photon's **TAA** is not ported (SMAA or FXAA
  take its place) and Photon's per-frame dither is held still

## Building

```sh
python -P tools/bake_textures.py <photon>/shaders pack/textures   # Photon's 3-D textures as PNGs
python -P tools/gen_manifest.py tools/manifest_head.toml pack/horizon-shaders.toml
horizon-shader check pack
horizon-shader pack pack --out dist/photon-2.0.0.hshader
```

Horizon's own packs have no language files: a manifest's option names are shown as written. So the option names
and descriptions also come in Chinese, as a second build of the same pack (same id `photon`, so the selection and
the saved option values are shared):

```sh
# into Horizon's shaderpacks folder as photon/, in the game's language (options.txt `lang:`; zh_* gets Chinese)
python -P tools/gen_manifest.py tools/manifest_head.toml pack/horizon-shaders.toml --install
# or a Chinese build to pack yourself
python -P tools/gen_manifest.py tools/manifest_head.toml pack/horizon-shaders.toml --zh dist/photon_zh
horizon-shader pack dist/photon_zh --out dist/photon-2.0.0-zh.hshader
```

## Licence

Photon's licence (see [LICENSE](LICENSE)): free to share, but not for money, and not on sites that pay creators
(such as Modrinth or CurseForge) without SixthSurge's written permission. The atmosphere mapping functions are
Eric Bruneton's (BSD-3-Clause, also in LICENSE).
