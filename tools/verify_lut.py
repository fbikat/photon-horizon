# checks that scattering.png decodes (as common.wgsl reads it) back to photon's scattering.dat
import sys, numpy as np
from PIL import Image

lut = np.maximum(np.fromfile(sys.argv[1], dtype='<f2').astype(np.float64).reshape(32, 64, 32, 3), 0.0)
atlas = np.asarray(Image.open(sys.argv[2]).convert('RGBA')).astype(np.float64) / 255.0
worst = 0.0
for z in range(32):
    tx, ty = (z % 8) * 32, (z // 8) * 64
    c = atlas[ty:ty + 64, tx:tx + 32]
    dec = c[..., :3] * np.exp2(c[..., 3:4] * 25.0 - 25.0)
    ref = lut[z]
    big = ref.max(axis=2) > 1e-4
    rel = np.abs(dec - ref).max(axis=2)[big] / ref.max(axis=2)[big]
    if rel.size:
        worst = max(worst, rel.max())
print('worst relative error of texels above 1e-4: %.4f' % worst)
