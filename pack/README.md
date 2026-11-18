# Photon for Horizon

[Photon Shaders](https://github.com/sixthsurge/photon) by SixthSurge, ported to Horizon's native shader pack format
(`.hshader`, **Shader API 0.2**).

Includes Photon's precomputed Bruneton atmosphere, sun & moon disc with `moon_phase` lighting, stars, Milky Way galaxy,
aurora borealis, rainbows, crepuscular rays, custom Nether & End black hole skies; multi-layer volumetric clouds
(cumulus, altocumulus, congestus, cirrus, noctilucent) with compute cloud shadows; soft colored PCSS shadows, SSRT
distant shadows, and hardware ray-traced contact shadows & reflections; LabPBR highlights, foliage SSS, rain puddles with
ripples & Land SSR, animated water caustics, entity lighting, `[[lights]]` & `[[particle_lights]]` multi-colored block
lighting, SSAO, Purkinje shift, 5-level compute bloom, auto exposure, optional Depth of Field, optional camera-reprojected
TAA, color grading, tonemapping, FXAA, and EASU & CAS sharpening.

Remaining engine-side gaps (not yet exposed by Horizon's runtime): custom pack shading for the first-person hand,
items, and particles (`entity` covers mobs & block entities today), full voxel bounce LPV GI beyond `[[lights]]`, and
per-object `[motion]` vectors (so moving entities can show slight ghosting if optional TAA is turned on).

All credit for the artistic direction goes to SixthSurge and Photon's contributors. This port follows Photon's licence
(see LICENSE): it may be shared freely, but not sold, and not uploaded to sites that pay creators (such as Modrinth or
CurseForge) without SixthSurge's written permission.
