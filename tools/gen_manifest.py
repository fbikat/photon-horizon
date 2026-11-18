# writes pack/horizon-shaders.toml from one table, so pages and options stay in step
import os
import sys

F, I, B, C = 'float', 'int', 'bool', 'choice'
pages = [
    ('lighting', 'Lighting', 'Sun, sky, block light, surfaces and foliage.', [
        ('sun_i', 'Sunlight Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('moon_i', 'Moonlight Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('skylight_i', 'Skylight Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('blocklight_i', 'Blocklight Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('blocklight_warmth', 'Blocklight Warmth', F, 1.0, 0.0, 1.5, 0.05, '0: neutral white; 1.0: warm Photon torchlight.'),
        ('emission_strength', 'Emission Strength', F, 1.0, 0.0, 2.0, 0.05, 'How brightly light sources glow.'),
        ('shading_strength', 'Shading Strength', F, 1.0, 0.1, 2.0, 0.05, "How much the sun's angle darkens faces."),
        ('sss_intensity', 'Subsurface Scattering', F, 1.0, 0.0, 2.0, 0.05, 'Light passing through leaves and plants.'),
        ('bounced_light_i', 'Bounced Light', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('cave_lighting_i', 'Cave Lighting', F, 1.0, 0.0, 2.0, 0.05, 'Minimum light underground.'),
        ('specular_highlights', 'Specular Highlights', B, True, 'Sun highlights on smooth surfaces (LabPBR).'),
        ('rt_reflections', 'Ray-Traced Reflections', B, True, 'Hardware ray-traced water and smooth specular reflections.'),
        ('rain_puddles', 'Rain Puddles', B, True, 'Wet darkening, raindrop ripples and reflective puddles when wet.'),
        ('ssao', 'Screen-Space AO', B, True, 'Contact ambient occlusion in crevices and corners.'),
        ('ao_intensity', 'AO Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('waving_plants', 'Waving Plants', B, True, ''),
        ('waving_leaves', 'Waving Leaves', B, True, ''),
    ]),
    ('shadows', 'Shadows', 'Sun, moon, cloud and distant shadows.', [
        ('shadows', 'Shadows', B, True, 'Off: no shadow map is drawn.'),
        ('shadow_resolution', 'Shadow Resolution', C, ['1024', '2048', '4096', '8192'], '2048', ''),
        ('shadow_distance', 'Shadow Distance', C, ['64', '96', '128', '192', '256', '384', '512'], '128', 'In blocks.'),
        ('shadow_vps', 'Variable Penumbra Shadows', B, True, 'Soft shadows that sharpen near their caster.'),
        ('colored_shadows', 'Colored Shadows', B, True, 'Light tinted by stained glass and water.'),
        ('shadow_pcf_steps', 'Shadow Filter Samples', I, 12, 4, 32, 1, ''),
        ('rt_contact_shadows', 'Ray-Traced Contact Shadows', B, True, 'Hardware ray-traced near-field contact shadows.'),
        ('ssrt_shadows', 'Distant SSRT Shadows', B, True, 'Screen-space raymarched shadows beyond shadow map range.'),
        ('cloud_shadows', 'Cloud Shadows', B, True, 'Casts volumetric cloud shadows across terrain and fog.'),
    ]),
    ('sky', 'Sky', 'Atmosphere, moon, stars, aurora and rainbows.', [
        ('stars_intensity', 'Stars Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('galaxy', 'Galaxy', B, False, ''),
        ('galaxy_intensity', 'Galaxy Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('aurora', 'Aurora', C, ['Off', 'Snowy Biomes', 'Always'], 'Snowy Biomes', 'Northern lights in the night sky.'),
        ('rainbows', 'Rainbows', B, True, 'Renders rainbows opposite the sun after or during rain.'),
        ('crepuscular_rays', 'Crepuscular Rays', B, True, 'Volumetric sunbeams streaming around clouds.'),
    ]),
    ('clouds', 'Clouds', 'Volumetric and high-altitude clouds.', [
        ('clouds_cumulus', 'Cumulus Clouds', B, True, ''),
        ('clouds_quality', 'Cloud Quality', C, ['Low', 'Medium', 'High'], 'Medium', 'Medium adds altocumulus & noctilucent layers; High adds distant cumulus congestus.'),
        ('clouds_cumulus_coverage', 'Cumulus Coverage', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('clouds_cumulus_density', 'Cumulus Density', F, 1.0, 0.1, 2.0, 0.05, ''),
        ('clouds_cirrus', 'Cirrus Clouds', B, True, ''),
        ('clouds_cirrus_coverage', 'Cirrus Coverage', F, 1.0, 0.0, 2.0, 0.05, ''),
    ]),
    ('fog', 'Fog', 'Air fog and light shafts.', [
        ('vl', 'Volumetric Light', B, True, 'Light shafts through the shadow map.'),
        ('vl_intensity', 'Volumetric Light Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('air_fog_density', 'Air Fog Density', F, 1.0, 0.0, 4.0, 0.1, ''),
        ('border_fog', 'Border Fog', B, True, 'Fades terrain into the sky at the render distance.'),
    ]),
    ('water', 'Water', 'Waves, caustics, colour and reflections.', [
        ('water_wave_strength', 'Wave Strength', F, 1.0, 0.0, 2.0, 0.05, '0: flat water without waves.'),
        ('water_absorption', 'Water Absorption', F, 1.0, 0.0, 3.0, 0.05, 'How quickly light fades in water.'),
        ('water_texture', 'Water Texture', C, ['Off', 'Highlight', 'Vanilla'], 'Highlight', ''),
        ('water_reflections', 'Water Reflections', B, True, 'Ray-traced and screen-space reflections in water.'),
        ('water_caustics', 'Water Caustics', B, True, 'Dancing sunlight patterns projected onto underwater surfaces.'),
    ]),
    ('post', 'Post-Processing', 'Bloom, depth of field, colour grading and anti-aliasing.', [
        ('bloom', 'Bloom', B, True, ''),
        ('bloom_intensity', 'Bloom Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('auto_exposure', 'Auto Exposure', B, True, 'Adapts camera brightness smoothly to scene luminance.'),
        ('manual_exposure', 'Exposure (EV)', F, 0.0, -3.0, 3.0, 0.1, "Photon's manual exposure; higher is darker."),
        ('tonemap_operator', 'Tonemap', C, ['Lottes', 'ACES Fit', 'Hejl 2015', 'Uncharted 2', 'Tech', 'Reinhard-Jodie'], 'Lottes', ''),
        ('grade_brightness', 'Brightness', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('grade_contrast', 'Contrast', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('grade_saturation', 'Saturation', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('grade_vibrance', 'Colour Vibrance', F, 0.0, -0.5, 0.5, 0.01, 'Selective saturation trim around teal/orange/green; 0 matches Photon default.'),
        ('purkinje_shift', 'Purkinje Shift', B, True, 'Blue-shifted night vision.'),
        ('vignette_intensity', 'Vignette Intensity', F, 1.0, 0.0, 2.0, 0.05, '0: vignette off.'),
        ('dof', 'Depth of Field', B, False, 'Bokeh focus blur around center-screen distance.'),
        ('dof_intensity', 'DoF Intensity', F, 1.0, 0.0, 2.0, 0.05, 'Strength of Depth of Field blur.'),
        ('taa', 'Temporal AA (TAA)', B, False, 'Camera-reprojected TAA; moving mobs can ghost without object motion vectors.'),
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
