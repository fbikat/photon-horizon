// photon's settings.glsl options this port keeps, as horizon overrides

// lighting
override sun_i: f32 = 1.0;
override moon_i: f32 = 1.0;
override skylight_i: f32 = 1.0;
override blocklight_i: f32 = 1.0;
override blocklight_warmth: f32 = 1.0;
override colored_lights: bool = true;
override emission_strength: f32 = 1.0;
override shading_strength: f32 = 1.0;
override sss_intensity: f32 = 1.0;
override bounced_light_i: f32 = 1.0;
override cave_lighting_i: f32 = 1.0;
override specular_highlights: bool = true;
override rt_reflections: bool = true;
override rain_puddles: bool = true;
override ssao: bool = true;
override ao_intensity: f32 = 1.0;
override waving_plants: bool = true;
override waving_leaves: bool = true;

// shadows (shadows turns horizon's shadow pass off; resolution and distance size it)
override shadows: bool = true;
override shadow_vps: bool = true;
override colored_shadows: bool = true;
override shadow_pcf_steps: i32 = 12;
override rt_contact_shadows: bool = true;
override ssrt_shadows: bool = true;
override cloud_shadows: bool = true;

// sky
override stars_intensity: f32 = 1.0;
override galaxy: bool = false;
override galaxy_intensity: f32 = 1.0;
override aurora: u32 = 1u;
override rainbows: bool = true;
override crepuscular_rays: bool = true;

// clouds
override clouds_cumulus: bool = true;
override clouds_quality: u32 = 1u;
override clouds_cumulus_coverage: f32 = 1.0;
override clouds_cumulus_density: f32 = 1.0;
override clouds_cirrus: bool = true;
override clouds_cirrus_coverage: f32 = 1.0;

// fog
override vl: bool = true;
override vl_intensity: f32 = 1.0;
override vl_twilight: f32 = 2.0;
override air_fog_density: f32 = 1.0;
override border_fog: bool = true;

// water
override water_wave_strength: f32 = 1.0;
override water_absorption: f32 = 1.0;
override water_texture: u32 = 1u;
override water_reflections: bool = true;
override water_caustics: bool = true;

// post-processing
// bloom is off at intensity 0 (the manifest is at its 64-option limit, so there is no separate switch)
override bloom_intensity: f32 = 1.0;
fn bloom_on() -> bool { return bloom_intensity > 0.0; }
override auto_exposure: bool = false;
override manual_exposure: f32 = 0.0;
override tonemap_operator: u32 = 0u;
override grade_brightness: f32 = 1.0;
override grade_contrast: f32 = 1.0;
override grade_saturation: f32 = 1.0;
override grade_vibrance: f32 = 0.0;
override purkinje_shift: bool = true;
override vignette_intensity: f32 = 1.0;
override dof: bool = false;
override dof_intensity: f32 = 1.0;
override motion_blur: bool = false;
// 0 off, 1 FXAA, 2 SMAA
override anti_aliasing: u32 = 2u;
override cas_intensity: f32 = 0.5;

