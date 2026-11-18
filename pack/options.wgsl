// photon's settings.glsl options this port keeps, as horizon overrides

// lighting
override sun_i: f32 = 1.0;
override moon_i: f32 = 1.0;
override skylight_i: f32 = 1.0;
override blocklight_i: f32 = 1.0;
override blocklight_r: f32 = 1.0;
override blocklight_g: f32 = 0.75;
override blocklight_b: f32 = 0.63;
override emission_strength: f32 = 1.0;
override shading_strength: f32 = 1.0;
override sss_intensity: f32 = 1.0;
override bounced_light_i: f32 = 1.0;
override cave_lighting_i: f32 = 1.0;
override waving_plants: bool = true;
override waving_leaves: bool = true;
override specular_highlights: bool = true;
override ssao: bool = true;
override ao_intensity: f32 = 1.0;

// shadows (shadows turns horizon's shadow pass off; resolution and distance size it)
override shadows: bool = true;
override shadow_vps: bool = true;
override colored_shadows: bool = true;
override shadow_penumbra_scale: f32 = 1.0;
override shadow_pcf_steps: i32 = 12;

// sky
override sun_angular_radius: f32 = 2.0;
override stars_intensity: f32 = 1.0;
override stars_coverage: f32 = 0.5;
override galaxy: bool = false;
override galaxy_intensity: f32 = 1.0;
override atmosphere_saturation_boost: f32 = 1.0;

// clouds
override clouds_cumulus: bool = true;
override clouds_quality: u32 = 1u;
override clouds_cumulus_coverage: f32 = 1.0;
override clouds_cumulus_density: f32 = 1.0;
override clouds_cumulus_altitude: f32 = 1200.0;
override clouds_wind_speed: f32 = 25.0;
override clouds_cirrus: bool = true;
override clouds_cirrus_coverage: f32 = 1.0;

// fog
override vl: bool = true;
override vl_intensity: f32 = 1.0;
override air_fog_density: f32 = 1.0;
override border_fog: bool = true;

// water
override water_wave_strength: f32 = 1.0;
override water_absorption: f32 = 1.0;
override water_texture: u32 = 1u;
override water_reflections: bool = true;

// post-processing
override bloom: bool = true;
override bloom_intensity: f32 = 1.0;
override auto_exposure: bool = true;
override manual_exposure: f32 = 0.0;
override tonemap_operator: u32 = 0u;
override grade_brightness: f32 = 1.0;
override grade_contrast: f32 = 1.0;
override grade_saturation: f32 = 1.0;
override grade_orange_sat_boost: f32 = 0.0;
override grade_teal_sat_boost: f32 = 0.1;
override grade_green_sat_boost: f32 = 0.0;
override purkinje_shift: bool = true;
override vignette_intensity: f32 = 1.0;
override motion_blur: bool = false;
override fxaa: bool = true;
override cas_intensity: f32 = 0.5;
