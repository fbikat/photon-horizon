# bakes photon's 3d textures into 2d pngs horizon can load
import sys, os, math, numpy as np
from PIL import Image

src, out = sys.argv[1], sys.argv[2]
img = os.path.join(src, 'image')

# scattering lut: 32 (mu_s) x 64 (mu) x 32 (nu) rgb16f -> 8x4 tiles of 32x64, rgbm with log2 m
lut = np.fromfile(os.path.join(img, 'atmosphere', 'scattering.dat'), dtype='<f2').astype(np.float64)
lut = np.maximum(lut.reshape(32, 64, 32, 3), 0.0)
m = np.maximum(lut.max(axis=3), 2.0 ** -25)
a = np.clip((np.log2(m) + 25.0) / 25.0, 0.0, 1.0)
m = 2.0 ** (np.round(a * 255.0) / 255.0 * 25.0 - 25.0)
rgb = np.clip(lut / m[..., None], 0.0, 1.0)
atlas = np.zeros((256, 256, 4), np.uint8)
for z in range(32):
    cx, cy = (z % 8) * 32, (z // 8) * 64
    atlas[cy:cy + 64, cx:cx + 32, :3] = np.round(rgb[z] * 255.0)
    atlas[cy:cy + 64, cx:cx + 32, 3] = np.round(a[z] * 255.0)
Image.fromarray(atlas, 'RGBA').save(os.path.join(out, 'scattering.png'), optimize=True)

# worley 64^3 r8 x2 -> 8x8 tiles of 66x66 (1 texel wrapped border), r bubbly g swirley
def worley(name):
    return np.fromfile(os.path.join(img, name), dtype=np.uint8).reshape(64, 64, 64)
wb, ws = worley('worley_bubbly.dat'), worley('worley_swirley.dat')
T = 66
w = np.zeros((8 * T, 8 * T, 4), np.uint8)
w[..., 3] = 255
idx = (np.arange(T) - 1) % 64
for z in range(64):
    cx, cy = (z % 8) * T, (z // 8) * T
    w[cy:cy + T, cx:cx + T, 0] = wb[z][np.ix_(idx, idx)]
    w[cy:cy + T, cx:cx + T, 1] = ws[z][np.ix_(idx, idx)]
Image.fromarray(w, 'RGBA').save(os.path.join(out, 'worley.png'), optimize=True)

# noise as is
Image.open(os.path.join(img, 'noise.png')).convert('RGBA').save(os.path.join(out, 'noise.png'), optimize=True)

# galaxy: halve to fit horizon's 1 mib per file limit
g = Image.open(os.path.join(img, 'galaxy.png')).convert('RGB').resize((1024, 512), Image.LANCZOS)
g.save(os.path.join(out, 'galaxy.png'), optimize=True)
for f in sorted(os.listdir(out)):
    print(f, os.path.getsize(os.path.join(out, f)))
