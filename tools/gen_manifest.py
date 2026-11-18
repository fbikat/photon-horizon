# writes pack/horizon-shaders.toml from one table, so pages and options stay in step
import os
import sys

F, I, B, C = 'float', 'int', 'bool', 'choice'
pages = [
    ('lighting', 'Lighting', 'Sun, sky, block light and foliage.', [
        ('sun_i', 'Sunlight Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('moon_i', 'Moonlight Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('skylight_i', 'Skylight Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('blocklight_i', 'Blocklight Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('blocklight_r', 'Blocklight Red', F, 1.0, 0.0, 1.0, 0.01, ''),
        ('blocklight_g', 'Blocklight Green', F, 0.75, 0.0, 1.0, 0.01, ''),
        ('blocklight_b', 'Blocklight Blue', F, 0.63, 0.0, 1.0, 0.01, ''),
        ('emission_strength', 'Emission Strength', F, 1.0, 0.0, 2.0, 0.05, 'How brightly light sources glow.'),
        ('shading_strength', 'Shading Strength', F, 1.0, 0.1, 2.0, 0.05, "How much the sun's angle darkens faces."),
        ('sss_intensity', 'Subsurface Scattering', F, 1.0, 0.0, 2.0, 0.05, 'Light passing through leaves and plants.'),
        ('bounced_light_i', 'Bounced Light', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('cave_lighting_i', 'Cave Lighting', F, 1.0, 0.0, 2.0, 0.05, 'Minimum light underground.'),
        ('specular_highlights', 'Specular Highlights', B, True, 'Sun highlights on smooth surfaces (LabPBR).'),
        ('ssao', 'Screen-Space AO', B, True, 'Contact ambient occlusion in crevices and corners.'),
        ('ao_intensity', 'AO Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('waving_plants', 'Waving Plants', B, True, ''),
        ('waving_leaves', 'Waving Leaves', B, True, ''),
    ]),
    ('shadows', 'Shadows', 'The sun and moon shadow map.', [
        ('shadows', 'Shadows', B, True, 'Off: no shadow map is drawn.'),
        ('shadow_resolution', 'Shadow Resolution', C, ['1024', '2048', '4096', '8192'], '2048', ''),
        ('shadow_distance', 'Shadow Distance', C, ['64', '96', '128', '192', '256', '384', '512'], '128', 'In blocks.'),
        ('shadow_vps', 'Variable Penumbra Shadows', B, True, 'Soft shadows that sharpen near their caster.'),
        ('colored_shadows', 'Colored Shadows', B, True, 'Light tinted by stained glass and water.'),
        ('shadow_penumbra_scale', 'Penumbra Scale', F, 1.0, 0.0, 2.0, 0.1, ''),
        ('shadow_pcf_steps', 'Shadow Filter Samples', I, 12, 4, 32, 1, ''),
    ]),
    ('sky', 'Sky', 'Atmosphere, sun and stars.', [
        ('sun_angular_radius', 'Sun Size', F, 2.0, 0.5, 4.0, 0.1, 'Angular radius in degrees.'),
        ('stars_intensity', 'Stars Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('stars_coverage', 'Stars Coverage', F, 0.5, 0.0, 1.0, 0.05, ''),
        ('galaxy', 'Galaxy', B, False, ''),
        ('galaxy_intensity', 'Galaxy Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('atmosphere_saturation_boost', 'Atmosphere Saturation Boost', F, 1.0, -1.0, 1.0, 0.05, ''),
    ]),
    ('clouds', 'Clouds', 'Volumetric clouds.', [
        ('clouds_cumulus', 'Cumulus Clouds', B, True, ''),
        ('clouds_quality', 'Cloud Quality', C, ['Low', 'Medium', 'High'], 'Medium', 'Raymarching steps.'),
        ('clouds_cumulus_coverage', 'Cumulus Coverage', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('clouds_cumulus_density', 'Cumulus Density', F, 1.0, 0.1, 2.0, 0.05, ''),
        ('clouds_cumulus_altitude', 'Cumulus Altitude', F, 1200.0, 400.0, 3000.0, 100.0, 'In metres of the sky model.'),
        ('clouds_wind_speed', 'Wind Speed', F, 25.0, 0.0, 60.0, 1.0, ''),
        ('clouds_cirrus', 'Cirrus Clouds', B, True, ''),
        ('clouds_cirrus_coverage', 'Cirrus Coverage', F, 1.0, 0.0, 2.0, 0.05, ''),
    ]),
    ('fog', 'Fog', 'Air fog and light shafts.', [
        ('vl', 'Volumetric Light', B, True, 'Light shafts through the shadow map.'),
        ('vl_intensity', 'Volumetric Light Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('air_fog_density', 'Air Fog Density', F, 1.0, 0.0, 4.0, 0.1, ''),
        ('border_fog', 'Border Fog', B, True, 'Fades terrain into the sky at the render distance.'),
    ]),
    ('water', 'Water', 'Waves, colour and reflections.', [
        ('water_wave_strength', 'Wave Strength', F, 1.0, 0.0, 2.0, 0.05, '0: flat water without waves.'),
        ('water_absorption', 'Water Absorption', F, 1.0, 0.0, 3.0, 0.05, 'How quickly light fades in water.'),
        ('water_texture', 'Water Texture', C, ['Off', 'Highlight', 'Vanilla'], 'Highlight', ''),
        ('water_reflections', 'Water Reflections', B, True, "Horizon's mirror of the world in water."),
    ]),
    ('post', 'Post-Processing', 'Bloom, colour grading and anti-aliasing.', [
        ('bloom', 'Bloom', B, True, ''),
        ('bloom_intensity', 'Bloom Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('auto_exposure', 'Auto Exposure', B, True, 'Adapts camera brightness smoothly to scene luminance.'),
        ('manual_exposure', 'Exposure (EV)', F, 0.0, -3.0, 3.0, 0.1, "Photon's manual exposure; higher is darker."),
        ('tonemap_operator', 'Tonemap', C, ['Lottes', 'ACES Fit', 'Hejl 2015', 'Uncharted 2', 'Tech', 'Reinhard-Jodie'], 'Lottes', ''),
        ('grade_brightness', 'Brightness', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('grade_contrast', 'Contrast', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('grade_saturation', 'Saturation', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('grade_orange_sat_boost', 'Orange Saturation Boost', F, 0.0, -0.5, 0.5, 0.01, ''),
        ('grade_teal_sat_boost', 'Teal Saturation Boost', F, 0.1, -0.5, 0.5, 0.01, ''),
        ('grade_green_sat_boost', 'Green Saturation Boost', F, 0.0, -0.5, 0.5, 0.01, ''),
        ('purkinje_shift', 'Purkinje Shift', B, True, 'Blue-shifted night vision.'),
        ('vignette_intensity', 'Vignette Intensity', F, 1.0, 0.0, 2.0, 0.05, '0: vignette off.'),
        ('motion_blur', 'Motion Blur', B, False, ''),
        ('fxaa', 'FXAA', B, True, ''),
        ('cas_intensity', 'Sharpening (CAS)', F, 0.5, 0.0, 1.0, 0.05, ''),
    ]),
]


def q(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


_here = os.path.dirname(os.path.abspath(__file__))
head_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(_here, 'manifest_head.toml')
out_path = sys.argv[2] if len(sys.argv) > 2 else os.path.normpath(os.path.join(_here, '..', 'pack', 'horizon-shaders.toml'))

out = [open(head_path, encoding='utf-8').read().rstrip() + '\n']
w = out.append
w('\n[[pages]]\nid = "main"\nname = "Photon"\ncolumns = 1\nitems = ['
  + ', '.join(q('page:' + p[0]) for p in pages) + ']\n')
for pid, name, desc, opts in pages:
    w(f'\n[[pages]]\nid = {q(pid)}\nname = {q(name)}\ndescription = {q(desc)}\nitems = ['
      + ', '.join(q(o[0]) for o in opts) + ']\n')
for _, _, _, opts in pages:
    for o in opts:
        oid, name, kind = o[0], o[1], o[2]
        w(f'\n[[options]]\nid = {q(oid)}\nname = {q(name)}\ntype = "{kind}"\n')
        if kind == F:
            d, lo, hi, st, desc = o[3:]
            w(f'default = {d}\nmin = {lo}\nmax = {hi}\nstep = {st}\n')
        elif kind == I:
            d, lo, hi, st, desc = o[3:]
            w(f'default = {d}\nmin = {lo}\nmax = {hi}\n')
        elif kind == B:
            d, desc = o[3:]
            w(f'default = {str(d).lower()}\n')
        else:
            vals, d, desc = o[3:]
            w('values = [' + ', '.join(q(v) for v in vals) + f']\ndefault = {q(d)}\n')
        if desc:
            w(f'description = {q(desc)}\n')
open(out_path, 'w', encoding='utf-8', newline='\n').write(''.join(out))
print(sum(len(p[3]) for p in pages), 'options')
