# Photon for Horizon

An unofficial port of [Photon Shaders](https://github.com/sixthsurge/photon) v1.4 by SixthSurge to
[Horizon](https://playhorizon.dev)'s own shader pack format (`.hshader`, shader API 0.1). All credit for the look
goes to SixthSurge and Photon's contributors; this is not affiliated with or endorsed by them.

## Install

Download `photon-1.4.0.hshader` from the releases, put it in your `shaderpacks` folder and pick **Photon** on
Options > Video Settings > Shaders > Shader Packs. Shader Options... has 61 of Photon's settings on 7 pages.

## What's ported

- Photon's atmosphere (its precomputed scattering table), sun, stars and galaxy
- Its lighting: soft, coloured shadows, subsurface scattering on foliage, block light falloff, LabPBR highlights
- Water: waves, absorption, refraction, Fresnel reflections on Horizon's water mirror
- Waving plants and leaves
- Volumetric cumulus clouds and cirrus, accumulated over frames
- Air fog with light shafts, underwater fog
- Bloom, colour grading, Photon's tone curves, motion blur, FXAA and CAS sharpening

## Missing

Horizon's shader API can't do these yet: TAA, ambient occlusion beyond vanilla's, reflections on land, depth of
field, moon phases, the altocumulus, cumulus congestus and noctilucent clouds, aurora and rainbows, shading of
entities, block entities, the hand and particles, and Photon's Nether and End looks. Weather follows Horizon's
clock instead of the world's day count.

## Building

```sh
python -P tools/bake_textures.py <photon>/shaders pack/textures   # Photon's 3-D textures as PNGs
python -P tools/gen_manifest.py tools/manifest_head.toml pack/horizon-shaders.toml
horizon-shader pack pack --out dist/photon-1.4.0.hshader            # from horizon-rust/horizon
```

## Licence

Photon's licence (see [LICENSE](LICENSE)): free to share, but not for money, and not on sites that pay creators
(such as Modrinth or CurseForge) without SixthSurge's written permission. The atmosphere mapping functions are
Eric Bruneton's (BSD-3-Clause, also in LICENSE).
