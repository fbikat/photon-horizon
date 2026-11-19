# writes pack/horizon-shaders.toml from one table, so pages and options stay in step;
# --zh [DIR]: also a Chinese build of the pack (default dist/photon_zh);
# --install [SHADERPACKS]: copies the pack into Horizon's shaderpacks folder, in the game's language
import os
import re
import shutil
import sys

F, I, B, C = 'float', 'int', 'bool', 'choice'
pages = [
    ('lighting', 'Lighting', 'Sun, sky, block light, surfaces and foliage.', [
        ('sun_i', 'Sunlight Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('moon_i', 'Moonlight Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('skylight_i', 'Skylight Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('blocklight_i', 'Blocklight Intensity', F, 1.0, 0.0, 2.0, 0.05, ''),
        ('blocklight_warmth', 'Blocklight Warmth', F, 1.0, 0.0, 1.5, 0.05, '0: neutral white; 1.0: warm Photon torchlight.'),
        ('colored_lights', 'Coloured Light', B, True, "On: coloured block lights from the light grid; off: Photon's default, one warm colour for every block light."),
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
        ('vl_twilight', 'Dawn & Dusk Shafts', F, 2.0, 0.0, 3.0, 0.1, 'Brighter, deeper light shafts while the sun is low. 1.0: as Photon.'),
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
        ('bloom_intensity', 'Bloom Intensity', F, 1.0, 0.0, 2.0, 0.05, '0 turns bloom off.'),
        ('auto_exposure', 'Auto Exposure', B, False, "Adapts brightness to the scene. Off, as in Photon: rain and dusk stay darker than noon."),
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
        ('motion_blur', 'Motion Blur', B, False, ''),
        ('anti_aliasing', 'Anti-Aliasing', C, ['Off', 'FXAA', 'SMAA'], 'SMAA', 'SMAA: crisper edges than FXAA, with less blur.'),
        ('cas_intensity', 'Sharpening (CAS)', F, 0.5, 0.0, 1.0, 0.05, ''),
    ]),
]


# The Chinese build: Horizon's native packs have no language files (a manifest's names are shown as written), so
# the pack is built in the game's language when it is installed. Same id, so the selection and the option values
# (`shaderpacks/.horizon-options/photon.txt`, a choice saved as its index) are shared by both builds.
ZH_HEAD = {
    'description':'SixthSurge 的 Photon 光影，移植到 Horizon 光影 API：大气散射、月相、末地黑洞、多层体积云、云影、极光、'
                   '彩虹、SSRT 与光追阴影、彩色方块光、雨天水坑、水下焦散、5 级泛光，以及可选的景深。',
}
ZH = {
    # pages
    'Lighting': '光照', 'Sun, sky, block light, surfaces and foliage.': '阳光、天空光、方块光、表面与植物。',
    'Shadows': '阴影', 'Sun, moon, cloud and distant shadows.': '日月阴影、云影和远处的阴影。',
    'Sky': '天空', 'Atmosphere, moon, stars, aurora and rainbows.': '大气、月亮、星星、极光和彩虹。',
    'Clouds': '云', 'Volumetric and high-altitude clouds.': '体积云和高空云。',
    'Fog': '雾', 'Air fog and light shafts.': '空气雾和光束。',
    'Water': '水', 'Waves, caustics, colour and reflections.': '波浪、焦散、颜色和反射。',
    'Post-Processing': '后期处理',
    'Bloom, depth of field, colour grading and anti-aliasing.': '泛光、景深、调色和抗锯齿。',
    # lighting
    'Sunlight Intensity': '阳光强度', 'Moonlight Intensity': '月光强度', 'Skylight Intensity': '天空光强度',
    'Blocklight Intensity': '方块光强度', 'Blocklight Warmth': '方块光暖色',
    '0: neutral white; 1.0: warm Photon torchlight.': '0：中性白光；1.0：Photon 的暖色火把光。',
    'Emission Strength': '自发光强度', 'How brightly light sources glow.': '光源本身发光的亮度。',
    'Shading Strength': '明暗强度', "How much the sun's angle darkens faces.": '太阳角度让各个面变暗的程度。',
    'Subsurface Scattering': '次表面散射', 'Light passing through leaves and plants.': '光线透过树叶和植物。',
    'Bounced Light': '反弹光', 'Cave Lighting': '洞穴照明', 'Minimum light underground.': '地下的最低亮度。',
    'Specular Highlights': '镜面高光', 'Sun highlights on smooth surfaces (LabPBR).': '光滑表面上的太阳高光（LabPBR）。',
    'Ray-Traced Reflections': '光追反射',
    'Hardware ray-traced water and smooth specular reflections.': '硬件光线追踪的水面和光滑表面反射。',
    'Rain Puddles': '雨天水坑',
    'Wet darkening, raindrop ripples and reflective puddles when wet.': '下雨时表面变湿变暗，出现雨滴涟漪和反光水坑。',
    'Screen-Space AO': '屏幕空间环境光遮蔽', 'Contact ambient occlusion in crevices and corners.': '缝隙和角落里的接触阴影。',
    'AO Intensity': '环境光遮蔽强度', 'Waving Plants': '植物摆动', 'Waving Leaves': '树叶摆动',
    # shadows
    'Off: no shadow map is drawn.': '关闭后不绘制阴影贴图。', 'Shadow Resolution': '阴影分辨率',
    'Shadow Distance': '阴影距离', 'In blocks.': '单位：格。',
    'Variable Penumbra Shadows': '可变半影阴影', 'Soft shadows that sharpen near their caster.': '柔和的阴影，靠近投影物处变清晰。',
    'Colored Shadows': '彩色阴影', 'Light tinted by stained glass and water.': '透过染色玻璃和水的光会带上颜色。',
    'Shadow Filter Samples': '阴影过滤采样数', 'Ray-Traced Contact Shadows': '光追接触阴影',
    'Hardware ray-traced near-field contact shadows.': '硬件光线追踪的近处接触阴影。',
    'Distant SSRT Shadows': '远处 SSRT 阴影',
    'Screen-space raymarched shadows beyond shadow map range.': '阴影贴图范围之外，用屏幕空间光线步进补上的阴影。',
    'Cloud Shadows': '云影', 'Casts volumetric cloud shadows across terrain and fog.': '体积云投在地面和雾里的阴影。',
    # sky
    'Stars Intensity': '星星亮度', 'Galaxy': '银河', 'Galaxy Intensity': '银河亮度',
    'Aurora': '极光', 'Snowy Biomes': '雪地群系', 'Always': '所有群系',
    'Northern lights in the night sky.': '夜空中的北极光。雪地群系：只在会下雪的群系出现，每晚都有。',
    'Rainbows': '彩虹', 'Renders rainbows opposite the sun after or during rain.': '雨中或雨后在太阳对面出现彩虹。',
    'Crepuscular Rays': '云隙光', 'Volumetric sunbeams streaming around clouds.': '从云的缝隙间射出的体积光束。',
    # clouds
    'Cumulus Clouds': '积云', 'Cloud Quality': '云质量', 'Low': '低', 'Medium': '中', 'High': '高',
    'Medium adds altocumulus & noctilucent layers; High adds distant cumulus congestus.':
        '中：加上高积云和夜光云；高：再加上远处的浓积云（Photon 默认就有）。',
    'Cumulus Coverage': '积云覆盖率', 'Cumulus Density': '积云密度',
    'Cirrus Clouds': '卷云', 'Cirrus Coverage': '卷云覆盖率',
    # fog
    'Volumetric Light': '体积光', 'Light shafts through the shadow map.': '穿过阴影贴图的光束。',
    'Volumetric Light Intensity': '体积光强度', 'Air Fog Density': '空气雾浓度',
    'Dawn & Dusk Shafts': '晨昏光柱',
    'Brighter, deeper light shafts while the sun is low. 1.0: as Photon.': '太阳低时光柱更亮、明暗更分明。1.0：与 Photon 相同。',
    'Border Fog': '边界雾', 'Fades terrain into the sky at the render distance.': '在渲染距离边缘让地形淡入天空。',
    # water
    'Wave Strength': '波浪强度', '0: flat water without waves.': '0：没有波浪的平静水面。',
    'Water Absorption': '水体吸光', 'How quickly light fades in water.': '光在水中衰减的快慢。',
    'Water Texture': '水面纹理', 'Highlight': '高光', 'Vanilla': '原版',
    'Water Reflections': '水面反射', 'Ray-traced and screen-space reflections in water.': '光追和屏幕空间的水面反射。',
    'Water Caustics': '水下焦散',
    'Dancing sunlight patterns projected onto underwater surfaces.': '投在水下表面、随波晃动的阳光纹路。',
    # post
    'Coloured Light': '彩色光', "On: coloured block lights from the light grid; off: Photon's default, one warm colour for every block light.": '开：灯光按方块带颜色（光源格子）；关：Photon 默认，所有方块光都是同一种暖色。', 'Bloom Intensity': '泛光强度', '0 turns bloom off.': '0 为关闭泛光。', 'Auto Exposure': '自动曝光',
    'Adapts brightness to the scene. Off, as in Photon: rain and dusk stay darker than noon.':
        '根据场景自动调整亮度。默认关闭，与 Photon 一致：雨天和黄昏会比正午暗。',
    'Exposure (EV)': '曝光（EV）', "Photon's manual exposure; higher is darker.": 'Photon 的手动曝光；数值越高越暗。',
    'Tonemap': '色调映射', 'Brightness': '亮度', 'Contrast': '对比度', 'Saturation': '饱和度',
    'Colour Vibrance': '自然饱和度',
    'Selective saturation trim around teal/orange/green; 0 matches Photon default.':
        '针对青、橙、绿色调的饱和度微调；0 与 Photon 默认一致。',
    'Purkinje Shift': '浦肯野效应', 'Blue-shifted night vision.': '夜间视觉偏蓝。',
    'Vignette Intensity': '暗角强度', '0: vignette off.': '0：关闭暗角。',
    'Depth of Field': '景深', 'Bokeh focus blur around center-screen distance.': '对焦在屏幕中心的距离，其余部分散景模糊。',
    'DoF Intensity': '景深强度', 'Strength of Depth of Field blur.': '景深模糊的强度。',
    'Motion Blur': '动态模糊', 'Anti-Aliasing': '抗锯齿', 'Off': '关',
    'SMAA: crisper edges than FXAA, with less blur.': 'SMAA：边缘比 FXAA 更清晰，画面更不糊。',
    'Sharpening (CAS)': '锐化（CAS）',
}
# shown as they are in Chinese too: numbers and proper names
ZH_KEEP = {'Photon', 'FXAA', 'SMAA', 'Lottes', 'ACES Fit', 'Hejl 2015', 'Uncharted 2', 'Tech', 'Reinhard-Jodie'}


def q(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def manifest(head, tr):
    out = [head.rstrip() + '\n']
    w = out.append
    w('\n[[pages]]\nid = "main"\nname = "Photon"\ncolumns = 1\nitems = ['
      + ', '.join(q('page:' + p[0]) for p in pages) + ']\n')
    for pid, name, desc, opts in pages:
        w(f'\n[[pages]]\nid = {q(pid)}\nname = {q(tr(name))}\ndescription = {q(tr(desc))}\nitems = ['
          + ', '.join(q(o[0]) for o in opts) + ']\n')
    for _, _, _, opts in pages:
        for o in opts:
            oid, name, kind = o[0], o[1], o[2]
            w(f'\n[[options]]\nid = {q(oid)}\nname = {q(tr(name))}\ntype = "{kind}"\n')
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
                w('values = [' + ', '.join(q(tr(v)) for v in vals) + f']\ndefault = {q(tr(d))}\n')
            if desc:
                w(f'description = {q(tr(desc))}\n')
    return ''.join(out)


def zh(s):
    if s in ZH:
        return ZH[s]
    if s in ZH_KEEP or s.isdigit():
        return s
    sys.exit(f'no Chinese for {s!r}: add it to ZH (or ZH_KEEP)')


def zh_head(head):
    for key, value in ZH_HEAD.items():
        head, n = re.subn(rf'^{key} = .*$', lambda _: f'{key} = {q(value)}', head, count=1, flags=re.M)
        assert n == 1, key
    return head


def pack_id(head):
    return re.search(r'^id = "([a-z0-9_]+)"$', head, flags=re.M).group(1)


def write_pack(src, dest, head, chinese):
    """dest: a copy of the pack at src, its manifest in English or Chinese. A pack may hold only the files it uses,
    so a previous copy there is replaced, and only when it is one (a folder holding this pack's manifest)."""
    old = os.path.join(dest, 'horizon-shaders.toml')
    if os.path.exists(dest):
        if not (os.path.isfile(old) and f'id = {q(pack_id(head))}' in open(old, encoding='utf-8').read()):
            sys.exit(f'{dest} exists and is not a copy of this pack; not replacing it')
        shutil.rmtree(dest)
    shutil.copytree(src, dest, ignore=shutil.ignore_patterns('horizon-shaders.toml'))
    text = manifest(zh_head(head), zh) if chinese else manifest(head, lambda s: s)
    open(old, 'w', encoding='utf-8', newline='\n').write(text)


def game_language(shaderpacks):
    """The `lang:` of the options.txt beside the shaderpacks folder (Horizon's, as Minecraft's), else en_us."""
    try:
        text = open(os.path.join(shaderpacks, '..', 'options.txt'), encoding='utf-8').read()
    except OSError:
        return 'en_us'
    found = re.search(r'^lang:(\S+)', text, flags=re.M)
    return found.group(1).lower() if found else 'en_us'


def take(args, flag, default):
    """Removes `flag` and the value after it from args (flags go after the two paths): that value, else `default`
    when no value follows, else None without the flag."""
    if flag not in args:
        return None
    i = args.index(flag)
    value = args.pop(i + 1) if i + 1 < len(args) and not args[i + 1].startswith('--') else default
    args.pop(i)
    return value


_here = os.path.dirname(os.path.abspath(__file__))
_root = os.path.normpath(os.path.join(_here, '..'))
args = sys.argv[1:]
# --zh [DIR]: also the Chinese build (default dist/photon_zh), to pack as a .hshader
zh_dest = take(args, '--zh', os.path.join(_root, 'dist', 'photon_zh'))
# --install [SHADERPACKS]: copy the pack into Horizon's shaderpacks folder as photon/, in the game's language
install_dir = take(args, '--install', os.path.join(os.environ.get('APPDATA', ''), 'horizon', 'shaderpacks'))
head_path = args[0] if len(args) > 0 else os.path.join(_here, 'manifest_head.toml')
out_path = args[1] if len(args) > 1 else os.path.join(_root, 'pack', 'horizon-shaders.toml')

head = open(head_path, encoding='utf-8').read()
open(out_path, 'w', encoding='utf-8', newline='\n').write(manifest(head, lambda s: s))
print(sum(len(p[3]) for p in pages), 'options')
src = os.path.dirname(os.path.abspath(out_path))
if zh_dest:
    write_pack(src, zh_dest, head, chinese=True)
    print('Chinese build:', zh_dest)
if install_dir:
    lang = game_language(install_dir)
    dest = os.path.join(install_dir, pack_id(head))
    write_pack(src, dest, head, chinese=lang.startswith('zh'))
    print(f'installed for {lang}:', dest)