// Switches for checking the look against Java Photon, one per gap; constants, not options, as the manifest
// already has the 64 options it may.
// Photon's SH_SKYLIGHT: the sky's light by the direction a face looks, not one colour for every face
const sh_skylight: bool = true;
// Photon's sky map (program/d0_sky_map): a low-res map of the whole sky with its clouds, which the SH skylight and
// the sky and cloud reflections read (post/clouds_draw.wgsl, before/cloud_shadows.wgsl); off, the SH sees the sky
// without clouds and reflections reuse last frame's on-screen clouds
const sky_map_clouds: bool = true;
// the sky map's clouds and the air fog behind stained glass, tinted glass and ice (material.wgsl), where photon blends its
// translucent layers over a fully fogged background
const behind_glass_sky: bool = true;
// geometric specular anti-aliasing (material.wgsl): widens highlights where the normal varies faster than a pixel
const specular_aa: bool = true;
// the cumulus light march as photon has it (6 steps of 0.1 of the layer's thickness); off, the older 5 steps of
// 0.25 (1 + stratus), which reach farther and darken thick clouds more
const clouds_photon_light_march: bool = true;
// light shafts weighed by the fog along the ray and over the sky too, as photon's raymarched air fog (post/vlao.wgsl);
// off, the older plain average of the shadow along the ray over terrain only
const vl_weighted_shafts: bool = true;
// Catmull-Rom instead of bilinear upsampling of the half-res cloud history in the composite
const clouds_bicubic_upsample: bool = true;
// Photon's GTAO (2 slices x 3 steps, radius 2, multibounce) in place of the older SSAO, applied to the ambient light
// only (post/vlao.wgsl, post/composite.wgsl); off, the SSAO darkens the whole colour
const gtao: bool = true;
// the foliage's ambient_sss from the GTAO, last frame's, in place of a constant 0.25 (lighting.wgsl)
const gtao_foliage_sss: bool = true;
// skylight passing through foliage (Photon's ambient_sss, from GTAO; approximated, see get_diffuse_lighting)
const foliage_ambient_sss: bool = true;
// sunlight reaching under water dimmed and tinted by 5 m of it, as Photon's shadow pass does
const water_sun_absorption: bool = true;
// Photon's light under water: 4 x 0.25 (its shadow colour's headroom) x its caustics' 0.25 x their area ratio
const water_sun_scale: f32 = 0.3;
// Photon's water caustics: the sunlight under water scaled by the area ratio of the waves' refraction over 5 m
// (water_caustic_ratio in lighting.wgsl) with Photon's 0.25 base, instead of a scrolling noise pattern and
// water_sun_scale
const photon_caustics: bool = true;
// Photon's EDGE_HIGHLIGHT (off by default there, on in the player's Java settings): blocks' convex edges lit up,
// one block pixel wide, by this much (photon: 0.5, so 1.5x)
const edge_highlight: bool = true;
const edge_highlight_strength: f32 = 0.5;

// Photon features that had no counterpart here (docs/photon-parity.md), on as Photon or the player's Java has them
// SKY_GROUND (the player's): below the horizon the atmosphere is seen against the ground, not clamped to it
const sky_ground: bool = true;
// WATER_EDGE_HIGHLIGHT: a pale line where water is shallower than half a block
const water_edge_highlight: bool = true;
// CAVE_FOG: a dim grey fog underground
const cave_fog: bool = true;
// DESERT_SANDSTORM: dust instead of rain where none falls and it is hot (deserts, badlands; savannas too, which
// the frame's temperature and precipitation can't tell apart)
const desert_sandstorm: bool = true;
// HARDCODED_SPECULAR (on in Photon): blocks' smoothness from their texels' brightness by kind ([[materials]]
// ids 7..30 as photon's material masks); only ice, obsidian, metals, gems, end stone and copper reflect
const hardcoded_specular: bool = true;
// cirrocumulus: the small high puffs photon draws on its cirrus layer
const cirrocumulus: bool = true;
// biome fog: each biome category's air fog colour and density (desert, snowy, taiga, jungle, swamp, pale garden),
// eased between them; off, all air fog is the temperate one
const biome_fog: bool = true;
// LIGHTNING_FLASH: lightning lights up the clouds
const lightning_flash: bool = true;
// BLOCK_ENTITY_SHADOWS (the player's): the traced contact shadows also hit entities and the block entities the ray
// tracing scene keeps (chests, shulker boxes, bells, pots, banners), which Horizon's shadow map lacks
const block_entity_shadows: bool = true;
// AIR_FOG_CLOUDY_NOISE: the mist thicker and thinner in drifting patches hundreds of blocks wide
const air_fog_cloudy_noise: bool = true;
// WATER_PARALLAX: the waves' detail shifts with the view as if 0.2 blocks deep
const water_parallax: bool = true;
// END_GLOW: glowing purple and green wisps in the End's fog
const end_glow: bool = true;
// FANCY_NETHER_PORTAL: the portal's swirl seen in layers going into it ([[materials]] id 40)
const fancy_nether_portal: bool = true;
// AURORA_CLOUD_LIGHTING: clouds under a visible aurora are lit by its colour (post/clouds_draw.wgsl)
const aurora_cloud_lighting: bool = true;
// photon's dither_8bit on the final colour, in the display's encoding (tonemap.wgsl), against banding in smooth gradients
const dither_output: bool = true;
